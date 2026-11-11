--!strict
-- Explore's usage route: pods (of a namespace scope, a selector or a node)
-- against their requests and limits, one pod's containers, or nodes against
-- allocatable. Read-only; pure (no `tern` global): state.luau dispatches to
-- it and keeps each load in its cache, so header age, loading and errors
-- work as for lists.
--
-- A load is two or three pinned reads (usage/parse.luau templates) answered
-- in any order; it is ok once every read answered. Only the first read
-- (pods, or nodes) failing fails the load: without the metrics API the rows
-- still show requests and limits, with the reason as a note.
--
-- Trends: every metrics read adds samples to one store per target (deduped
-- by metrics window, usage/series.luau). Besides open and `r`, the user may
-- start a sampling run with `w`: the view's metrics read only, every
-- SAMPLE_EVERY s for SAMPLE_FOR s, one read in flight, driven by the Explore
-- liveness tick. Sampling moves only the trend cells (rows, numbers and
-- order change on `r` alone) and stops on time, `w`, a route, context or
-- namespace change, a failed read, or a reload (never saved).

local Model = require("../usage/model")
local Parse = require("../usage/parse")
local Query = require("./query")
local Series = require("../usage/series")
local T = require("./types")
local Types = require("../model/types")
local View = require("../usage/view")
local ui = require("../ui")

type Ref = Types.ResourceRef
type Route = T.Route
type Node = ui.Node

local M = {}

M.SAMPLE_TAG = "usage-sample|"
M.SAMPLE_EVERY = 15
M.SAMPLE_FOR = 120
M.SAMPLE_READS = 8
M.NOT_HERE = "Not available in usage views"

export type Sampling = {
	-- Route key and target scope it runs for; anything else stops it.
	key: string,
	scope: string,
	argv: { string },
	sub: string,
	endsAt: number,
	nextAt: number,
	inflight: boolean,
	gen: number,
	reads: number,
	-- Pods a sample reported that the rows do not have.
	ignored: number,
}

export type U = {
	store: Series.Store,
	-- Bumped when samples land: the cached table node is rebuilt.
	rev: number,
	sampling: Sampling?,
	gen: number,
	-- Samples of the last run, for the trend title after it ends.
	last: number?,
}

export type Sub = { name: string, argv: { string } }

export type SubResult = {
	done: boolean,
	ok: boolean,
	stdout: string?,
	stderr: string?,
	-- The generic failure text and kind (state.luau M.failure).
	error: string?,
	kind: string?,
}

-- Load.data of a usage route: sub-reads, then the built table (ListData
-- shaped: headers, types, rows, memo, view) once all answered.
export type Data = {
	route: Route,
	subs: { [string]: SubResult },
	order: { string },
	-- Why the metrics read gave nothing (mapped), once built.
	metricsNote: string?,
	pods: { Parse.Pod }?,
	podMetrics: { Parse.PodMetric }?,
	nodes: { Parse.Node }?,
	nodeMetrics: { Parse.NodeMetric }?,
	built: View.Built?,
	headers: { string },
	types: { Types.ColumnType },
	rows: { View.URow },
	memo: any?,
	view: any?,
	-- Oldest metrics window end and its length.
	metricsAt: number?,
	window: string?,
}

function M.new(): U
	return { store = Series.new(), rev = 0, sampling = nil, gen = 0, last = nil }
end

function M.clone(u: U): U
	return table.clone(u)
end

function M.isRoute(kind: string): boolean
	return kind == "usage"
end

-- A node name before it reaches --field-selector: a DNS-1123 subdomain.
function M.validNode(v: any): string?
	if type(v) ~= "string" or #v < 1 or #v > 253 then
		return nil
	end
	for label in string.gmatch(v .. ".", "([^.]*)%.") do
		if
			#label < 1
			or #label > 63
			or not string.find(label, "^[a-z0-9]$") and not string.find(label, "^[a-z0-9][a-z0-9%-]*[a-z0-9]$")
		then
			return nil
		end
	end
	return v
end

function M.isNodes(route: Route): boolean
	return route.resource == "nodes"
end

local function scopeId(sc: Query.Scope): string
	return if sc.all then "*" else (sc.namespace or "")
end

