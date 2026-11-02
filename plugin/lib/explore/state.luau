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
local EventsModel = require("../events/model")
local ExploreTypes = require("./types")
local Gitops = require("./gitops")
local Helm = require("./helm")
local HelmOwner = require("../helm/owner")
local HelmQuery = require("../helm/query")
local Json = require("../parse/json")
local Kinds = require("../kubectl/kinds")
local Link = require("../mutation/link")
local LogsParse = require("../logs/parse")
local LogsQuery = require("../logs/query")
local LogsStore = require("../logs/store")
local LogsTypes = require("../logs/types")
local Query = require("./query")
local Quick = require("../actions/quick")
local Redact = require("../model/redact")
local Relations = require("./relations")
local Resource = require("../model/resource")
local Shellenv = require("../env/shellenv")
local Textfield = require("../textfield")
local Timeline = require("../events/timeline")
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
-- order: every kept record, merged by kubelet time (each source keeps its
-- own order); memo: the last filtered view of it, so moving the selection
-- does not re-filter.
export type LogsData = {
	store: LogsStore.Store,
	order: { number },
	memo: { key: string, indices: { number } }?,
}
-- events: newest first; root: the scoped object (nil = the whole
-- namespace); scope: root and what it owns, once every query answered;
-- pending: sub-queries still running.
export type EventsData = {
	events: { EventsModel.Event },
	root: Ref?,
	objects: { any }?,
	scope: { Ref }?,
	note: string?,
	pending: { [string]: boolean },
}
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
	-- Resolved helm program (env_host.program("helm")); nil = not found.
	helm: string?,
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
	-- Caret and undo history of the field being edited (its text is the
	-- filter or the GitOps draft; a mismatch starts the field over).
	input: Textfield.Field?,
	dataDir: string?,
	nonce: () -> string,
	isList: ((t: { [any]: any }) -> boolean)?,
	null: any?,
	-- A link asked for the filter field focused (lens "Search…"); done once
	-- the target is resolved and the route is loading.
	searchPending: boolean,
	-- Helm releases, history, values and their loads (helm.luau).
	helm: Helm.H,
	helmProgram: string?,
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
-- Lines of a block that are not grid rows: header, target banner, crumbs,
-- filter, count, column heads, both overflow lines and the dock. Measured on
-- Tern 0.9.8 (`tern ctl dump`, lines of 16.2 px): 384 px of chrome, grid rows
-- 21 px, so a row is about 4/3 of a line and the chrome 24 lines.
M.CHROME_LINES = 24
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

-- Namespace scope of a list or events route under the current target.
function M.scope(s: State, route: Route): Query.Scope
	if route.namespace == "*" then
		return { namespace = nil, all = true }
	elseif route.namespace then
		return { namespace = route.namespace, all = false }
	end
	return { namespace = s.target.namespace, all = s.target.allNamespaces }
end

-- An events route reads its object's namespace, or its namespace scope.
function M.eventsScope(s: State, route: Route): Query.Scope
	local ref = route.ref
	if ref then
		return { namespace = ref.namespace, all = false }
	end
	return M.scope(s, route)
end

local RELATED_KINDS: { [string]: boolean } = {
	Deployment = true,
	StatefulSet = true,
	DaemonSet = true,
	ReplicaSet = true,
	Job = true,
	CronJob = true,
}

-- Whether an object-scoped events route includes what the object owns.
function M.related(route: Route): boolean
	local ref = route.ref
	if ref == nil then
		return false
	end
	if route.related ~= nil then
		return route.related
	end
	return RELATED_KINDS[ref.kind] == true
end

local function scopeId(sc: Query.Scope): string
	return if sc.all then "*" else (sc.namespace or "")
end

function M.logsTail(s: State, route: Route): number
	return route.tail or s.config.explore.logs_tail
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
	elseif Helm.isRoute(kind) then
		-- Never a cache key either: Helm routes keep their data in s.helm.
		return Helm.routeKey(route, targetId(s.target), M.scope(s, route))
	end
	if kind == "events" then
		local subject = if route.ref then Resource.key(route.ref) else "ns:" .. scopeId(M.eventsScope(s, route))
		return "events|" .. targetId(s.target) .. "|" .. subject .. "|" .. (if M.related(route) then "r" else "")
	end
	if kind == "logs" then
		local subject = if route.ref
			then Resource.key(route.ref)
			else "-l " .. (route.selector or "") .. "@" .. scopeId(M.scope(s, route))
		return table.concat({
			"logs",
			targetId(s.target),
			subject,
			route.container or "",
			if route.previous then "p" else "",
			route.since or "",
			tostring(M.logsTail(s, route)),
		}, "|")
	end
	local ref = route.ref :: Ref
	return kind .. "|" .. targetId(s.target) .. "|" .. Resource.key(ref)
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
	-- `logs --previous` of a container that never restarted reads like a
	-- missing object; it is not one.
	if string.find(lower, "previous terminated container", 1, true) then
		return string.format(
			"No previous instance: the container has not restarted. Press o for the current logs.\n%s",
			first
		),
			"previous"
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
		helm = s.helmProgram,
	}
end

-- What the Helm routes need to know about the block.
function M.helmCtx(s: State): Helm.Ctx
	return {
		target = s.target,
		helm = s.helmProgram,
		kubectl = s.program,
		config = s.config,
		decode = s.decode,
		isList = s.isList,
		resolved = M.resolved(s),
		now = s.now,
		daemonPath = s.daemonPath,
		dataDir = s.dataDir,
		nonce = s.nonce,
		chartDirs = Gitops.chartDirs(s.gitops),
	}
