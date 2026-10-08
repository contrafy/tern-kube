--!strict
-- Deterministic lens benchmark in standalone luau (`make bench`): capture
-- build, query and render over embedded fixtures, p50/p95 over RUNS samples
-- and Lua heap use. Thresholds are several times the PRD/M1 budgets so CI
-- fails on gross regressions only; docs/performance.md has the measured
-- numbers and the in-window ones.
local Capture = require("../plugin/lib/lens/capture")
local Query = require("../plugin/lib/lens/query")
local View = require("../plugin/lib/lens/view")
local json = require("../tests/lib/json")
local runs = require("../tests/lib/runs")
local vsm = require("../plugin/lib/lens/viewstate")

local RUNS = 30
local WARMUP = 3

type Stats = { p50: number, p95: number, max: number }
type Case = { name: string, run: () -> (), p95Limit: number }

local function percentile(sorted: { number }, p: number): number
	local rank = math.max(1, math.ceil(p / 100 * #sorted))
	return sorted[rank]
end

local function measure(fn: () -> ()): Stats
	for _ = 1, WARMUP do
		fn()
	end
	local samples: { number } = table.create(RUNS)
	for i = 1, RUNS do
		local t0 = os.clock()
		fn()
		samples[i] = (os.clock() - t0) * 1000
	end
	table.sort(samples)
	return { p50 = percentile(samples, 50), p95 = percentile(samples, 95), max = samples[#samples] }
end

local function build(id: string): Capture.Capture
	local f = runs.load(id)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function buildAndRender(id: string, vs: vsm.ViewState): () -> ()
	local f = runs.load(id)
	return function()
		local c = Capture.build(f.run, f.lines, f.status, { decode = json.decode })
		View.render(c, vs)
	end
end

local T100 = "synthetic/rows-100/get_pods_-A_-o_wide"
local T1000 = "synthetic/rows-1000/get_pods_-A_-o_wide"

local sorted = vsm.sortedBy(vsm.sortedBy(vsm.default(), "AGE"), "AGE")
local filtered =
	vsm.toggledFilter(vsm.toggledFilter(vsm.toggledProblems(sorted), "STATUS", "Running"), "STATUS", "CrashLoopBackOff")

local c1000 = build(T1000)
local t1000 = (c1000.snapshot :: any).tables[1]
local firstKey: string = t1000.rows[1].key

local cases: { Case } = {
	{ name = "100 rows: build + render", run = buildAndRender(T100, vsm.default()), p95Limit = 50 },
	{
		name = "100 rows: build + render, row open",
		run = buildAndRender(T100, vsm.opened(vsm.default(), "x")),
		p95Limit = 50,
	},
	{
		name = "1000 rows: build",
		run = function()
			build(T1000)
		end,
		p95Limit = 200,
	},
	{
		name = "1000 rows: sort + filter + problems",
		run = function()
			Query.apply(t1000, filtered)
			Query.apply(t1000, vsm.sortedBy(vsm.default(), "RESTARTS"))
		end,
		p95Limit = 100,
	},
	{
		name = "1000 rows: render sorted (500 cap)",
		run = function()
			View.render(c1000, sorted)
		end,
		p95Limit = 200,
	},
	{
		name = "1000 rows: render Inspect",
		run = function()
			View.render(c1000, vsm.inspect(sorted, firstKey))
		end,
		p95Limit = 100,
	},
	{
		name = "-o json (7 pods): build + render",
		run = buildAndRender("ns-apps/get_pods_-o_json", vsm.default()),
		p95Limit = 100,
	},
	{
		name = "-o yaml (7 pods): build + render",
		run = buildAndRender("ns-apps/get_pods_-o_yaml", vsm.default()),
		p95Limit = 100,
	},
	{
		name = "describe pods: build + render",
		run = buildAndRender("ns-apps/describe_pods", vsm.default()),
		p95Limit = 100,
	},
}

local failures: { string } = {}
print(string.format("%-40s %9s %9s %9s %9s", "case (" .. RUNS .. " runs)", "p50 ms", "p95 ms", "max ms", "limit"))
for _, case in cases do
	local s = measure(case.run)
	local ok = s.p95 < case.p95Limit
	print(
		string.format(
			"%-40s %9.2f %9.2f %9.2f %9s%s",
			case.name,
			s.p50,
			s.p95,
			s.max,
			"<" .. case.p95Limit,
			if ok then "" else "  FAIL"
		)
	)
	if not ok then
		table.insert(failures, case.name)
	end
end

-- Strict Luau only offers gcinfo() (no forced collection), so heap use is
-- sampled: the peak while building and rendering 1000-row captures, and the
-- growth from holding HELD of them (per capture: that growth / HELD; it
-- includes garbage not yet collected, so it is an upper bound).
local MEMORY_LIMIT_KB = 64 * 1024
local HELD = 10
local fixture = runs.load(T1000)
local base = gcinfo()
local peak = base
local held: { any } = {}
for i = 1, HELD do
	local capture = Capture.build(fixture.run, fixture.lines, fixture.status, { decode = json.decode })
	peak = math.max(peak, gcinfo())
	held[i] = { capture = capture, node = View.render(capture, sorted) }
	peak = math.max(peak, gcinfo())
end
local perCapture = (gcinfo() - base) / HELD
print(
	string.format(
		"1000 rows: <= %.0f KB per capture + view; heap peak %.0f KB (start %.0f KB); limit %d KB",
		perCapture,
		peak,
		base,
		MEMORY_LIMIT_KB
	)
)
if perCapture > MEMORY_LIMIT_KB then
	table.insert(failures, "1000-row memory per capture")
end

if #failures > 0 then
	error("bench thresholds exceeded: " .. table.concat(failures, ", "))
end
