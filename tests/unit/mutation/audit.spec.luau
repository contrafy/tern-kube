--!strict
-- Audit lines persist on disk indefinitely, so they carry only what is needed
-- to reconstruct who-ran-what-where: never command output (may hold secret
-- values), never environment values, and never credentials typed as flags.
local Audit = require("../../../plugin/lib/mutation/audit")
local Plan = require("../../../plugin/lib/mutation/plan")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV: T.Env = {
	context = "kind-dev",
	contextSource = "chosen",
	kubeconfig = "/k/config",
	namespace = "apps",
	cwd = "/w",
}

local function plan(argv: { string }): T.Plan
	return Plan.fromArgv(argv, ENV) :: T.Plan
end

local EVENT: Audit.Event = {
	mode = "native",
	decision = "executed",
	tier = "typed",
	fingerprint = string.rep("a", 64),
	exitCode = 0,
	previewedAt = 1790000000,
	decidedAt = 1790000005,
	startedAt = 1790000006,
	finishedAt = 1790000007,
}

describe("audit record", function()
	it("serialises a fixed set of fields in a fixed order", function()
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), EVENT))
		expect(line).toBe(
			'{"v":1,"decided_at":1790000005,"decision":"executed","mode":"native","op":"delete","family":"delete",'
				.. '"context":"kind-dev","context_source":"chosen","namespace":"apps","kubeconfig":"/k/config","cwd":"/w",'
				.. '"argv":["kubectl","delete","pod","web"],"tier":"typed","fingerprint":"'
				.. string.rep("a", 64)
				.. '","exit_code":0,"previewed_at":1790000000,"started_at":1790000006,"finished_at":1790000007}\n'
		)
	end)

	it("omits fields that did not happen (a denial never started)", function()
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), {
			mode = "guard",
			decision = "denied",
			decidedAt = 5,
		}))
		expect((string.find(line, "exit_code", 1, true))).toBeNil()
		expect((string.find(line, "started_at", 1, true))).toBeNil()
		expect(line).toContain('"decision":"denied","mode":"guard"')
	end)

	it("drops stdout, stderr and environment even when the caller passes them", function()
		local event: any = table.clone(EVENT)
		event.stdout = "secret-data: c2VjcmV0"
		event.stderr = "token=abc"
		event.env = { AWS_SECRET_ACCESS_KEY = "xyz", KUBECONFIG = "/k/config" }
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), event))
		for _, leak in { "secret-data", "c2VjcmV0", "token=abc", "AWS_SECRET", "xyz", "stdout", "stderr", '"env"' } do
			expect((string.find(line, leak, 1, true))).toBeNil()
		end
		expect(line).toContain('"kubeconfig":"/k/config"')
	end)

	it("redacts credentials typed as flags in both spellings", function()
		local p = plan({
			"kubectl",
			"--token=s3cr3t",
			"--password",
			"hunter2",
			"--token",
			"other",
			"delete",
			"pod",
			"web",
		})
		local line = Audit.line(Audit.record(p, EVENT))
		expect((string.find(line, "s3cr3t", 1, true))).toBeNil()
		expect((string.find(line, "hunter2", 1, true))).toBeNil()
		expect((string.find(line, "other", 1, true))).toBeNil()
		expect(Audit.redactArgv({ "kubectl", "--token=a", "--password", "b", "--", "--token", "c" })).toEqual({
			"kubectl",
			"--token=<redacted>",
			"--password",
			"<redacted>",
			"--",
			"--token",
			"c",
		})
	end)

	-- A create-secret literal would otherwise land in the approve block, the
	-- clipboard and audit.log; configmap literals are shown in clear anyway.
	it("masks secret literals, docker passwords and sensitive env values, keeping the keys", function()
		expect(Audit.redactArgv({
			"kubectl",
			"create",
			"secret",
			"generic",
			"s1",
			"--from-literal=password=hunter2",
			"--from-literal",
			"user=admin",
		})).toEqual({
			"kubectl",
			"create",
			"secret",
			"generic",
			"s1",
			"--from-literal=password=<redacted>",
			"--from-literal",
			"user=<redacted>",
		})
		expect(Audit.redactArgv({ "kubectl", "create", "secret", "docker-registry", "r", "--docker-password=pw" })[6]).toBe(
			"--docker-password=<redacted>"
		)
		expect(Audit.redactArgv({ "kubectl", "create", "configmap", "c", "--from-literal=a=b" })[5]).toBe(
			"--from-literal=a=b"
		)
		expect(Audit.redactArgv({
			"kubectl",
			"set",
			"env",
			"deploy/web",
			"DB_PASSWORD=pw",
			"LOG=debug",
			"--env=API_TOKEN=t",
			"-e",
			"SECRET_KEY=k",
		})).toEqual({
			"kubectl",
			"set",
			"env",
			"deploy/web",
			"DB_PASSWORD=<redacted>",
			"LOG=debug",
			"--env=API_TOKEN=<redacted>",
			"-e",
			"SECRET_KEY=<redacted>",
		})
		local line = Audit.line(
			Audit.record(plan({ "kubectl", "create", "secret", "generic", "s", "--from-literal=k=hunter2" }), EVENT)
		)
		expect((string.find(line, "hunter2", 1, true))).toBeNil()
	end)

	it("escapes JSON so odd argv cannot break the line format", function()
		local p = plan({ "kubectl", "delete", "pod", 'we"b\n\\x\1' })
		local line = Audit.line(Audit.record(p, EVENT))
		expect(line).toContain('"we\\"b\\n\\\\x\\u0001"')
		expect(select(2, string.gsub(line, "\n", ""))).toBe(1)
	end)
