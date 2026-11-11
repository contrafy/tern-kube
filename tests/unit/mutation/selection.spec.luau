--!strict
-- A selector, `--all` or a bare type is resolved by kubectl when it runs,
-- not when it was previewed: a pod that started matching while the user
-- read the preview would be deleted unseen. At confirm the block reads the
-- set again and refuses when it differs, including an object deleted and
-- re-created under the same name (a new uid is a different object).
local Plan = require("../../../plugin/lib/mutation/plan")
local Selection = require("../../../plugin/lib/mutation/selection")
local Steps = require("../../../plugin/lib/mutation/steps")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV = { context = "kind-dev", contextSource = "flag" :: "flag", cwd = "/w", namespace = "apps" }

local function plan(argv: { string })
	local p, d = Plan.fromArgv(argv, ENV)
	assert(p, if d[1] then d[1].text else "no plan")
	return p
end

local function obj(apiVersion: string, kind: string, ns: string?, name: string, uid: string): any
	return { apiVersion = apiVersion, kind = kind, metadata = { namespace = ns, name = name, uid = uid } }
end

describe("Selection.applies", function()
	it("covers selectors, --all and bare types", function()
		expect(Selection.applies(plan({ "kubectl", "delete", "pods", "-l", "app=web" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "delete", "pods", "--all" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "delete", "pods", "--field-selector=status.phase=Failed" }))).toBe(
			true
		)
		expect(Selection.applies(plan({ "kubectl", "delete", "pods", "--all", "-A" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "rollout", "restart", "deploy" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "scale", "deploy", "--all", "--replicas=0" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "label", "pods", "--all", "k=v" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "cordon", "-l", "pool=a" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "rollout", "undo", "deploy", "-l", "a=b" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "set", "image", "deploy", "--all", "app=x:1" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "taint", "nodes", "--all", "k=v:NoSchedule" }))).toBe(true)
		expect(Selection.applies(plan({ "kubectl", "taint", "nodes", "n1", "k=v:NoSchedule" }))).toBe(false)
	end)

	it("leaves named targets and files alone: they name their objects", function()
		expect(Selection.applies(plan({ "kubectl", "delete", "deploy/web" }))).toBe(false)
		expect(Selection.applies(plan({ "kubectl", "delete", "pod", "a", "b" }))).toBe(false)
		expect(Selection.applies(plan({ "kubectl", "cordon", "n1" }))).toBe(false)
		expect(Selection.applies(plan({ "kubectl", "delete", "-f", "x.yaml" }))).toBe(false)
		expect(Selection.applies(plan({ "kubectl", "apply", "-f", "x.yaml" }))).toBe(false)
	end)
end)

describe("Selection.step", function()
	it("re-runs the targets read with a jsonpath that keeps namespaces and uids", function()
		local p = plan({ "kubectl", "delete", "pods", "-l", "app=web", "--field-selector=x=y", "-A" })
		local s = Selection.step(p) :: any
		expect(s.id).toBe("v-selection")
		expect(s.kind).toBe("selection")
		local targets = (Steps.forPlan(p))[1]
		local n = #targets.argv
		expect(table.concat(s.argv, " ", 1, #s.argv - 2)).toBe(table.concat(targets.argv, " ", 1, n - 2))
		expect(s.argv[#s.argv - 1]).toBe("-o")
		-- Not `-o name`: it drops the namespace with -A.
		expect(s.argv[#s.argv]).toBe(
			'jsonpath={range .items[*]}{.apiVersion}{"\\t"}{.kind}{"\\t"}{.metadata.namespace}{"\\t"}{.metadata.name}{"\\t"}{.metadata.uid}{"\\n"}{end}'
		)
		local joined = table.concat(s.argv, " ")
		expect(joined).toContain("--selector=app=web")
		expect(joined).toContain("--field-selector=x=y")
		expect(joined).toContain("--all-namespaces=true")
	end)

	it("drops --all like the targets read (get has no --all)", function()
		local s = Selection.step(plan({ "kubectl", "delete", "pods", "--all" })) :: any
		expect((string.find(table.concat(s.argv, " "), "--all", 1, true))).toBeNil()
	end)

	it("has no step for named targets", function()
		expect(Selection.step(plan({ "kubectl", "delete", "deploy/web" }))).toBeNil()
	end)
end)

describe("Selection.parse / fromLive", function()
	it("reads kubectl's tab-separated lines, cluster-scoped objects included", function()
		local out = "apps/v1\tDeployment\tapps\tweb\tu1\nv1\tNode\t\tn1\tu2\n"
		local got = Selection.parse(out) :: { Selection.Entry }
		expect(got).toEqual({
			{ group = "apps", kind = "Deployment", namespace = "apps", name = "web", uid = "u1" },
			{ group = "", kind = "Node", namespace = "", name = "n1", uid = "u2" },
		})
		expect((Selection.parse(""))).toEqual({})
	end)

	it("refuses output it cannot read rather than guessing an empty set", function()
		local got, why = Selection.parse("apps/v1 Deployment apps web u1\n")
		expect(got).toBeNil()
		expect(why).toContain("unexpected")
	end)

	it("takes the same tuples from the preview's live objects", function()
		local live = { obj("apps/v1", "Deployment", "apps", "web", "u1"), obj("v1", "Node", nil, "n1", "u2") }
		expect(Selection.fromLive(live)).toEqual({
			{ group = "apps", kind = "Deployment", namespace = "apps", name = "web", uid = "u1" },
			{ group = "", kind = "Node", namespace = "", name = "n1", uid = "u2" },
		})
	end)
end)

describe("Selection.compare", function()
	local web = { group = "apps", kind = "Deployment", namespace = "apps", name = "web", uid = "u1" }
	local api = { group = "apps", kind = "Deployment", namespace = "apps", name = "api", uid = "u2" }

	it("accepts the same set in any order", function()
		expect(Selection.compare({ web, api }, { api, web })).toBeNil()
		expect(Selection.compare({}, {})).toBeNil()
	end)

	it("refuses a new match and a vanished one, naming them", function()
		local why = Selection.compare({ web }, { web, api }) :: string
		expect(why).toContain("now matches 2 object(s) (previewed 1)")
		expect(why).toContain("+Deployment apps/api")
		expect(why).toContain("Press r to preview again")
		why = Selection.compare({ web, api }, { web }) :: string
		expect(why).toContain("-Deployment apps/api")
	end)

	it("refuses an empty preview that now matches something", function()
		expect(Selection.compare({}, { web })).toContain("+Deployment apps/web")
	end)

	it("counts a re-created object (same name, new uid) as a different target", function()
		local again = table.clone(web)
		again.uid = "u9"
		local why = Selection.compare({ web }, { again }) :: string
		expect(why).toContain("Deployment apps/web")
		expect(why).toContain("re-created since the preview")
	end)

	it("lists at most three names per side", function()
		local now = {}
		for i = 1, 5 do
			table.insert(now, { group = "", kind = "Pod", namespace = "apps", name = "p" .. i, uid = "x" .. i })
		end
		local why = Selection.compare({}, now) :: string
		expect(why).toContain("+Pod apps/p3")
		expect((string.find(why, "p4", 1, true))).toBeNil()
		expect(why).toContain("and 2 more")
	end)
end)

return nil