-- The pods a pods usage route reads: its node's (all namespaces), else its
-- namespace scope.
function M.podScope(route: Route, scope: Query.Scope): Query.Scope
	local ref = route.ref
	if ref then
		return { namespace = ref.namespace, all = false }
	elseif route.node then
		return { namespace = nil, all = true }
	end
	return scope
end

function M.routeKey(targetId: string, route: Route, scope: Query.Scope): string
	if M.isNodes(route) then
		return "usage|" .. targetId .. "|nodes"
	end
	local ref = route.ref
	if ref then
		return "usage|" .. targetId .. "|pod|" .. (ref.namespace or "") .. "/" .. ref.name
	end
	return table.concat({
		"usage",
		targetId,
		"pods",
		scopeId(M.podScope(route, scope)),
		route.selector or "",
		route.node or "",
	}, "|")
end

-- The pinned reads of a route, the primary first.
function M.subs(program: string, target: Query.Target, route: Route, scope: Query.Scope): { Sub }
	if M.isNodes(route) then
		return {
			{ name = "nodes", argv = Query.usageNodes(program, target) },
			{ name = "metrics", argv = Query.usageNodeMetrics(program, target) },
			{ name = "allpods", argv = Query.usagePods(program, target, { namespace = nil, all = true }) },
		}
	end
	local sc = M.podScope(route, scope)
	local ref = route.ref
	local f: Query.UsageFilter = {
		selector = if ref then nil else route.selector,
		node = if ref then nil else route.node,
		name = if ref then ref.name else nil,
	}
	return {
		{ name = "pods", argv = Query.usagePods(program, target, sc, f) },
		{ name = "metrics", argv = Query.usagePodMetrics(program, target, sc, f) },
	}
end

function M.newData(subs: { Sub }, route: Route): Data
	local results: { [string]: SubResult } = {}
	local order: { string } = {}
	for _, sub in subs do
		results[sub.name] = { done = false, ok = false }
		table.insert(order, sub.name)
	end
	return {
		route = route,
		subs = results,
		order = order,
		headers = {},
		types = {},
		rows = {},
	}
end

-- The data with one more answer; nil when `name` is not pending.
function M.answer(
	data: Data,
	name: string,
	ok: boolean,
	stdout: string?,
	stderr: string?,
	err: string?,
	kind: string?
): Data?
	local cur = data.subs[name]
	if cur == nil or cur.done then
		return nil
	end
	local subs = table.clone(data.subs)
	subs[name] = { done = true, ok = ok, stdout = stdout, stderr = stderr, error = err, kind = kind }
	local upd = table.clone(data)
	upd.subs = subs
	return upd
end

function M.complete(data: Data): boolean
	for _, name in data.order do
		if not data.subs[name].done then
			return false
		end
	end
	return true
end

local function firstLine(text: string?): string
	return string.match(text or "", "^%s*([^\n]*)") or ""
end

-- Why a metrics (or all-pods) read failed, for a note.
local function noteOf(r: SubResult, api: string): (string?, boolean)
	if r.ok then
		return nil, false
	end
	local mapped, kind = Model.metricsError(r.stderr or "", api)
	if mapped then
		return mapped, kind == "forbidden"
	end
	return firstLine(r.error), r.kind == "forbidden"
end

local function oldest(times: { { t: number?, window: string? } }): (number?, string?)
	local at: number? = nil
	local window: string? = nil
	for _, m in times do
		local t = m.t
		if t and (at == nil or t < (at :: number)) then
			at = t
			window = m.window
		end
	end
	return at, window
end

