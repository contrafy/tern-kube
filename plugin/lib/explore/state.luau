--!strict
-- The Explore block's pure core, Elm style: `init` and `update` return the
-- next state plus the effects the host must execute (run kubectl, copy,
-- toast, open a link, focus the filter, exit). Nothing here touches `tern`.
--
-- Live data is read only on user action (navigation to a view not loaded yet,
-- or refresh); there is no polling. Processes cannot be killed, so "cancel"
-- means ignoring late results: every load carries a generation and a result
-- whose generation is not the load's current one is dropped.
--
-- Target safety: once the context is resolved every cluster query pins it
-- (query.luau), cache keys include it, and the context only changes when the
-- user picks another one in the chooser.

local Capture = require("../lens/capture")
local Command = require("../kubectl/command")
local Config = require("../config")
local ExploreTypes = require("./types")
local Gitops = require("./gitops")
local Json = require("../parse/json")
local Kinds = require("../kubectl/kinds")
local Link = require("../mutation/link")
local Query = require("./query")
local Quick = require("../actions/quick")
local Redact = require("../model/redact")
local Relations = require("./relations")
local Resource = require("../model/resource")
local Shellenv = require("../env/shellenv")
local Types = require("../model/types")
local Values = require("../model/values")

type Config = Config.Config
type Ref = Types.ResourceRef
type ColumnType = Types.ColumnType
export type Target = Query.Target
export type ContextSource = Query.ContextSource

export type RouteKind = ExploreTypes.RouteKind
export type Route = ExploreTypes.Route

export type LoadStatus = "idle" | "loading" | "ok" | "error"

export type Load = {
	status: LoadStatus,
	data: any?,
	error: string?,
	errorKind: string?,
	-- os.time() of the result.
	fetchedAt: number?,
	argv: { string },
	gen: number,
}

export type Row = {
	key: string,
	ref: Ref?,
	cells: { string },
	-- Lowercased cells joined, for the filter.
	hay: string,
	object: any?,
}

export type ListData = { kind: string?, headers: { string }, types: { ColumnType }, rows: { Row } }
export type NamesData = { names: { string } }
-- masked: the object view hides at least one value of the fetched object.
export type DetailData = { object: any, masked: boolean }
export type LogsData = { lines: { string } }
export type RelationsData = {
	root: any?,
	results: Relations.Results,
	queries: { [string]: Query.RelQuery },
	inflight: { [string]: boolean },
	asked: number,
	graph: Relations.Graph?,
}

export type Item = ExploreTypes.Item

export type Decode = ExploreTypes.Decode

export type Env = {
	kubeconfig: string?,
	home: string?,
	-- Resolved kubectl program (env_host.program("kubectl")).
	kubectl: string?,
	-- The PATH Tern was launched with, for the kubectl-not-found message.
	daemonPath: string?,
	-- The login shell's PATH is still being read: nothing runs yet; the host
	-- calls init again once it is known.
	pending: boolean?,
	decode: Decode,
	-- os.time() at init.
	now: number?,
	-- The block's working directory: where the manifest index is built.
	cwd: string?,
	-- tern.plugin.data (temporary manifests go to <dataDir>/tmp).
	dataDir: string?,
	-- Random token for temporary file names.
	nonce: (() -> string)?,
	-- Export: `[]` vs `{}` of decoded JSON, and the JSON null value.
	isList: ((t: { [any]: any }) -> boolean)?,
	null: any?,
}

export type Resolve = { phase: "current" | "verify" | "done" | "failed", gen: number }

export type PendingQuick = { action: string, ref: Ref, gen: number, selector: string?, port: number? }

export type State = {
	target: Target,
	stack: { Route },
	cache: { [string]: Load },
	sel: { [string]: string },
	filter: { [string]: string },
	editing: boolean,
	gen: number,
	now: number?,
	config: Config,
	program: string,
	decode: Decode,
	help: boolean,
	pendingG: boolean,
	resolve: Resolve,
	-- Why the target cannot be used (kubectl missing, context not in kubeconfig).
	targetError: string?,
	-- M.failure's kind of targetError ("spawn": kubectl could not run).
	targetErrorKind: string?,
	-- Waiting for the login shell's PATH (Env.pending).
	envPending: boolean,
	daemonPath: string?,
	quick: PendingQuick?,
	-- Block height in lines (BlockCx.rows; nil until the host reports it).
	rows: number?,
	-- First visible grid row per view, kept vim-like (scrolloff) by update().
	offset: { [string]: number },
	url: string?,
	-- Manifest index, drift, export and git flow (gitops.luau).
	gitops: Gitops.G,
	-- While editing: the GitOps text field ("dir", "branch", "message");
	-- nil edits the filter.
	field: string?,
	dataDir: string?,
	nonce: () -> string,
	isList: ((t: { [any]: any }) -> boolean)?,
	null: any?,
}

export type Effect = ExploreTypes.Effect

export type ProcessResult = ExploreTypes.ProcessResult

export type Key = ExploreTypes.Key

export type Msg = ExploreTypes.Msg

local M = {}

M.FILTER_INPUT = "main.filter"
M.RESOLVE_TAG = "resolve"
M.QUICK_TAG = "quick"
-- window.luau routes it to the Settings block with the kubectl key selected.
M.SETTINGS_URL = "tern-kube://settings?key=kubectl"
M.MAX_RELATION_QUERIES = 60
-- Lines of a block that are not grid rows (header, crumbs, filter, count,
-- column heads, dock); a grid row is about 4/3 of a line tall.
M.CHROME_LINES = 18
M.SCROLLOFF = 2
M.SAVE_VERSION = 1

local SEP = "\n"

-- Helpers --------------------------------------------------------------------

