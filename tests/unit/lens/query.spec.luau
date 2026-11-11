--!strict
-- Sorting and filtering as the user sees them: ages and restarts order by
-- value, not text; filters combine the way chips suggest; problems means
-- what kubectl's columns say.
local Capture = require("../../../plugin/lib/lens/capture")
local Query = require("../../../plugin/lib/lens/query")
local json = require("../../lib/json")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function tableOf(command: string, lines: { string }): any
	local c = Capture.build(runs.run(command), lines, 0, { decode = json.decode })
	return (c.snapshot :: any).tables[1]
end

local function names(result: Query.Result): { string }
	local out: { string } = {}
	for _, row in result.rows do
		table.insert(out, row.cells[1])
	end
	return out
end

local function sortedBy(col: string, desc: boolean?): vsm.ViewState
	local vs = vsm.sortedBy(vsm.default(), col)
	if desc then
		vs = vsm.sortedBy(vs, col)
	end
	return vs
end

local PODS = {
	"NAME   READY   STATUS             RESTARTS       AGE",
	"a      1/1     Running            0              9m",
	"b      0/1     CrashLoopBackOff   12 (3m ago)    2d",
	"c      1/2     Running            2 (40s ago)    90s",
	"d      1/1     Completed          0              1h",
	"e      2/2     Running            0              <unknown>",
}