-- Builds the table once every read answered. Returns the error of a failed
-- primary read (the load fails), else nil.
function M.build(data: Data, context: string?): (Data, string?, string?)
	local route = data.route
	local primary = data.subs[data.order[1]]
	if not primary.ok then
		return data, primary.error or "kubectl failed", primary.kind
	end
	local upd = table.clone(data)
	local metrics = data.subs.metrics
	local metricsNote: string? = nil
	if M.isNodes(route) then
		upd.nodes = Parse.nodes(primary.stdout or "")
		upd.nodeMetrics = if metrics.ok then Parse.nodeMetrics(metrics.stdout or "") else {}
		metricsNote = noteOf(metrics, "nodes.metrics.k8s.io")
		local all = data.subs.allpods
		upd.pods = if all.ok then Parse.pods(all.stdout or "") else nil
		local podsNote, forbidden = noteOf(all, "pods")
		local rows = Model.nodeRows(upd.nodes :: { Parse.Node }, upd.nodeMetrics :: { Parse.NodeMetric }, upd.pods)
		upd.built = View.nodes(rows, context, {
			metricsError = metricsNote,
			podsError = if podsNote then "Requested and limits unknown: " .. podsNote else nil,
			podsForbidden = forbidden,
		})
		upd.metricsAt, upd.window = oldest(upd.nodeMetrics :: any)
	else
		upd.pods = Parse.pods(primary.stdout or "")
		upd.podMetrics = if metrics.ok then Parse.podMetrics(metrics.stdout or "") else {}
		metricsNote = noteOf(metrics, "pods.metrics.k8s.io")
		local rows = Model.podRows(upd.pods :: { Parse.Pod }, upd.podMetrics :: { Parse.PodMetric }, route.node)
		local ref = route.ref
		if ref then
			local row = rows[1]
			if row == nil then
				return data,
					"Pod "
						.. (ref.namespace or "")
						.. "/"
						.. ref.name
						.. " not found (it may have been deleted). Press r to retry.",
					"notfound"
			end
			upd.built = View.containers(row, context, metricsNote)
		else
			upd.built = View.pods(rows, { context = context, metricsError = metricsNote, metricsRead = metrics.ok })
		end
		upd.metricsAt, upd.window = oldest(upd.podMetrics :: any)
	end
	upd.metricsNote = metricsNote
	local built = upd.built :: View.Built
	upd.headers = built.headers
	upd.types = built.types
	upd.rows = built.rows
	upd.memo = nil
	upd.view = nil
	-- Raw texts are not kept once parsed.
	local subs: { [string]: SubResult } = {}
	for name, r in data.subs do
		subs[name] = { done = true, ok = r.ok, error = r.error, kind = r.kind }
	end
	upd.subs = subs
	return upd, nil, nil
end

-- A containers load from a pods load already read (no query); nil when no
-- cached load has the pod.
function M.fromCached(data: Data, ref: Ref, context: string?): Data?
	if data.built == nil or data.built.kind ~= "pods" or data.pods == nil then
		return nil
	end
	local key = Model.podKey(ref.namespace or "", ref.name)
	for _, p in data.pods :: { Parse.Pod } do
		if Model.podKey(p.namespace, p.name) == key then
			local m = Model.metricsByKey(data.podMetrics or {})[key]
			local built = View.containers(Model.podRow(p, m), context, data.metricsNote)
			return {
				route = { kind = "usage", resource = "pods", ref = ref },
				subs = {},
				order = {},
				metricsNote = data.metricsNote,
				pods = { p },
				podMetrics = if m then { m } else {},
				built = built,
				headers = built.headers,
				types = built.types,
				rows = built.rows,
				metricsAt = if m then m.t else nil,
				window = if m then m.window else nil,
			}
		end
	end
	return nil
end

-- Trend samples of a load's metrics.
function M.samples(data: Data): { Series.Sample }
	if data.nodeMetrics then
		return View.nodeSamples(data.nodeMetrics :: { any })
	end
	return View.podSamples((data.podMetrics or {}) :: { any })
end

-- Adds a load's samples to the store (no trends above Series.MAX_ROWS).
function M.record(u: U, data: Data)
	if #data.rows > Series.MAX_ROWS then
		return
	end
	local store, added = Series.add(u.store, M.samples(data))
	if added > 0 then
		u.store = store
		u.rev += 1
	end
end

-- Navigation ----------------------------------------------------------------------

-- Where enter on a row goes: a pod's containers, a node's pods.
function M.drill(route: Route, item: { key: string, ref: Ref? }?): Route?
	if item == nil or item.ref == nil or route.ref then
		return nil
	end
	local ref = item.ref :: Ref
	if M.isNodes(route) then
		return { kind = "usage", resource = "pods", node = ref.name }
	end
	return {
		kind = "usage",
		resource = "pods",
		ref = { kind = "Pod", name = ref.name, namespace = ref.namespace, source = "live" },
	}
end

