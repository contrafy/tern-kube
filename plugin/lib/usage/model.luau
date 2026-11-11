--!strict
-- Resource usage arithmetic for the lens tones and the Explore usage views:
-- what a pod requests and may use, what a node has committed, percentages,
-- thresholds, formatting like `kubectl top`, and kubectl error mapping. Pure;
-- base units are cores and bytes, percentages are computed from the exact
-- values (nanocores, Ki), never from rounded text.
--
-- Two request totals exist on purpose:
-- - a pod's running request (its %CPU/R and %MEM/R): pod-level requests when
--   set, else app containers plus restartable init containers (sidecars);
--   what the pod asks for while it runs.
-- - the scheduler's effective request (a node's REQ column), KEP-753:
--   max(max_i(init_i + sidecars started before i), apps + sidecars), plus
--   overhead; pod-level requests replace it when set (KEP-2837). kubectl 1.34
--   `describe node` counts pod-level pods as 0, so the totals differ there.
-- Limits are enforced per container, so a pod's %CPU/L is the highest share a
-- container has of its own limit (an app at 101% of 20m next to a sidecar
-- with a 50m limit is not "29% of 70m").

local Parse = require("./parse")

type Pod = Parse.Pod
type PodMetric = Parse.PodMetric
type Res = Parse.Res

local M = {}

export type Tone = "warning" | "error"
-- limit: usage of a container limit; request: usage of a request; node: usage
-- of allocatable; nodeReq: requested of allocatable; nodeLim: limits of
-- allocatable (overcommit).
export type Scale = "limit" | "request" | "node" | "nodeReq" | "nodeLim"

-- Percent at or above which a cell turns warning / error (nil: never);
-- `over` is strict: limits may reach 100% of allocatable without overcommit.
M.TONES = table.freeze({
	limit = table.freeze({ warning = 80, error = 95 }),
	request = table.freeze({ warning = 100 }),
	node = table.freeze({ warning = 80, error = 95 }),
	nodeReq = table.freeze({ warning = 90, error = 100 }),
	nodeLim = table.freeze({ over = 100 }),
})

-- A pod at or above this share of a limit counts in the Near limits tile.
M.NEAR_LIMIT = 90

type Thresholds = { warning: number?, error: number?, over: number? }

function M.tone(scale: Scale, pct: number?): Tone?
	if pct == nil then
		return nil
	end
	local t: Thresholds = (M.TONES :: any)[scale]
	if t.error and pct >= t.error then
		return "error"
	end
	if (t.warning and pct >= t.warning) or (t.over and pct > t.over) then
		return "warning"
	end
	return nil
end

-- Formatting -------------------------------------------------------------------

local MI = 1024 * 1024
local GI = 1024 * MI

-- Millicores like `kubectl top` (Quantity.MilliValue rounds up: 20137840n is
-- 21m there too).
function M.cpu(cores: number?): string
	if cores == nil then
		return ""
	end
	return string.format("%dm", math.ceil(cores * 1000 - 1e-6))
end

