--!strict
-- Explore's compare route: one object, or one list, read from the block's
-- context (the base) and from other contexts of the same kubeconfig, then
-- paired and diffed (compare/model.luau). Read-only: nothing here acts on
-- any context. Pure: no `tern` global; state.luau dispatches to it like the
-- Helm and GitOps sub-cores.
--
-- Every side is one pinned kubectl run (`--context C`), all sides of a route
-- are refetched together (r), never automatically, and at most
-- compare.max_parallel run at once. Raw objects stay only until every side
-- has answered: then the matrix and the pairwise diffs that involve Secrets
-- are computed and the raw Secrets are dropped, so their values never sit
-- in the block's state (non-Secret objects are kept for drill-in, like the
-- objects of a list load).

local Command = require("../kubectl/command")
local Config = require("../config")
local Contexts = require("../compare/contexts")
local Model = require("../compare/model")
local Objdiff = require("../mutation/objdiff")
local Query = require("./query")
local Redact = require("../model/redact")
local Resource = require("../model/resource")
local T = require("./types")
local Types = require("../model/types")

type Ref = Types.ResourceRef
type Route = T.Route
type Effect = T.Effect
type Msg = T.Msg
type Item = T.Item
type Key = T.Key
type ProcessResult = T.ProcessResult
type Column = Model.Column
type Cell = Model.Cell
type Matrix = Model.Matrix
type Filter = Model.Filter

export type Ctx = {
	target: Query.Target,
	program: string,
	config: Config.Config,
	decode: T.Decode,
	resolved: boolean,
	null: any?,
	isList: ((t: { [any]: any }) -> boolean)?,
	-- state.luau M.failure for a run against `context`.
	failure: (result: ProcessResult, spawnError: string?, context: string) -> string,
}

export type ContextsLoad = {
	status: "loading" | "ok" | "error",
	gen: number,
	argv: { string },
	contexts: { Contexts.ContextInfo }?,
	error: string?,
}

export type Pair = { cell: Cell, result: Objdiff.Result? }

export type Load = {
	-- The object compared (nil: a list compare of `resource` in `scope`).
	ref: Ref?,
	resource: string?,
	scope: Query.Scope?,
	-- Base first; argv are the pinned runs.
	columns: { Column },
	gens: { number },
	-- Raw items per column while sides are still running (transient).
	pending: { [number]: { any } },
	-- Once every side settled.
	matrix: Matrix?,
	-- Pairwise results by `<row key>\n<context>` (computed on drill-in, or at
	-- once for Secrets).
	pairs: { [string]: Pair },
	-- Raw non-Secret objects by row key, per column, for drill-in.
	kept: { [number]: { [string]: any } },
	-- At least one compared object is a Secret.
	secret: boolean,
	-- Why the compare could not start (unknown context, over budget).
	error: string?,
	-- A list compare opened on a filtered list: the filter text and the row
	-- keys it showed (lower-cased text matches names on every side).
	match: string?,
	keys: { [string]: boolean }?,
	-- Objects each settled side had after the filter.
	counts: { [number]: number },
}

export type C = {
	gen: number,
	contexts: { [string]: ContextsLoad },
	loads: { [string]: Load },
	filters: { [string]: Filter },
}

export type Nav = { push: Route?, replace: Route?, pop: boolean? }

local M = {}

M.TAG = "compare|"
M.MAX_PATHS = 3
M.READ_ONLY = "Compare views are read-only"

local FILTERS: { Filter } = { "all", "differs", "presence" }

function M.new(): C
	return { gen = 0, contexts = {}, loads = {}, filters = {} }
end

-- Shallow copy: every update works on a fresh C so older states stay valid.
function M.clone(c: C): C
	return table.clone(c)
end

function M.isRoute(kind: string): boolean
	return kind == "compare"
end

local function targetId(t: Query.Target): string
	return (t.kubeconfig or "") .. "@" .. (t.context or "?")
end