-- The row key of an object in a usage table.
function M.rowKey(ref: Ref): string
	return if ref.kind == "Node" then ref.name else Model.podKey(ref.namespace or "", ref.name)
end

-- Trend columns have no order.
function M.unsortable(header: string): boolean
	return header == "CPU~" or header == "MEM~"
end

-- The row of the view below that the route came from (selected on back).
function M.parentKey(route: Route): string?
	local ref = route.ref
	if ref then
		return M.rowKey(ref)
	end
	return route.node
end

-- `%` inside a usage view: pods <-> nodes.
function M.toggle(route: Route): Route
	if M.isNodes(route) then
		return { kind = "usage", resource = "pods" }
	end
	return { kind = "usage", resource = "nodes" }
end

-- Sampling ------------------------------------------------------------------------

-- The read a sampling run repeats: the load's metrics read.
function M.sampleSub(subs: { Sub }): Sub?
	for _, s in subs do
		if s.name == "metrics" then
			return s
		end
	end
	return nil
end

function M.start(u: U, key: string, scope: string, sub: Sub, now: number)
	u.gen += 1
	u.sampling = {
		key = key,
		scope = scope,
		argv = sub.argv,
		sub = sub.name,
		endsAt = now + M.SAMPLE_FOR,
		nextAt = now,
		inflight = false,
		gen = u.gen,
		reads = 0,
		ignored = 0,
	}
end

function M.stop(u: U)
	local smp = u.sampling
	if smp then
		u.last = smp.reads
	end
	u.sampling = nil
end

-- A tick: the argv of a read that is due, or nil. Ends a run whose time is
-- up (returns true as the second value when anything changed).
function M.tick(u: U, now: number): ({ string }?, boolean)
	local smp = u.sampling
	if smp == nil then
		return nil, false
	end
	if now >= smp.endsAt then
		M.stop(u)
		return nil, true
	end
	if smp.inflight or now < smp.nextAt or smp.reads >= M.SAMPLE_READS then
		return nil, true
	end
	local upd = table.clone(smp)
	upd.inflight = true
	upd.reads += 1
	upd.nextAt = now + M.SAMPLE_EVERY
	u.sampling = upd
	return upd.argv, true
end

-- A failed sample read's metrics-specific reason, else nil.
function M.sampleError(stderr: string): string?
	return (Model.metricsError(stderr, "metrics.k8s.io"))
end

-- A sample read answered. Returns an error text when the run stops on it.
-- Pods the read reports that the rows lack are counted, except on a node's
-- pods (its read covers every node).
function M.onSample(
	u: U,
	gen: number,
	ok: boolean,
	stdout: string,
	rows: { View.URow },
	route: Route,
	err: string?
): (boolean, string?)
	local nodes = M.isNodes(route)
	local counted = route.node == nil
	local smp = u.sampling
	if smp == nil or smp.gen ~= gen then
		return false, nil
	end
	if not ok then
		M.stop(u)
		return true, err or "kubectl failed"
	end
	local upd = table.clone(smp)
	upd.inflight = false
	local known: { [string]: boolean } = {}
	for _, r in rows do
		known[r.key] = true
		local ref = r.ref
		if ref and ref.kind == "Pod" then
			known[Model.podKey(ref.namespace or "", ref.name)] = true
		end
	end
	local samples: { Series.Sample } = {}
	local ignored = 0
	local list: { Series.Sample } = if nodes
		then View.nodeSamples(Parse.nodeMetrics(stdout) :: any)
		else View.podSamples(Parse.podMetrics(stdout) :: any)
	for _, sm in list do
		local owner = string.match(sm.key, "^([^/]+/[^/]+)") or sm.key
		if known[owner] then
			table.insert(samples, sm)
		elseif owner == sm.key and counted then
			ignored += 1
		end
	end
	upd.ignored = ignored
	u.sampling = upd
	if #rows <= Series.MAX_ROWS then
		local store, added = Series.add(u.store, samples)
		if added > 0 then
			u.store = store
			u.rev += 1
		end
	end
	return true, nil
end

-- View ------------------------------------------------------------------------------

