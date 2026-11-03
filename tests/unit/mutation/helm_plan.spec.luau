--!strict
-- `helm rollback` as a mutation plan. The approve block only ever runs the
-- argv it previewed, so the grammar is strict: anything it cannot model
-- (unknown flags, an implicit revision, an unbounded run) is refused before
-- a preview could vouch for it.
local Plan = require("../../../plugin/lib/mutation/plan")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local HELM = "/opt/bin/helm"

local ENV: T.Env = {
	context = "kind-dev",
	contextSource = "chosen",
	kubeconfig = "/k/config",
	namespace = "team",
	cwd = "/home/me",
	program = "kubectl",
	helm = HELM,
	helmDriver = "secret",
}

local function words(line: string): { string }
	local out = string.split(line, " ")
	if out[1] == "helm" then
		out[1] = HELM
	end
	return out
end

local function plan(line: string, env: T.Env?): T.Plan
	local p, diags = Plan.fromArgv(words(line), env or ENV)
	expect(diags).toEqual({})
	return p :: T.Plan
end

local function rejected(line: string): { string }
	local p, diags = Plan.fromArgv(words(line), ENV)
	expect(p).toBeNil()
	local codes = {}
	for _, d in diags do
		table.insert(codes, d.severity .. ":" .. d.code)
	end
	return codes
end

local function textOf(line: string): string
	local _, diags = Plan.fromArgv(words(line), ENV)
	return diags[1].text
end

