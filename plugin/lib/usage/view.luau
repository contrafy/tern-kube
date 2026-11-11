--!strict
-- The usage views' tiles and table data: pods (of a namespace scope, a
-- selector or a node), one pod's containers, and nodes. Built once per load
-- (cells are text so the list machinery sorts and filters them; tones and
-- titles are prebuilt Tern cells in `raw`); the trend cells are added per
-- render for the visible rows only (`withTrends`). Pure.

local Model = require("./model")
local Series = require("./series")
local Types = require("../model/types")

type Ref = Types.ResourceRef
type ColumnType = Types.ColumnType

local M = {}

M.NONE = "<none>"
M.NO_METRICS = "<no metrics>"
M.FORBIDDEN = "<forbidden>"
M.NO_METRICS_TITLE = "metrics-server has no window for this pod yet (new, not running, or completed)"
M.TRENDS_OFF = string.format("Trends off above %d objects", Series.MAX_ROWS)
M.ONE_SAMPLE = "·"

export type Trend = { key: string, limCpu: number?, limMem: number? }

export type URow = {
	key: string,
	ref: Ref?,
	cells: { string },
	hay: string,
	-- Prebuilt Tern table cells by column index (tones, titles).
	raw: { [number]: any },
	trend: Trend?,
}

export type Built = {
	kind: "pods" | "containers" | "nodes",
	headers: { string },
	types: { ColumnType },
	rows: { URow },
	tiles: { any },
	notes: { string },
	-- Columns the header click does not sort (trends).
	unsortable: { [string]: boolean },
	-- Indices of the CPU~ / MEM~ columns.
	trendCols: { cpu: number, mem: number },
}

local UNSORTABLE = table.freeze({ ["CPU~"] = true, ["MEM~"] = true })

local function spans(text: string, style: string?): { any }
	return { if style then { t = text, s = style } else { t = text } }
end

local function tile(label: string, value: string, sub: string?, tone: string?, title: string?): any
	return {
		label = spans(label),
		value = spans(value),
		sub = if sub then spans(sub) else nil,
		tone = tone,
		title = title,
	}
end

-- A percent cell: text for sort/filter, a toned raw cell with its title.
local function pctCell(raw: { [number]: any }, i: number, pct: number?, scale: Model.Scale, title: string?): string
	if pct == nil then
		return M.NONE
	end
	local text = Model.pct(pct)
	local tone = Model.tone(scale, pct)
	local cell = { text = spans(text, if tone then tone .. " mono" else "mono"), title = title }
	raw[i] = cell
	return text
end

local function noMetrics(raw: { [number]: any }, i: number): string
	raw[i] = { text = spans(M.NO_METRICS, "muted"), title = M.NO_METRICS_TITLE }
	return M.NO_METRICS
end

local function hay(cells: { string }): string
	return string.lower(table.concat(cells, " "))
end

-- The limit a pod's whole trend is drawn against: pod-level, else the sum of
-- its running containers' limits when every one has one.
local function podLimit(pod: any, field: "cpu" | "mem"): number?
	local own = pod.podLim[field]
	if own then
		return own
	end
	local sum = 0
	local any = false
	for _, c in pod.containers do
		local v = c.lim[field]
		if v == nil then
			return nil
		end
		sum += v
		any = true
	end
	for _, c in pod.inits do
		if c.sidecar then
			local v = c.lim[field]
			if v == nil then
				return nil
			end
			sum += v
		end
	end
	return if any then sum else nil
end

local function orDash(p: number?): string
	return if p then Model.pct(p) else "-"
end

local function shareTitle(share: Model.Share, word: string): string?
	return if share.title then share.title .. " (highest container share of its " .. word .. " limit)" else nil
end

export type PodOpts = {
	context: string?,
	-- Why metrics are missing (mapped error), nil when they were read.
	metricsError: string?,
	-- Metrics were read (an empty read with listed pods gets a note).
	metricsRead: boolean,
}