function M.scope(ctx: Ctx, route: Route): Query.Scope
	if route.namespace == "*" then
		return { namespace = nil, all = true }
	elseif route.namespace then
		return { namespace = route.namespace, all = false }
	end
	local t = ctx.target
	return { namespace = t.namespace, all = t.allNamespaces }
end

local function subject(ctx: Ctx, route: Route): string
	local ref = route.ref
	if ref then
		return "obj:" .. Resource.key(ref)
	end
	local sc = M.scope(ctx, route)
	return "list:"
		.. (route.resource or "pods")
		.. "@"
		.. (if sc.all then "*" else (sc.namespace or ""))
		.. (if route.match then "~" .. route.match else "")
end

-- The data of a compare route: one per target, subject and choice.
function M.loadId(ctx: Ctx, route: Route): string
	return targetId(ctx.target) .. "|" .. subject(ctx, route) .. "|" .. (route.across or "")
end

-- Selection / filter / offset key of the route (state.routeKey).
function M.routeKey(ctx: Ctx, route: Route): string
	return table.concat({
		"compare",
		targetId(ctx.target),
		subject(ctx, route),
		route.across or "",
		route.item or "",
		route.context or "",
	}, "|")
end

local function kubeconfigId(ctx: Ctx): string
	return ctx.target.kubeconfig or ""
end

function M.contextsLoad(c: C, ctx: Ctx): ContextsLoad?
	return c.contexts[kubeconfigId(ctx)]
end

function M.load(c: C, ctx: Ctx, route: Route): Load?
	if route.across == nil then
		return nil
	end
	return c.loads[M.loadId(ctx, route)]
end

function M.filter(c: C, ctx: Ctx, route: Route): Filter
	return c.filters[M.loadId(ctx, route)] or "all"
end

function M.policy(ctx: Ctx): Redact.Policy
	return Redact.fromConfig(ctx.config)
end

-- The picker's rows; none until the kubeconfig's contexts are read.
function M.choices(c: C, ctx: Ctx): { Contexts.Choice }
	local l = M.contextsLoad(c, ctx)
	if l == nil or l.contexts == nil then
		return {}
	end
	local cfg = ctx.config.compare
	return Contexts.choices(l.contexts, ctx.target.context or "", cfg.contexts, cfg.max_contexts)
end

local function serverOf(c: C, ctx: Ctx, name: string): string?
	local l = M.contextsLoad(c, ctx)
	local infos: { Contexts.ContextInfo } = if l and l.contexts then l.contexts else {}
	for _, info in infos do
		if info.name == name then
			return info.server
		end
	end
	return nil
end

local function setLoad(c: C, id: string, l: Load)
	local loads = table.clone(c.loads)
	loads[id] = l
	c.loads = loads
end

local function runEffect(ctx: Ctx, tag: string, argv: { string }, gen: number): Effect
	return { t = "run", tag = tag, argv = argv, timeout_ms = ctx.config.explore.query_timeout_ms, gen = gen }
end

local function sideTag(id: string, i: number): string
	return M.TAG .. "side|" .. i .. "|" .. id
end

local function ensureContexts(c: C, ctx: Ctx, force: boolean, effects: { Effect })
	local k = kubeconfigId(ctx)
	local existing = c.contexts[k]
	if existing and not (force and existing.status ~= "loading") then
		return
	end
	c.gen += 1
	local argv = Query.contextsInfo(ctx.program, ctx.target.kubeconfig)
	local map = table.clone(c.contexts)
	map[k] = { status = "loading", gen = c.gen, argv = argv }
	c.contexts = map
	table.insert(effects, runEffect(ctx, M.TAG .. "ctx|" .. k, argv, c.gen))
end

local function sideArgv(ctx: Ctx, route: Route, context: string): { string }
	local t = table.clone(ctx.target)
	t.context = context
	local ref = route.ref
	if ref then
		return Query.compareObject(ctx.program, t, ref)
	end
	return Query.list(ctx.program, t, route.resource or "pods", M.scope(ctx, route))
end

