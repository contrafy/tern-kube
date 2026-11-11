--!strict
-- Trends keep one sample per metrics window: metrics-server moves a pod's
-- window every 10-30 s, so a read inside the same window must not add a
-- duplicate point. Rings are capped and copy-on-write, so the previous state
-- of the Explore block keeps its own trends.
local Series = require("../../../plugin/lib/usage/series")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function clock(at: number): string
	return tostring(at)
end

local function fmt(v: number): string
	return string.format("%dm", math.floor(v * 1000 + 0.5))
end

describe("usage/series", function()
	it("the same window twice is one sample", function()
		local s, n = Series.add(Series.new(), { { key = "ns/p", t = 10, cpu = 0.02, mem = 1 } })
		expect(n).toBe(1)
		local s2, n2 = Series.add(s, { { key = "ns/p", t = 10, cpu = 0.03, mem = 1 } })
		expect(n2).toBe(0)
		expect(s2).toBe(s)
		expect(Series.count(s2, "ns/p")).toBe(1)
	end)

	it("keeps the last CAP samples", function()
		local s = Series.new()
		for i = 1, Series.CAP + 5 do
			s = (Series.add(s, { { key = "k", t = i, cpu = i, mem = i } }))
		end
		expect(Series.count(s, "k")).toBe(Series.CAP)
		expect(s.k.t[1]).toBe(6)
	end)

	it("is copy on write", function()
		local a = (Series.add(Series.new(), { { key = "k", t = 1, cpu = 1, mem = 1 } }))
		local b = (Series.add(a, { { key = "k", t = 2, cpu = 2, mem = 2 } }))
		expect(Series.count(a, "k")).toBe(1)
		expect(Series.count(b, "k")).toBe(2)
	end)

	it("a new key starts empty; samples without time or usage are skipped", function()
		local s = (
			Series.add(
				Series.new(),
				{ { key = "k", t = nil, cpu = 1, mem = 1 }, { key = "j", t = 1, cpu = nil, mem = 1 } }
			)
		)
		expect(Series.count(s, "k")).toBe(0)
		expect(Series.count(s, "j")).toBe(0)
		expect(Series.count(s, "other")).toBe(0)
	end)

	it("a spark needs two samples and names its span, extremes and limit", function()
		local s = (Series.add(Series.new(), { { key = "k", t = 100, cpu = 0.018, mem = 1 } }))
		local o: Series.SparkOpts = { field = "cpu", label = "CPU", format = fmt, clock = clock, limit = 0.02 }
		expect(Series.spark(s, "k", o)).toBeNil()
		s = (Series.add(s, { { key = "k", t = 115, cpu = 0.0199, mem = 1 } }))
		local cell = Series.spark(s, "k", o)
		expect(cell.spark.title).toBe("CPU, 2 samples 100-115, min 18m, max 20m, limit 20m")
		expect(cell.spark.max).toBe(0.02)
		expect(cell.spark.tone).toBe("error")
		expect(#cell.spark.values).toBe(2)
	end)

	it("without a limit the spark scales to its own max and has no tone", function()
		local s = (
			Series.add(Series.new(), { { key = "k", t = 1, cpu = 1, mem = 1 }, { key = "q", t = 1, cpu = 1, mem = 1 } })
		)
		s = (Series.add(s, { { key = "k", t = 2, cpu = 2, mem = 2 } }))
		local cell =
			Series.spark(s, "k", { field = "mem", label = "memory", format = tostring, clock = clock, limit = nil })
		expect(cell.spark.max).toBeNil()
		expect(cell.spark.tone).toBeNil()
	end)
end)

return nil