end

-- The kinds picker's synthetic first row (shown when helm was found).
M.HELM_KIND_ROW = "helm releases"

-- Record indices of a logs load that pass the route's filter and level
-- floor, in display order (merged by kubelet time).
function M.logIndices(route: Route, data: LogsData, text: string): { number }
	local memoKey = (route.floor or "") .. "\0" .. text
	local memo = data.memo
	if memo and memo.key == memoKey then
		return memo.indices
	end
	local indices = data.order
	if text ~= "" or route.floor ~= nil then
		local store = data.store
		local hits = LogsQuery.apply(
			store,
			{ text = text, minLevel = route.floor, merge = false },
			1,
			math.max(1, LogsStore.size(store))
		)
		local hit: { [number]: boolean } = {}
		for _, i in hits.indices do
			hit[i] = true
		end
		indices = {}
		for _, i in data.order do
			if hit[i] then
				table.insert(indices, i)
			end
		end
	end
	data.memo = { key = memoKey, indices = indices }
	return indices
end

-- Events of an events load that pass the route's filters, newest first.
function M.eventList(route: Route, data: EventsData, text: string): { EventsModel.Event }
	return Timeline.filter(data.events, { warnings = route.warnings == true, text = text, scope = data.scope })
end

-- Selection over what the current route shows, after the filter.
function M.items(s: State, route: Route?): { Item }
	local r = route or top(s)
	local key = M.routeKey(s, r)
	local load = s.cache[key]
	if Gitops.isRoute(r.kind) then
		return Gitops.items(s.gitops, M.gitopsCtx(s), r)
	end
	if Helm.isRoute(r.kind) then
		return Helm.items(s.helm, M.helmCtx(s), r, s.filter[key])
	end
	local out: { Item } = {}
	local f = string.lower(s.filter[key] or "")
	if r.kind == "namespaces" then
		local all = "* all namespaces"
		if f == "" or string.find(all, f, 1, true) then
			table.insert(out, { key = "*", value = "*" })
		end
	end
	if r.kind == "kinds" and s.helmProgram then
		if f == "" or string.find(M.HELM_KIND_ROW, f, 1, true) or f == "hr" then
			table.insert(out, { key = M.HELM_KIND_ROW, value = M.HELM_KIND_ROW })
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
	elseif r.kind == "logs" then
		for _, i in M.logIndices(r, load.data :: LogsData, s.filter[key] or "") do
			table.insert(out, { key = tostring(i) })
		end
	elseif r.kind == "events" then
		for _, e in M.eventList(r, load.data :: EventsData, s.filter[key] or "") do
			table.insert(out, { key = e.key, ref = e.object })
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
	-- Logs open on the newest line, like the tail they are.
	return if top(s).kind == "logs" then #items else 1
end

function M.selectedItem(s: State): Item?
	local items = M.items(s)
	local i = M.selectedIndex(s, items)
	return if i > 0 then items[i] else nil
end

-- The object the keys act on: the selected row, or the route's own object.
function M.focusRef(s: State): Ref?
	local r = top(s)
	if r.kind == "list" or r.kind == "relations" or r.kind == "events" then
		local item = M.selectedItem(s)
		if item and item.ref then
			return item.ref
		end
		return if r.kind == "list" then nil else r.ref
	end
	if Gitops.isRoute(r.kind) then
		return Gitops.focusRef(s.gitops, M.gitopsCtx(s), r, M.selectedItem(s))
	end
	if Helm.isRoute(r.kind) then
		return Helm.focusRef(s.helm, M.helmCtx(s), r, M.selectedItem(s))
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
	elseif kind == "events" then
		return Query.events(p, t, M.eventsScope(s, route))
	elseif kind == "logs" then
		if route.ref == nil and route.selector == nil then
			return nil
		end
		return Query.logs(p, t, {
			ref = route.ref,
			selector = route.selector,
			namespace = M.scope(s, route).namespace,
			container = route.container,
			previous = route.previous == true,
			since = route.since,
			tail = M.logsTail(s, route),
		})
	end
	local ref = route.ref
	if ref == nil then
		return nil
	end
	if kind == "detail" or kind == "relations" then
		return Query.get(p, t, ref)
	elseif kind == "describe" then
		return Query.describe(p, t, ref)
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

M.EVENTS_SUB = "events"
M.OWNED_SUB = "owned"

-- The events list, plus what the scoped workload owns when related events
-- are on; the load completes when both answered.
local function startEvents(s: State, route: Route, key: string, argv: { string }, gen: number, effects: { Effect })
	local pending: { [string]: boolean } = { [M.EVENTS_SUB] = true }
	local ref = route.ref
	local related = ref ~= nil and M.related(route)
	if related then
		pending[M.OWNED_SUB] = true
	end
	local root: Ref? = nil
	if ref then
		-- With its uid, a recreated object's old events are not its own.
		local obj = M.findObject(s, ref)
		local md = if type(obj) == "table" then obj.metadata else nil
		local uid = if type(md) == "table" then nonEmpty(md.uid) else nil
		local scoped = table.clone(ref)
		scoped.uid = uid
		root = scoped
	end
	local data: EventsData = { events = {}, root = root, objects = nil, scope = nil, note = nil, pending = pending }
	setLoad(s, key, { status = "loading", data = data, argv = argv, gen = gen })
	table.insert(effects, runEffect(s, key .. SEP .. M.EVENTS_SUB, argv, gen))
	if ref and related then
		table.insert(
			effects,
			runEffect(s, key .. SEP .. M.OWNED_SUB, Query.owned(s.program, s.target, ref.namespace), gen)
		)
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
	elseif route.kind == "events" then
		startEvents(s, route, key, argv, s.gen, effects)
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