-- Starts every pending side the parallel budget allows.
local function pump(c: C, ctx: Ctx, id: string, l: Load, effects: { Effect })
	local statuses: { string } = {}
	for i, col in l.columns do
		statuses[i] = col.status
	end
	local start = Model.queue(statuses, ctx.config.compare.max_parallel)
	if #start == 0 then
		return
	end
	local columns = table.clone(l.columns)
	local gens = table.clone(l.gens)
	for _, i in start do
		c.gen += 1
		local col = table.clone(columns[i])
		col.status = "running"
		columns[i] = col
		gens[i] = c.gen
		table.insert(effects, runEffect(ctx, sideTag(id, i), col.argv :: { string }, c.gen))
	end
	local upd = table.clone(l)
	upd.columns = columns
	upd.gens = gens
	setLoad(c, id, upd)
end

local function failed(c: C, id: string, message: string)
	setLoad(c, id, {
		ref = nil,
		resource = nil,
		scope = nil,
		columns = {},
		gens = {},
		pending = {},
		matrix = nil,
		pairs = {},
		kept = {},
		secret = false,
		error = message,
		match = nil,
		keys = nil,
		counts = {},
	})
end

local function startLoad(c: C, ctx: Ctx, route: Route, effects: { Effect })
	local id = M.loadId(ctx, route)
	local choices = M.choices(c, ctx)
	local choice: Contexts.Choice? = nil
	for _, ch in choices do
		if ch.id == route.across then
			choice = ch
		end
	end
	if choice == nil then
		local name = string.match(route.across or "", "^=(.+)$")
		failed(
			c,
			id,
			if name
				then string.format("Context %s is not in the kubeconfig.", name)
				else "Nothing to compare with: pick a context (x)."
		)
		return
	end
	if choice.disabled then
		failed(c, id, "Cannot compare: " .. choice.disabled .. ".")
		return
	end
	local base = ctx.target.context :: string
	local names = { base }
	for _, name in choice.contexts do
		if name ~= base then
			table.insert(names, name)
		end
	end
	local labels = Contexts.short(names)
	local columns: { Column } = {}
	for i, name in names do
		columns[i] = {
			context = name,
			label = labels[name] or name,
			server = serverOf(c, ctx, name),
			fetchedAt = nil,
			status = "pending",
			error = nil,
			argv = sideArgv(ctx, route, name),
		}
	end
	local keys: { [string]: boolean }? = nil
	if route.ref == nil and route.keys then
		local set: { [string]: boolean } = {}
		for _, k in route.keys do
			set[k] = true
		end
		keys = set
	end
	local l: Load = {
		ref = route.ref,
		resource = if route.ref then nil else (route.resource or "pods"),
		scope = if route.ref then nil else M.scope(ctx, route),
		columns = columns,
		gens = table.create(#columns, 0),
		pending = {},
		matrix = nil,
		pairs = {},
		kept = {},
		secret = false,
		error = nil,
		match = if route.ref then nil else route.match,
		keys = keys,
		counts = {},
	}
	setLoad(c, id, l)
	pump(c, ctx, id, l, effects)
end

-- Starts what `route` needs (force: r reads the contexts and every side
-- again, dropping whatever raw objects were held).
function M.enter(c: C, ctx: Ctx, route: Route, force: boolean, effects: { Effect })
	if not ctx.resolved or not ctx.config.explore.allow_live_queries then
		return
	end
	ensureContexts(c, ctx, force and route.across == nil, effects)
	local cl = M.contextsLoad(c, ctx)
	if route.across == nil or cl == nil or cl.status ~= "ok" then
		return
	end
	local id = M.loadId(ctx, route)
	if force or c.loads[id] == nil then
		startLoad(c, ctx, route, effects)
	end
	M.ensurePair(c, ctx, route)
end

local function isSecretRef(ref: Ref?): boolean
	return ref ~= nil and ref.kind == "Secret" and (ref.group == nil or ref.group == "")
end

local function diffOpts(ctx: Ctx, l: Load, i: number): Model.DiffOptions
	return {
		labels = { l.columns[1].context, l.columns[i].context },
		policy = M.policy(ctx),
		null = ctx.null,
		isList = ctx.isList,
		maxPaths = nil,
	}
end

local function errorCell(l: Load, i: number): Cell?
	if l.columns[1].status == "error" then
		return { state = "error", error = "the base context failed" }
	elseif l.columns[i].status == "error" then
		return { state = "error", error = l.columns[i].error }
	end
	return nil
end

-- The view needs only the diff text: Objdiff's `pairs` hold both objects
-- (Secret values included), so they are never kept.
local function keep(cell: Cell, result: Objdiff.Result?): Pair
	return {
		cell = cell,
		result = if result then { summary = result.summary, unchanged = result.unchanged, pairs = {} } else nil,
	}
end

local function byKey(items: { any }): { [string]: any }
	local out: { [string]: any } = {}
	for _, obj in items do
		local ref = if type(obj) == "table" then Resource.fromObject(obj, "live") else nil
		if ref then
			local k = Resource.key(ref)
			if out[k] == nil then
				out[k] = obj
			end
		end
	end
	return out
end

-- A filtered list compare keeps the rows the list showed and, on every
-- side, objects whose name contains the filter text (so objects only the
-- other contexts have still show up as extra).
local function inView(l: Load, items: { any }): { any }
	if l.match == nil then
		return items
	end
	local text = string.lower(l.match)
	local out: { any } = {}
	for _, obj in items do
		local ref = if type(obj) == "table" then Resource.fromObject(obj, "live") else nil
		if
			ref
			and (
				(l.keys ~= nil and l.keys[Resource.key(ref)])
				or string.find(string.lower(ref.name), text, 1, true) ~= nil
			)
		then
			table.insert(out, obj)
		end
	end
	return out
end

-- Every side answered: the matrix, the Secret pairs, and no raw Secret left.
local function finish(ctx: Ctx, l: Load): Load
	local upd = table.clone(l)
	local sides: { { any }? } = {}
	local maps: { [number]: { [string]: any } } = {}
	local counts: { [number]: number } = {}
	for i, col in l.columns do
		local items = if col.status == "ok" and l.pending[i] then inView(l, l.pending[i]) else nil
		sides[i] = items
		if items then
			maps[i] = byKey(items)
			counts[i] = #items
		end
	end
	upd.counts = counts
	local pairs: { [string]: Pair } = {}
	local secret = false
	local ref = l.ref
	local matrix: Matrix
	if ref then
		local k = Resource.key(ref)
		local a = if maps[1] then maps[1][k] else nil
		local cells: { Cell } = {
			if l.columns[1].status == "error"
				then { state = "error", error = l.columns[1].error }
				elseif a ~= nil then { state = "base" }
				else { state = "absent" },
		}
		for i = 2, #l.columns do
			local cell = errorCell(l, i)
			local result: Objdiff.Result? = nil
			if cell == nil then
				cell, result = Model.objectDiff(a, maps[i][k], diffOpts(ctx, l, i))
			end
			cells[i] = cell :: Cell
			pairs[k .. "\n" .. l.columns[i].context] = keep(cell :: Cell, result)
		end
		secret = isSecretRef(ref)
		matrix = { columns = l.columns, rows = { { key = k, ref = ref, cells = cells } }, notes = {} }
	else
		matrix = Model.listMatrix(l.columns, sides, {
			policy = M.policy(ctx),
			maxPaths = M.MAX_PATHS,
			maxObjects = ctx.config.compare.max_objects,
		})
		local kept: { [number]: { [string]: any } } = {}
		for i in maps do
			kept[i] = {}
		end
		for _, row in matrix.rows do
			if isSecretRef(row.ref) then
				secret = true
				local a = if maps[1] then maps[1][row.key] else nil
				for i = 2, #matrix.columns do
					local cell = row.cells[i]
					if cell and cell.state ~= "error" and cell.state ~= "pending" and maps[i] then
						local c2, result = Model.objectDiff(a, maps[i][row.key], diffOpts(ctx, l, i))
						pairs[row.key .. "\n" .. matrix.columns[i].context] = keep(c2, result)
					end
				end
			else
				for i, m in maps do
					kept[i][row.key] = m[row.key]
				end
			end
		end
		upd.kept = kept
		upd.columns = matrix.columns
	end
	upd.matrix = matrix
	upd.pairs = pairs
	upd.secret = secret
	upd.pending = {}
	return upd
end

local function settled(l: Load): boolean
	for _, col in l.columns do
		if col.status ~= "ok" and col.status ~= "error" then
			return false
		end
	end
	return true
end

local function onSide(c: C, ctx: Ctx, id: string, i: number, msg: Msg, effects: { Effect }): boolean
	local l = c.loads[id]
	if l == nil or l.gens[i] ~= msg.gen or l.columns[i] == nil or l.columns[i].status ~= "running" then
		return false
	end
	local col = table.clone(l.columns[i])
	local result = msg.result :: ProcessResult
	local items: { any }? = nil
	if msg.spawnError or result.status ~= 0 then
		col.status = "error"
		col.error = ctx.failure(result, msg.spawnError, col.context)
	else
		local ok, doc = pcall(ctx.decode, result.stdout)
		if ok and type(doc) == "table" and type(doc.items) == "table" then
			col.status = "ok"
			items = doc.items
		else
			col.status = "error"
			col.error = "kubectl printed invalid JSON"
		end
	end
	col.fetchedAt = msg.at
	local upd = table.clone(l)
	local columns = table.clone(l.columns)
	columns[i] = col
	upd.columns = columns
	if items then
		local pending = table.clone(l.pending)
		pending[i] = items
		upd.pending = pending
	end
	if settled(upd) then
		setLoad(c, id, finish(ctx, upd))
		return true
	end
	setLoad(c, id, upd)
	pump(c, ctx, id, upd, effects)
	return true
end

local function onContexts(c: C, ctx: Ctx, k: string, msg: Msg): boolean
	local l = c.contexts[k]
	if l == nil or l.gen ~= msg.gen or l.status ~= "loading" then
		return false
	end
	local upd = table.clone(l)
	local result = msg.result :: ProcessResult
	if msg.spawnError or result.status ~= 0 then
		upd.status = "error"
		upd.error = ctx.failure(result, msg.spawnError, ctx.target.context or "?")
	else
		local list, err = Contexts.parse(result.stdout, ctx.decode)
		if list then
			upd.status = "ok"
			upd.contexts = list
		else
			upd.status = "error"
			upd.error = err
		end
	end
	local map = table.clone(c.contexts)
	map[k] = upd
	c.contexts = map
	return true
end

-- Results tagged `compare|...`; `route` is the route on top (its sides
-- start once the contexts are known, its pair once its sides settled).
-- False: a stale result, dropped.
function M.onResult(c: C, ctx: Ctx, msg: Msg, route: Route?, effects: { Effect }): boolean
	local tag = msg.tag or ""
	if string.sub(tag, 1, #M.TAG) ~= M.TAG then
		return false
	end
	local rest = string.sub(tag, #M.TAG + 1)
	local changed = false
	local k = string.match(rest, "^ctx|(.*)$")
	local index, id = string.match(rest, "^side|(%d+)|(.*)$")
	if k then
		changed = onContexts(c, ctx, k, msg)
	elseif index and id then
		changed = onSide(c, ctx, id, tonumber(index) :: number, msg, effects)
	end
	if changed and route and M.isRoute(route.kind) then
		M.enter(c, ctx, route, false, effects)
	end
	return changed
end

-- The other context a pairwise view shows: the route's choice, else the
-- first other column.
function M.otherContext(l: Load, route: Route): string?
	if route.context then
		for i = 2, #l.columns do
			if l.columns[i].context == route.context then
				return route.context
			end
		end
	end
	local col = l.columns[2]
	return if col then col.context else nil
end

-- The row a pairwise view shows: the drilled-into row, or the object.
local function pairRow(l: Load, route: Route): string?
	if route.item then
		return route.item
	elseif l.ref and #l.columns == 2 then
		return Resource.key(l.ref)
	end
	return nil
end

-- Whether the route shows one pairwise diff (rather than a table).
function M.isPair(c: C, ctx: Ctx, route: Route): boolean
	local l = M.load(c, ctx, route)
	return l ~= nil and l.error == nil and pairRow(l, route) ~= nil
end

-- Computes the drilled-into pair from the kept list objects (Secrets were
-- computed when the list settled).
function M.ensurePair(c: C, ctx: Ctx, route: Route)
	local id = M.loadId(ctx, route)
	local l = c.loads[id]
	if l == nil or l.matrix == nil then
		return
	end
	local row = pairRow(l, route)
	local other = M.otherContext(l, route)
	if row == nil or other == nil then
		return
	end
	local pk = row .. "\n" .. other
	if l.pairs[pk] then
		return
	end
	local i = 2
	for j = 2, #l.columns do
		if l.columns[j].context == other then
			i = j
		end
	end
	local cell = errorCell(l, i)
	local result: Objdiff.Result? = nil
	if cell == nil then
		local a = if l.kept[1] then l.kept[1][row] else nil
		local b = if l.kept[i] then l.kept[i][row] else nil
		cell, result = Model.objectDiff(a, b, diffOpts(ctx, l, i))
	end
	local upd = table.clone(l)
	local pairs = table.clone(l.pairs)
	pairs[pk] = keep(cell :: Cell, result)
	upd.pairs = pairs
	setLoad(c, id, upd)
end

-- The pairwise view's data: cell, diff and its two columns.
function M.pair(c: C, ctx: Ctx, route: Route): (Pair?, { Column }?)
	local l = M.load(c, ctx, route)
	if l == nil or l.matrix == nil then
		return nil, nil
	end
	local row = pairRow(l, route)
	local other = M.otherContext(l, route)
	if row == nil or other == nil then
		return nil, nil
	end
	local cols: { Column } = { l.columns[1] }
	for j = 2, #l.columns do
		if l.columns[j].context == other then
			cols[2] = l.columns[j]
		end
	end
	return l.pairs[row .. "\n" .. other], cols
end

local function lower(s: string?): string
	return string.lower(s or "")
end

-- The list matrix after the f filter and the / text.
function M.visible(c: C, ctx: Ctx, route: Route, text: string?): Matrix?
	local l = M.load(c, ctx, route)
	local m = if l then l.matrix else nil
	if l == nil or m == nil then
		return nil
	end
	m = Model.filter(m, M.filter(c, ctx, route))
	local f = lower(text)
	if f == "" then
		return m
	end
	local rows: { Model.Row } = {}
	for _, row in m.rows do
		if string.find(lower(row.ref.kind .. "/" .. row.ref.name .. " " .. (row.ref.namespace or "")), f, 1, true) then
			table.insert(rows, row)
		end
	end
	return { columns = m.columns, rows = rows, notes = m.notes }
end

function M.items(c: C, ctx: Ctx, route: Route, text: string?): { Item }
	local out: { Item } = {}
	if route.across == nil then
		local f = lower(text)
		for _, ch in M.choices(c, ctx) do
			if f == "" or string.find(lower(ch.label), f, 1, true) then
				table.insert(out, { key = ch.id, value = ch.id })
			end
		end
		return out
	end
	local l = M.load(c, ctx, route)
	if l == nil or l.error or M.isPair(c, ctx, route) then
		return out
	end
	if l.ref then
		for _, col in l.columns do
			table.insert(out, { key = col.context, ref = l.ref })
		end
		return out
	end
	local m = M.visible(c, ctx, route, text)
	for _, row in (if m then m.rows else {}) :: { Model.Row } do
		table.insert(out, { key = row.key, ref = row.ref })
	end
	return out
end

-- The object Explore's own keys act on (in the base context).
function M.focusRef(_c: C, _ctx: Ctx, route: Route, selected: Item?): Ref?
	if route.ref then
		return route.ref
	end
	return if selected then selected.ref else nil
end

local function cycleContext(l: Load, route: Route, dir: number): Route?
	local n = #l.columns - 1
	if n < 2 then
		return nil
	end
	local current = M.otherContext(l, route)
	local at = 1
	for j = 2, #l.columns do
		if l.columns[j].context == current then
			at = j - 1
		end
	end
	local upd = table.clone(route)
	upd.context = l.columns[(at - 1 + dir) % n + 2].context
	return upd
end

local function toast(effects: { Effect }, level: "success" | "info" | "error", text: string, sub: string?)
	table.insert(effects, { t = "toast", level = level, text = text, sub = sub })
end

local function pick(c: C, ctx: Ctx, route: Route, selected: Item?, effects: { Effect }): Nav?
	if selected == nil then
		return nil
	end
	for _, ch in M.choices(c, ctx) do
		if ch.id == selected.key then
			if ch.disabled then
				toast(effects, "error", "Cannot compare with " .. ch.label, ch.disabled)
				return nil
			end
			local upd = table.clone(route)
			upd.across = ch.id
			upd.item = nil
			upd.context = nil
			return { replace = upd }
		end
	end
	return nil
end

local function drill(c: C, ctx: Ctx, route: Route, selected: Item?, effects: { Effect }): Nav?
	local l = M.load(c, ctx, route)
	if l == nil or l.matrix == nil or selected == nil or M.isPair(c, ctx, route) then
		return nil
	end
	local upd = table.clone(route)
	if l.ref then
		if selected.key == l.columns[1].context then
			toast(effects, "info", "That is the base context", "Pick another row to see its diff")
			return nil
		end
		upd.item = Resource.key(l.ref)
		upd.context = selected.key
	else
		upd.item = selected.key
		upd.context = M.otherContext(l, route)
	end
	return { push = upd }
end

-- Keys of the compare route; false lets Explore's own keys run.
function M.onKey(
	c: C,
	ctx: Ctx,
	route: Route,
	selected: Item?,
	ch: string?,
	key: Key,
	effects: { Effect }
): (boolean, Nav?)
	local name = key.name
	if ch == "x" then
		if route.across == nil then
			return true, nil
		end
		return true,
			{
				replace = {
					kind = "compare",
					ref = route.ref,
					resource = route.resource,
					namespace = route.namespace,
					match = route.match,
					keys = route.keys,
				},
			}
	end
	if route.across == nil then
		if name == "enter" or name == "return" then
			return true, pick(c, ctx, route, selected, effects)
		end
		return false, nil
	end
	local l = M.load(c, ctx, route)
	if name == "enter" or name == "return" then
		return true, drill(c, ctx, route, selected, effects)
	elseif ch == "]" or ch == "[" then
		local upd = if l then cycleContext(l, route, if ch == "]" then 1 else -1) else nil
		return true, if upd then { replace = upd } else nil
	elseif ch == "f" then
		if l and l.ref == nil and route.item == nil then
			local id = M.loadId(ctx, route)
			local now = table.find(FILTERS, c.filters[id] or "all") or 1
			local filters = table.clone(c.filters)
			filters[id] = FILTERS[now % #FILTERS + 1]
			c.filters = filters
		end
		return true, nil
	end
	return false, nil
end

local function typed(argv: { string }): string
	local copy = table.clone(argv)
	copy[1] = "kubectl"
	return Command.format(copy)
end

-- Y: every pinned command of the route, one per line.
function M.copy(c: C, ctx: Ctx, route: Route, effects: { Effect })
	local lines: { string } = {}
	local l = M.load(c, ctx, route)
	if l and #l.columns > 0 then
		for _, col in l.columns do
			if col.argv then
				table.insert(lines, typed(col.argv))
			end
		end
	else
		local cl = M.contextsLoad(c, ctx)
		table.insert(lines, typed(if cl then cl.argv else Query.contextsInfo(ctx.program, ctx.target.kubeconfig)))
	end
	local text = table.concat(lines, "\n")
	table.insert(effects, { t = "copy", text = text })
	toast(effects, "success", if #lines > 1 then string.format("Copied %d commands", #lines) else "Copied", lines[1])
end

return M
