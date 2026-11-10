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

	-- The lens "Filter in Explore" chip carries `get … -l SEL`: Explore must
	-- list the same objects, not the whole namespace.
	it("list with a label selector passes -l", function()
		local argv = Query.list("kubectl", bare(), "pods", { namespace = "apps", all = false }, "app=web,tier!=db")
		expect(argv).toEqual({
			"kubectl",
			"--context",
			"kind-dev",
			"get",
			"pods",
			"-n",
			"apps",
			"-l",
			"app=web,tier!=db",
			"-o",
			"json",
		})
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

	-- Records need the exact kubelet time and the pod/container of every
	-- line, so Explore always asks for both; no container means all of them.
	it("logs of a pod ask for timestamps, prefixes and every container, bounded by tail", function()
		expect(Query.logs("k", bare(), {
			ref = POD,
			container = nil,
			previous = false,
			since = nil,
			tail = 500,
		})).toEqual({
			"k",
			"--context",
			"kind-dev",
			"logs",
			"web-0",
			"-n",
			"apps",
			"--all-containers",
			"--timestamps",
			"--prefix",
			"--tail=500",
		})
	end)

	it("logs of one container add -c, --previous and --since; a workload is TYPE/NAME", function()
		local argv = Query.logs("k", bare(), {
			ref = DEPLOY,
			container = "app",
			previous = true,
			since = "1h",
			tail = 42,
		})
		expect(argv).toContain("deployment.apps/web")
		expect(argv).toContain("-c")
		expect(argv).toContain("--previous")
		expect(argv).toContain("--since=1h")
		expect(argv).toContain("--tail=42")
		expect(table.find(argv, "--all-containers")).toBeNil()
		expect(table.find(argv, "--max-log-requests=10")).toBeNil()
	end)

	-- kubectl refuses more than 5 concurrent pod streams by default; a
	-- selector over a larger workload would fail without the raised limit.
	it("selector-only logs use -l in the given namespace and raise the request limit", function()
		expect(Query.logs("k", bare(), {
			ref = nil,
			selector = "app=web",
			namespace = "apps",
			container = nil,
			previous = false,
			since = nil,
			tail = 100,
		})).toEqual({
			"k",
			"--context",
			"kind-dev",
			"logs",
			"-l",
			"app=web",
			"-n",
			"apps",
			"--all-containers",
			"--timestamps",
			"--prefix",
			"--tail=100",
			"--max-log-requests=10",
		})
	end)

	-- `kubectl events` needs kubectl >= 1.26; `get events` returns the same
	-- EventList from any version.
	it("events read get events as JSON in one namespace or across all of them", function()
		expect(Query.events("k", bare(), { namespace = "apps", all = false })).toEqual({
			"k",
			"--context",
			"kind-dev",
			"get",
			"events",
			"-n",
			"apps",
			"-o",
			"json",
		})
		local all = Query.events("k", target(), { namespace = nil, all = true })
		expect(all).toContain("-A")
		expect(table.find(all, "-n")).toBeNil()
	end)

	it("related events read what can own pods in the object's namespace", function()
		expect(Query.owned("k", bare(), "apps")).toEqual({
			"k",
			"--context",
			"kind-dev",
			"get",
			"replicasets,pods,jobs",
			"-n",
			"apps",
			"-o",
			"json",
		})
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