-- Runs a Helm call on a fresh copy of s.helm.
local function withHelm<R>(s: State, fn: (h: Helm.H, ctx: Helm.Ctx) -> R): R
	local h = Helm.clone(s.helm)
	local r = fn(h, M.helmCtx(s))
	s.helm = h
	return r
end

local function enterHelm(s: State, route: Route, force: boolean, effects: { Effect })
	withHelm(s, function(h, ctx)
		Helm.enter(h, ctx, route, force, effects)
		return nil
	end)
end

local startEdit: (s: State, effects: { Effect }) -> boolean

local function replaceTop(s: State, route: Route)
	local stack = table.clone(s.stack)
	stack[#stack] = route
	s.stack = stack
end

local function ensure(s: State, effects: { Effect })
	local route = top(s)
	if Gitops.isRoute(route.kind) then
		enterGitops(s, route, false, effects)
		return
	end
	if Helm.isRoute(route.kind) then
		enterHelm(s, route, false, effects)
		return
	end
	local q = route.q
	if q and M.resolved(s) then
		local filter = table.clone(s.filter)
		filter[M.routeKey(s, route)] = q
		s.filter = filter
		local upd = table.clone(route)
		upd.q = nil
		replaceTop(s, upd)
	end
	startLoad(s, top(s), false, effects)
	if s.searchPending and M.resolved(s) then
		s.searchPending = false
		startEdit(s, effects)
	end
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
	events = true,
	contexts = true,
	namespaces = true,
	kinds = true,
	["helm-releases"] = true,
	["helm-release"] = true,
	["helm-history"] = true,
	["helm-values"] = true,
	["helm-manifest"] = true,
	["helm-notes"] = true,
	["helm-hooks"] = true,
	["helm-resources"] = true,
	["helm-diff"] = true,
}

function M.validRelease(v: any): string?
	return if type(v) == "string" and HelmQuery.validRelease(v) then v else nil
end

function M.validRevision(v: any): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	return if n and HelmQuery.validRevision(n) then n else nil
end

-- A Helm route from a link or saved state; nil when it names no valid
-- release (helm-releases needs none).
local function helmRoute(kind: string, release: any, namespace: any, revision: any, against: any, mode: any): Route?
	if kind == "helm-releases" then
		return { kind = "helm-releases" }
	end
	local name = M.validRelease(release)
	local ns = nonEmpty(namespace)
	if name == nil or ns == nil or ns == "*" then
		return nil
	end
	local route: Route =
		{ kind = kind :: RouteKind, release = name, namespace = ns, revision = M.validRevision(revision) }
	if kind == "helm-diff" then
		route.against = M.validRevision(against)
		if route.revision == nil or route.against == nil then
			return nil
		end
	elseif kind == "helm-values" then
		route.mode = Helm.validMode(mode)
	end
	return route
end

-- Link and saved-state values reach kubectl's argv: each must look like what
-- it claims to be (same rules as actions/quick.luau).
function M.validContainer(v: any): string?
	return if type(v) == "string" and #v >= 1 and #v <= 63 and string.find(v, "^[a-z0-9][a-z0-9%-]*$") then v else nil
end

function M.validSelector(v: any): string?
	return if type(v) == "string" and #v >= 1 and #v <= 1024 and string.find(v, "^[%w%-_%./=!, ()]+$") then v else nil
end

function M.validSince(v: any): string?
	return if type(v) == "string" and #v >= 1 and #v <= 16 and string.find(v, "^[%d%.hms]+$") then v else nil
end

-- -1 is kubectl's "everything"; longer numbers are not line counts.
function M.validTail(v: any): number?
	if type(v) == "number" then
		v = string.format("%d", v)
	end
	if type(v) ~= "string" or #v > 7 or not string.find(v, "^%-?%d+$") then
		return nil
	end
	local n = tonumber(v) :: number
	return if n >= -1 then n else nil
end

function M.validQuery(v: any): string?
	return if type(v) == "string" and #v >= 1 and #v <= 256 and not string.find(v, "%c") then v else nil
end

local function restoreRoute(v: any): Route?
	if type(v) ~= "table" or not ROUTE_KINDS[v.kind] then
		return nil
	end
	if Helm.isRoute(v.kind) then
		local route = helmRoute(v.kind, v.release, v.namespace, v.revision, v.against, v.mode)
		if route and v.kind == "helm-releases" then
			route.namespace = nonEmpty(v.namespace)
		end
		return route
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
	local needsRef = v.kind == "detail" or v.kind == "relations" or v.kind == "describe"
	if needsRef and ref == nil then
		return nil
	end
	local route: Route = {
		kind = v.kind,
		resource = nonEmpty(v.resource),
		namespace = nonEmpty(v.namespace),
		ref = ref,
		container = nonEmpty(v.container),
		previous = if v.previous == true then true else nil,
	}
	if v.kind == "logs" then
		route.container = M.validContainer(v.container)
		route.selector = if ref then nil else M.validSelector(v.selector)
		if ref == nil and route.selector == nil then
			return nil
		end
		route.since = M.validSince(v.since)
		route.tail = M.validTail(v.tail)
		route.floor = if v.floor == "warn" then "warn" elseif v.floor == "error" then "error" else nil
		route.wrap = if v.wrap == true then true else nil
	elseif v.kind == "events" then
		route.warnings = if v.warnings == true then true else nil
		route.related = if type(v.related) == "boolean" then v.related else nil
	end
	return route
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

