--!strict
local t = require("../../lib/test")
local fixtures = require("../../lib/fixtures")
local Discovery = require("../../../plugin/lib/kubectl/discovery")
local describe, it, expect = t.describe, t.it, t.expect

-- Explore's own discovery argv (`api-resources --verbs=list -o wide`)
-- captured from the kind cluster: core, apps, the lens.example.com CRD
-- (`wd`), events.k8s.io and metrics.k8s.io duplicates of core names.
local WIDE = fixtures.read("kubectl/discovery/verbs-list-wide.out")
local DEFAULT = fixtures.read("kubectl/discovery/default.out")
local NAMES = fixtures.read("kubectl/discovery/name.out")

local function find(rows: { Discovery.KindRow }, name: string): Discovery.KindRow?
	for _, row in rows do
		if row.name == name then
			return row
		end
	end
	return nil
end

local function names(list: { { row: Discovery.KindRow, score: number } }): { string }
	local out = {}
	for _, s in list do
		table.insert(out, s.row.name)
	end
	return out
end

describe("Discovery.parse", function()
	-- The prompt and the api-resources lens read the same table; every row
	-- must keep its group so `events` and `events.events.k8s.io` stay apart.
	it("reads the -o wide table with verbs and categories", function()
		local res = Discovery.parse(WIDE, "", 0)
		expect(#res.rows).toBe(67)
		expect(res.partial).toBeNil()
		expect(#res.diagnostics).toBe(0)
		local cm = find(res.rows, "configmaps") :: Discovery.KindRow
		expect(cm.plural).toBe("configmaps")
		expect(cm.group).toBeNil()
		expect(cm.version).toBe("v1")
		expect(cm.kind).toBe("ConfigMap")
		expect(cm.short).toEqual({ "cm" })
		expect(cm.namespaced).toBe(true)
		expect(cm.standard).toBe(true)
		expect(cm.line).toBe(3)
		expect(cm.categories).toEqual({})
		expect((cm.verbs :: { string })[5]).toBe("list")
		local wd = find(res.rows, "widgets.lens.example.com") :: Discovery.KindRow
		expect(wd.group).toBe("lens.example.com")
		expect(wd.version).toBe("v1alpha1")
		expect(wd.short).toEqual({ "wd" })
		expect(wd.categories).toEqual({ "lens" })
		expect(wd.standard).toBe(false)
		local deploy = find(res.rows, "deployments.apps") :: Discovery.KindRow
		expect(deploy.standard).toBe(true)
		expect(find(res.rows, "events.events.k8s.io") ~= nil).toBe(true)
		expect(find(res.rows, "pods.metrics.k8s.io") ~= nil).toBe(true)
	end)

	it("reads the default table without VERBS / CATEGORIES", function()
		local res = Discovery.parse(DEFAULT)
		expect(#res.diagnostics).toBe(0)
		local b = find(res.rows, "bindings") :: Discovery.KindRow
		expect(b.short).toEqual({})
		expect(b.verbs).toBeNil()
		expect(b.categories).toBeNil()
	end)

	-- kubectl before 1.20 printed APIGROUP (group only, blank for core).
	it("accepts the old APIGROUP header", function()
		local text = table.concat({
			"NAME          SHORTNAMES   APIGROUP   NAMESPACED   KIND",
			"pods          po                      true         Pod",
			"deployments   deploy       apps       true         Deployment",
			"",
		}, "\n")
		local res = Discovery.parse(text)
		expect(#res.rows).toBe(2)
		expect(res.rows[1].group).toBeNil()
		expect(res.rows[1].version).toBeNil()
		expect(res.rows[2].name).toBe("deployments.apps")
		expect(res.rows[2].group).toBe("apps")
	end)

	-- `-o name` prints plural.group only; Kind and scope come from the
	-- static table when kubectl knows the resource.
	it("reads the -o name form", function()
		local res = Discovery.parse(NAMES)
		expect(#res.rows).toBe(74)
		expect(#res.diagnostics).toBe(0)
		local ev = find(res.rows, "events.events.k8s.io") :: Discovery.KindRow
		expect(ev.plural).toBe("events")
		expect(ev.group).toBe("events.k8s.io")
		local deploy = find(res.rows, "deployments.apps") :: Discovery.KindRow
		expect(deploy.kind).toBe("Deployment")
		expect(deploy.namespaced).toBe(true)
		local wd = find(res.rows, "widgets.lens.example.com") :: Discovery.KindRow
		expect(wd.kind).toBe("")
		expect(wd.namespaced).toBeNil()
	end)

	-- An unavailable aggregated API makes kubectl exit 1 after printing the
	-- groups it could read; Explore keeps those rows and names the gap.
	it("keeps rows of a partial discovery and names the failed groups", function()
		local stdout = table.concat({
			"NAME   SHORTNAMES   APIVERSION   NAMESPACED   KIND   VERBS   CATEGORIES",
			"pods   po           v1           true         Pod    get,list   all",
			"",
		}, "\n")
		local stderr = "error: unable to retrieve the complete list of server APIs: "
			.. "metrics.k8s.io/v1beta1: the server is currently unable to handle the request, "
			.. "custom.metrics.k8s.io/v1beta2: stale GroupVersion discovery\n"
		local res = Discovery.parse(stdout, stderr, 1)
		expect(#res.rows).toBe(1)
		expect(res.partial).toBe("metrics.k8s.io/v1beta1, custom.metrics.k8s.io/v1beta2")
	end)

	it("reports kubectl errors as diagnostics, never rows", function()
		local res = Discovery.parse("", "error: You must be logged in to the server (Unauthorized)\n", 1)
		expect(#res.rows).toBe(0)
		expect(res.partial).toBeNil()
		expect(res.diagnostics[1].severity).toBe("error")
		local header = Discovery.parse("NAME   SHORTNAMES   APIVERSION   NAMESPACED   KIND\n", "", 0)
		expect(#header.rows).toBe(0)
		expect(#header.diagnostics).toBe(0)
	end)
end)

describe("Discovery.resolve", function()
	local idx = Discovery.index(Discovery.parse(WIDE).rows)

	-- k9s rule: built-ins win bare names, metrics.k8s.io never gets one,
	-- so `:pods` / `:nodes` / `:ev` stay core.
	it("gives bare names to core before other groups, never to metrics", function()
		expect((Discovery.resolve(idx, "pods") :: Discovery.KindRow).name).toBe("pods")
		expect((Discovery.resolve(idx, "nodes") :: Discovery.KindRow).name).toBe("nodes")
		expect((Discovery.resolve(idx, "events") :: Discovery.KindRow).name).toBe("events")
		expect((Discovery.resolve(idx, "ev") :: Discovery.KindRow).name).toBe("events")
		expect(Discovery.resolve(idx, "podmetrics") :: Discovery.KindRow?).toBeNil()
		expect((Discovery.resolve(idx, "pods.metrics.k8s.io") :: Discovery.KindRow).group).toBe("metrics.k8s.io")
		expect((Discovery.resolve(idx, "events.events.k8s.io") :: Discovery.KindRow).group).toBe("events.k8s.io")
	end)

	it("resolves plural, singular, Kind, short names and plural.group", function()
		for _, token in { "deployments", "deployment", "Deployment", "deploy", "DEPLOY", "deployments.apps" } do
			expect((Discovery.resolve(idx, token) :: Discovery.KindRow).name).toBe("deployments.apps")
		end
		for _, token in { "wd", "widget", "widgets", "widgets.lens.example.com" } do
			expect((Discovery.resolve(idx, token) :: Discovery.KindRow).name).toBe("widgets.lens.example.com")
		end
		expect(Discovery.resolve(idx, "nope") :: Discovery.KindRow?).toBeNil()
		expect(Discovery.resolve(idx, "") :: Discovery.KindRow?).toBeNil()
	end)

	-- The prompt must answer `:po` / `:deploy` / `:svc` / `:cm` before the
	-- cluster does: the static table knows kubectl's built-ins.
	it("has a static index of kubectl's built-in kinds", function()
		local static = Discovery.staticIndex()
		expect((Discovery.resolve(static, "po") :: Discovery.KindRow).name).toBe("pods")
		expect((Discovery.resolve(static, "deploy") :: Discovery.KindRow).name).toBe("deployments.apps")
		expect((Discovery.resolve(static, "svc") :: Discovery.KindRow).name).toBe("services")
		expect((Discovery.resolve(static, "cm") :: Discovery.KindRow).name).toBe("configmaps")
		expect(Discovery.resolve(static, "wd") :: Discovery.KindRow?).toBeNil()
	end)
end)

describe("Discovery.suggest", function()
	local idx = Discovery.index(Discovery.parse(WIDE).rows)

	it("ranks exact alias, then prefix, then substring", function()
		local list = Discovery.suggest(idx, "deploy")
		expect(list[1].row.name).toBe("deployments.apps")
		expect(list[1].score).toBe(0)
		local dep = Discovery.suggest(idx, "dep")
		expect(dep[1].row.name).toBe("deployments.apps")
		expect(dep[1].score).toBe(1)
		local sub = Discovery.suggest(idx, "ploy")
		expect(sub[1].score).toBe(2)
		expect(names(sub)).toContain("deployments.apps")
	end)

	-- Ties keep core first, then standard groups, then CRDs and the rest.
	it("orders ties core, standard groups, then the rest", function()
		local ev = names(Discovery.suggest(idx, "events"))
		expect(ev[1]).toBe("events")
		expect(ev[2]).toBe("events.events.k8s.io")
		local po = names(Discovery.suggest(idx, "pods"))
		expect(po[1]).toBe("pods")
		local all = Discovery.suggest(idx, "")
		expect(#all).toBe(67)
		expect(all[1].row.name).toBe("componentstatuses")
		expect(all[#all].row.group == "metrics.k8s.io" or not all[#all].row.standard).toBe(true)
	end)

	it("is case-insensitive and empty for no match", function()
		expect(Discovery.suggest(idx, "WD")[1].row.name).toBe("widgets.lens.example.com")
		expect(#Discovery.suggest(idx, "zzzz")).toBe(0)
	end)
end)

return nil
