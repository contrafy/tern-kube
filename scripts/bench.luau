--!strict
-- Deterministic lens benchmark in standalone luau (`make bench`): capture
-- build, query and render over embedded fixtures, p50/p95 over RUNS samples
-- and Lua heap use. Thresholds are several times the PRD/M1 budgets so CI
-- fails on gross regressions only; docs/performance.md has the measured
-- numbers and the in-window ones.
local Capture = require("../plugin/lib/lens/capture")
local CompareModel = require("../plugin/lib/compare/model")
local CompareView = require("../plugin/lib/compare/view")
local LogsQuery = require("../plugin/lib/logs/query")
local LogsStore = require("../plugin/lib/logs/store")
local LogsTypes = require("../plugin/lib/logs/types")
local Query = require("../plugin/lib/lens/query")
local UsageModel = require("../plugin/lib/usage/model")
local UsageParse = require("../plugin/lib/usage/parse")
local UsageView = require("../plugin/lib/usage/view")
local View = require("../plugin/lib/lens/view")
local fixtures = require("../tests/lib/fixtures")
local json = require("../tests/lib/json")
local runs = require("../tests/lib/runs")
local synth = require("./fixtures/synth")
local vsm = require("../plugin/lib/lens/viewstate")

local RUNS = 30
local WARMUP = 3

type Stats = { p50: number, p95: number, max: number }
-- `items`: also report the p50 per item (logs: microseconds per line).
-- `setup`: runs untimed before every sample.
type Case = { name: string, run: () -> (), p95Limit: number, items: number?, setup: (() -> ())? }