-- The route a link names on top of the object's list and detail views.
-- Invalid parameters are dropped; the route still opens without them.
local function linkRoutes(params: { { key: string, value: string } }): { Route }
	local kind = param(params, "kind")
	local group = param(params, "group")
	local name = param(params, "name")
	local namespace = param(params, "namespace")
	if namespace == "*" then
		namespace = nil
	end
	local resource = if kind then M.resourceToken(kind, group) else "pods"
	local stack: { Route } = { { kind = "list", resource = resource } }
	local route = param(params, "route")
	if route == "helm-releases" or route == "helm-release" or route == "helm-history" then
		local helm: { Route } = { { kind = "helm-releases" } }
		local release =
			helmRoute("helm-release", param(params, "release"), namespace, param(params, "revision"), nil, nil)
		if release then
			table.insert(helm, release)
			if route == "helm-history" then
				table.insert(helm, { kind = "helm-history", release = release.release, namespace = release.namespace })
			end
		end
		return helm
	end
	local ref: Ref? = nil
	if kind and name then
		local info = Kinds.normalize(resource)
		ref = {
			kind = if info.known then info.kind else kind,
			group = group or info.group,
			name = name,
			namespace = namespace,
			source = "live",
		}
		table.insert(stack, { kind = "detail", ref = ref })
	end
	local q = M.validQuery(param(params, "q"))
	if route == "logs" then
		local selector = if ref then nil else M.validSelector(param(params, "selector"))
		if ref or selector then
			table.insert(stack, {
				kind = "logs",
				ref = ref,
				selector = selector,
				container = M.validContainer(param(params, "container")),
				previous = if param(params, "previous") == "1" then true else nil,
				since = M.validSince(param(params, "since")),
				tail = M.validTail(param(params, "tail")),
				q = q,
			})
		end
	elseif route == "events" then
		table.insert(stack, {
			kind = "events",
			ref = ref,
			warnings = if param(params, "types") == "Warning" then true else nil,
			q = q,
		})
	elseif ref and route == "manifest" then
		-- Lens chips "Manifest" / "Diff vs manifest".
		table.insert(stack, { kind = "manifest", ref = ref })
	elseif ref and route == "diff" then
		table.insert(stack, { kind = "diff", ref = ref, doc = 1 })
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
		namespace = if param(params, "namespace") == "*" then nil else param(params, "namespace"),
		allNamespaces = param(params, "namespace") == "*",
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
		input = nil,
		dataDir = env.dataDir,
		nonce = env.nonce or function(): string
			counter += 1
			return tostring(counter)
		end,
		isList = env.isList,
		null = env.null,
		searchPending = param(params, "search") == "1",
		helm = Helm.new(),
		helmProgram = env.helm,
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
			selector = r.selector,
			since = r.since,
			tail = r.tail,
			floor = r.floor,
			wrap = r.wrap,
			warnings = r.warnings,
			related = r.related,
			release = r.release,
			revision = r.revision,
			against = r.against,
			mode = r.mode,
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
	-- Back to the root view of the newly chosen cluster; nothing read from
	-- the previous one may show under the new target.
	s.helm = Helm.new()
	local root = s.stack[1]
	if root.kind == "helm-releases" then
		root = { kind = "helm-releases" }
	elseif root.kind ~= "list" then
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

-- v (ref nil): events of the namespace in view; V: events of `ref`.
local function openEvents(s: State, ref: Ref?, effects: { Effect })
	local r = top(s)
	local route: Route
	if ref then
		route = { kind = "events", ref = ref }
	elseif r.kind == "list" then
		local sc = M.scope(s, r)
		route = { kind = "events", namespace = if sc.all then "*" else sc.namespace }
	else
		route = { kind = "events", namespace = if r.ref then r.ref.namespace else r.namespace }
	end
	if r.kind == "events" and M.routeKey(s, r) == M.routeKey(s, route) then
		return
	end
	pushRoute(s, route, effects)
end

local function drill(s: State, effects: { Effect })
	local r = top(s)
	if Gitops.isRoute(r.kind) or Helm.isRoute(r.kind) then
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
		if item.key == M.HELM_KIND_ROW then
			s.stack = { { kind = "helm-releases" } }
			ensure(s, effects)
		else
			chooseKind(s, item.key, effects)
		end
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
	if Helm.isRoute(r.kind) then
		enterHelm(s, r, true, effects)
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
	local r = top(s)
	if Helm.isRoute(r.kind) then
		withHelm(s, function(h, ctx)
			Helm.copy(h, ctx, r, effects)
			return nil
		end)
		return
	end
	local argv = argvFor(s, r)
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

-- The link carries this host's placement and logs tail: the window opens
-- the split, but a remote host's config governs its quick actions.
local function openQuick(s: State, action: string, ref: Ref?, opts: { [string]: any }, effects: { Effect })
	local qa = s.config.quick_actions
	local withHost = Quick.withHost(action, opts :: any, { placement = qa.placement, logsTail = qa.logs_tail })
	local url, err = Quick.encode(action :: any, s.target :: any, ref, withHost)
	if url == nil then
		table.insert(effects, toast("error", "Cannot " .. action, err))
		return
	end
	table.insert(effects, { t = "open", url = url })
end

