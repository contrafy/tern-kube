--!strict
-- Budgets from the M1 contract, measured in standalone luau. Thresholds are
-- the budgets themselves; each measurement takes the best of a few runs so
-- a busy machine does not fail the suite on one slow sample.
local Capture = require("../../../plugin/lib/lens/capture")
local Query = require("../../../plugin/lib/lens/query")
local View = require("../../../plugin/lib/lens/view")
local json = require("../../lib/json")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local RUNS = 5

local function bestMs(fn: () -> ()): number
	local best = math.huge
	for _ = 1, RUNS do
		local t0 = os.clock()
		fn()
		best = math.min(best, (os.clock() - t0) * 1000)
	end
	return best
end

local function buildOf(id: string): () -> Capture.Capture
	local f = runs.load(id)
	return function()
		return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
	end
end

describe("lens performance budgets", function()
	it("100-row capture build + render < 15 ms", function()
		local build = buildOf("synthetic/rows-100/get_pods_-A_-o_wide")
		local ms = bestMs(function()
			View.render(build(), vsm.opened(vsm.default(), "x"))
		end)
		expect(ms < 15).toBe(true)
	end)

	it("1000-row capture build < 60 ms", function()
		local build = buildOf("synthetic/rows-1000/get_pods_-A_-o_wide")
		local ms = bestMs(function()
			build()
		end)
		expect(ms < 60).toBe(true)
	end)

	it("1000-row sort + filter < 30 ms", function()
		local c = buildOf("synthetic/rows-1000/get_pods_-A_-o_wide")()
		local tbl = (c.snapshot :: any).tables[1]
		local vs = vsm.toggledProblems(vsm.sortedBy(vsm.sortedBy(vsm.default(), "AGE"), "AGE"))
		vs = vsm.toggledFilter(vs, "STATUS", "Running")
		vs = vsm.toggledFilter(vs, "STATUS", "CrashLoopBackOff")
		local ms = bestMs(function()
			Query.apply(tbl, vs)
			Query.apply(tbl, vsm.sortedBy(vsm.default(), "RESTARTS"))
		end)
		expect(ms < 30).toBe(true)
	end)

	it("1000-row render (500 cap) < 60 ms", function()
		local c = buildOf("synthetic/rows-1000/get_pods_-A_-o_wide")()
		local vs = vsm.sortedBy(vsm.default(), "AGE")
		local ms = bestMs(function()
			View.render(c, vs)
		end)
		expect(ms < 60).toBe(true)
	end)
end)

return nil