describe("lens query", function()
	it("sorts AGE by duration, not text (90s < 9m < 1h < 2d)", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(names(Query.apply(tbl, sortedBy("AGE")))).toEqual({ "c", "a", "d", "b", "e" })
	end)

	it("descending still puts placeholders last", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(names(Query.apply(tbl, sortedBy("AGE", true)))).toEqual({ "b", "d", "a", "c", "e" })
	end)

	it("sorts RESTARTS numerically (2 < 12) with stable ties", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(names(Query.apply(tbl, sortedBy("RESTARTS")))).toEqual({ "a", "d", "e", "c", "b" })
		expect(names(Query.apply(tbl, sortedBy("RESTARTS", true)))).toEqual({ "b", "c", "a", "d", "e" })
	end)

	it("sorts READY by ratio (0/1 < 1/2 < 1/1)", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(names(Query.apply(tbl, sortedBy("READY")))).toEqual({ "b", "c", "a", "d", "e" })
	end)

	it("sorts real AGE values from a capture by duration", function()
		local f = runs.load("synthetic/rows-100/get_pods")
		local c = Capture.build(f.run, f.lines, 0, { decode = json.decode })
		local tbl = (c.snapshot :: any).tables[1]
		local result = Query.apply(tbl, sortedBy("AGE"))
		local Values = require("../../../plugin/lib/model/values")
		local prev = -1
		for _, row in result.rows do
			local d = Values.duration(row.cells[5])
			if d then
				expect(d >= prev).toBe(true)
				prev = d
			end
		end
	end)

	it("filters OR within a column and AND across columns", function()
		local tbl = tableOf("kubectl get pods", PODS)
		local vs = vsm.toggledFilter(vsm.default(), "STATUS", "Running")
		vs = vsm.toggledFilter(vs, "STATUS", "Completed")
		expect(names(Query.apply(tbl, vs))).toEqual({ "a", "c", "d", "e" })
		vs = vsm.toggledFilter(vs, "READY", "1/1")
		local result = Query.apply(tbl, vs)
		expect(names(result)).toEqual({ "a", "d" })
		expect(result.total).toBe(5)
		expect(result.matched).toBe(2)
	end)

	it("a filter on a column the table lacks hides that table", function()
		local tbl = tableOf("kubectl get pods", PODS)
		local result = Query.apply(tbl, vsm.toggledFilter(vsm.default(), "TYPE", "ClusterIP"))
		expect(#result.rows).toBe(0)
	end)

	it("KIND filters match the table's kind", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(#Query.apply(tbl, vsm.toggledFilter(vsm.default(), "KIND", "Pod")).rows).toBe(5)
		expect(#Query.apply(tbl, vsm.toggledFilter(vsm.default(), "KIND", "Service")).rows).toBe(0)
	end)

	it("problems: bad status, short READY, recent restarts", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(names(Query.apply(tbl, vsm.toggledProblems(vsm.default())))).toEqual({ "b", "c" })
	end)

	-- After a node or Docker restart every healthy pod shows `2 (25h ago)`:
	-- counting any restart ever flagged 27 of 33 pods. Only a restart within
	-- the last hour says the pod is unstable now.
	it("problems count only recent restarts of ready, running pods", function()
		local tbl = tableOf("kubectl get pods", {
			"NAME     READY   STATUS    RESTARTS        AGE",
			"old      1/1     Running   2 (25h ago)     32d",
			"recent   1/1     Running   3 (12m ago)     32d",
			"edge     1/1     Running   1 (59m59s ago)  32d",
			"hour     1/1     Running   1 (60m ago)     32d",
			"plain    1/1     Running   4               32d",
		})
		expect(names(Query.apply(tbl, vsm.toggledProblems(vsm.default())))).toEqual({ "recent", "edge" })
		expect(Query.recentRestart("3 (12m ago)")).toBe(true)
		expect(Query.recentRestart("2 (25h ago)")).toBe(false)
		expect(Query.recentRestart("0")).toBe(false)
	end)

	it("problems on real pods find the crashloop, image pull and pending pods", function()
		local f = runs.load("ns-apps/get_pods")
		local c = Capture.build(f.run, f.lines, 0, { decode = json.decode })
		local got = names(Query.apply((c.snapshot :: any).tables[1], vsm.toggledProblems(vsm.default())))
		table.sort(got)
		expect(#got).toBe(3)
		expect(got[2]).toBe("crashloop")
		expect(got[3]).toBe("pending")
	end)

	it("problems on deployments use READY short of desired", function()
		local tbl = tableOf("kubectl get deploy", {
			"NAME           READY   UP-TO-DATE   AVAILABLE   AGE",
			"broken-image   0/1     1            0           5m",
			"web            2/2     2            2           5m",
		})
		expect(names(Query.apply(tbl, vsm.toggledProblems(vsm.default())))).toEqual({ "broken-image" })
	end)

	-- Live `get pods -A` counted the completed job pod (READY 0/1, STATUS
	-- Completed) as a problem: a finished pod's containers are meant to be
	-- not ready.
	it("problems skip short READY of finished pods (Completed, Succeeded)", function()
		local tbl = tableOf("kubectl get pods", {
			"NAME       READY   STATUS      RESTARTS   AGE",
			"done-job   0/1     Completed   0          5m",
			"ok-job     0/1     Succeeded   0          5m",
			"fail-job   0/1     Error       0          5m",
			"starting   0/1     Running     0          5m",
		})
		expect(names(Query.apply(tbl, vsm.toggledProblems(vsm.default())))).toEqual({ "fail-job", "starting" })
	end)

	it("does not reorder or copy rows when nothing is asked", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(Query.apply(tbl, vsm.default()).rows).toBe(tbl.rows)
	end)
end)

-- api-resources VERB / can-i TYPE facets are row tags, not cells: a row
-- matches when any of its values is selected (OR within a column, AND across).
describe("lens query tags", function()
	local function row(name: string, tags: { [string]: { string } }): any
		return { key = name, cells = { name }, rawLines = {}, warnings = {}, tags = tags }
	end
	local tbl: any = {
		headers = { "NAME" },
		types = { "text" },
		facets = { "VERB", "GROUP" },
		rows = {
			row("pods", { VERB = { "get", "list" }, GROUP = { "core" } }),
			row("bindings", { VERB = { "create" }, GROUP = { "core" } }),
			row("deployments", { VERB = { "list", "patch" }, GROUP = { "apps" } }),
		},
	}

	it("matches any tag value, OR within a column and AND across columns", function()
		local listing = vsm.toggledFilter(vsm.default(), "VERB", "list")
		expect(names(Query.apply(tbl, listing))).toEqual({ "pods", "deployments" })
		local either = vsm.toggledFilter(listing, "VERB", "create")
		expect(names(Query.apply(tbl, either))).toEqual({ "pods", "bindings", "deployments" })
		local core = vsm.toggledFilter(listing, "GROUP", "core")
		expect(names(Query.apply(tbl, core))).toEqual({ "pods" })
	end)

	it("a tag column the table does not facet still excludes the table", function()
		local other = vsm.toggledFilter(vsm.default(), "CATEGORY", "x")
		expect(Query.apply(tbl, other).matched).toBe(0)
	end)
end)

return nil