local function quick(s: State, action: string, effects: { Effect })
	if Quick.gate(action) == "editor" and not s.config.mutations.enabled then
		table.insert(effects, toast("error", "Mutations are disabled", "mutations.enabled is false in the config"))
		return
	end
	if not M.resolved(s) then
		table.insert(effects, toast("error", "No cluster target yet", "Pick a context first (c)"))
		return
	end
	local r = top(s)
	if action == "logs-follow" and r.kind == "logs" and r.ref == nil and r.selector then
		-- A selector-only logs route follows the same pods.
		openQuick(
			s,
			action,
			nil,
			{ selector = r.selector, namespace = M.scope(s, r).namespace, container = r.container },
			effects
		)
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

-- ctrl+d / ctrl+r / shift+s / U p P t T X C u D and the matching chips:
-- open the approve block for the focused object; it previews and confirms,
-- Explore never mutates.
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

M.FIELD_INPUTS = {
	dir = "main.gitops-dir",
	branch = "main.gitops-branch",
	message = "main.gitops-message",
} :: { [string]: string }

-- Drops the GitOps draft being edited, if any (escape, or another field).
local function dropDraft(s: State)
	local field = s.field
	if field == nil then
		return
	end
	s.field = nil
	withGitops(s, function(g)
		local fields = table.clone(g.fields)
		fields[field] = nil
		g.fields = fields
		return nil
	end)
end

local function startField(s: State, field: string, effects: { Effect }): boolean
	if s.editing and s.field == field then
		return false
	end
	if top(s).kind ~= FIELD_ROUTES[field] then
		return false
	end
	local g = s.gitops
	if (field == "dir" and g.export == nil) or (field ~= "dir" and (g.git == nil or g.git.status ~= "ready")) then
		return false
	end
	dropDraft(s)
	local value = Gitops.fieldValue(g, field)
	withGitops(s, function(g2)
		Gitops.setField(g2, field, value)
		return nil
	end)
	s.editing = true
	s.field = field
	s.input = Textfield.new(value)
	table.insert(effects, { t = "focus", id = M.FIELD_INPUTS[field] })
	return true
end

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

-- The text of the field being edited: the filter or the GitOps draft.
local function fieldText(s: State): string
	local field = s.field
	if field then
		return Gitops.fieldValue(s.gitops, field)
	end
	return s.filter[M.currentKey(s)] or ""
end

local function activeInput(s: State): Textfield.Field
	return Textfield.sync(s.input, fieldText(s))
end