local function mmss(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Header items: the metrics time and the sampling badge.
function M.headerNodes(u: U, data: Data?, now: number?, clock: (number) -> string): { Node }
	local out: { Node } = {}
	if data and data.metricsAt then
		local text = "metrics " .. clock(data.metricsAt :: number)
		local w = data.window and tonumber(string.match(data.window, "^([%d%.]+)s$"))
		if w then
			text ..= string.format(" (%d s window)", math.floor(w + 0.5))
		end
		table.insert(
			out,
			ui.text({ ui.span(text, "muted") }, {
				key = "metrics-at",
				role = "tern-kube.metrics-at",
				title = "End of the oldest metrics-server window in this read",
			})
		)
	end
	local smp = u.sampling
	if smp then
		table.insert(
			out,
			ui.badge("Sampling " .. mmss(smp.endsAt - (now or smp.endsAt)) .. " · w stops", "accent", {
				key = "sampling",
				role = "tern-kube.sampling",
				title = string.format(
					"Reads the metrics API every %d s for %d s (%d of at most %d reads); only the trend columns change",
					M.SAMPLE_EVERY,
					M.SAMPLE_FOR,
					smp.reads,
					M.SAMPLE_READS
				),
			})
		)
	end
	return out
end

function M.crumb(route: Route, scopeText: string): string
	if M.isNodes(route) then
		return "usage · nodes"
	end
	local ref = route.ref
	if ref then
		return "usage · pod/" .. ref.name
	elseif route.node then
		return "usage · pods · node " .. route.node
	elseif route.selector then
		return "usage · pods -l " .. route.selector .. " · " .. scopeText
	end
	return "usage · pods · " .. scopeText
end

function M.hint(u: U, route: Route): string
	local w = if u.sampling then "w stop sampling" else "w sample 2 min"
	local enter = if M.isNodes(route) then "enter pods" elseif route.ref then nil else "enter containers"
	local parts = { "j/k move" }
	if enter then
		table.insert(parts, enter)
	end
	for _, p in
		{
			if M.isNodes(route) then "% pods" else "% nodes",
			w,
			"r refresh",
			"/ filter",
			"d describe",
			"Y copy commands",
			"esc back",
		}
	do
		table.insert(parts, p)
	end
	return table.concat(parts, " · ")
end

export type HeadOpts = {
	shown: number,
	filter: string,
	chip: (text: string, action: string, props: { [string]: any }?) -> Node,
	allowLive: boolean,
}

-- The count row, tiles and notes above the table.
function M.head(u: U, route: Route, data: Data, o: HeadOpts): { Node }
	local built = data.built :: View.Built
	local what = if built.kind == "nodes" then "nodes" elseif built.kind == "containers" then "containers" else "pods"
	local summary = string.format("%d %s", #data.rows, what)
	if o.filter ~= "" then
		summary ..= string.format(" · %d match /%s", o.shown, o.filter)
	end
	local row: { Node } = { ui.text({ ui.span(summary, "muted") }, { key = "count" }) }
	if route.ref == nil and route.node == nil then
		table.insert(
			row,
			o.chip(if built.kind == "nodes" then "Pods (%)" else "Nodes (%)", "usage-key=%", {
				key = "usage-toggle",
				title = if built.kind == "nodes"
					then "Pods usage of the namespace scope"
					else "Nodes against allocatable",
			})
		)
	end
	if o.allowLive then
		table.insert(
			row,
			o.chip(if u.sampling then "Stop sampling (w)" else "Sample 2 min (w)", "usage-key=w", {
				key = "usage-sample",
				tone = if u.sampling then "accent" else nil,
				title = string.format(
					"Reads the metrics API every %d s for %d s for the trend columns; numbers and order change only on r",
					M.SAMPLE_EVERY,
					M.SAMPLE_FOR
				),
			})
		)
	end
	local out: { Node } = { ui.row(row, { key = "count-row", wrap = true, role = "tern-kube.chips" }) }
	table.insert(out, { k = "stats", p = { key = "stats", items = built.tiles } })
	local notes = table.clone(built.notes)
	local smp = u.sampling
	if smp and smp.ignored > 0 then
		table.insert(notes, string.format("%d pods not in the last read; r includes them", smp.ignored))
	end
	for i, n in notes do
		table.insert(out, ui.muted(n, { key = "note" .. i, role = "tern-kube.usage-note" }))
	end
	return out
end

return M