local function nonEmpty(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function copyState(s: State): State
	return table.clone(s)
end

-- Grid rows that fit a block `rows` lines tall, at most `cap`
-- (general.max_rendered_rows); `cap` when the height is unknown.
function M.viewport(rows: number?, cap: number): number
	if rows == nil then
		return cap
	end
	return math.clamp(math.floor((rows - M.CHROME_LINES) * 3 / 4), math.min(3, cap), cap)
end

-- Rows `[first, last]` of a `size`-row window over `total` rows that keeps
-- `selected` at least SCROLLOFF rows from either edge (vim's scrolloff),
-- moving the previous `offset` as little as possible.
function M.window(selected: number, total: number, offset: number?, size: number): (number, number)
	if total <= size then
		return 1, total
	end
	local so = math.min(M.SCROLLOFF, (size - 1) // 2)
	local sel = math.clamp(selected, 1, total)
	local first = offset or 1
	if sel < first + so then
		first = sel - so
	elseif sel > first + size - 1 - so then
		first = sel - size + 1 + so
	end
	first = math.clamp(first, 1, total - size + 1)
	return first, first + size - 1
end

local function top(s: State): Route
	return s.stack[#s.stack]
end

local function splitLines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(out, (string.gsub(line, "\r$", "")))
	end
	while #out > 0 and string.find(out[#out], "^%s*$") do
		table.remove(out)
	end
	return out
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s)
end

function M.resourceToken(kind: string, group: string?): string
	local info = Kinds.normalize(if group and group ~= "" then kind .. "." .. group else kind)
	if info.known then
		return if info.group then info.plural .. "." .. info.group else info.plural
	end
	local base = string.lower(kind)
	return if group and group ~= "" then base .. "." .. group else base
end

local function isPod(ref: Ref): boolean
	return ref.kind == "Pod" and (ref.group == nil or ref.group == "")
end

function M.encodeRef(ref: Ref): string
	return table.concat({
		Command.urlencode(ref.kind),
		Command.urlencode(ref.group or ""),
		Command.urlencode(ref.namespace or ""),
		Command.urlencode(ref.name),
	}, "|")
end

function M.decodeRef(value: string): Ref?
	local kind, group, ns, name = string.match(value, "^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
	if kind == nil or kind == "" or name == nil or name == "" then
		return nil
	end
	return {
		kind = Command.urldecode(kind),
		group = nonEmpty(Command.urldecode(group or "")),
		namespace = nonEmpty(Command.urldecode(ns or "")),
		name = Command.urldecode(name),
		source = "live",
	}
end

local function targetId(t: Target): string
	return (t.kubeconfig or "") .. "@" .. (t.context or "?")
end

-- Namespace scope of a list route under the current target.
function M.scope(s: State, route: Route): Query.Scope
	if route.namespace then
		return { namespace = route.namespace, all = false }
	end
	return { namespace = s.target.namespace, all = s.target.allNamespaces }
end

function M.routeKey(s: State, route: Route): string
	local kind = route.kind
	if kind == "contexts" then
		return "contexts|" .. (s.target.kubeconfig or "")
	elseif kind == "namespaces" or kind == "kinds" then
		return kind .. "|" .. targetId(s.target)
	elseif kind == "list" then
		local sc = M.scope(s, route)
		local ns = if sc.all then "*" else (sc.namespace or "")
		return "list|" .. targetId(s.target) .. "|" .. (route.resource or "") .. "|" .. ns
	elseif Gitops.isRoute(kind) then
		-- Never a cache key: GitOps routes keep their data in s.gitops.
		local parts = { "gitops-" .. kind, targetId(s.target) }
		if route.ref then
			table.insert(parts, Resource.key(route.ref))
		end
		table.insert(parts, route.source or "")
		table.insert(parts, route.item or "")
		table.insert(parts, tostring(route.doc or ""))
		return table.concat(parts, "|")
	end
	local ref = route.ref :: Ref
	local key = kind .. "|" .. targetId(s.target) .. "|" .. Resource.key(ref)
	if kind == "logs" then
		key ..= "|" .. (route.container or "") .. "|" .. (if route.previous then "p" else "")
	end
	return key
end

function M.currentKey(s: State): string
	return M.routeKey(s, top(s))
end

function M.currentLoad(s: State): Load?
	return s.cache[M.currentKey(s)]
end

local function needsContext(route: Route): boolean
	return route.kind ~= "contexts"
end

function M.resolved(s: State): boolean
	return s.target.context ~= nil and s.resolve.phase == "done" and s.targetError == nil
end

local function timeout(s: State): number
	return s.config.explore.query_timeout_ms
end

local function policy(s: State): Redact.Policy
	return Redact.fromConfig(s.config)
end

local function runEffect(s: State, tag: string, argv: { string }, gen: number): Effect
	return { t = "run", tag = tag, argv = argv, timeout_ms = timeout(s), gen = gen }
end

local function toast(level: "success" | "info" | "error", text: string, sub: string?): Effect
	return { t = "toast", level = level, text = text, sub = sub }
end

-- Errors ---------------------------------------------------------------------

local function firstLines(text: string, n: number): string
	local lines = splitLines(text)
	local out: { string } = {}
	for i = 1, math.min(n, #lines) do
		table.insert(out, lines[i])
	end
	return table.concat(out, "\n")
end

-- An actionable message for a failed kubectl run, plus a short kind.
function M.failure(s: State, result: ProcessResult, spawnError: string?): (string, string)
	if spawnError then
		if Shellenv.isNotFound(spawnError) then
			return Shellenv.notFoundText("kubectl", s.program, s.daemonPath), "spawn"
		end
		return string.format(
			'Cannot run kubectl (%s): %s. Set "kubectl" to its full path in Tern Kube: Settings '
				.. "(or ~/.config/tern-kube/config.json).",
			s.program,
			spawnError
		),
			"spawn"
	end
	if result.timed_out then
		return string.format(
			"kubectl did not answer within %d ms (explore.query_timeout_ms); the cluster may be unreachable. Press r to retry.",
			timeout(s)
		),
			"timeout"
	end
	local stderr = trim(result.stderr or "")
	local lower = string.lower(stderr)
	local first = firstLines(stderr, 3)
	local ctx = s.target.context or "(unresolved)"
	if string.find(lower, "forbidden", 1, true) then
		return string.format(
			"RBAC: the user of context %s may not do this (Forbidden). Ask for access or pick another context (c).\n%s",
			ctx,
			first
		),
			"forbidden"
	end
	if
		string.find(stderr, 'context "[^"]*" does not exist')
		or string.find(lower, "context was not found", 1, true)
		or string.find(lower, "no context exists", 1, true)
	then
		return string.format("Context %s is not in the kubeconfig. Pick another context (c).\n%s", ctx, first),
			"context"
	end
	if string.find(lower, "current-context is not set", 1, true) then
		return "The kubeconfig has no current-context. Pick a context (c).", "context"
	end
	if
		string.find(lower, "unable to connect to the server", 1, true)
		or string.find(lower, "connection refused", 1, true)
		or string.find(lower, "no such host", 1, true)
		or string.find(lower, "i/o timeout", 1, true)
	then
		return string.format("Cluster of context %s is unreachable.\n%s", ctx, first), "unreachable"
	end
	if string.find(lower, "doesn't have a resource type", 1, true) then
		return string.format("The cluster has no such resource type. Pick a kind (:).\n%s", first), "resource"
	end
	if string.find(lower, "notfound", 1, true) or string.find(lower, "not found", 1, true) then
		return string.format("Not found (it may have been deleted). Press r to retry.\n%s", first), "notfound"
	end
	if result.status == 127 or string.find(lower, "executable file not found", 1, true) then
		return string.format('kubectl not found (%s). Set "kubectl" in config.json.\n%s', s.program, first), "spawn"
	end
	if first == "" then
		return string.format("kubectl exited with status %d and printed no error.", result.status), "exit"
	end
	return string.format("kubectl exited with status %d:\n%s", result.status, first), "exit"
end

-- Data -----------------------------------------------------------------------

local function columnTypes(headers: { string }, rows: { Row }): { ColumnType }
	local types: { ColumnType } = table.create(#headers)
	local samples: { string } = table.create(#rows)
	for c, h in headers do
		for r, row in rows do
			samples[r] = row.cells[c] or ""
		end
		types[c] = Values.columnType(h, samples)
	end
	return types
end

function M.listData(stdout: string, decode: Decode, context: string?, redaction: Redact.Policy?): ListData
	local parsed = Json.parse(stdout, decode)
	local headers: { string } = {}
	local rows: { Row } = table.create(#parsed.resources)
	local kind: string? = nil
	local seen: { [string]: boolean } = {}
	for i, res in parsed.resources do
		if i == 1 then
			headers = res.summary.headers
			kind = res.ref.kind
		end
		local cells = res.summary.cells
		if res.summary.headers ~= headers and #res.summary.headers ~= #headers then
			local byName: { [string]: string } = {}
			for c, h in res.summary.headers do
				byName[h] = res.summary.cells[c]
			end
			cells = table.create(#headers)
			for c, h in headers do
				cells[c] = byName[h] or ""
			end
		end
		local ref = table.clone(res.ref)
		ref.clusterContext = context
		ref.source = "live"
		local key = Resource.key(ref)
		if seen[key] then
			key ..= "#" .. i
		end
		seen[key] = true
		rows[i] = {
			key = key,
			ref = ref,
			cells = cells,
			hay = string.lower(table.concat(cells, " ")),
			object = (Json.redactSecrets(res, redaction)),
		}
	end
	return { kind = kind, headers = headers, types = columnTypes(headers, rows), rows = rows }
end

local function namesData(stdout: string): NamesData
	local names: { string } = {}
	for _, line in splitLines(stdout) do
		local name = trim(line)
		name = string.match(name, "^namespace/(.+)$") or name
		if name ~= "" then
			table.insert(names, name)
		end
	end
	return { names = names }
end

-- The decoded object for `ref` already in the cache (detail or any list row).
function M.findObject(s: State, ref: Ref): any?
	local detail = s.cache[M.routeKey(s, { kind = "detail", ref = ref })]
	if detail and detail.status == "ok" and detail.data then
		return (detail.data :: DetailData).object
	end
	local key = Resource.key(ref)
	for _, load in s.cache do
		if load.status == "ok" and type(load.data) == "table" and load.data.rows then
			for _, row in (load.data :: ListData).rows do
				if row.key == key then
					return row.object
				end
			end
		end
	end
	return nil
end

-- What the GitOps routes need to know about the block.
function M.gitopsCtx(s: State): Gitops.Ctx
	return {
		target = s.target,
		program = s.program,
		config = s.config,
		decode = s.decode,
		resolved = M.resolved(s),
		now = s.now,
		dataDir = s.dataDir,
		nonce = s.nonce,
		isList = s.isList,
		null = s.null,
	}
end

-- Selection over what the current route shows, after the filter.
function M.items(s: State, route: Route?): { Item }
	local r = route or top(s)
	local key = M.routeKey(s, r)
	local load = s.cache[key]
	if Gitops.isRoute(r.kind) then
		return Gitops.items(s.gitops, M.gitopsCtx(s), r)
	end
	local out: { Item } = {}
	local f = string.lower(s.filter[key] or "")
	if r.kind == "namespaces" then
		local all = "* all namespaces"
		if f == "" or string.find(all, f, 1, true) then
			table.insert(out, { key = "*", value = "*" })
		end
	end
	if load == nil or load.status ~= "ok" or load.data == nil then
		return out
	end
	if r.kind == "list" then
		for _, row in (load.data :: ListData).rows do
			if f == "" or string.find(row.hay, f, 1, true) then
				table.insert(out, { key = row.key, ref = row.ref })
			end
		end
	elseif r.kind == "contexts" or r.kind == "namespaces" or r.kind == "kinds" then
		for _, name in (load.data :: NamesData).names do
			if f == "" or string.find(string.lower(name), f, 1, true) then
				table.insert(out, { key = name, value = name })
			end
		end
	elseif r.kind == "relations" then
		local graph = (load.data :: RelationsData).graph
		if graph then
			for _, node in graph.nodes do
				local hay = string.lower(node.ref.kind .. " " .. node.ref.name .. " " .. (node.provenance or ""))
				if f == "" or string.find(hay, f, 1, true) then
					table.insert(out, { key = node.key, ref = node.ref })
				end
			end
		end
	end
	return out
end

function M.selectedIndex(s: State, items: { Item }): number
	if #items == 0 then
		return 0
	end
	local want = s.sel[M.currentKey(s)]
	if want then
		for i, item in items do
			if item.key == want then
				return i
			end
		end
	end
	return 1
end

function M.selectedItem(s: State): Item?
	local items = M.items(s)
	local i = M.selectedIndex(s, items)
	return if i > 0 then items[i] else nil
end

-- The object the keys act on: the selected row, or the route's own object.
function M.focusRef(s: State): Ref?
	local r = top(s)
	if r.kind == "list" or r.kind == "relations" then
		local item = M.selectedItem(s)
		if item and item.ref then
			return item.ref
		end
		return if r.kind == "relations" then r.ref else nil
	end
	if Gitops.isRoute(r.kind) then
		return Gitops.focusRef(s.gitops, M.gitopsCtx(s), r, M.selectedItem(s))
	end
	return r.ref
end

-- Loading --------------------------------------------------------------------

local function allowLive(s: State): boolean
	return s.config.explore.allow_live_queries
end

local function relOpts(s: State): Relations.Options
	return { maxNodes = s.config.explore.relationship_max_nodes, maxDepth = 2, fanOut = nil, childKinds = nil }
end

local function argvFor(s: State, route: Route): { string }?
	local p, t = s.program, s.target
	local kind = route.kind
	if kind == "contexts" then
		return Query.contexts(p, t.kubeconfig)
	elseif kind == "namespaces" then
		return Query.namespaces(p, t)
	elseif kind == "kinds" then
		return Query.apiResources(p, t)
	elseif kind == "list" then
		return Query.list(p, t, route.resource or "pods", M.scope(s, route))
	end
	local ref = route.ref
	if ref == nil then
		return nil
	end
	if kind == "detail" or kind == "relations" then
		return Query.get(p, t, ref)
	elseif kind == "describe" then
		return Query.describe(p, t, ref)
	elseif kind == "logs" then
		return Query.logs(p, t, ref, route.container, route.previous == true, Query.LOG_TAIL)
	end
	return nil
end

local function setLoad(s: State, key: string, load: Load)
	local cache = table.clone(s.cache)
	cache[key] = load
	s.cache = cache
end

local function issueRelationQueries(s: State, key: string, load: Load, effects: { Effect })
	local data = load.data :: RelationsData
	local pending = Relations.pending(data.root, data.results, relOpts(s))
	local inflight: { [string]: boolean } = {}
	local queries = table.clone(data.queries)
	local asked = data.asked
	for _, q in pending do
		if asked >= M.MAX_RELATION_QUERIES then
			break
		end
		if queries[q.key] == nil then
			queries[q.key] = q
			inflight[q.key] = true
			asked += 1
			table.insert(effects, runEffect(s, key .. SEP .. q.key, Query.relation(s.program, s.target, q), load.gen))
		end
	end
	local upd = table.clone(data)
	upd.queries = queries
	upd.inflight = inflight
	upd.asked = asked
	if next(inflight) == nil then
		local graph = Relations.build(data.root, data.results, relOpts(s))
		if asked >= M.MAX_RELATION_QUERIES then
			local notes = table.clone(graph.notes)
			table.insert(notes, string.format("Stopped after %d queries (query budget).", M.MAX_RELATION_QUERIES))
			graph = table.clone(graph)
			graph.notes = notes
		end
		upd.graph = graph
		load.status = "ok"
	end
	load.data = upd
	setLoad(s, key, load)
end

local function startRelations(s: State, route: Route, key: string, gen: number, effects: { Effect })
	local ref = route.ref :: Ref
	local root = M.findObject(s, ref)
	local data: RelationsData = { root = root, results = {}, queries = {}, inflight = {}, asked = 0, graph = nil }
	local argv = Query.get(s.program, s.target, ref)
	local load: Load = { status = "loading", data = data, argv = argv, gen = gen }
	if root then
		issueRelationQueries(s, key, load, effects)
	else
		setLoad(s, key, load)
		table.insert(effects, runEffect(s, key .. SEP .. "root", argv, gen))
	end
end

-- Starts loading `route` (or reloads it when `force`).
local function startLoad(s: State, route: Route, force: boolean, effects: { Effect })
	local key = M.routeKey(s, route)
	local existing = s.cache[key]
	if existing and not force and existing.status ~= "idle" then
		return
	end
	if not allowLive(s) then
		return
	end
	if needsContext(route) and not M.resolved(s) then
		return
	end
	local argv = argvFor(s, route)
	if argv == nil then
		return
	end
	s.gen += 1
	if route.kind == "relations" then
		startRelations(s, route, key, s.gen, effects)
		return
	end
	setLoad(s, key, { status = "loading", argv = argv, gen = s.gen })
	table.insert(effects, runEffect(s, key, argv, s.gen))
end

-- Runs a GitOps call on a fresh copy of s.gitops.
local function withGitops<R>(s: State, fn: (g: Gitops.G, ctx: Gitops.Ctx) -> R): R
	local g = Gitops.clone(s.gitops)
	local r = fn(g, M.gitopsCtx(s))
	s.gitops = g
	return r
end

local function enterGitops(s: State, route: Route, force: boolean, effects: { Effect })
	withGitops(s, function(g, ctx)
		Gitops.enter(g, ctx, route, force, effects)
		return nil
	end)
end

local function ensure(s: State, effects: { Effect })
	local route = top(s)
	if Gitops.isRoute(route.kind) then
		enterGitops(s, route, false, effects)
		return
	end
	startLoad(s, route, false, effects)
end

local function pushRoute(s: State, route: Route, effects: { Effect })
	local stack = table.clone(s.stack)
	table.insert(stack, route)
	s.stack = stack
	s.editing = false
	ensure(s, effects)
end

-- Init -----------------------------------------------------------------------

local function param(params: { { key: string, value: string } }, key: string): string?
	for _, p in params do
		if p.key == key and p.value ~= "" then
			return p.value
		end
	end
	return nil
end

-- --kubeconfig accepts one file; a KUBECONFIG list is left to the inherited
-- environment instead.
local function kubeconfigPath(link: string?, config: Config, env: Env): string?
	if link then
		return link
	end
	if config.kubeconfig then
		return config.kubeconfig
	end
	local fromEnv = nonEmpty(env.kubeconfig)
	if fromEnv then
		return if string.find(fromEnv, ":", 1, true) then nil else fromEnv
	end
	if env.home and env.home ~= "" then
		return (string.gsub(env.home, "/+$", "")) .. "/.kube/config"
	end
	return nil
end

local SOURCES: { [string]: boolean } = { flag = true, chosen = true, inferred = true }
local ROUTE_KINDS: { [string]: boolean } = {
	list = true,
	detail = true,
	relations = true,
	describe = true,
	logs = true,
	contexts = true,
	namespaces = true,
	kinds = true,
}

local function restoreRoute(v: any): Route?
	if type(v) ~= "table" or not ROUTE_KINDS[v.kind] then
		return nil
	end
	local ref: Ref? = nil
	if type(v.ref) == "table" then
		local kind, name = nonEmpty(v.ref.kind), nonEmpty(v.ref.name)
		if kind and name then
			ref = {
				kind = kind,
				name = name,
				group = nonEmpty(v.ref.group),
				namespace = nonEmpty(v.ref.namespace),
				source = "live",
			}
		end
	end
	local needsRef = v.kind == "detail" or v.kind == "relations" or v.kind == "describe" or v.kind == "logs"
	if needsRef and ref == nil then
		return nil
	end
	return {
		kind = v.kind,
		resource = nonEmpty(v.resource),
		namespace = nonEmpty(v.namespace),
		ref = ref,
		container = nonEmpty(v.container),
		previous = if v.previous == true then true else nil,
	}
end

local function stringMap(v: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(v) == "table" then
		for k, x in v do
			if type(k) == "string" and type(x) == "string" then
				out[k] = x
			end
		end
	end
	return out
end

local function linkRoutes(params: { { key: string, value: string } }): { Route }
	local kind = param(params, "kind")
	local group = param(params, "group")
	local name = param(params, "name")
	local resource = if kind then M.resourceToken(kind, group) else "pods"
	local stack: { Route } = { { kind = "list", resource = resource } }
	if kind and name then
		local info = Kinds.normalize(resource)
		local ref: Ref = {
			kind = if info.known then info.kind else kind,
			group = group or info.group,
			name = name,
			namespace = param(params, "namespace"),
			source = "live",
		}
		table.insert(stack, { kind = "detail", ref = ref })
		-- Lens chips "Manifest" / "Diff vs manifest".
		local route = param(params, "route")
		if route == "manifest" then
			table.insert(stack, { kind = "manifest", ref = ref })
		elseif route == "diff" then
			table.insert(stack, { kind = "diff", ref = ref, doc = 1 })
		end
	end
	return stack
end

function M.init(args: { string }, saved: any, config: Config, env: Env): (State, { Effect })
	local url = args[1]
	local params = if url and string.sub(url, 1, 12) == "tern-kube://" then Command.parseQuery(url) else {}
	local linkContext = param(params, "context")
	local target: Target = {
		kubeconfig = kubeconfigPath(param(params, "kubeconfig"), config, env),
		context = linkContext,
		contextSource = if linkContext then "flag" else "unresolved",
		namespace = param(params, "namespace"),
		allNamespaces = false,
		confirmed = linkContext ~= nil,
		inferredAt = nil,
	}
	local stack = linkRoutes(params)
	local sel: { [string]: string } = {}
	local filter: { [string]: string } = {}
	if type(saved) == "table" and saved.v == M.SAVE_VERSION then
		local st = saved.target
		if type(st) == "table" and SOURCES[st.contextSource] and nonEmpty(st.context) then
			target = {
				kubeconfig = nonEmpty(st.kubeconfig),
				context = st.context,
				contextSource = st.contextSource,
				namespace = nonEmpty(st.namespace),
				allNamespaces = st.allNamespaces == true,
				confirmed = st.confirmed == true,
				inferredAt = if type(st.inferredAt) == "number" then st.inferredAt else nil,
			}
		end
		if type(saved.stack) == "table" then
			local restored: { Route } = {}
			for _, r in saved.stack do
				local route = restoreRoute(r)
				if route then
					table.insert(restored, route)
				end
			end
			if #restored > 0 then
				stack = restored
			end
		end
		sel = stringMap(saved.sel)
		filter = stringMap(saved.filter)
	end
	local linkCwd = param(params, "cwd")
	local cwd = if linkCwd and string.sub(linkCwd, 1, 1) == "/" then linkCwd else nonEmpty(env.cwd)
	local counter = 0
	local s: State = {
		target = target,
		stack = stack,
		cache = {},
		sel = sel,
		filter = filter,
		editing = false,
		gen = 0,
		now = env.now,
		config = config,
		program = env.kubectl or config.kubectl,
		decode = env.decode,
		help = false,
		pendingG = false,
		resolve = { phase = "current", gen = 0 },
		targetError = nil,
		targetErrorKind = nil,
		envPending = env.pending == true,
		daemonPath = env.daemonPath,
		quick = nil,
		url = url,
		rows = nil,
		offset = {},
		gitops = Gitops.new(cwd),
		field = nil,
		dataDir = env.dataDir,
		nonce = env.nonce or function(): string
			counter += 1
			return tostring(counter)
		end,
		isList = env.isList,
		null = env.null,
	}
	local effects: { Effect } = {}
	if s.envPending then
		return s, effects
	end
	if not allowLive(s) then
		s.resolve = { phase = "failed", gen = 0 }
		s.targetError = "Live queries are disabled (explore.allow_live_queries = false in config.json)."
		s.targetErrorKind = "disabled"
		return s, effects
	end
	s.gen += 1
	if target.context then
		-- The named context must exist before anything is queried with it.
		local contextsRoute: Route = { kind = "contexts" }
		local key = M.routeKey(s, contextsRoute)
		local argv = Query.contexts(s.program, target.kubeconfig)
		s.resolve = { phase = "verify", gen = s.gen }
		setLoad(s, key, { status = "loading", argv = argv, gen = s.gen })
		table.insert(effects, runEffect(s, key, argv, s.gen))
	else
		s.resolve = { phase = "current", gen = s.gen }
		table.insert(effects, runEffect(s, M.RESOLVE_TAG, Query.currentContext(s.program, target.kubeconfig), s.gen))
	end
	return s, effects
end

-- Save -----------------------------------------------------------------------

local function savedRef(ref: Ref?): any
	if ref == nil then
		return nil
	end
	return { kind = ref.kind, group = ref.group, namespace = ref.namespace, name = ref.name }
end

-- Navigation and target only: cached cluster data is never persisted, and
-- GitOps routes are not restored (they would rescan without being asked).
function M.save(s: State): any
	local stack: { any } = {}
	for i, r in s.stack do
		if Gitops.isRoute(r.kind) then
			break
		end
		stack[i] = {
			kind = r.kind,
			resource = r.resource,
			namespace = r.namespace,
			ref = savedRef(r.ref),
			container = r.container,
			previous = r.previous,
		}
	end
	local t = s.target
	local target = if t.context and t.contextSource ~= "unresolved"
		then {
			kubeconfig = t.kubeconfig,
			context = t.context,
			contextSource = t.contextSource,
			namespace = t.namespace,
			allNamespaces = t.allNamespaces,
			confirmed = t.confirmed,
			inferredAt = t.inferredAt,
		}
		else nil
	return {
		v = M.SAVE_VERSION,
		target = target,
		stack = stack,
		sel = table.clone(s.sel),
		filter = table.clone(s.filter),
	}
end

-- Navigation -----------------------------------------------------------------

local function selectKey(s: State, key: string)
	local sel = table.clone(s.sel)
	sel[M.currentKey(s)] = key
	s.sel = sel
end

local function move(s: State, delta: number?, absolute: number?)
	local items = M.items(s)
	if #items == 0 then
		return
	end
	local i = absolute or (M.selectedIndex(s, items) + (delta or 0))
	i = math.clamp(i, 1, #items)
	selectKey(s, items[i].key)
end

local function back(s: State, effects: { Effect })
	if #s.stack > 1 then
		local stack = table.clone(s.stack)
		local left = table.remove(stack) :: Route
		s.stack = stack
		if left.ref and stack[#stack].kind == "list" and s.sel[M.currentKey(s)] == nil then
			selectKey(s, Resource.key(left.ref))
		end
		ensure(s, effects)
		return
	end
	local key = M.currentKey(s)
	if (s.filter[key] or "") ~= "" then
		local filter = table.clone(s.filter)
		filter[key] = nil
		s.filter = filter
		return
	end
	table.insert(effects, { t = "exit" })
end

local function truncate(s: State, depth: number, effects: { Effect })
	if depth < 1 or depth > #s.stack then
		return
	end
	s.stack = table.move(s.stack, 1, depth, 1, table.create(depth))
	ensure(s, effects)
end

local function chooseContext(s: State, name: string, effects: { Effect })
	local t = table.clone(s.target)
	t.context = name
	t.contextSource = "chosen"
	-- Picking from the list is a choice, not a confirmation of the target.
	t.confirmed = false
	t.inferredAt = nil
	t.namespace = nil
	t.allNamespaces = false
	s.target = t
	s.targetError = nil
	s.targetErrorKind = nil
	s.resolve = { phase = "done", gen = s.resolve.gen }
	-- Back to the root view of the newly chosen cluster.
	local root = s.stack[1]
	if root.kind ~= "list" then
		root = { kind = "list", resource = "pods" }
	end
	s.stack = { root }
	ensure(s, effects)
	table.insert(effects, toast("info", "Context " .. name, "Press Confirm target before any mutation"))
end

local function chooseNamespace(s: State, name: string, effects: { Effect })
	local t = table.clone(s.target)
	if name == "*" then
		t.namespace = nil
		t.allNamespaces = true
	else
		t.namespace = name
		t.allNamespaces = false
	end
	s.target = t
	local stack = table.clone(s.stack)
	while #stack > 1 and stack[#stack].kind == "namespaces" do
		table.remove(stack)
	end
	s.stack = stack
	ensure(s, effects)
end

local function chooseKind(s: State, resource: string, effects: { Effect })
	s.stack = { { kind = "list", resource = resource } }
	ensure(s, effects)
end

local function openRef(s: State, kind: RouteKind, ref: Ref?, effects: { Effect })
	if ref == nil then
		return
	end
	local r = top(s)
	if r.kind == kind and r.ref and Resource.key(r.ref) == Resource.key(ref) then
		return
	end
	pushRoute(s, { kind = kind, ref = ref, previous = if kind == "logs" then false else nil }, effects)
end

local function drill(s: State, effects: { Effect })
	local r = top(s)
	if Gitops.isRoute(r.kind) then
		return
	end
	if r.kind == "detail" then
		openRef(s, "relations", r.ref, effects)
		return
	end
	local item = M.selectedItem(s)
	if item == nil then
		return
	end
	if r.kind == "contexts" then
		chooseContext(s, item.key, effects)
	elseif r.kind == "namespaces" then
		chooseNamespace(s, item.key, effects)
	elseif r.kind == "kinds" then
		chooseKind(s, item.key, effects)
	elseif item.ref then
		openRef(s, "detail", item.ref, effects)
	end
end

local function pushPicker(s: State, kind: RouteKind, effects: { Effect })
	if top(s).kind == kind then
		return
	end
	if kind ~= "contexts" and not M.resolved(s) then
		table.insert(effects, toast("error", "No cluster target yet", "Pick a context first (c)"))
		return
	end
	pushRoute(s, { kind = kind }, effects)
end

-- After kubectl could not run, a retry starts over (the host re-reads the
-- config and the program, which the user may just have set).
function M.refresh(s: State, effects: { Effect })
	if s.targetErrorKind == "spawn" then
		table.insert(effects, { t = "restart" })
		return
	end
	local r = top(s)
	if Gitops.isRoute(r.kind) then
		enterGitops(s, r, true, effects)
		return
	end
	if r.kind == "contexts" or M.resolved(s) then
		startLoad(s, r, true, effects)
	end
end

-- Copy -----------------------------------------------------------------------

-- What a user would type: `kubectl`, not the daemon's resolved program path.
local function typed(argv: { string }): string
	local copy = table.clone(argv)
	copy[1] = "kubectl"
	return Command.format(copy)
end

local function copyCommand(s: State, effects: { Effect })
	local argv = argvFor(s, top(s))
	if argv == nil then
		return
	end
	local text = typed(argv)
	table.insert(effects, { t = "copy", text = text })
	table.insert(effects, toast("success", "Copied", text))
end

function M.execCommand(s: State, ref: Ref): string?
	if not isPod(ref) then
		return nil
	end
	local argv = Query.base("kubectl", s.target)
	for _, a in { "exec", "-it", "-n", ref.namespace or "default", ref.name, "--", "sh" } do
		table.insert(argv, a)
	end
	return Command.format(argv)
end

local function copyWhat(s: State, what: string, effects: { Effect })
	local ref = M.focusRef(s)
	if what == "cmd" then
		copyCommand(s, effects)
		return
	end
	if ref == nil then
		table.insert(effects, toast("error", "Nothing selected"))
		return
	end
	local text: string? = nil
	if what == "id" then
		text = Resource.qualifiedId(ref)
	elseif what == "name" then
		text = ref.name
	elseif what == "exec" then
		text = M.execCommand(s, ref)
	end
	if text == nil then
		table.insert(effects, toast("error", "Nothing to copy", what .. " does not apply to " .. ref.kind))
		return
	end
	table.insert(effects, { t = "copy", text = text })
	if what == "exec" then
		table.insert(effects, toast("info", "Copied exec command", "Runs a shell in the container; check the context"))
	else
		table.insert(effects, toast("success", "Copied", text))
	end
end

-- Quick actions --------------------------------------------------------------

local WORKLOADS: { [string]: boolean } =
	{ Deployment = true, StatefulSet = true, DaemonSet = true, ReplicaSet = true, Job = true }

local function podSpec(obj: any): any
	if type(obj) ~= "table" or type(obj.spec) ~= "table" then
		return nil
	end
	if obj.kind == "Pod" then
		return obj.spec
	end
	local template = obj.spec.template
	return if type(template) == "table" then template.spec else nil
end

function M.ports(obj: any): { number }
	local out: { number } = {}
	if type(obj) ~= "table" or type(obj.spec) ~= "table" then
		return out
	end
	if obj.kind == "Service" then
		for _, p in (if type(obj.spec.ports) == "table" then obj.spec.ports else {}) :: { any } do
			if type(p) == "table" and type(p.port) == "number" then
				table.insert(out, p.port)
			end
		end
		return out
	end
	local spec = podSpec(obj)
	if type(spec) ~= "table" or type(spec.containers) ~= "table" then
		return out
	end
	for _, c in spec.containers do
		if type(c) == "table" and type(c.ports) == "table" then
			for _, p in c.ports do
				if type(p) == "table" and type(p.containerPort) == "number" then
					table.insert(out, p.containerPort)
				end
			end
		end
	end
	return out
end

function M.containers(obj: any): { string }
	local out: { string } = {}
	local spec = podSpec(obj)
	if type(spec) == "table" and type(spec.containers) == "table" then
		for _, c in spec.containers do
			if type(c) == "table" and type(c.name) == "string" then
				table.insert(out, c.name)
			end
		end
	end
	return out
end

local function selectorOf(obj: any): string?
	if type(obj) ~= "table" or type(obj.spec) ~= "table" then
		return nil
	end
	return Query.selectorString(obj.spec.selector)
end

function M.readyPod(items: { any }): string?
	for _, pod in items do
		if type(pod) ~= "table" or type(pod.status) ~= "table" or pod.status.phase ~= "Running" then
			continue
		end
		local conditions = pod.status.conditions
		if type(conditions) == "table" then
			for _, c in conditions do
				if type(c) == "table" and c.type == "Ready" and c.status == "True" then
					return if type(pod.metadata) == "table" then pod.metadata.name else nil
				end
			end
		end
	end
	return nil
end

local function openQuick(s: State, action: string, ref: Ref, opts: { [string]: any }, effects: { Effect })
	local url, err = Quick.encode(action :: any, s.target :: any, ref, opts :: any)
	if url == nil then
		table.insert(effects, toast("error", "Cannot " .. action, err))
		return
	end
	table.insert(effects, { t = "open", url = url })
end

local function quick(s: State, action: string, effects: { Effect })
	if not M.resolved(s) then
		table.insert(effects, toast("error", "No cluster target yet", "Pick a context first (c)"))
		return
	end
	local ref = M.focusRef(s)
	if ref == nil then
		table.insert(effects, toast("error", "Select an object first"))
		return
	end
	local obj = M.findObject(s, ref)
	local selector = selectorOf(obj)
	local ports = M.ports(obj)
	local container: string? = nil
	local r = top(s)
	if r.kind == "logs" and r.ref and Resource.key(r.ref) == Resource.key(ref) then
		container = r.container
	end
	-- Each action takes only its own parameters (quick.luau rejects the rest).
	local opts: { [string]: any } = {}
	if action == "shell" then
		opts.container = container
	elseif action == "logs-follow" then
		opts.container = container
		opts.selector = if isPod(ref) then nil else selector
	elseif action == "port-forward" then
		opts.port = ports[1]
	end
	if action == "shell" and WORKLOADS[ref.kind] then
		-- A workload has no shell of its own: pick one of its ready pods first.
		if selector == nil then
			table.insert(effects, toast("error", "Cannot shell", "Open the workload first so its selector is known"))
			return
		end
		s.gen += 1
		local pending: PendingQuick = { action = action, ref = ref, gen = s.gen, selector = selector, port = nil }
		s.quick = pending
		local argv = Query.list(s.program, s.target, "pods", { namespace = ref.namespace, all = false })
		table.insert(argv, #argv - 1, "-l")
		table.insert(argv, #argv - 1, selector)
		table.insert(effects, runEffect(s, M.QUICK_TAG, argv, s.gen))
		table.insert(effects, toast("info", "Finding a ready pod of " .. ref.name))
		return
	end
	openQuick(s, action, ref, opts, effects)
end

-- ctrl+d / ctrl+r / shift+s and the matching chips: open the approve block
-- for the focused object; it previews and confirms, Explore never mutates.
local function mutate(s: State, op: string, effects: { Effect })
	if not s.config.mutations.enabled then
		table.insert(effects, toast("error", "Mutations are disabled", "mutations.enabled is false in the config"))
		return
	end
	if not M.resolved(s) then
		table.insert(effects, toast("error", "No cluster target yet", "Pick a context first (c)"))
		return
	end
	local ref = M.focusRef(s)
	if ref == nil then
		table.insert(effects, toast("error", "Select an object first"))
		return
	end
	local url, err = Link.forRef(op :: Link.Op, ref, {
		context = s.target.context,
		source = Link.sourceOf(s.target.contextSource, s.target.confirmed),
		kubeconfig = s.target.kubeconfig,
	})
	if url == nil then
		table.insert(effects, toast("error", "Cannot " .. op .. " " .. ref.kind, err))
		return
	end
	table.insert(effects, { t = "open", url = url })
end

-- GitOps ---------------------------------------------------------------------

local function applyNav(s: State, nav: Gitops.Nav?, effects: { Effect })
	if nav == nil then
		return
	end
	if nav.push then
		pushRoute(s, nav.push :: Route, effects)
	elseif nav.replace then
		local stack = table.clone(s.stack)
		stack[#stack] = nav.replace :: Route
		s.stack = stack
		ensure(s, effects)
	elseif nav.pop then
		back(s, effects)
	end
end

local function needTarget(s: State, effects: { Effect }): boolean
	if M.resolved(s) then
		return true
	end
	table.insert(effects, toast("error", "No cluster target yet", "Pick a context first (c)"))
	return false
end

-- m: the manifest list of the focused object, opening its best manifest.
local function manifestKey(s: State, effects: { Effect })
	local ref = M.focusRef(s)
	if ref == nil then
		table.insert(effects, toast("error", "Select an object first"))
		return
	end
	local r = top(s)
	if not (r.kind == "manifest" and r.ref and Resource.key(r.ref) == Resource.key(ref)) then
		pushRoute(s, { kind = "manifest", ref = ref }, effects)
	end
	withGitops(s, function(g, ctx)
		Gitops.openManifest(g, ctx, ref, effects)
		return nil
	end)
end

-- =: the focused object diffed against its best manifest.
local function diffKey(s: State, effects: { Effect })
	local ref = M.focusRef(s)
	if ref == nil then
		table.insert(effects, toast("error", "Select an object first"))
		return
	end
	if needTarget(s, effects) then
		pushRoute(s, { kind = "diff", ref = ref, doc = 1 }, effects)
	end
end

-- ctrl+g: the drift source chooser.
local function driftKey(s: State, effects: { Effect })
	if top(s).kind == "drift" and top(s).source == nil then
		return
	end
	if needTarget(s, effects) then
		pushRoute(s, { kind = "drift" }, effects)
	end
end

-- E: export the object in view, or every row of the (filtered) list.
local function exportKey(s: State, effects: { Effect })
	local r = top(s)
	local objects: { any } = {}
	local label: string
	if r.kind == "list" then
		local key = M.currentKey(s)
		local load = s.cache[key]
		local f = string.lower(s.filter[key] or "")
		if load and load.status == "ok" and load.data then
			for _, row in (load.data :: ListData).rows do
				if row.object and (f == "" or string.find(row.hay, f, 1, true)) then
					table.insert(objects, row.object)
				end
			end
		end
		local sc = M.scope(s, r)
		local where = if sc.all then "all namespaces" else (sc.namespace or "the default namespace")
		local resource = r.resource or "pods"
		local plural = string.match(resource, "^[^.]+") or resource
		local info = Kinds.normalize(resource)
		local one = if info.known then string.lower(info.kind) else plural
		label = Gitops.count(#objects, one, plural) .. " from " .. where
	else
		local ref = M.focusRef(s)
		local obj = if ref then M.findObject(s, ref) else nil
		if ref == nil or obj == nil then
			table.insert(effects, toast("error", "Nothing to export", "Open the object first (y)"))
			return
		end
		table.insert(objects, obj)
		label = string.lower(ref.kind) .. " " .. ref.name
	end
	if #objects == 0 then
		table.insert(effects, toast("error", "Nothing to export", "The list is empty"))
		return
	end
	withGitops(s, function(g, ctx)
		Gitops.startExport(g, ctx, objects, { label = label, dir = nil, summary = nil }, effects)
		return nil
	end)
	if r.kind == "export" then
		ensure(s, effects)
	else
		pushRoute(s, { kind = "export" }, effects)
	end
end

local FIELD_ROUTES: { [string]: string } = { dir = "export", branch = "git", message = "git" }

M.FIELD_INPUTS = { dir = "main.gitops-dir", branch = "main.gitops-branch", message = "main.gitops-message" }

local function startField(s: State, field: string, effects: { Effect }): boolean
	if top(s).kind ~= FIELD_ROUTES[field] then
		return false
	end
	local g = s.gitops
	if (field == "dir" and g.export == nil) or (field ~= "dir" and (g.git == nil or g.git.status ~= "ready")) then
		return false
	end
	withGitops(s, function(g2)
		Gitops.setField(g2, field, Gitops.fieldValue(g2, field))
		return nil
	end)
	s.editing = true
	s.field = field
	table.insert(effects, { t = "focus", id = M.FIELD_INPUTS[field] })
	return true
end

local function fieldKey(s: State, key: Key, ch: string?, effects: { Effect }): boolean
	local field = s.field :: string
	local name = key.name
	local current = Gitops.fieldValue(s.gitops, field)
	if name == "enter" or name == "return" then
		s.editing = false
		s.field = nil
		withGitops(s, function(g, ctx)
			Gitops.commitField(g, ctx, field, effects)
			return nil
		end)
	elseif name == "escape" then
		s.editing = false
		s.field = nil
		withGitops(s, function(g)
			local fields = table.clone(g.fields)
			fields[field] = nil
			g.fields = fields
			return nil
		end)
	elseif name == "backspace" then
		withGitops(s, function(g)
			Gitops.setField(g, field, string.sub(current, 1, -2))
			return nil
		end)
	elseif ch then
		withGitops(s, function(g)
			Gitops.setField(g, field, current .. ch)
			return nil
		end)
	else
		return false
	end
	return true
end

-- Route-specific keys of the GitOps views; false lets the global keys run.
local function gitopsRouteKey(s: State, key: Key, ch: string?, effects: { Effect }): boolean
	local r = top(s)
	if not Gitops.isRoute(r.kind) then
		return false
	end
	if r.kind == "export" and ch == "t" then
		return startField(s, "dir", effects)
	elseif r.kind == "git" and ch == "b" then
		return startField(s, "branch", effects)
	elseif r.kind == "git" and ch == "e" then
		return startField(s, "message", effects)
	end
	local selected = M.selectedItem(s)
	local g = Gitops.clone(s.gitops)
	local handled, nav = Gitops.onKey(g, M.gitopsCtx(s), r, selected, ch, key, effects)
	s.gitops = g
	applyNav(s, nav, effects)
	return handled
end

-- Keys -----------------------------------------------------------------------

local FILTERABLE: { [string]: boolean } =
	{ list = true, contexts = true, namespaces = true, kinds = true, relations = true }

local function setFilter(s: State, text: string)
	local filter = table.clone(s.filter)
	if text == "" then
		filter[M.currentKey(s)] = nil
	else
		filter[M.currentKey(s)] = text
	end
	s.filter = filter
	local sel = table.clone(s.sel)
	sel[M.currentKey(s)] = nil
	s.sel = sel
end

local function editKey(s: State, key: Key, ch: string?): boolean
	local name = key.name
	local current = s.filter[M.currentKey(s)] or ""
	if name == "escape" or name == "enter" or name == "return" then
		s.editing = false
	elseif name == "backspace" then
		setFilter(s, string.sub(current, 1, -2))
	elseif ch then
		setFilter(s, current .. ch)
	elseif name == "down" then
		move(s, 1)
	elseif name == "up" then
		move(s, -1)
	else
		return false
	end
	return true
end

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function startEdit(s: State, effects: { Effect }): boolean
	if not FILTERABLE[top(s).kind] then
		return false
	end
	s.editing = true
	table.insert(effects, { t = "focus", id = M.FILTER_INPUT })
	return true
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	local ch = printable(key)
	if s.editing then
		if s.field then
			return fieldKey(s, key, ch, effects)
		end
		return editKey(s, key, ch)
	end
	local name = key.name
	local wasG = s.pendingG
	s.pendingG = false
	if s.help and (name == "escape" or ch == "?") then
		s.help = false
		return true
	end
	if not s.help and gitopsRouteKey(s, key, ch, effects) then
		return true
	end
	if ch == "g" then
		if wasG then
			move(s, nil, 1)
		else
			s.pendingG = true
		end
		return true
	elseif ch == "G" then
		local items = M.items(s)
		move(s, nil, #items)
		return true
	elseif ch == "j" or name == "down" then
		move(s, 1)
	elseif ch == "k" or name == "up" then
		move(s, -1)
	elseif name == "pagedown" or (key.ctrl and name == "f") then
		move(s, M.viewport(s.rows, s.config.general.max_rendered_rows))
	elseif name == "pageup" or (key.ctrl and (name == "b" or name == "u")) then
		move(s, -M.viewport(s.rows, s.config.general.max_rendered_rows))
	elseif key.ctrl and name == "d" then
		mutate(s, "delete", effects)
	elseif key.ctrl and name == "r" then
		mutate(s, "restart", effects)
	elseif ch == "S" or (name == "s" and key.shift) then
		mutate(s, "scale", effects)
	elseif name == "home" then
		move(s, nil, 1)
	elseif name == "end" then
		move(s, nil, #M.items(s))
	elseif name == "enter" or name == "return" then
		drill(s, effects)
	elseif name == "escape" or name == "backspace" then
		back(s, effects)
	elseif ch == "/" then
		return startEdit(s, effects)
	elseif ch == "?" then
		s.help = not s.help
	elseif ch == "r" then
		M.refresh(s, effects)
	elseif ch == "c" then
		pushPicker(s, "contexts", effects)
	elseif ch == "n" then
		pushPicker(s, "namespaces", effects)
	elseif ch == ":" then
		pushPicker(s, "kinds", effects)
	elseif ch == "d" then
		openRef(s, "describe", M.focusRef(s), effects)
	elseif ch == "y" then
		openRef(s, "detail", M.focusRef(s), effects)
	elseif ch == "L" then
		openRef(s, "logs", M.focusRef(s), effects)
	elseif ch == "R" then
		openRef(s, "relations", M.focusRef(s), effects)
	elseif ch == "Y" then
		copyCommand(s, effects)
	elseif ch == "s" then
		quick(s, "shell", effects)
	elseif ch == "l" then
		quick(s, "logs-follow", effects)
	elseif ch == "F" or (name == "f" and key.shift) then
		quick(s, "port-forward", effects)
	elseif key.ctrl and name == "g" then
		driftKey(s, effects)
	elseif ch == "m" then
		manifestKey(s, effects)
	elseif ch == "=" then
		diffKey(s, effects)
	elseif ch == "E" or (name == "e" and key.shift) then
		exportKey(s, effects)
	else
		return false
	end
	return true
end

-- Actions (pointer) ----------------------------------------------------------

local function onAction(s: State, act: string, value: string, effects: { Effect }): boolean
	if act == "open" then
		selectKey(s, value)
		if Gitops.isRoute(top(s).kind) then
			gitopsRouteKey(s, { name = "enter" }, nil, effects)
			return true
		end
		drill(s, effects)
	elseif act == "sel" then
		selectKey(s, value)
	elseif act == "page" then
		local size = M.viewport(s.rows, s.config.general.max_rendered_rows)
		move(s, if value == "up" then -size else size)
	elseif act == "back" then
		back(s, effects)
	elseif act == "crumb" then
		truncate(s, tonumber(value) or 0, effects)
	elseif act == "refresh" then
		M.refresh(s, effects)
	elseif act == "settings" then
		table.insert(effects, { t = "open", url = M.SETTINGS_URL })
	elseif act == "help" then
		s.help = not s.help
	elseif act == "nav" then
		if value == "contexts" or value == "namespaces" or value == "kinds" then
			pushPicker(s, value :: RouteKind, effects)
		elseif value == "detail" or value == "describe" or value == "logs" or value == "relations" then
			openRef(s, value :: RouteKind, M.focusRef(s), effects)
		else
			return false
		end
	elseif act == "goto" then
		openRef(s, "detail", M.decodeRef(value), effects)
	elseif act == "ctx" then
		chooseContext(s, value, effects)
	elseif act == "ns" then
		if not M.resolved(s) then
			return false
		end
		chooseNamespace(s, value, effects)
	elseif act == "kind" then
		if not M.resolved(s) then
			return false
		end
		chooseKind(s, value, effects)
	elseif act == "confirm" then
		if not M.resolved(s) then
			return false
		end
		local t = table.clone(s.target)
		t.confirmed = true
		s.target = t
		table.insert(effects, { t = "save" })
	elseif act == "copy" then
		copyWhat(s, value, effects)
	elseif act == "quick" then
		quick(s, value, effects)
	elseif act == "mutate" then
		mutate(s, value, effects)
	elseif act == "container" or act == "previous" then
		local r = top(s)
		if r.kind ~= "logs" then
			return false
		end
		local upd = table.clone(r)
		if act == "container" then
			upd.container = if value == "" then nil else value
		else
			upd.previous = not r.previous
		end
		local stack = table.clone(s.stack)
		stack[#stack] = upd
		s.stack = stack
		ensure(s, effects)
	elseif act == "filter-focus" then
		return startEdit(s, effects)
	elseif act == "filter-clear" then
		setFilter(s, "")
		s.editing = false
	elseif act == "exit" then
		table.insert(effects, { t = "exit" })
	elseif act == "gitops" then
		if value == "manifest" then
			manifestKey(s, effects)
		elseif value == "diff" then
			diffKey(s, effects)
		elseif value == "drift" then
			driftKey(s, effects)
		elseif value == "export" then
			exportKey(s, effects)
		else
			return false
		end
	elseif act == "field-focus" then
		return startField(s, value, effects)
	elseif act == "gitops-key" then
		local ch = if value == "enter" or value == "escape" then nil else value
		return gitopsRouteKey(s, { name = value, text = ch }, ch, effects)
	elseif string.sub(act, 1, 7) == "gitops-" then
		local r = top(s)
		local g = Gitops.clone(s.gitops)
		local handled, nav = Gitops.onAction(g, M.gitopsCtx(s), r, act, value, effects)
		s.gitops = g
		applyNav(s, nav, effects)
		return handled
	else
		return false
	end
	return true
end

-- Results --------------------------------------------------------------------

local function decodeJson(s: State, text: string): (boolean, any)
	return pcall(s.decode, text)
end

local function failLoad(s: State, key: string, load: Load, msg: Msg)
	local text, kind = M.failure(s, msg.result :: ProcessResult, msg.spawnError)
	local upd = table.clone(load)
	upd.status = "error"
	upd.error = text
	upd.errorKind = kind
	upd.fetchedAt = msg.at
	setLoad(s, key, upd)
end

local function contextsLoaded(s: State, names: { string }, effects: { Effect })
	if s.resolve.phase ~= "verify" then
		return
	end
	local want = s.target.context
	if want and table.find(names, want) then
		s.resolve = { phase = "done", gen = s.resolve.gen }
		ensure(s, effects)
		return
	end
	s.resolve = { phase = "failed", gen = s.resolve.gen }
	s.targetErrorKind = "context"
	s.targetError = string.format(
		'Context "%s" is not in the kubeconfig%s. Pick a context.',
		want or "?",
		if s.target.kubeconfig then " " .. s.target.kubeconfig else ""
	)
	if top(s).kind ~= "contexts" then
		local stack = table.clone(s.stack)
		table.insert(stack, { kind = "contexts" })
		s.stack = stack
	end
end

local function onResolve(s: State, msg: Msg, effects: { Effect })
	if s.resolve.phase ~= "current" or msg.gen ~= s.resolve.gen then
		return
	end
	local result = msg.result :: ProcessResult
	local name = if msg.spawnError == nil and result.status == 0 then trim(result.stdout) else ""
	if name == "" then
		local text, kind = M.failure(s, result, msg.spawnError)
		s.resolve = { phase = "failed", gen = s.resolve.gen }
		s.targetError = text
		s.targetErrorKind = kind
		if msg.spawnError == nil and not result.timed_out then
			pushRoute(s, { kind = "contexts" }, effects)
		end
		return
	end
	local t = table.clone(s.target)
	t.context = name
	t.contextSource = "inferred"
	t.inferredAt = msg.at
	t.confirmed = false
	s.target = t
	s.resolve = { phase = "done", gen = s.resolve.gen }
	ensure(s, effects)
end

local function onQuick(s: State, msg: Msg, effects: { Effect })
	local pending = s.quick
	if pending == nil or pending.gen ~= msg.gen then
		return
	end
	s.quick = nil
	local result = msg.result :: ProcessResult
	if msg.spawnError or result.status ~= 0 then
		local text = M.failure(s, result, msg.spawnError)
		table.insert(effects, toast("error", "Cannot find a pod", text))
		return
	end
	local ok, doc = decodeJson(s, result.stdout)
	local items = if ok and type(doc) == "table" and type(doc.items) == "table" then doc.items else {}
	local pod = M.readyPod(items)
	if pod == nil then
		table.insert(
			effects,
			toast("error", "No ready pod", "No Running+Ready pod matches " .. (pending.selector or ""))
		)
		return
	end
	openQuick(s, pending.action, pending.ref, { pod = pod }, effects)
end

local function onRelationResult(s: State, key: string, sub: string, load: Load, msg: Msg, effects: { Effect })
	local data = table.clone(load.data :: RelationsData)
	local result = msg.result :: ProcessResult
	local upd = table.clone(load)
	upd.fetchedAt = msg.at
	if sub == "root" then
		if msg.spawnError or result.status ~= 0 then
			failLoad(s, key, load, msg)
			return
		end
		local ok, obj = decodeJson(s, result.stdout)
		if not ok or type(obj) ~= "table" then
			upd.status = "error"
			upd.error = "kubectl printed invalid JSON"
			setLoad(s, key, upd)
			return
		end
		data.root = (Json.redactObject(obj, policy(s)))
		upd.data = data
		issueRelationQueries(s, key, upd, effects)
		return
	end
	local q = data.queries[sub]
	if q == nil or not data.inflight[sub] then
		return
	end
	local results = table.clone(data.results)
	if msg.spawnError or result.status ~= 0 then
		local text = M.failure(s, result, msg.spawnError)
		results[sub] = { items = {}, error = string.match(text, "^[^\n]*") or text }
	elseif trim(result.stdout) == "" then
		-- --ignore-not-found printed nothing: the referenced object is missing.
		results[sub] = { items = {} }
	elseif q.nameOnly or Kinds.normalize(q.kind).kind == "Secret" then
		results[sub] = Relations.itemsFromNames(q, result.stdout)
	else
		local ok, doc = decodeJson(s, result.stdout)
		if ok and type(doc) == "table" then
			results[sub] = { items = if type(doc.items) == "table" then doc.items else { doc } }
		else
			results[sub] = { items = {}, error = "kubectl printed invalid JSON" }
		end
	end
	local inflight = table.clone(data.inflight)
	inflight[sub] = nil
	data.results = results
	data.inflight = inflight
	upd.data = data
	if next(inflight) == nil then
		issueRelationQueries(s, key, upd, effects)
	else
		setLoad(s, key, upd)
	end
end

local function onResult(s: State, msg: Msg, effects: { Effect }): boolean
	local tag = msg.tag or ""
	if tag == M.RESOLVE_TAG then
		onResolve(s, msg, effects)
		return true
	elseif tag == M.QUICK_TAG then
		onQuick(s, msg, effects)
		return true
	elseif string.sub(tag, 1, 7) == "gitops|" then
		local g = Gitops.clone(s.gitops)
		Gitops.onResult(g, M.gitopsCtx(s), msg, effects)
		s.gitops = g
		return true
	end
	local key, sub = string.match(tag, "^(.-)\n(.*)$")
	key = key or tag
	local load = s.cache[key :: string]
	if load == nil or load.gen ~= msg.gen or load.status ~= "loading" then
		return false
	end
	if sub then
		onRelationResult(s, key :: string, sub, load, msg, effects)
		return true
	end
	local result = msg.result :: ProcessResult
	if msg.spawnError or result.status ~= 0 then
		failLoad(s, key :: string, load, msg)
		if string.sub(key :: string, 1, 9) == "contexts|" and s.resolve.phase == "verify" then
			s.resolve = { phase = "failed", gen = s.resolve.gen }
			local failed = s.cache[key :: string] :: Load
			s.targetError = failed.error
			s.targetErrorKind = failed.errorKind
		end
		return true
	end
	local kind = string.match(key :: string, "^(%a+)|") or ""
	local data: any = nil
	local ok = true
	if kind == "list" then
		ok, data = pcall(M.listData, result.stdout, s.decode, s.target.context, policy(s))
	elseif kind == "detail" then
		local okj, obj = decodeJson(s, result.stdout)
		ok = okj and type(obj) == "table"
		if ok then
			local shown, masked = Json.redactObject(obj, policy(s))
			data = { object = shown, masked = masked }
		end
	elseif kind == "describe" then
		local argv = load.argv
		local args = table.move(argv, 2, #argv, 1, table.create(#argv - 1))
		ok, data = pcall(Capture.build, { program = "kubectl", args = args }, splitLines(result.stdout), 0, {
			decode = s.decode,
			policy = policy(s),
		})
	elseif kind == "logs" then
		data = { lines = splitLines(result.stdout) }
	else
		data = namesData(result.stdout)
	end
	local upd = table.clone(load)
	upd.fetchedAt = msg.at
	if ok then
		upd.status = "ok"
		upd.data = data
	else
		upd.status = "error"
		upd.error = "Could not read kubectl output: " .. tostring(data)
	end
	setLoad(s, key :: string, upd)
	if kind == "detail" and ok then
		withGitops(s, function(g, ctx)
			Gitops.noticeObject(g, ctx, (data :: DetailData).object, effects)
			return nil
		end)
	end
	if kind == "contexts" and ok then
		contextsLoaded(s, (data :: NamesData).names, effects)
	end
	return true
end

-- Ticks ----------------------------------------------------------------------

function M.age(now: number?, at: number?): string?
	if now == nil or at == nil then
		return nil
	end
	local d = math.max(0, now - at)
	if d < 10 then
		return "just now"
	elseif d < 60 then
		return string.format("%ds ago", d - d % 10)
	elseif d < 3600 then
		return string.format("%dm ago", d // 60)
	end
	return string.format("%dh ago", d // 3600)
end

-- Update ---------------------------------------------------------------------

-- Returns the same state table when the message changed nothing, so the
-- host can tell Tern a key was not handled.
function M.update(state: State, msg: Msg): (State, { Effect })
	local s = copyState(state)
	local effects: { Effect } = {}
	local changed = false
	if msg.t == "key" and msg.key then
		changed = onKey(s, msg.key, effects)
	elseif msg.t == "action" and msg.act then
		changed = onAction(s, msg.act, msg.value or "", effects)
	elseif msg.t == "result" and msg.result then
		changed = onResult(s, msg, effects)
	elseif msg.t == "tick" and msg.now then
		local load = M.currentLoad(state)
		local at = if load then load.fetchedAt else nil
		s.now = msg.now
		changed = true
		if M.age(state.now, at) ~= M.age(msg.now, at) then
			table.insert(effects, { t = "render" })
		end
	elseif msg.t == "resize" and msg.rows then
		s.rows = msg.rows
		changed = msg.rows ~= state.rows
	elseif msg.t == "progress" and msg.progress then
		local g = Gitops.clone(s.gitops)
		changed = Gitops.onProgress(g, msg)
		s.gitops = g
	end
	if not changed then
		return state, {}
	end
	-- Keep the selection inside the visible window; a new filter starts the
	-- window over.
	local key = M.currentKey(s)
	local offset: number? = s.offset[key]
	if (s.filter[key] or "") ~= (state.filter[key] or "") then
		offset = nil
	end
	local items = M.items(s)
	if #items > 0 then
		offset =
			M.window(M.selectedIndex(s, items), #items, offset, M.viewport(s.rows, s.config.general.max_rendered_rows))
	end
	if offset ~= s.offset[key] then
		local map: { [string]: number? } = table.clone(s.offset)
		map[key] = offset
		s.offset = map :: any
	end
	return s, effects
end

return M