-- Takes the field `f` an edit produced (nil: the edit was not the field's).
local function applyInput(s: State, f: Textfield.Field?): boolean
	if f == nil then
		return false
	end
	if f.text ~= fieldText(s) then
		local field = s.field
		if field then
			withGitops(s, function(g)
				Gitops.setField(g, field, f.text)
				return nil
			end)
		else
			setFilter(s, f.text)
		end
	end
	s.input = f
	return true
end

local function fieldKey(s: State, key: Key, effects: { Effect }): boolean
	local field = s.field :: string
	local name = key.name
	if name == "enter" or name == "return" then
		s.editing = false
		s.field = nil
		withGitops(s, function(g, ctx)
			Gitops.commitField(g, ctx, field, effects)
			return nil
		end)
		return true
	elseif name == "escape" then
		s.editing = false
		dropDraft(s)
		return true
	end
	return applyInput(s, Textfield.key(activeInput(s), key))
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

-- Helm -------------------------------------------------------------------------

-- H: the focused object's Helm release, else the release list.
local function helmKey(s: State, effects: { Effect })
	if s.helmProgram == nil then
		table.insert(effects, toast("error", "helm not found", Helm.notFound(M.helmCtx(s))))
		return
	end
	if not needTarget(s, effects) then
		return
	end
	local ref = M.focusRef(s)
	local obj = if ref then M.findObject(s, ref) else nil
	local owner = if obj then HelmOwner.fromObject(obj) else nil
	if owner then
		pushRoute(s, { kind = "helm-release", release = owner.release, namespace = owner.namespace }, effects)
	elseif top(s).kind ~= "helm-releases" then
		pushRoute(s, { kind = "helm-releases" }, effects)
	end
end

-- Route-specific keys of the Helm views; false lets the global keys run.
-- Runs before the GitOps and logs/events dispatch.
local function helmRouteKey(s: State, key: Key, ch: string?, effects: { Effect }): boolean
	local r = top(s)
	if not Helm.isRoute(r.kind) then
		return false
	end
	if r.kind == "helm-release" and key.ctrl and key.name == "g" then
		-- The drift report of the chart directory that matches the release.
		local row = withHelm(s, function(h, ctx)
			return Helm.releaseRow(h, ctx, r)
		end)
		local id = if row
			then withGitops(s, function(g, ctx)
				return Gitops.releaseSource(g, ctx, row)
			end)
			else nil
		if id then
			pushRoute(s, { kind = "drift", source = id }, effects)
		else
			driftKey(s, effects)
		end
		return true
	end
	local selected = M.selectedItem(s)
	local h = Helm.clone(s.helm)
	local handled, nav = Helm.onKey(h, M.helmCtx(s), r, selected, ch, key, effects)
	s.helm = h
	applyNav(s, nav, effects)
	return handled
end

-- Logs and events routes ------------------------------------------------------

local ERROR_RANK = LogsParse.rank("error")

-- Replaces the route on top; a changed query starts loading and keeps the
-- filter typed so far.
local function updateRoute(s: State, upd: Route, effects: { Effect })
	local before = M.currentKey(s)
	replaceTop(s, upd)
	local after = M.currentKey(s)
	if after == before then
		return
	end
	local text = s.filter[before]
	if text then
		local filter = table.clone(s.filter)
		filter[after] = text
		s.filter = filter
	end
	ensure(s, effects)
end

local function loaded(s: State, kind: RouteKind): any?
	local load = M.currentLoad(s)
	if top(s).kind == kind and load and load.status == "ok" then
		return load.data
	end
	return nil
end

-- The kubectl line without its `--prefix` and `--timestamps` parts.
function M.payload(raw: string): string
	local _, _, rest = LogsParse.splitPrefix(raw)
	local _, payload = LogsParse.splitTimestamp(rest)
	return payload
end

-- Containers the `a` key cycles through: the object's pod template, else
-- what an every-container read of the same source printed.
function M.logContainers(s: State, route: Route): { string }
	local ref = route.ref
	if ref then
		local names = M.containers(M.findObject(s, ref))
		if #names > 0 then
			return names
		end
	end
	local all = table.clone(route)
	all.container = nil
	local load = s.cache[M.routeKey(s, all)] or s.cache[M.routeKey(s, route)]
	local out: { string } = {}
	if load and load.status == "ok" and load.data then
		for _, src in (load.data :: LogsData).store.sources do
			local c = src.container
			if c and not table.find(out, c) then
				table.insert(out, c)
			end
		end
	end
	return out
end

-- ] / [: the next / previous error (logs) or Warning (events) from the
-- selection; before any selection ] starts at the top and [ at the bottom.
local function jump(s: State, dir: number, effects: { Effect })
	local r = top(s)
	local items = M.items(s)
	if #items == 0 then
		return
	end
	local hit: (item: Item) -> boolean
	if r.kind == "logs" then
		local store = (loaded(s, "logs") :: LogsData).store
		hit = function(item: Item): boolean
			local rec = LogsStore.get(store, tonumber(item.key) or 0)
			return rec ~= nil and LogsParse.rank(rec.level) >= ERROR_RANK
		end
	else
		local warning: { [string]: boolean } = {}
		for _, e in (loaded(s, "events") :: EventsData).events do
			warning[e.key] = e.type == "Warning"
		end
		hit = function(item: Item): boolean
			return warning[item.key] == true
		end
	end
	local i = if s.sel[M.currentKey(s)] ~= nil then M.selectedIndex(s, items) + dir else (if dir > 0 then 1 else #items)
	while i >= 1 and i <= #items do
		if hit(items[i]) then
			selectKey(s, items[i].key)
			return
		end
		i += dir
	end
	local what = if r.kind == "logs" then "errors" else "Warning events"
	table.insert(effects, toast("info", "No more " .. what .. (if dir > 0 then " below" else " above")))
end

local NEXT_FLOOR: { [string]: string } = { [""] = "warn", warn = "error", error = "" }

local function setFloor(s: State, floor: string)
	local upd = table.clone(top(s))
	upd.floor = if floor == "warn" or floor == "error" then floor else nil
	replaceTop(s, upd)
end

local function cycleContainer(s: State, effects: { Effect })
	local r = top(s)
	local list = M.logContainers(s, r)
	if #list == 0 then
		table.insert(effects, toast("info", "No containers known yet", "Load the logs first (r)"))
		return
	end
	local at = if r.container then table.find(list, r.container) else 0
	local upd = table.clone(r)
	upd.container = if at then list[at + 1] else nil
	upd.inspect = nil
	updateRoute(s, upd, effects)
end

local function toggle(s: State, field: "wrap" | "inspect" | "previous" | "warnings", effects: { Effect })
	local r = top(s)
	local upd = table.clone(r)
	local on = not (r :: any)[field];
	(upd :: any)[field] = if on then true else nil
	if field == "previous" then
		upd.inspect = nil
	end
	updateRoute(s, upd, effects)
end

local function copyRecord(s: State, what: string, index: number, effects: { Effect }): boolean
	local data = loaded(s, "logs") :: LogsData?
	local rec = if data then LogsStore.get(data.store, index) else nil
	if rec == nil then
		return false
	end
	local text: string? = nil
	if what == "line" then
		text = if rec.extra then rec.raw .. "\n" .. table.concat(rec.extra, "\n") else rec.raw
	elseif what == "msg" then
		text = rec.message
	elseif what == "json" and rec.format == "json" then
		text = M.payload(rec.raw)
	end
	if text == nil then
		return false
	end
	table.insert(effects, { t = "copy", text = text })
	table.insert(effects, toast("success", "Copied", string.sub(text, 1, 80)))
	return true
end

-- Keys of the logs and events views; false lets the global keys run.
local function dataRouteKey(s: State, key: Key, ch: string?, effects: { Effect }): boolean
	local r = top(s)
	local name = key.name
	if r.kind == "logs" then
		if ch == "]" then
			jump(s, 1, effects)
		elseif ch == "[" then
			jump(s, -1, effects)
		elseif ch == "x" then
			setFloor(s, NEXT_FLOOR[r.floor or ""])
		elseif ch == "w" then
			toggle(s, "wrap", effects)
		elseif ch == "o" then
			toggle(s, "previous", effects)
		elseif ch == "a" then
			cycleContainer(s, effects)
		elseif name == "enter" or name == "return" then
			if #M.items(s) == 0 then
				return false
			end
			toggle(s, "inspect", effects)
		elseif name == "escape" and r.inspect then
			toggle(s, "inspect", effects)
		else
			return false
		end
		return true
	elseif r.kind == "events" then
		if ch == "]" then
			jump(s, 1, effects)
		elseif ch == "[" then
			jump(s, -1, effects)
		elseif ch == "x" then
			toggle(s, "warnings", effects)
		else
			return false
		end
		return true
	end
	return false
end

-- Keys -----------------------------------------------------------------------

local FILTERABLE: { [string]: boolean } = {
	list = true,
	contexts = true,
	namespaces = true,
	kinds = true,
	relations = true,
	logs = true,
	events = true,
	["helm-releases"] = true,
	["helm-history"] = true,
	["helm-resources"] = true,
}
M.FILTERABLE = FILTERABLE

local function editKey(s: State, key: Key): boolean
	local name = key.name
	if name == "escape" or name == "enter" or name == "return" then
		s.editing = false
	elseif name == "down" then
		move(s, 1)
	elseif name == "up" then
		move(s, -1)
	else
		return applyInput(s, Textfield.key(activeInput(s), key))
	end
	return true
end

function startEdit(s: State, effects: { Effect }): boolean
	if not FILTERABLE[top(s).kind] then
		return false
	end
	dropDraft(s)
	s.editing = true
	s.input = Textfield.new(s.filter[M.currentKey(s)] or "")
	table.insert(effects, { t = "focus", id = M.FILTER_INPUT })
	return true
end

-- An `edit` or `undo` event of field `id`: Tern reports one only for the
-- focused field, so a field the state is not editing starts editing first.
local function inputEvent(
	s: State,
	id: string,
	effects: { Effect },
	apply: (Textfield.Field) -> Textfield.Field?
): boolean
	local editingIt = s.editing
		and (if id == M.FILTER_INPUT then s.field == nil else M.FIELD_INPUTS[s.field or ""] == id)
	if not editingIt then
		local started = false
		if id == M.FILTER_INPUT then
			started = startEdit(s, effects)
		else
			for field, input in M.FIELD_INPUTS do
				if input == id then
					started = startField(s, field, effects)
				end
			end
		end
		if not started then
			return false
		end
	end
	local before = activeInput(s)
	local f = apply(before)
	if f == nil or f == before then
		return not editingIt
	end
	return applyInput(s, f)
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	local ch = Textfield.printable(key)
	if s.editing then
		if s.field then
			return fieldKey(s, key, effects)
		end
		return editKey(s, key)
	end
	local name = key.name
	local wasG = s.pendingG
	s.pendingG = false
	if s.help and (name == "escape" or ch == "?") then
		s.help = false
		return true
	end
	if not s.help and helmRouteKey(s, key, ch, effects) then
		return true
	end
	if not s.help and gitopsRouteKey(s, key, ch, effects) then
		return true
	end
	if not s.help and dataRouteKey(s, key, ch, effects) then
		return true
	end
	if ch == "H" or (name == "h" and key.shift) then
		helmKey(s, effects)
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
	elseif ch == "U" or (name == "u" and key.shift) then
		mutate(s, "undo", effects)
	elseif ch == "P" or (name == "p" and key.shift) then
		mutate(s, "resume", effects)
	elseif ch == "T" or (name == "t" and key.shift) then
		mutate(s, "annotate", effects)
	elseif ch == "X" or (name == "x" and key.shift) then
		mutate(s, "patch", effects)
	elseif ch == "C" or (name == "c" and key.shift) then
		mutate(s, "cordon", effects)
	elseif ch == "D" or (name == "d" and key.shift) then
		mutate(s, "drain", effects)
	elseif ch == "p" and not key.shift then
		mutate(s, "pause", effects)
	elseif ch == "t" and not key.shift then
		mutate(s, "label", effects)
	elseif ch == "u" and not key.shift then
		mutate(s, "uncordon", effects)
	elseif ch == "e" and not key.shift then
		quick(s, "edit", effects)
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
	elseif ch == "V" or (name == "v" and key.shift) then
		local ref = M.focusRef(s)
		if ref == nil then
			table.insert(effects, toast("error", "Select an object first"))
		else
			openEvents(s, ref, effects)
		end
	elseif ch == "v" then
		openEvents(s, nil, effects)
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
		if Helm.isRoute(top(s).kind) then
			helmRouteKey(s, { name = "enter" }, nil, effects)
			return true
		end
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
		elseif value == "events" then
			local ref = M.focusRef(s)
			if ref == nil then
				return false
			end
			openEvents(s, ref, effects)
		elseif value == "events-ns" then
			openEvents(s, nil, effects)
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
			upd.container = M.validContainer(value)
		else
			upd.previous = if r.previous then nil else true
		end
		upd.inspect = nil
		updateRoute(s, upd, effects)
	elseif act == "logs-floor" or act == "logs-wrap" or act == "logs-jump" or act == "logs-inspect" then
		if top(s).kind ~= "logs" then
			return false
		end
		if act == "logs-floor" then
			setFloor(s, value)
		elseif act == "logs-wrap" then
			toggle(s, "wrap", effects)
		elseif act == "logs-jump" then
			jump(s, if value == "prev" then -1 else 1, effects)
		else
			if value ~= "" then
				selectKey(s, value)
			end
			local upd = table.clone(top(s))
			upd.inspect = if value == "" then nil else true
			replaceTop(s, upd)
		end
	elseif act == "lcopy" then
		local what, index = string.match(value, "^(%a+):(%d+)$")
		return what ~= nil and copyRecord(s, what, tonumber(index) or 0, effects)
	elseif act == "events-warnings" or act == "events-related" or act == "events-scope" or act == "events-reason" then
		local r = top(s)
		if r.kind ~= "events" then
			return false
		end
		if act == "events-warnings" then
			toggle(s, "warnings", effects)
		elseif act == "events-related" then
			local upd = table.clone(r)
			upd.related = not M.related(r)
			updateRoute(s, upd, effects)
		elseif act == "events-scope" then
			local ref = r.ref
			if ref == nil then
				return false
			end
			updateRoute(s, { kind = "events", namespace = ref.namespace, warnings = r.warnings }, effects)
		else
			setFilter(s, if s.filter[M.currentKey(s)] == value then "" else value)
		end
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
	elseif string.sub(act, 1, 5) == "helm-" then
		local h = Helm.clone(s.helm)
		local handled, nav = Helm.onAction(h, M.helmCtx(s), top(s), act, value, effects)
		s.helm = h
		applyNav(s, nav, effects)
		return handled
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
		withHelm(s, function(h, ctx)
			Helm.noticeObject(h, ctx, data.root, effects)
			return nil
		end)
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

-- Both answers of an events load: the list, and what the scoped workload
-- owns. A failed ownership read still shows the object's own events.
local function onEventsResult(s: State, key: string, sub: string, load: Load, msg: Msg)
	local data = table.clone(load.data :: EventsData)
	if not data.pending[sub] then
		return
	end
	local result = msg.result :: ProcessResult
	local failed = msg.spawnError ~= nil or result.status ~= 0
	if sub == M.EVENTS_SUB and failed then
		failLoad(s, key, load, msg)
		return
	end
	local upd = table.clone(load)
	upd.fetchedAt = msg.at
	local ok = false
	local doc: any = nil
	if not failed then
		ok, doc = decodeJson(s, result.stdout)
		ok = ok and type(doc) == "table"
	end
	if sub == M.EVENTS_SUB then
		if not ok then
			upd.status = "error"
			upd.error = "kubectl printed invalid JSON"
			setLoad(s, key, upd)
			return
		end
		data.events = Timeline.sort(EventsModel.fromList(doc))
	elseif ok and type(doc.items) == "table" then
		data.objects = doc.items
	else
		local text = if failed then M.failure(s, result, msg.spawnError) else "kubectl printed invalid JSON"
		data.note = "Only the object's own events: its pods and jobs could not be read ("
			.. (string.match(text, "^[^\n]*") or text)
			.. ")"
	end
	local pending = table.clone(data.pending)
	pending[sub] = nil
	data.pending = pending
	if next(pending) == nil then
		local root = data.root
		if root then
			data.scope = if data.objects then Timeline.owned(root, data.objects) else { root }
		end
		upd.status = "ok"
	end
	upd.data = data
	setLoad(s, key, upd)
end

-- A logs run as records; kubectl's stderr notes (Found N pods, Defaulted
-- container, warnings) become notices.
function M.logsData(stdout: string, stderr: string, decode: Decode, limits: LogsTypes.Limits): LogsData
	local store = LogsStore.new({ prefix = true, timestamps = true, follow = false, decode = decode }, limits)
	for _, line in splitLines(stdout) do
		LogsStore.push(store, line)
	end
	LogsStore.finish(store, 0)
	for _, line in splitLines(stderr) do
		local n = LogsParse.diagnostic(line, "end")
		if n then
			table.insert(store.notices, n)
		end
	end
	local order = LogsQuery.apply(store, { merge = true }, 1, math.max(1, LogsStore.size(store))).indices
	return { store = store, order = order, memo = nil }
end

local function onResult(s: State, msg: Msg, effects: { Effect }): boolean
	local tag = msg.tag or ""
	if tag == M.RESOLVE_TAG then
		onResolve(s, msg, effects)
		return true
	elseif tag == M.QUICK_TAG then
		onQuick(s, msg, effects)
		return true
	elseif string.sub(tag, 1, 5) == "helm|" then
		local route = top(s)
		local h = Helm.clone(s.helm)
		local ctx = M.helmCtx(s)
		Helm.onResult(h, ctx, msg, if Helm.isRoute(route.kind) then route else nil, effects)
		-- Chained reads (the latest status's extras, pristine defaults inputs,
		-- live presence) start once what they need arrived.
		if Helm.isRoute(route.kind) then
			Helm.enter(h, ctx, route, false, effects)
		end
		s.helm = h
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
	if sub and string.sub(key :: string, 1, 7) == "events|" then
		onEventsResult(s, key :: string, sub, load, msg)
		return true
	elseif sub then
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
		local general = s.config.general
		ok, data = pcall(M.logsData, result.stdout, result.stderr or "", s.decode, {
			maxLines = math.max(general.max_rows, s.config.explore.logs_tail),
			maxBytes = general.max_capture_bytes,
		})
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
		withHelm(s, function(h, ctx)
			Helm.noticeObject(h, ctx, (data :: DetailData).object, effects)
			return nil
		end)
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
	elseif msg.t == "edit" and msg.id and msg.edit then
		local ev = msg.edit
		changed = inputEvent(s, msg.id, effects, function(f)
			return Textfield.edit(f, ev)
		end)
	elseif msg.t == "undo" and msg.id then
		changed = inputEvent(s, msg.id, effects, Textfield.undo)
	end
	if not changed then
		return state, {}
	end
	-- A field left focused would keep Tern's native editing keys (⇧-arrows,
	-- Home/End, ⌘A) away from the list.
	if state.editing and not s.editing then
		table.insert(effects, { t = "blur" })
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
