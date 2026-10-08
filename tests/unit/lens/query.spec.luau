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

	it("problems: bad status, short READY, restarts > 0", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(names(Query.apply(tbl, vsm.toggledProblems(vsm.default())))).toEqual({ "b", "c" })
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

	it("does not reorder or copy rows when nothing is asked", function()
		local tbl = tableOf("kubectl get pods", PODS)
		expect(Query.apply(tbl, vsm.default()).rows).toBe(tbl.rows)
	end)
end)

return nil