local POD_HEADERS =
	{ "NAMESPACE", "NAME", "CPU", "MEM", "%CPU/L", "%MEM/L", "%CPU/R", "%MEM/R", "CPU~", "MEM~", "NODE" }
local POD_TYPES: { ColumnType } =
	{ "text", "text", "quantity", "quantity", "percent", "percent", "percent", "percent", "text", "text", "text" }

function M.podRef(namespace: string, name: string, context: string?): Ref
	return { kind = "Pod", name = name, namespace = namespace, source = "live", clusterContext = context }
end

function M.pods(rows: { Model.PodRow }, o: PodOpts): Built
	local out: { URow } = table.create(#rows)
	for i, r in rows do
		local raw: { [number]: any } = {}
		local cells: { string } = table.create(#POD_HEADERS)
		cells[1] = r.namespace
		cells[2] = r.name
		if r.metric then
			cells[3] = Model.cpu(r.cpu)
			cells[4] = Model.mem(r.mem)
			cells[5] = pctCell(raw, 5, r.limCpu.pct, "limit", shareTitle(r.limCpu, "CPU"))
			cells[6] = pctCell(raw, 6, r.limMem.pct, "limit", shareTitle(r.limMem, "memory"))
			cells[7] = pctCell(raw, 7, r.reqCpuPct, "request", nil)
			cells[8] = pctCell(raw, 8, r.reqMemPct, "request", nil)
		else
			for c = 3, 8 do
				cells[c] = noMetrics(raw, c)
			end
		end
		cells[9] = ""
		cells[10] = ""
		cells[11] = r.node or M.NONE
		out[i] = {
			key = r.key,
			ref = M.podRef(r.namespace, r.name, o.context),
			cells = cells,
			hay = hay(cells),
			raw = raw,
			trend = { key = r.key, limCpu = podLimit(r.pod, "cpu"), limMem = podLimit(r.pod, "mem") },
		}
	end
	local t = Model.podTotals(rows)
	local missing = t.listed - t.withMetrics
	local tiles = {
		tile(
			"Pods",
			string.format("%d / %d", t.withMetrics, t.listed),
			if missing > 0 then string.format("%d without metrics", missing) else nil,
			nil,
			"Pods with a metrics window / pods listed"
		),
		tile(
			"CPU",
			Model.cpu(t.cpu),
			string.format(
				"%s of %s requested · %s of %s limits",
				orDash(Model.percent(t.cpu, t.reqCpu)),
				Model.cpu(t.reqCpu),
				orDash(Model.percent(t.cpu, t.limCpu)),
				Model.cpu(t.limCpu)
			),
			if t.reqCpu > 0 and t.cpu > t.reqCpu then "warning" else nil,
			"Used by pods with metrics; requested and limits of the pods not finished"
		),
		tile(
			"Memory",
			Model.mem(t.mem),
			string.format(
				"%s of %s requested · %s of %s limits",
				orDash(Model.percent(t.mem, t.reqMem)),
				Model.mem(t.reqMem),
				orDash(Model.percent(t.mem, t.limMem)),
				Model.mem(t.limMem)
			),
			if t.reqMem > 0 and t.mem > t.reqMem then "warning" else nil,
			"Used by pods with metrics; requested and limits of the pods not finished"
		),
		tile(
			"Near limits",
			tostring(t.nearLimits),
			"CPU throttling or OOM risk",
			if t.nearLimits > 0 then "error" else nil,
			string.format("Pods with a container at %d%% or more of its CPU or memory limit", Model.NEAR_LIMIT)
		),
		tile(
			"No requests",
			tostring(t.noRequests),
			"BestEffort or partial",
			if t.noRequests > 0 then "warning" else nil,
			"Running pods with a container that requests no CPU or no memory"
		),
	}
	local notes: { string } = {}
	if o.metricsError then
		table.insert(notes, o.metricsError)
	elseif o.metricsRead and t.listed > 0 and t.withMetrics == 0 then
		table.insert(notes, Model.NO_WINDOW)
	end
	if #rows > Series.MAX_ROWS then
		table.insert(notes, M.TRENDS_OFF)
	end
	return {
		kind = "pods",
		headers = table.clone(POD_HEADERS),
		types = table.clone(POD_TYPES),
		rows = out,
		tiles = tiles,
		notes = notes,
		unsortable = UNSORTABLE,
		trendCols = { cpu = 9, mem = 10 },
	}
end

local CONTAINER_HEADERS = { "CONTAINER", "KIND", "CPU", "MEM", "%CPU/L", "%MEM/L", "%CPU/R", "%MEM/R", "CPU~", "MEM~" }
local CONTAINER_TYPES: { ColumnType } =
	{ "text", "text", "quantity", "quantity", "percent", "percent", "percent", "percent", "text", "text" }

-- One pod's containers; `row` from the pods load (no new query).
function M.containers(r: Model.PodRow, context: string?, metricsError: string?): Built
	local ref = M.podRef(r.namespace, r.name, context)
	local out: { URow } = {}
	for _, c in Model.containerRows(r.pod, r.metric) do
		local raw: { [number]: any } = {}
		local cells: { string } = { c.name, c.kind }
		local done = c.kind == "init (done)"
		if c.cpu ~= nil or c.mem ~= nil then
			cells[3] = Model.cpu(c.cpu)
			cells[4] = Model.mem(c.mem)
			cells[5] = pctCell(raw, 5, Model.percent(c.cpu, c.lim.cpu), "limit", nil)
			cells[6] = pctCell(raw, 6, Model.percent(c.mem, c.lim.mem), "limit", nil)
			cells[7] = pctCell(raw, 7, Model.percent(c.cpu, c.req.cpu), "request", nil)
			cells[8] = pctCell(raw, 8, Model.percent(c.mem, c.req.mem), "request", nil)
		elseif done then
			for i = 3, 8 do
				cells[i] = ""
			end
		else
			for i = 3, 8 do
				cells[i] = noMetrics(raw, i)
			end
		end
		cells[9] = ""
		cells[10] = ""
		table.insert(out, {
			key = c.key,
			ref = ref,
			cells = cells,
			hay = hay(cells),
			raw = raw,
			trend = if done then nil else { key = c.key, limCpu = c.lim.cpu, limMem = c.lim.mem },
		})
	end
	local notes: { string } = {}
	if metricsError then
		table.insert(notes, metricsError)
	elseif r.metric == nil then
		table.insert(notes, M.NO_METRICS_TITLE)
	end
	local p = r.pod
	if p.podReq.cpu or p.podReq.mem or p.podLim.cpu or p.podLim.mem then
		table.insert(
			notes,
			string.format(
				"pod-level requests %s / %s, limits %s / %s apply to the pod as a whole",
				if p.podReq.cpu then Model.cpu(p.podReq.cpu) else M.NONE,
				if p.podReq.mem then Model.mem(p.podReq.mem) else M.NONE,
				if p.podLim.cpu then Model.cpu(p.podLim.cpu) else M.NONE,
				if p.podLim.mem then Model.mem(p.podLim.mem) else M.NONE
			)
		)
	end
	local tiles = {
		tile("CPU", if r.metric then Model.cpu(r.cpu) else M.NO_METRICS, nil, nil, nil),
		tile("Memory", if r.metric then Model.mem(r.mem) else M.NO_METRICS, nil, nil, nil),
		tile(
			"Limit share",
			if r.limCpu.pct or r.limMem.pct then Model.pct(math.max(r.limCpu.pct or 0, r.limMem.pct or 0)) else M.NONE,
			r.limCpu.title or r.limMem.title,
			Model.tone(
				"limit",
				if r.limCpu.pct or r.limMem.pct then math.max(r.limCpu.pct or 0, r.limMem.pct or 0) else nil
			),
			"Highest container share of its CPU or memory limit"
		),
		tile("Node", r.node or M.NONE, r.phase, nil, nil),
	}
	return {
		kind = "containers",
		headers = table.clone(CONTAINER_HEADERS),
		types = table.clone(CONTAINER_TYPES),
		rows = out,
		tiles = tiles,
		notes = notes,
		unsortable = UNSORTABLE,
		trendCols = { cpu = 9, mem = 10 },
	}
end

local NODE_HEADERS = {
	"NAME",
	"STATUS",
	"CPU",
	"%CPU",
	"%CPU REQ",
	"MEM",
	"%MEM",
	"%MEM REQ",
	"PODS",
	"%CPU LIM",
	"%MEM LIM",
	"CPU~",
	"MEM~",
}
local NODE_TYPES: { ColumnType } = {
	"text",
	"status",
	"quantity",
	"percent",
	"percent",
	"quantity",
	"percent",
	"percent",
	"ratio",
	"percent",
	"percent",
	"text",
	"text",
}

export type NodeOpts = {
	metricsError: string?,
	-- Why the pods (requested columns) could not be read.
	podsError: string?,
	podsForbidden: boolean,
}

function M.nodeRef(name: string, context: string?): Ref
	return { kind = "Node", name = name, source = "live", clusterContext = context }
end

function M.nodes(rows: { Model.NodeRow }, context: string?, o: NodeOpts): Built
	local out: { URow } = {}
	for _, r in rows do
		local raw: { [number]: any } = {}
		local cells: { string } = table.create(#NODE_HEADERS)
		cells[1] = r.name
		cells[2] = r.status
		local alloc = r.node.alloc
		local pending = if o.podsForbidden then M.FORBIDDEN else M.NONE
		if r.metric then
			cells[3] = Model.cpu(r.cpu)
			cells[4] = pctCell(raw, 4, r.cpuPct, "node", "used of allocatable " .. Model.cores(alloc.cpu or 0))
			cells[6] = Model.mem(r.mem)
			cells[7] = pctCell(raw, 7, r.memPct, "node", "used of allocatable " .. Model.bytes(alloc.mem or 0))
		else
			cells[3] = noMetrics(raw, 3)
			cells[4] = noMetrics(raw, 4)
			cells[6] = noMetrics(raw, 6)
			cells[7] = noMetrics(raw, 7)
		end
		if r.reqCpu then
			cells[5] =
				pctCell(raw, 5, Model.percent(r.reqCpu, alloc.cpu), "nodeReq", Model.cpu(r.reqCpu) .. " requested")
			cells[8] =
				pctCell(raw, 8, Model.percent(r.reqMem, alloc.mem), "nodeReq", Model.mem(r.reqMem) .. " requested")
			cells[10] =
				pctCell(raw, 10, Model.percent(r.limCpu, alloc.cpu), "nodeLim", Model.cpu(r.limCpu) .. " limits")
			cells[11] =
				pctCell(raw, 11, Model.percent(r.limMem, alloc.mem), "nodeLim", Model.mem(r.limMem) .. " limits")
			cells[9] = string.format("%d/%d", r.pods or 0, alloc.pods or 0)
			raw[9] = { text = spans(cells[9], "mono"), title = "Scheduled pods not finished / allocatable pods" }
		else
			for _, c in { 5, 8, 9, 10, 11 } do
				cells[c] = pending
			end
		end
		cells[12] = ""
		cells[13] = ""
		table.insert(out, {
			key = r.key,
			ref = M.nodeRef(r.name, context),
			cells = cells,
			hay = hay(cells),
			raw = raw,
			trend = { key = r.key, limCpu = alloc.cpu, limMem = alloc.mem },
		})
	end
	local t = Model.nodeTotals(rows)
	local cpuPct = Model.percent(t.cpu, t.allocCpu)
	local memPct = Model.percent(t.mem, t.allocMem)
	local reqCpuPct = Model.percent(t.reqCpu, t.allocCpu)
	local reqMemPct = Model.percent(t.reqMem, t.allocMem)
	local limCpuPct = Model.percent(t.limCpu, t.allocCpu)
	local tiles = {
		tile(
			"Nodes",
			string.format("%d / %d", t.ready, t.total),
			"ready",
			if t.ready < t.total then "warning" else nil,
			"Ready nodes / nodes"
		),
		tile(
			"CPU",
			orDash(cpuPct) .. " used",
			string.format(
				"%s of %s · %s requested · %s limits",
				Model.cpu(t.cpu),
				Model.cores(t.allocCpu),
				orDash(reqCpuPct),
				orDash(limCpuPct)
			),
			Model.tone("node", cpuPct),
			"Of allocatable CPU"
		),
		tile(
			"Memory",
			orDash(memPct) .. " used",
			string.format("%s of %s · %s requested", Model.bytes(t.mem), Model.bytes(t.allocMem), orDash(reqMemPct)),
			Model.tone("node", memPct),
			"Of allocatable memory"
		),
		tile(
			"Pods",
			string.format("%s / %d", if t.pods then tostring(t.pods) else "?", t.allocPods),
			"scheduled / allocatable",
			nil,
			"Scheduled pods not finished / allocatable pods"
		),
	}
	local notes: { string } = {}
	if o.metricsError then
		table.insert(notes, o.metricsError)
	end
	if o.podsError then
		table.insert(notes, o.podsError)
	end
	return {
		kind = "nodes",
		headers = table.clone(NODE_HEADERS),
		types = table.clone(NODE_TYPES),
		rows = out,
		tiles = tiles,
		notes = notes,
		unsortable = UNSORTABLE,
		trendCols = { cpu = 12, mem = 13 },
	}
end

export type TrendOpts = {
	store: Series.Store,
	clock: (number) -> string,
	-- More rows than Series.MAX_ROWS: no trend cells.
	off: boolean,
}

-- `raw` of a visible row with its trend cells: a spark from two samples,
-- else a muted dot that says how to get more.
local function trendCell(store: Series.Store, trend: Trend, field: "cpu" | "mem", clock: (number) -> string): any
	local cell = Series.spark(store, trend.key, {
		field = field,
		label = if field == "cpu" then "CPU" else "memory",
		format = if field == "cpu" then Model.cpu else Model.mem,
		clock = clock,
		limit = if field == "cpu" then trend.limCpu else trend.limMem,
	})
	if cell then
		return cell
	end
	return {
		text = spans(M.ONE_SAMPLE, "muted"),
		title = if Series.count(store, trend.key) == 1 then Series.ONE_SAMPLE else "No samples yet; r or w adds them",
	}
end

function M.withTrends(b: Built, row: URow, o: TrendOpts): { [number]: any }
	local trend = row.trend
	if trend == nil or o.off then
		return row.raw
	end
	local raw = table.clone(row.raw)
	raw[b.trendCols.cpu] = trendCell(o.store, trend, "cpu", o.clock)
	raw[b.trendCols.mem] = trendCell(o.store, trend, "mem", o.clock)
	return raw
end

-- The samples of a pods or nodes metrics read, keyed like the rows
-- (containers as `ns/pod/container`).
function M.podSamples(metrics: { any }): { Series.Sample }
	local out: { Series.Sample } = {}
	for _, m in metrics do
		local key = Model.podKey(m.namespace, m.name)
		table.insert(out, { key = key, t = m.t, cpu = m.cpu, mem = m.mem })
		for _, c in m.containers do
			table.insert(out, { key = key .. "/" .. c.name, t = m.t, cpu = c.cpu, mem = c.mem })
		end
	end
	return out
end

function M.nodeSamples(metrics: { any }): { Series.Sample }
	local out: { Series.Sample } = {}
	for _, m in metrics do
		table.insert(out, { key = m.name, t = m.t, cpu = m.cpu, mem = m.mem })
	end
	return out
end

return M
