--!strict
-- Explore's argv builders. Every cluster query pins --context (and
-- --kubeconfig when known) so a later `kubectl config use-context` in the
-- user's shell cannot redirect Explore to another cluster.
local Query = require("../../../plugin/lib/explore/query")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function target(over: { [string]: any }?): Query.Target
	local base: Query.Target = {
		kubeconfig = "/k/config",
		context = "kind-dev",
		contextSource = "flag",
		namespace = "apps",
		allNamespaces = false,
		confirmed = true,
		inferredAt = nil,
	}
	if over then
		for k, v in over do
			(base :: any)[k] = v
		end
	end
	return base
end

local function bare(): Query.Target
	local tg = target()
	tg.kubeconfig = nil
	return tg
end

local POD = { kind = "Pod", name = "web-0", namespace = "apps", source = "live" } :: any
local DEPLOY = { kind = "Deployment", group = "apps", name = "web", namespace = "apps", source = "live" } :: any

describe("explore query", function()
	it("list pins kubeconfig and context before the verb", function()
		expect(Query.list("kubectl", target(), "pods", { namespace = "apps", all = false })).toEqual({
			"kubectl",
			"--kubeconfig",
			"/k/config",
			"--context",
			"kind-dev",
			"get",
			"pods",
			"-n",
			"apps",
			"-o",
			"json",
		})
	end)

	it("list across namespaces uses -A and never -n", function()
		local argv = Query.list("kubectl", target(), "pods", { namespace = nil, all = true })
		expect(argv).toContain("-A")
		expect(table.find(argv, "-n")).toBeNil()
	end)

	it("list without a namespace leaves the context default", function()
		local argv = Query.list("kubectl", bare(), "nodes", { namespace = nil, all = false })
		expect(argv).toEqual({ "kubectl", "--context", "kind-dev", "get", "nodes", "-o", "json" })
	end)

	it("get and describe address the object by group-qualified type", function()
		expect(Query.get("k", bare(), DEPLOY)).toEqual({
			"k",
			"--context",
			"kind-dev",
			"get",
			"deployment.apps",
			"web",
			"-n",
			"apps",
			"-o",
			"json",
		})
		expect(Query.describe("k", bare(), POD)).toEqual({
			"k",
			"--context",
			"kind-dev",
			"describe",
			"pod",
			"web-0",
			"-n",
			"apps",
		})
	end)

	it("logs of a pod name the pod; of a workload the type/name; tail is bounded", function()
		expect(Query.logs("k", bare(), POD, "app", true, 500)).toEqual({
			"k",
			"--context",
			"kind-dev",
			"logs",
			"web-0",
			"-n",
			"apps",
			"-c",
			"app",
			"--previous",
			"--tail=500",
		})
		local argv = Query.logs("k", target(), DEPLOY, nil, false, nil)
		expect(argv).toContain("deployment.apps/web")
		expect(argv).toContain("--tail=500")
	end)

	it("kubeconfig queries need no context", function()
		expect(Query.contexts("k", "/k/config")).toEqual({
			"k",
			"--kubeconfig",
			"/k/config",
			"config",
			"get-contexts",
			"-o",
			"name",
		})
		expect(Query.currentContext("k", nil)).toEqual({ "k", "config", "current-context" })
	end)

	it("pickers pin the context", function()
		expect(Query.namespaces("k", target())).toContain("--context")
		expect(Query.apiResources("k", target())).toEqual({
			"k",
			"--kubeconfig",
			"/k/config",
			"--context",
			"kind-dev",
			"api-resources",
			"--verbs=list",
			"-o",
			"name",
		})
	end)

	it("relation queries carry selectors and never fetch secret data", function()
		local argv = Query.relation("k", bare(), {
			key = "pods",
			kind = "pods",
			namespace = "apps",
			selector = "app=web",
			fieldSelector = "spec.nodeName=n1",
			reason = "selector",
			provenance = "selector (heuristic)",
			nameOnly = false,
		})
		expect(argv).toEqual({
			"k",
			"--context",
			"kind-dev",
			"get",
			"pods",
			"-n",
			"apps",
			"-l",
			"app=web",
			"--field-selector",
			"spec.nodeName=n1",
			"-o",
			"json",
		})
		local secret = Query.relation("k", target(), {
			key = "s",
			kind = "secrets",
			namespace = "apps",
			name = "tls",
			reason = "tls",
			provenance = "spec reference",
			-- Defense in depth: even unflagged, a Secret is fetched by name only.
			nameOnly = false,
		})
		expect(secret[#secret]).toBe("name")
		expect(table.find(secret, "json")).toBeNil()
		local cluster = Query.relation("k", target(), {
			key = "n",
			kind = "nodes",
			name = "n1",
			reason = "node",
			provenance = "node binding",
			nameOnly = false,
		})
		expect(table.find(cluster, "-A")).toBeNil()
	end)

	it("selectorString renders matchLabels sorted and matchExpressions", function()
		expect(Query.selectorString({
			matchLabels = { tier = "web", app = "shop" },
			matchExpressions = {
				{ key = "env", operator = "In", values = { "a", "b" } },
				{ key = "gone", operator = "DoesNotExist" } :: any,
			},
		})).toBe("app=shop,tier=web,env in (a,b),!gone")
		expect(Query.selectorString({ app = "x" })).toBe("app=x")
		expect(Query.selectorString(nil)).toBeNil()
	end)
end)

return nil