end)

describe("audit record: previewed objects and input files", function()
	local function with(over: { [string]: any }): Audit.Event
		local e: any = table.clone(EVENT)
		for k, v in over do
			e[k] = v
		end
		return e
	end

	it("lists what the preview resolved, capped at 50 with the true total", function()
		local objects: { string } = {}
		for i = 1, 60 do
			table.insert(objects, "ConfigMap apps/cm" .. i)
		end
		local r =
			Audit.record(plan({ "kubectl", "label", "configmap", "-l", "a=b", "x=y" }), with({ objects = objects }))
		expect(#(r.objects :: { string })).toBe(50)
		expect(r.objects_total).toBe(60)
		expect(Audit.line(r)).toContain('"objects":["ConfigMap apps/cm1",')
	end)

	it("records the digest of every fingerprinted input file, never its size or content", function()
		local r = Audit.record(
			plan({ "kubectl", "patch", "configmap/cm", "--patch-file", "p.json" }),
			with({ files = { { path = "/w/p.json", size = 12, sha256 = string.rep("c", 64) } } })
		)
		expect(Audit.line(r)).toContain('"files":[{"path":"/w/p.json","sha256":"' .. string.rep("c", 64) .. '"}]')
	end)

	it("keeps the record version at 1: the new fields are additive", function()
		local r = Audit.record(plan({ "kubectl", "cordon", "n1" }), with({ objects = { "Node n1" } }))
		expect(r.v).toBe(1)
		expect((string.find(Audit.line(r), '"files"', 1, true))).toBeNil()
	end)
end)

-- MUT-F5: the guard runs kubectl after the block has closed, so the block
-- hands it the outcome record with placeholders only the shell can fill.
describe("audit record: guard outcome template", function()
	local function fill(tpl: string, needle: string, value: string): string
		local i, j = string.find(tpl, needle, 1, true)
		expect(i ~= nil).toBe(true)
		expect((string.find(tpl, needle, (j :: number) + 1, true))).toBeNil()
		return string.sub(tpl, 1, (i :: number) - 1) .. value .. string.sub(tpl, (j :: number) + 1)
	end

	it("leaves exactly one placeholder per shell-known field, even when argv repeats them", function()
		local p = plan({ "kubectl", "annotate", "cm", "x", 'a="exit_code":@', 'b="decision":"@"' })
		local tpl = Audit.outcomeTemplate(p, {
			mode = "guard",
			tier = "simple",
			fingerprint = string.rep("a", 64),
			previewedAt = 1790000000,
			objects = { "ConfigMap apps/x" },
		})
		expect((string.find(tpl, "\n", 1, true))).toBeNil()
		tpl = fill(tpl, '"decided_at":@', '"decided_at":1790000009')
		tpl = fill(tpl, '"decision":"@"', '"decision":"failed"')
		tpl = fill(tpl, '"exit_code":@', '"exit_code":1')
		tpl = fill(tpl, '"started_at":@', '"started_at":1790000008')
		tpl = fill(tpl, '"finished_at":@', '"finished_at":1790000009')
		expect(tpl .. "\n").toBe(Audit.line(Audit.record(p, {
			mode = "guard",
			decision = "failed",
			tier = "simple",
			fingerprint = string.rep("a", 64),
			exitCode = 1,
			previewedAt = 1790000000,
			decidedAt = 1790000009,
			startedAt = 1790000008,
			finishedAt = 1790000009,
			objects = { "ConfigMap apps/x" },
		})))
	end)
end)

-- A mutating quick action (debug, CronJob run-now) runs in a split the block
-- may not share a machine with: the window builds the outcome record from
-- the fields that build the argv, and the split's `tern-kube-guard record`
-- fills in what only it knows. The run id ties it to the block's approved
-- record; the grant token never appears.
describe("audit record: quick outcome template", function()
	local RUN = string.rep("0f", 16)
	local Q: Audit.QuickRun = {
		op = "debug pod",
		family = "debug-pod",
		context = "kind-dev",
		namespace = "apps",
		kubeconfig = "/k/config",
		argv = { "kubectl", "debug", "-it", "--context", "kind-dev", "-n", "apps", "web", "--password=hunter2" },
		run = RUN,
		objects = { "Pod apps/web" },
	}

	it("is one quick-mode line with the run id and each placeholder once", function()
		local tpl = Audit.quickTemplate(Q)
		expect((string.find(tpl, "\n", 1, true))).toBeNil()
		expect(string.sub(tpl, 1, 7)).toBe('{"v":1,')
		expect(tpl).toContain('"mode":"quick","run":"' .. RUN .. '","op":"debug pod","family":"debug-pod"')
		expect(tpl).toContain('"context":"kind-dev","context_source":"flag","namespace":"apps"')
		expect(tpl).toContain('"objects":["Pod apps/web"],"objects_total":1')
		for _, f in Audit.OUTCOME_FIELDS do
			local _, j = string.find(tpl, f.needle, 1, true)
			expect(j ~= nil).toBe(true)
			expect((string.find(tpl, f.needle, (j :: number) + 1, true))).toBeNil()
		end
	end)

	it("has no cwd, tier or fingerprint (the approved record holds those) and masks credentials", function()
		local tpl = Audit.quickTemplate(Q)
		expect((string.find(tpl, '"cwd"', 1, true))).toBeNil()
		expect((string.find(tpl, '"tier"', 1, true))).toBeNil()
		expect((string.find(tpl, '"fingerprint"', 1, true))).toBeNil()
		expect((string.find(tpl, "hunter2", 1, true))).toBeNil()
	end)

	it("leaves out a malformed run id instead of logging arbitrary text", function()
		local q = table.clone(Q)
		q.run = "not a run id"
		expect((string.find(Audit.quickTemplate(q), '"run"', 1, true))).toBeNil()
	end)

	it("carries the run id in an approved quick record", function()
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), {
			mode = "quick",
			decision = "approved",
			decidedAt = 1790000005,
			run = RUN,
		}))
		expect(line).toContain('"mode":"quick","run":"' .. RUN .. '"')
		local bad = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), {
			mode = "quick",
			decision = "approved",
			decidedAt = 1790000005,
			run = "zz",
		}))
		expect((string.find(bad, '"run"', 1, true))).toBeNil()
	end)
end)

return nil