-- Mebibytes like `kubectl top` (floored); below 1Mi in Ki rather than `0Mi`.
function M.mem(bytes: number?): string
	if bytes == nil then
		return ""
	end
	if bytes < MI then
		return string.format("%dKi", bytes // 1024)
	end
	return string.format("%dMi", bytes // MI)
end

-- Tile figures: `10 cores`, `1.5 cores`, `193m`.
function M.cores(cores: number): string
	if cores < 1 then
		return M.cpu(cores)
	end
	local whole = math.floor(cores)
	if math.abs(cores - whole) < 1e-9 then
		return string.format("%d %s", whole, if whole == 1 then "core" else "cores")
	end
	return string.format("%.1f cores", cores)
end

-- Tile figures: `835Mi`, `1.7Gi`.
function M.bytes(bytes: number): string
	if bytes >= GI then
		return string.format("%.1fGi", bytes / GI)
	end
	return M.mem(bytes)
end

-- `7.5%` under 10, `101%` above; sortable by Values.percent.
function M.pct(p: number?): string
	if p == nil then
		return ""
	end
	if p < 10 then
		return string.format("%.1f%%", math.floor(p * 10 + 0.5) / 10)
	end
	return string.format("%d%%", math.floor(p + 0.5))
end

function M.percent(part: number?, whole: number?): number?
	if part == nil or whole == nil or whole <= 0 then
		return nil
	end
	return part / whole * 100
end

-- Requests and limits -----------------------------------------------------------

local function add(a: number?, b: number?): number?
	if a == nil then
		return b
	elseif b == nil then
		return a
	end
	return a + b
end

type Which = "req" | "lim"

local function pick(c: { req: Res, lim: Res }, which: Which): Res
	return if which == "req" then c.req else c.lim
end

-- The containers that run beside the app: apps and restartable inits.
local function running(pod: Pod): { { name: string, req: Res, lim: Res, kind: string } }
	local out: { { name: string, req: Res, lim: Res, kind: string } } = {}
	for _, c in pod.containers do
		table.insert(out, { name = c.name, req = c.req, lim = c.lim, kind = "container" })
	end
	for _, c in pod.inits do
		if c.sidecar then
			table.insert(out, { name = c.name, req = c.req, lim = c.lim, kind = "sidecar" })
		end
	end
	return out
end

-- What the pod asks for while it runs; nil per resource when nothing sets it.
function M.runningRequest(pod: Pod): Res
	local out: Res = { cpu = nil, mem = nil }
	for _, c in running(pod) do
		out.cpu = add(out.cpu, c.req.cpu)
		out.mem = add(out.mem, c.req.mem)
	end
	return { cpu = pod.podReq.cpu or out.cpu, mem = pod.podReq.mem or out.mem }
end

-- The scheduler's effective request (or limit) of a pod; 0 when unset, as
-- the node totals count it.
function M.effective(pod: Pod, which: Which): { cpu: number, mem: number }
	local podLevel = pick({ req = pod.podReq, lim = pod.podLim }, which)
	local function one(field: "cpu" | "mem"): number
		local own = (podLevel :: any)[field] :: number?
		if own then
			return own + ((pod.overhead :: any)[field] or 0)
		end
		local apps = 0
		for _, c in pod.containers do
			apps += (pick(c, which) :: any)[field] or 0
		end
		local sidecars, initMax = 0, 0
		for _, c in pod.inits do
			local v = (pick(c, which) :: any)[field] or 0
			if c.sidecar then
				sidecars += v
				initMax = math.max(initMax, sidecars)
			else
				initMax = math.max(initMax, v + sidecars)
			end
		end
		return math.max(apps + sidecars, initMax) + ((pod.overhead :: any)[field] or 0)
	end
	return { cpu = one("cpu"), mem = one("mem") }
end

-- Every running container sets both requests, or the pod sets them.
function M.hasRequests(pod: Pod): boolean
	for _, field in { "cpu", "mem" } do
		if (pod.podReq :: any)[field] == nil then
			for _, c in running(pod) do
				if (c.req :: any)[field] == nil then
					return false
				end
			end
		end
	end
	return true
end

function M.terminal(pod: Pod): boolean
	return pod.phase == "Succeeded" or pod.phase == "Failed"
end

export type Share = { pct: number?, title: string? }

-- The highest share a running container has of its own limit (or the pod's
-- usage of its pod-level limit), with who and what the others lack.
function M.limitShare(pod: Pod, metric: PodMetric?, field: "cpu" | "mem"): Share
	local fmt: (number?) -> string = if field == "cpu" then M.cpu else M.mem
	local podLimit = (pod.podLim :: any)[field] :: number?
	if podLimit then
		local used = if metric then (metric :: any)[field] :: number? else nil
		local pct = M.percent(used, podLimit)
		return {
			pct = pct,
			title = if pct then "pod at " .. M.pct(pct) .. " of its pod-level limit " .. fmt(podLimit) else nil,
		}
	end
	local best: number? = nil
	local bestText: string? = nil
	local without: { string } = {}
	local limited = 0
	for _, c in running(pod) do
		local lim = (c.lim :: any)[field] :: number?
		if lim == nil then
			table.insert(without, c.name)
			continue
		end
		limited += 1
		local u = if metric then Parse.container(metric, c.name) else nil
		local used = if u then (u :: any)[field] :: number? else nil
		local pct = M.percent(used, lim)
		if pct and (best == nil or pct > best) then
			best = pct
			bestText = c.name .. " at " .. M.pct(pct) .. " of " .. fmt(lim)
		end
	end
	if limited == 0 or best == nil then
		return { pct = nil, title = nil }
	end
	local title = bestText :: string
	if #without > 0 then
		title ..= "; " .. table.concat(without, ", ") .. (if #without == 1 then " has" else " have") .. " no limit"
	end
	return { pct = best, title = title }
end

-- Rows --------------------------------------------------------------------------

export type PodRow = {
	key: string,
	namespace: string,
	name: string,
	node: string?,
	phase: string?,
	pod: Pod,
	metric: PodMetric?,
	cpu: number?,
	mem: number?,
	req: Res,
	limCpu: Share,
	limMem: Share,
	reqCpuPct: number?,
	reqMemPct: number?,
}

function M.podKey(namespace: string, name: string): string
	return namespace .. "/" .. name
end

function M.metricsByKey(metrics: { PodMetric }): { [string]: PodMetric }
	local out: { [string]: PodMetric } = {}
	for _, m in metrics do
		out[M.podKey(m.namespace, m.name)] = m
	end
	return out
end

function M.podRow(pod: Pod, metric: PodMetric?): PodRow
	local req = M.runningRequest(pod)
	local cpu = if metric then metric.cpu else nil
	local mem = if metric then metric.mem else nil
	return {
		key = M.podKey(pod.namespace, pod.name),
		namespace = pod.namespace,
		name = pod.name,
		node = pod.node,
		phase = pod.phase,
		pod = pod,
		metric = metric,
		cpu = cpu,
		mem = mem,
		req = req,
		limCpu = M.limitShare(pod, metric, "cpu"),
		limMem = M.limitShare(pod, metric, "mem"),
		reqCpuPct = M.percent(cpu, req.cpu),
		reqMemPct = M.percent(mem, req.mem),
	}
end

-- Pods joined with their metrics (pods without a metrics window keep nil
-- usage); `node` keeps only the pods bound to it.
function M.podRows(pods: { Pod }, metrics: { PodMetric }, node: string?): { PodRow }
	local byKey = M.metricsByKey(metrics)
	local out: { PodRow } = {}
	for _, p in pods do
		if node == nil or p.node == node then
			table.insert(out, M.podRow(p, byKey[M.podKey(p.namespace, p.name)]))
		end
	end
	return out
end

export type ContainerRow = {
	key: string,
	name: string,
	-- container | sidecar | init (done)
	kind: string,
	cpu: number?,
	mem: number?,
	req: Res,
	lim: Res,
}

function M.containerRows(pod: Pod, metric: PodMetric?): { ContainerRow }
	local out: { ContainerRow } = {}
	local function push(name: string, kind: string, req: Res, lim: Res)
		local u = if metric then Parse.container(metric, name) else nil
		table.insert(out, {
			key = M.podKey(pod.namespace, pod.name) .. "/" .. name,
			name = name,
			kind = kind,
			cpu = if u then u.cpu else nil,
			mem = if u then u.mem else nil,
			req = req,
			lim = lim,
		})
	end
	for _, c in pod.containers do
		push(c.name, "container", c.req, c.lim)
	end
	for _, c in pod.inits do
		push(c.name, if c.sidecar then "sidecar" else "init (done)", c.req, c.lim)
	end
	return out
end

export type PodTotals = {
	listed: number,
	withMetrics: number,
	cpu: number,
	mem: number,
	reqCpu: number,
	reqMem: number,
	limCpu: number,
	limMem: number,
	nearLimits: number,
	noRequests: number,
}

function M.podTotals(rows: { PodRow }): PodTotals
	local t: PodTotals = {
		listed = #rows,
		withMetrics = 0,
		cpu = 0,
		mem = 0,
		reqCpu = 0,
		reqMem = 0,
		limCpu = 0,
		limMem = 0,
		nearLimits = 0,
		noRequests = 0,
	}
	for _, r in rows do
		if r.metric then
			t.withMetrics += 1
			t.cpu += r.cpu or 0
			t.mem += r.mem or 0
		end
		if M.terminal(r.pod) then
			continue
		end
		t.reqCpu += r.req.cpu or 0
		t.reqMem += r.req.mem or 0
		local lim = M.effective(r.pod, "lim")
		t.limCpu += lim.cpu
		t.limMem += lim.mem
		if (r.limCpu.pct or 0) >= M.NEAR_LIMIT or (r.limMem.pct or 0) >= M.NEAR_LIMIT then
			t.nearLimits += 1
		end
		if r.phase == "Running" and not M.hasRequests(r.pod) then
			t.noRequests += 1
		end
	end
	return t
end

export type NodeRow = {
	key: string,
	name: string,
	node: Parse.Node,
	metric: Parse.NodeMetric?,
	cpu: number?,
	mem: number?,
	cpuPct: number?,
	memPct: number?,
	-- Committed by the scheduler (nil: the pods could not be read).
	reqCpu: number?,
	reqMem: number?,
	limCpu: number?,
	limMem: number?,
	pods: number?,
	status: string,
}

export type Committed = { cpu: number, mem: number, limCpu: number, limMem: number, pods: number }

-- Per node, what its non-terminal pods commit (scheduler formula).
function M.committed(pods: { Pod }): { [string]: Committed }
	local out: { [string]: Committed } = {}
	for _, p in pods do
		local node = p.node
		if node == nil or M.terminal(p) then
			continue
		end
		local c = out[node]
		if c == nil then
			c = { cpu = 0, mem = 0, limCpu = 0, limMem = 0, pods = 0 }
			out[node] = c
		end
		local req = M.effective(p, "req")
		local lim = M.effective(p, "lim")
		c.cpu += req.cpu
		c.mem += req.mem
		c.limCpu += lim.cpu
		c.limMem += lim.mem
		c.pods += 1
	end
	return out
end

-- STATUS like `kubectl get nodes`: Ready / NotReady / Unknown, plus
-- SchedulingDisabled when cordoned.
function M.nodeStatus(n: Parse.Node): string
	local base = if n.ready == "True" then "Ready" elseif n.ready == "False" then "NotReady" else "Unknown"
	return if n.unschedulable then base .. ",SchedulingDisabled" else base
end

function M.nodeRows(nodes: { Parse.Node }, metrics: { Parse.NodeMetric }, pods: { Pod }?): { NodeRow }
	local byName: { [string]: Parse.NodeMetric } = {}
	for _, m in metrics do
		byName[m.name] = m
	end
	local committed = if pods then M.committed(pods) else nil
	local out: { NodeRow } = {}
	for _, n in nodes do
		local m = byName[n.name]
		local c: Committed? = if committed
			then (committed[n.name] or { cpu = 0, mem = 0, limCpu = 0, limMem = 0, pods = 0 })
			else nil
		local cpu = if m then m.cpu else nil
		local mem = if m then m.mem else nil
		table.insert(out, {
			key = n.name,
			name = n.name,
			node = n,
			metric = m,
			cpu = cpu,
			mem = mem,
			cpuPct = M.percent(cpu, n.alloc.cpu),
			memPct = M.percent(mem, n.alloc.mem),
			reqCpu = if c then c.cpu else nil,
			reqMem = if c then c.mem else nil,
			limCpu = if c then c.limCpu else nil,
			limMem = if c then c.limMem else nil,
			pods = if c then c.pods else nil,
			status = M.nodeStatus(n),
		})
	end
	return out
end

export type NodeTotals = {
	total: number,
	ready: number,
	cpu: number,
	mem: number,
	allocCpu: number,
	allocMem: number,
	allocPods: number,
	reqCpu: number?,
	reqMem: number?,
	limCpu: number?,
	limMem: number?,
	pods: number?,
}

function M.nodeTotals(rows: { NodeRow }): NodeTotals
	local t: NodeTotals = {
		total = #rows,
		ready = 0,
		cpu = 0,
		mem = 0,
		allocCpu = 0,
		allocMem = 0,
		allocPods = 0,
		reqCpu = nil,
		reqMem = nil,
		limCpu = nil,
		limMem = nil,
		pods = nil,
	}
	for _, r in rows do
		if r.node.ready == "True" then
			t.ready += 1
		end
		t.cpu += r.cpu or 0
		t.mem += r.mem or 0
		t.allocCpu += r.node.alloc.cpu or 0
		t.allocMem += r.node.alloc.mem or 0
		t.allocPods += r.node.alloc.pods or 0
		t.reqCpu = add(t.reqCpu, r.reqCpu)
		t.reqMem = add(t.reqMem, r.reqMem)
		t.limCpu = add(t.limCpu, r.limCpu)
		t.limMem = add(t.limMem, r.limMem)
		t.pods = add(t.pods, r.pods)
	end
	return t
end

-- The oldest metrics window end of a read: the numbers are at least this old.
function M.oldest(times: { number? }): number?
	local out: number? = nil
	for _, t in times do
		if t and (out == nil or t < out) then
			out = t
		end
	end
	return out
end

-- Errors ------------------------------------------------------------------------

M.METRICS_MISSING =
	"Metrics API not available: metrics-server is not installed or not ready (kubectl top fails the same way)"
M.NO_WINDOW = "metrics-server reports a pod after its first window (about 15 s)"

local function firstLine(text: string): string
	return string.match(text, "^%s*([^\n]*)") or text
end

-- A failed metrics read as a message and kind (`metrics`, `forbidden`), or
-- nil when it is not a metrics problem (the generic failure text applies).
-- `api`: the resource read (`pods.metrics.k8s.io`, `nodes.metrics.k8s.io`,
-- `pods`).
function M.metricsError(stderr: string, api: string): (string?, string?)
	local lower = string.lower(stderr)
	if string.find(lower, "forbidden", 1, true) then
		return firstLine(stderr) .. " (needs list on " .. api .. ")", "forbidden"
	end
	if string.find(api, "metrics", 1, true) == nil then
		return nil, nil
	end
	if
		string.find(lower, "doesn't have a resource type", 1, true)
		or string.find(lower, "serviceunavailable", 1, true)
		or string.find(lower, "service unavailable", 1, true)
		or string.find(lower, "metrics api not available", 1, true)
		or string.find(lower, "could not find the requested resource", 1, true)
	then
		return M.METRICS_MISSING, "metrics"
	end
	return nil, nil
end

return M
