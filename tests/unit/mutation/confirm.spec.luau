--!strict
-- The confirmation gate. Each predicate exists because skipping it would let
-- a mutation run against something other than what the user saw: a failed
-- preview (nothing was shown), a sloppy typed token (no real acknowledgment),
-- an inferred context (maybe the wrong cluster), changed inputs (stale diff).
local Confirm = require("../../../plugin/lib/mutation/confirm")
local Plan = require("../../../plugin/lib/mutation/plan")
local Risk = require("../../../plugin/lib/mutation/risk")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local FP = string.rep("a", 64)

local function config(over: { [string]: boolean }?): Confirm.ConfigLike
	local m: Confirm.MutationsConfig = {
		enabled = true,
		require_target_confirmation = true,
		allow_failed_preview_override = false,
	}
	for k, v in over or {} :: { [string]: boolean } do
		(m :: any)[k] = v
	end
	return { mutations = m }
end

local function plan(line: string, source: T.ContextSource?): T.Plan
	local p = Plan.fromArgv(string.split(line, " "), {
		context = "kind-dev",
		contextSource = source or "chosen",
		namespace = "apps",
		cwd = "/w",
	})
	return p :: T.Plan
end

local function preview(p: T.Plan, facts: Risk.Facts): Confirm.Preview
	return { assessment = Risk.assess(p, facts), fingerprint = FP }
end

local WEB = { { kind = "Pod", name = "web", namespace = "apps", source = "live" } } :: any

describe("confirm: simple tier", function()
	it("confirms an ordinary scale with an unchanged fingerprint", function()
		local p = plan("kubectl scale deploy/web --replicas=2")
		expect((Confirm.canConfirm(p, preview(p, { previewOk = true }), { fingerprint = FP }, config()))).toBe(true)
	end)

	it("refuses when mutations are disabled", function()
		local p = plan("kubectl scale deploy/web --replicas=2")
		local ok, why =
			Confirm.canConfirm(p, preview(p, { previewOk = true }), { fingerprint = FP }, config({ enabled = false }))
		expect(ok).toBe(false)
		expect(why).toContain("disabled")
	end)
end)

describe("confirm: fingerprint", function()
	it("blocks when inputs changed since the preview", function()
		local p = plan("kubectl apply -f a.yaml")
		local ok, why =
			Confirm.canConfirm(p, preview(p, { previewOk = true }), { fingerprint = string.rep("b", 64) }, config())
		expect(ok).toBe(false)
		expect(why).toContain("fingerprint mismatch")
	end)

	it("blocks when either fingerprint is missing (unverified never confirms)", function()
		local p = plan("kubectl apply -f a.yaml")
		expect((Confirm.canConfirm(p, preview(p, { previewOk = true }), {}, config()))).toBe(false)
		local pv = preview(p, { previewOk = true })
		pv.fingerprint = nil
		expect((Confirm.canConfirm(p, pv, { fingerprint = FP }, config()))).toBe(false)
	end)

	it("compares hex case-insensitively", function()
		local p = plan("kubectl apply -f a.yaml")
		local pv = preview(p, { previewOk = true })
		pv.fingerprint = string.rep("AB", 32)
		expect((Confirm.canConfirm(p, pv, { fingerprint = string.rep("ab", 32) }, config()))).toBe(true)
	end)
end)