describe("helm rollback plan", function()
	it("accepts the argv a rollback link builds and pins the context first", function()
		local p = plan("helm rollback shop-a 1 -n shop --timeout 240s --wait --cleanup-on-fail")
		expect(p.family).toBe("helm-rollback")
		expect(p.operation).toBe("rollback")
		expect(p.program).toBe(HELM)
		expect(p.targetContext).toBe("kind-dev")
		expect(p.targetNamespace).toBe("shop")
		expect(p.explicitNamespace).toBe("shop")
		local h = p.helm :: T.HelmRollback
		expect(h.release).toBe("shop-a")
		expect(h.namespace).toBe("shop")
		expect(h.revision).toBe(1)
		expect(h.driver).toBe("secret")
		expect(h.kubectl).toBe("kubectl")
		expect(h.options).toEqual({
			wait = true,
			waitForJobs = false,
			cleanupOnFail = true,
			force = false,
			noHooks = false,
			timeoutS = 240,
		})
		-- What runs is the typed argv with the connection pinned in front:
		-- the user's current-context never decides the release.
		expect(p.execArgv).toEqual({
			HELM,
			"--kube-context",
			"kind-dev",
			"--kubeconfig",
			"/k/config",
			"rollback",
			"shop-a",
			"1",
			"-n",
			"shop",
			"--timeout",
			"240s",
			"--wait",
			"--cleanup-on-fail",
		})
		expect(Plan.execEnv(p)).toEqual({ HELM_DRIVER = "secret" })
	end)

	it("pins the release namespace when -n is absent (the context default, else default)", function()
		local p = plan("helm rollback shop-a 2 --timeout=5m")
		expect(p.targetNamespace).toBe("team")
		expect(p.explicitNamespace).toBeNil()
		expect(table.concat(p.execArgv, " ")).toContain("--namespace team rollback shop-a 2 --timeout=5m")
		expect((p.helm :: T.HelmRollback).options.timeoutS).toBe(300)
		local env = table.clone(ENV)
		env.namespace = nil
		expect((plan("helm rollback shop-a 2 --timeout=5m", env).helm :: T.HelmRollback).namespace).toBe("default")
	end)

	it("honours --kube-context and --kubeconfig typed before the verb", function()
		local p = plan("helm --kube-context other --kubeconfig /k/b rollback shop-a 1 -n shop --timeout 60s")
		expect(p.targetContext).toBe("other")
		expect(p.contextSource).toBe("flag")
		expect(p.kubeconfig).toBe("/k/b")
		expect(p.execArgv[2]).toBe("--kube-context")
		expect(p.execArgv[3]).toBe("other")
		expect(table.find(p.execArgv, "/k/config")).toBeNil()
	end)

	it("moves a kubeconfig path list to KUBECONFIG: --kubeconfig takes one file", function()
		local env = table.clone(ENV)
		env.kubeconfig = "/k/a:/k/b"
		local p = plan("helm rollback shop-a 1 -n shop --timeout 60s", env)
		expect(table.find(p.execArgv, "--kubeconfig")).toBeNil()
		expect(Plan.execEnv(p)).toEqual({ HELM_DRIVER = "secret", KUBECONFIG = "/k/a:/k/b" })
	end)

	it("treats --dry-run as a no-op that needs no approval", function()
		expect(rejected("helm rollback shop-a 1 -n shop --timeout 60s --dry-run")).toEqual({ "info:dry-run" })
	end)

	it("refuses flags it cannot model, so nothing unpreviewed slips into the exec argv", function()
		expect(rejected("helm rollback shop-a 1 -n shop --timeout 60s --set=a=b")).toEqual({ "error:unknown-flag" })
		expect(rejected("helm rollback shop-a 1 -n shop --timeout 60s --recreate-pods")).toEqual({
			"error:unknown-flag",
		})
		expect(textOf("helm rollback shop-a 1 --timeout 60s --debug")).toContain("--debug")
	end)

	it("needs an explicit revision: helm's implicit 'previous' moves with every upgrade", function()
		expect(rejected("helm rollback shop-a --timeout 60s")).toEqual({ "error:missing-target" })
		expect(rejected("helm rollback shop-a 0 --timeout 60s")).toEqual({ "error:invalid" })
		expect(rejected("helm rollback shop-a 1.5 --timeout 60s")).toEqual({ "error:invalid" })
		expect(rejected("helm rollback shop-a 1 2 --timeout 60s")).toEqual({ "error:invalid" })
	end)

	it("refuses release names helm would not accept", function()
		expect(rejected("helm rollback Shop_A 1 --timeout 60s")).toEqual({ "error:invalid" })
		expect(rejected("helm rollback -x shop-a 1 --timeout 60s")).toEqual({ "error:unknown-flag" })
	end)

	it("requires --timeout: it bounds the run and the hooks the block waits for", function()
		expect(rejected("helm rollback shop-a 1 -n shop")).toEqual({ "error:invalid" })
		expect(textOf("helm rollback shop-a 1 -n shop")).toContain("--timeout")
		expect(rejected("helm rollback shop-a 1 --timeout soon")).toEqual({ "error:invalid" })
		expect(rejected("helm rollback shop-a 1 --timeout 0s")).toEqual({ "error:invalid" })
	end)

	it("refuses --wait-for-jobs without --wait (helm would ignore it)", function()
		expect(rejected("helm rollback shop-a 1 --timeout 60s --wait-for-jobs")).toEqual({ "error:invalid" })
		local p = plan("helm rollback shop-a 1 --timeout 60s --wait --wait-for-jobs --force --no-hooks --history-max 5")
		local o = (p.helm :: T.HelmRollback).options
		expect(o.waitForJobs).toBe(true)
		expect(o.force).toBe(true)
		expect(o.noHooks).toBe(true)
	end)

	it("only rollback goes through the approve block", function()
		expect(rejected("helm upgrade shop-a ./chart")).toEqual({ "error:unsupported" })
		expect(rejected("helm")).toEqual({ "error:unsupported" })
	end)

	it("needs a context: helm would otherwise use the kubeconfig's current-context", function()
		local env = table.clone(ENV)
		env.context = nil
		local _, diags = Plan.fromArgv(words("helm rollback shop-a 1 --timeout 60s"), env)
		expect(diags[1].code).toBe("no-context")
	end)

	it("recognises a helm argv by program name when the resolved path is unknown", function()
		local env = table.clone(ENV)
		env.helm = nil
		local p, diags = Plan.fromArgv({ "helm", "rollback", "shop-a", "1", "--timeout", "60s" }, env)
		expect(diags).toEqual({})
		expect((p :: T.Plan).family).toBe("helm-rollback")
	end)
end)

return nil