local function percentile(sorted: { number }, p: number): number
	local rank = math.max(1, math.ceil(p / 100 * #sorted))
	return sorted[rank]
end

local function measure(fn: () -> (), setup: (() -> ())?): Stats
	for _ = 1, WARMUP do
		if setup then
			setup()
		end
		fn()
	end
	local samples: { number } = table.create(RUNS)
	for i = 1, RUNS do
		if setup then
			setup()
		end
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

local LOG_LINES = 20000
local mixedLines = synth.logLines(LOG_LINES, 20261102, false)
local prefixedLines = synth.logLines(LOG_LINES, 20261102, true)

local function logStore(lines: { string }, prefixed: boolean): LogsStore.Store
	local opts: LogsTypes.Options = { prefix = prefixed, timestamps = prefixed, follow = false, decode = json.decode }
	local s = LogsStore.new(opts, { maxLines = 100000, maxBytes = 64 * 1024 * 1024 })
	for _, l in lines do
		LogsStore.push(s, l)
	end
	LogsStore.finish(s, 0)
	return s
end

local prefixedStore = logStore(prefixedLines, true)
local PAGE = 500

-- Each sample follows an apply of another filter, so the store's last result
-- does not answer it: the cost of a click that changes the filter, with the
-- per-record search text and the merged order already built.
local OTHER_FILTER: LogsQuery.Filter = { merge = false, levels = {} }

local function applyCase(name: string, filter: LogsQuery.Filter): Case
	return {
		name = name,
		setup = function()
			LogsQuery.apply(prefixedStore, OTHER_FILTER, nil, PAGE)
		end,
		run = function()
			LogsQuery.apply(prefixedStore, filter, nil, PAGE)
		end,
		p95Limit = 20,
	}
end

-- List compare (0.6.0): COMPARE_OBJECTS Deployments per context, copies of
-- the captured tkm-web. Every other context lacks the first 10, has 10 of
-- its own and scales every 10th: same, changed, missing and extra rows.
local COMPARE_OBJECTS = 500
local deployTemplate = json.decode(fixtures.read("real/compare/a-deployments-list.json")).items[1]

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function deployments(base: boolean): { any }
	local out = table.create(COMPARE_OBJECTS)
	for i = 1, COMPARE_OBJECTS do
		local n = if base then i else i + 10
		local d = deepCopy(deployTemplate)
		d.metadata.name = string.format("tkm-%03d", n)
		if not base and n % 10 == 0 then
			d.spec.replicas = 5
		end
		out[i] = d
	end
	return out
end

local compareSides: { { any }? } = { deployments(true) }
for i = 2, 4 do
	compareSides[i] = deployments(false)
end

local function compareColumns(n: number): { CompareModel.Column }
	local out: { CompareModel.Column } = {}
	for i = 1, n do
		out[i] = { context = "kind-tern-kube-c" .. i, label = "c" .. i, status = "ok" }
	end
	return out
end

local COMPARE_OPTS: CompareModel.ListOptions =
	{ policy = { showSecrets = false, strict = false }, maxPaths = 3, maxObjects = COMPARE_OBJECTS }

local function listMatrix(n: number): CompareModel.Matrix
	return CompareModel.listMatrix(compareColumns(n), table.move(compareSides, 1, n, 1, {}), COMPARE_OPTS)
end

local matrix2 = listMatrix(2)
-- A degenerate matrix (nothing paired, nothing changed) would time the wrong work.
assert(
	#matrix2.rows == COMPARE_OBJECTS + 10
		and matrix2.rows[1].cells[2].state == "missing"
		and matrix2.rows[20].cells[2].state == "changed"
		and matrix2.rows[21].cells[2].state == "same"
		and matrix2.rows[#matrix2.rows].cells[2].state == "extra",
	"compare bench: unexpected synthetic matrix"
)

-- The usage views' jsonpath output for USAGE_PODS pods over 20 namespaces and
-- 10 nodes; every fourth pod has a sidecar, every tenth has no metrics yet.
local USAGE_PODS = 2000
local function usageText(): (string, string)
	local pods: { string } = table.create(USAGE_PODS)
	local metrics: { string } = {}
	for i = 1, USAGE_PODS do
		local ns, name = "ns-" .. (i % 20), "pod-" .. i
		local sidecar = i % 4 == 0
		table.insert(
			pods,
			string.format(
				"%s\t%s\tnode-%d\tRunning\t,,,\tapp=%dm,%dMi,500m,512Mi;\t%s\t,",
				ns,
				name,
				i % 10,
				50 + i % 200,
				64 + i % 128,
				if sidecar then "proxy=Always,20m,16Mi,50m,32Mi;" else "setup=,100m,64Mi,,;"
			)
		)
		if i % 10 ~= 0 then
			table.insert(
				metrics,
				string.format(
					"%s\t%s\t2026-11-11T10:00:00Z\t15s\tapp=%dm,%dKi;%s",
					ns,
					name,
					i % 480,
					40000 + i * 37 % 400000,
					if sidecar then "proxy=3m,9000Ki;" else ""
				)
			)
		end
	end
	return table.concat(pods, "\n") .. "\n", table.concat(metrics, "\n") .. "\n"
end
-- Held only while the usage cases run (cleared before the heap sample).
local usageInput: { pods: string?, metrics: string?, rows: { UsageModel.PodRow }? } = {}
usageInput.pods, usageInput.metrics = usageText()
usageInput.rows =
	UsageModel.podRows(UsageParse.pods(usageInput.pods :: string), UsageParse.podMetrics(usageInput.metrics :: string))
local usageRows = usageInput.rows :: { UsageModel.PodRow }
assert(
	#usageRows == USAGE_PODS and usageRows[1].metric ~= nil and usageRows[10].metric == nil,
	"usage bench: unexpected synthetic join"
)
usageRows = nil :: any

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
	{
		name = "20 000 mixed lines: push",
		run = function()
			logStore(mixedLines, false)
		end,
		p95Limit = 300,
		items = LOG_LINES,
	},
	{
		name = "20 000 prefixed+ts lines: push",
		run = function()
			logStore(prefixedLines, true)
		end,
		p95Limit = 300,
		items = LOG_LINES,
	},
	applyCase("20 000 lines: apply + page", { merge = false }),
	applyCase("20 000 lines: apply errors + page", { merge = false, levels = { error = true, fatal = true } }),
	applyCase("20 000 lines: apply warn+ 1 source", { merge = false, minLevel = "warn", sources = { [1] = true } }),
	applyCase("20 000 lines: apply text + page", { merge = false, text = "Checkout" }),
	applyCase("20 000 lines: apply merge by time", { merge = true }),
	{
		name = "compare 500 deploys x 2 ctx: matrix",
		run = function()
			listMatrix(2)
		end,
		p95Limit = 200,
	},
	{
		name = "compare 500 deploys x 4 ctx: matrix",
		run = function()
			listMatrix(4)
		end,
		p95Limit = 400,
	},
	{
		name = "compare 500 deploys x 2 ctx: render",
		run = function()
			CompareView.matrix(matrix2, nil, {
				narrow = true,
				filter = "all",
				title = "510 objects across 2 contexts",
				window = { first = 1, last = #matrix2.rows },
			})
		end,
		p95Limit = 100,
	},
	{
		name = "usage: 2000 pods parse + join + rows",
		run = function()
			local rows = UsageModel.podRows(
				UsageParse.pods(usageInput.pods :: string),
				UsageParse.podMetrics(usageInput.metrics :: string)
			)
			UsageModel.podTotals(rows)
		end,
		p95Limit = 100,
		items = USAGE_PODS,
	},
	{
		name = "usage: render page",
		run = function()
			UsageView.pods(usageInput.rows :: { UsageModel.PodRow }, { metricsRead = true })
		end,
		p95Limit = 100,
	},
}

local failures: { string } = {}
print(string.format("%-40s %9s %9s %9s %9s", "case (" .. RUNS .. " runs)", "p50 ms", "p95 ms", "max ms", "limit"))
for _, case in cases do
	local s = measure(case.run, case.setup)
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
	if case.items then
		print(string.format("%-40s %9.2f us per item (p50)", "", s.p50 * 1000 / case.items))
	end
	if not ok then
		table.insert(failures, case.name)
	end
end
usageInput.pods, usageInput.metrics, usageInput.rows = nil, nil, nil

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