describe("confirm: typed tier", function()
	it("requires the exact token: no trimming, no case folding", function()
		local p = plan("kubectl delete pod web")
		local pv = preview(p, { previewOk = true, targets = WEB })
		expect(Confirm.requirements(p, pv, config()).typed).toBe("web")
		for _, wrong in { "", "web ", " web", "WEB", "we" } do
			local ok, why = Confirm.canConfirm(p, pv, { fingerprint = FP, typed = wrong }, config())
			expect(ok).toBe(false)
			expect(why).toBe('Type "web" exactly to confirm')
		end
		expect((Confirm.canConfirm(p, pv, { fingerprint = FP }, config()))).toBe(false)
		expect((Confirm.canConfirm(p, pv, { fingerprint = FP, typed = "web" }, config()))).toBe(true)
	end)

	it("asks multi-object deletes for the phrase", function()
		local p = plan("kubectl delete pods -l app=web")
		local targets = {
			{ kind = "Pod", name = "a", namespace = "apps", source = "live" },
			{ kind = "Pod", name = "b", namespace = "apps", source = "live" },
		} :: any
		local pv = preview(p, { previewOk = true, targets = targets })
		expect((Confirm.canConfirm(p, pv, { fingerprint = FP, typed = "a" }, config()))).toBe(false)
		expect((Confirm.canConfirm(p, pv, { fingerprint = FP, typed = "delete 2 resources" }, config()))).toBe(true)
	end)
end)

describe("confirm: failed preview", function()
	local p = plan("kubectl delete pod web")
	local failed = preview(p, { previewOk = false, failure = "Forbidden" })

	it("blocks by default, even with override and the right token", function()
		local ok, why = Confirm.canConfirm(p, failed, { fingerprint = FP, override = true, typed = "web" }, config())
		expect(ok).toBe(false)
		expect(why).toBe("The preview failed: Forbidden (mutations.allow_failed_preview_override is off)")
		expect(Confirm.requirements(p, failed, config()).overrideAvailable).toBe(false)
	end)

	it("with the config gate open, still needs an explicit override", function()
		local cfg = config({ allow_failed_preview_override = true })
		local ok, why = Confirm.canConfirm(p, failed, { fingerprint = FP, typed = "web" }, cfg)
		expect(ok).toBe(false)
		expect(why).toContain("Override")
	end)

	it("an override escalates even a simple command to the typed tier", function()
		local cfg = config({ allow_failed_preview_override = true })
		local scale = plan("kubectl scale deploy/web --replicas=2")
		local pv = preview(scale, { previewOk = false, failure = "timeout" })
		expect(Confirm.requirements(scale, pv, cfg).typed).toBe("web")
		expect((Confirm.canConfirm(scale, pv, { fingerprint = FP, override = true }, cfg))).toBe(false)
		expect((Confirm.canConfirm(scale, pv, { fingerprint = FP, override = true, typed = "web" }, cfg))).toBe(true)
	end)

	it("an unfinished preview can never be overridden", function()
		local cfg = config({ allow_failed_preview_override = true })
		local pv = preview(p, {})
		local ok, why = Confirm.canConfirm(p, pv, { fingerprint = FP, override = true, typed = "web" }, cfg)
		expect(ok).toBe(false)
		expect(why).toBe("The preview has not finished")
	end)
end)

describe("confirm: target", function()
	it("an inferred context needs explicit target confirmation", function()
		local p = plan("kubectl scale deploy/web --replicas=2", "inferred")
		local pv = preview(p, { previewOk = true })
		local ok, why = Confirm.canConfirm(p, pv, { fingerprint = FP }, config())
		expect(ok).toBe(false)
		expect(why).toContain("kind-dev")
		expect((Confirm.canConfirm(p, pv, { fingerprint = FP, targetConfirmed = true }, config()))).toBe(true)
	end)

	it("is not asked for flag or chosen contexts, nor when config turns it off", function()
		local flagged = plan("kubectl --context kind-dev scale deploy/web --replicas=2", "inferred")
		expect((Confirm.canConfirm(flagged, preview(flagged, { previewOk = true }), { fingerprint = FP }, config()))).toBe(
			true
		)
		local inferred = plan("kubectl scale deploy/web --replicas=2", "inferred")
		expect(
			(
				Confirm.canConfirm(
					inferred,
					preview(inferred, { previewOk = true }),
					{ fingerprint = FP },
					config({ require_target_confirmation = false })
				)
			)
		).toBe(true)
	end)
end)

return nil
