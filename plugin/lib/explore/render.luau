--!strict
-- The Explore block's view: a live header that cannot be mistaken for a lens
-- snapshot ("Live" badge, fetch age, pinned target with its provenance),
-- breadcrumbs, the filter input, one body per route, a status dock and the
-- help layer. Pure: plain `{k,p,c}` tables, no `tern` global.

local Cells = require("../render/cells")
local Command = require("../kubectl/command")
local DescribeView = require("../render/describe_view")
local EventsModel = require("../events/model")
local Gitops = require("./gitops")
local GitopsView = require("../gitops/view")
local Grid = require("../render/grid")
local Helm = require("./helm")
local HelmView = require("../helm/view")
local ObjTree = require("../render/objtree")
local Link = require("../mutation/link")
local LogsStore = require("../logs/store")
local LogsTypes = require("../logs/types")
local Query = require("./query")
local Quick = require("../actions/quick")
local Redact = require("../model/redact")
local State = require("./state")
local Textfield = require("../textfield")
local Types = require("../model/types")
local Viewstate = require("../lens/viewstate")
local Timeline = require("../events/timeline")
local ui = require("../ui")

type Node = ui.Node
type State = State.State
type Route = State.Route
type Load = State.Load
type Ref = Types.ResourceRef

export type View = { main: Node, dock: Node?, layer: Node? }

local M = {}

-- Relation provenance as a compact badge label, with the full meaning as
-- the badge's tooltip; selector matches are heuristic and say so.
local PROVENANCE: { [string]: { label: string, title: string, tone: string } } = {
	ownerReference = { label = "owner", title = "ownerReference: metadata.ownerReferences link", tone = "neutral" },
	["selector (heuristic)"] = {
		label = "selector",
		title = "selector (heuristic): labels match the Service selector",
		tone = "warning",
	},
	["endpoint targetRef"] = {
		label = "endpoint",
		title = "endpoint targetRef: an EndpointSlice endpoint points at this Pod",
		tone = "success",
	},
	endpointslice = {
		label = "slice",
		title = "endpointslice: labelled kubernetes.io/service-name",
		tone = "neutral",
	},
	["spec reference"] = { label = "spec", title = "spec reference: named in the object's spec", tone = "neutral" },
	["node binding"] = { label = "node", title = "node binding: the Pod's spec.nodeName", tone = "neutral" },
	root = { label = "root", title = "the object this view started from", tone = "accent" },
}
local BY_LABEL: { [string]: { label: string, title: string, tone: string } } = {}
for _, p in PROVENANCE do
	BY_LABEL[p.label] = p
end

function M.provenanceLabel(provenance: string): string
	local p = PROVENANCE[provenance]
	return if p then p.label else provenance
end

local function provenanceCell(col: string, columnType: Types.ColumnType, value: string, finished: boolean): Node
	if col ~= "VIA" or value == "" then
		return Cells.cell(col, columnType, value, finished)
	end
	local p = BY_LABEL[value]
	return ui.badge(value, if p then p.tone else "neutral", { title = if p then p.title else value })
end

M.SENSITIVE = "Secret values are masked; set security.show_secret_values to show them"

local SOURCE_TEXT: { [string]: string } = {
	flag = "command flag",
	chosen = "chosen",
	inferred = "inferred",
	unresolved = "unresolved",
}

local ROUTE_TITLE: { [string]: string } = {
	detail = "Object",
	relations = "Relations",
	describe = "Describe",
	logs = "Logs",
	events = "Events",
	contexts = "Contexts",
	namespaces = "Namespaces",
	kinds = "Kinds",
}

local function chip(text: string, action: string, props: { [string]: any }?): Node
	local p: { [string]: any } = { actions = { click = action }, role = "tern-kube.chip" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return ui.badge(text, p.tone or "neutral", p)
end

local function typed(argv: { string }): string
	local copy = table.clone(argv)
	copy[1] = "kubectl"
	return Command.format(copy)
end

local function clock(at: number?): string
	if at == nil then
		return "open time"
	end
	return os.date("!%H:%M:%S UTC", at) :: string
end

local function scopeText(s: State, route: Route): string
	if route.kind == "list" or (route.kind == "events" and route.ref == nil) then
		local sc = if route.kind == "list" then State.scope(s, route) else State.eventsScope(s, route)
		if sc.all then
			return "all namespaces"
		end
		return if sc.namespace then "ns " .. sc.namespace else "ns (context default)"
	end
	local t = s.target
	if t.allNamespaces then
		return "all namespaces"
	end
	return if t.namespace then "ns " .. t.namespace else "ns (context default)"
end

-- Header ---------------------------------------------------------------------

local function targetNodes(s: State): { Node }
	local t = s.target
	local out: { Node } = {}
	if s.envPending then
		table.insert(out, ui.text({ ui.span("reading your shell's PATH …", "muted") }, { key = "env" }))
		return out
	end
	if t.context == nil then
		-- kubectl could not run: the error card says why; a context chooser
		-- would only fail the same way.
		if s.targetErrorKind ~= "spawn" then
			table.insert(
				out,
				chip("no context", "nav=contexts", { tone = "error", title = "Pick the cluster context", key = "ctx" })
			)
		end
		return out
	end
	local provenance = SOURCE_TEXT[t.contextSource] or t.contextSource
	if t.contextSource == "inferred" then
		provenance = "inferred: current-context at " .. clock(t.inferredAt)
	end
	table.insert(
		out,
		chip("context " .. t.context, "nav=contexts", {
			tone = if t.contextSource == "inferred" then "warning" else "accent",
			title = "Pinned with --context on every query; click to choose another",
			key = "ctx",
		})
	)
	table.insert(out, ui.text({ ui.span("(" .. provenance .. ")", "muted") }, { key = "prov" }))
	if t.contextSource == "inferred" then
		table.insert(
			out,
			ui.badge("inferred target: check before acting", "warning", {
				key = "inferred",
				role = "tern-kube.inferred",
				title = "Taken from the kubeconfig's current-context when Explore opened; "
					.. "a later `kubectl config use-context` does not change it",
			})
		)
	end
	if t.confirmed then
		table.insert(out, ui.badge("confirmed", "success", { key = "confirmed" }))
	elseif State.resolved(s) then
		table.insert(
			out,
			chip("Confirm target", "confirm", {
				tone = "warning",
				key = "confirm",
				title = "Mutating actions stay disabled until the target is confirmed",
			})
		)
	end
	table.insert(
		out,
		chip(scopeText(s, s.stack[#s.stack]), "nav=namespaces", { key = "ns", title = "Namespace scope" })
	)
	if t.kubeconfig then
		table.insert(out, ui.text({ ui.span("kubeconfig " .. t.kubeconfig, "muted mono") }, { key = "kc" }))
	end
	return out
end

local function crumbLabel(s: State, route: Route): string
	if route.kind == "list" then
		return route.resource or "pods"
	end
	if Gitops.isRoute(route.kind) then
		return GitopsView.crumb(s.gitops, route)
	end
	if Helm.isRoute(route.kind) then
		return HelmView.crumb(route)
	end
	local title = ROUTE_TITLE[route.kind] or route.kind
	local ref = route.ref
	if ref then
		return title .. " " .. string.lower(ref.kind) .. "/" .. ref.name
	elseif route.kind == "logs" and route.selector then
		return title .. " -l " .. route.selector
	elseif route.kind == "events" then
		return title .. " " .. scopeText(s, route)
	end
	return title
end

local function header(s: State): Node
	local load = State.currentLoad(s)
	local live: { Node } = {
		ui.badge("Live", "accent", {
			key = "live",
			role = "tern-kube.live",
			title = "Fetched from the cluster on request; never refreshed automatically",
		}),
	}
	if load and load.status == "loading" then
		table.insert(live, ui.text({ ui.span("fetching via " .. (s.target.context or "kubeconfig"), "muted") }))
	elseif load and load.fetchedAt then
		local age = State.age(s.now, load.fetchedAt) or "just now"
		table.insert(
			live,
			ui.text(
				{ ui.span("fetched " .. age .. " via " .. (s.target.context or "kubeconfig"), "muted") },
				{ key = "age", role = "tern-kube.fetched" }
			)
		)
	end
	table.insert(live, chip("Refresh", "refresh", { key = "refresh", title = "Run the query again (r)" }))
	table.insert(live, chip("?", "help", { key = "help", title = "Keys and actions (?)" }))
	for _, n in targetNodes(s) do
		table.insert(live, n)
	end
	local crumbs: { Node } = {}
	for i, route in s.stack do
		if i > 1 then
			table.insert(crumbs, ui.text({ ui.span("›", "muted") }))
		end
		local label = crumbLabel(s, route)
		if i == #s.stack then
			table.insert(crumbs, ui.text({ ui.span(label, "strong") }, { key = "c" .. i }))
		else
			table.insert(crumbs, chip(label, "crumb=" .. i, { key = "c" .. i }))
		end
	end
	return ui.col({
		ui.row(live, { key = "bar", wrap = true, role = "tern-kube.bar" }),
		ui.row(crumbs, { key = "crumbs", wrap = true, role = "tern-kube.breadcrumb" }),
	}, { key = "header", role = "tern-kube.explore-header" })
end

-- Bodies ---------------------------------------------------------------------

local function errorNode(text: string): Node
	return ui.text({ ui.span(text, "error") }, { key = "error", role = "tern-kube.error" })
end

-- The target error, shown once; kubectl that could not run gets the ways out.
local function targetErrorNode(s: State): Node
	local text = errorNode(s.targetError or "")
	if s.targetErrorKind ~= "spawn" then
		return text
	end
	return ui.col({
		text,
		ui.row({
			chip("Open Settings", "settings", {
				tone = "accent",
				key = "settings",
				title = "Tern Kube: Settings (set kubectl to its full path)",
			}),
			chip("Retry", "refresh", { key = "retry", title = "Re-read the config and run kubectl again (r)" }),
		}, { key = "fix", wrap = true, role = "tern-kube.chips" }),
	}, { key = "target-error", role = "tern-kube.explore-error" })
end

local function loadingNode(load: Load): Node
	return ui.text({ ui.span("Running " .. typed(load.argv) .. " …", "muted") }, { key = "loading" })
end

-- Status of a load that has no data to show yet; nil when it has data.
local function pendingNode(s: State, load: Load?): Node?
	if load == nil then
		if s.envPending then
			return ui.muted("Reading PATH and KUBECONFIG from your login shell …")
		end
		if s.targetError then
			return ui.muted("Nothing is queried until the target is resolved.")
		end
		return ui.muted(if State.resolved(s) then "Not loaded. Press r." else "Resolving the cluster context …")
	end
	if load.status == "loading" then
		return loadingNode(load)
	elseif load.status == "error" then
		return errorNode(load.error or "kubectl failed")
	end
	return nil
end

local function markSelected(grid: Node, key: string?)
	if key == nil then
		return
	end
	local inner = grid.c and grid.c[1]
	local children = inner and inner.c
	if children == nil then
		return
	end
	for _, child in children do
		local p = child.p
		if p and p.key == key then
			p.class = "tk-r tk-open tk-sel"
			return
		end
	end
end

local function noSort(_col: string): string
	return "noop"
end

type GridRow = Grid.GridRow

export type WindowSpec = {
	key: string,
	headers: { string },
	types: { Types.ColumnType },
	-- Rows in all; only the visible window is built (rowAt).
	total: number,
	rowAt: (i: number) -> GridRow,
	selected: number,
	cell: ((string, Types.ColumnType, string, boolean) -> Node)?,
	-- Inline body under the selected row (logs record inspector).
	inspector: ((rowKey: string) -> Node?)?,
	-- A full-width label before row i (events time groups); `first` is the
	-- first visible row.
	separator: ((i: number, first: boolean) -> string?)?,
}

-- The visible window of a long list (State.window: sized from the block's
-- height, selection kept SCROLLOFF rows from the edges), with clickable
-- "N above" / "N below" rows that page.
local function windowGrid(s: State, spec: WindowSpec): { Node }
	local total = spec.total
	local size = State.viewport(s.rows, s.config.general.max_rendered_rows)
	local first, last = State.window(spec.selected, total, s.offset[State.currentKey(s)], size)
	local shown: { GridRow } = table.create(math.max(0, last - first + 1))
	local labels: { [string]: string } = {}
	local selKey: string? = nil
	for i = first, last do
		local r = spec.rowAt(i)
		if i == spec.selected then
			r.open = true
			selKey = r.key
		end
		table.insert(shown, r)
		local sep = spec.separator
		local label = if sep then sep(i, i == first) else nil
		if label then
			labels[r.key] = label
		end
	end
	local grid = Grid.grid({
		key = spec.key,
		headers = spec.headers,
		types = spec.types,
		rows = shown,
		sortCol = nil,
		desc = false,
		sortAction = noSort,
		cell = spec.cell,
		inspector = spec.inspector,
	})
	markSelected(grid, selKey)
	if next(labels) then
		local inner = (grid.c :: { Node })[1]
		local children: { Node } = {}
		for _, child in inner.c :: { Node } do
			local key = if child.p then child.p.key else nil
			local label = if type(key) == "string" then labels[key] else nil
			if label then
				table.insert(
					children,
					ui.el(
						"div",
						{ key = "sep-" .. key, class = "tk-sep" },
						{ ui.text({ ui.span(label, "muted strong") }) }
					)
				)
			end
			table.insert(children, child)
		end
		inner.c = children
	end
	local out: { Node } = {}
	if first > 1 then
		table.insert(
			out,
			ui.muted(string.format("↑ %d above (k, pageup, gg)", first - 1), {
				key = "above",
				role = "tern-kube.overflow",
				actions = { click = "page=up" },
			})
		)
	end
	table.insert(out, grid)
	if last < total then
		table.insert(
			out,
			ui.muted(string.format("↓ %d below (j, pagedown, G; / filters)", total - last), {
				key = "overflow",
				role = "tern-kube.overflow",
				actions = { click = "page=down" },
			})
		)
	end
	return out
end

local function pagedGrid(
	key: string,
	headers: { string },
	types: { Types.ColumnType },
	rows: { GridRow },
	selected: number,
	s: State,
	cell: ((string, Types.ColumnType, string, boolean) -> Node)?
): { Node }
	return windowGrid(s, {
		key = key,
		headers = headers,
		types = types,
		total = #rows,
		rowAt = function(i: number): GridRow
			return rows[i]
		end,
		selected = selected,
		cell = cell,
		inspector = nil,
		separator = nil,
	})
end

-- What the GitOps views need: the shared paged grid and chip builders.
local function gitopsView(s: State, route: Route, object: any?): GitopsView.Ctx
	local selected = State.selectedItem(s)
	return {
		g = s.gitops,
		gctx = State.gitopsCtx(s),
		route = route,
		selectedKey = if selected then selected.key else nil,
		grid = function(key, headers, types, rows, sel, cell)
			return pagedGrid(key, headers, types, rows :: any, sel, s, cell)
		end,
		chip = chip,
		object = object,
	}
end

local function isListFallback(t: any): boolean
	return type(t) == "table" and (#t > 0 or next(t) == nil)
end

-- What the Helm views need: the sub-core's data, the shared paged grid and
-- chip builders, and the masking policy.
local function helmView(s: State, route: Route): HelmView.Ctx
	local selected = State.selectedItem(s)
	return {
		h = s.helm,
		hctx = State.helmCtx(s),
		route = route,
		config = s.config,
		now = s.now,
		selectedKey = if selected then selected.key else nil,
		filter = string.lower(s.filter[State.currentKey(s)] or ""),
		grid = function(key, headers, types, rows, sel, cell)
			return pagedGrid(key, headers, types, rows :: any, sel, s, cell)
		end,
		chip = chip,
		policy = Redact.fromConfig(s.config),
		isList = s.isList or isListFallback,
	}
end

local function selectedIndexIn(s: State, keys: { string }): number
	local want = s.sel[State.currentKey(s)]
	if want then
		for i, k in keys do
			if k == want then
				return i
			end
		end
	end
	return if #keys > 0 then 1 else 0
end

local function listBody(s: State, route: Route, load: Load?): { Node }
	local pending = pendingNode(s, load)
	if pending or load == nil then
		return { pending :: Node }
	end
	local data = load.data :: State.ListData
	local f = string.lower(s.filter[State.currentKey(s)] or "")
	local rows: { GridRow } = {}
	local keys: { string } = {}
	for _, row in data.rows do
		if f == "" or string.find(row.hay, f, 1, true) then
			local n = #rows + 1
			rows[n] = { key = row.key, cells = row.cells, action = "open=" .. row.key }
			keys[n] = row.key
		end
	end
	local resource = route.resource or "pods"
	if #data.rows == 0 then
		return { ui.muted(string.format("No %s in %s.", resource, scopeText(s, route)), { key = "empty" }) }
	end
	local summary = string.format("%d %s", #data.rows, resource)
	if f ~= "" then
		summary ..= string.format(" · %d match /%s", #rows, f)
	end
	local out: { Node } = { ui.text({ ui.span(summary, "muted") }, { key = "count" }) }
	if #rows == 0 then
		table.insert(out, ui.muted("Nothing matches the filter. Esc clears it.", { key = "empty" }))
		return out
	end
	for _, n in pagedGrid("grid", data.headers, data.types, rows, selectedIndexIn(s, keys), s) do
		table.insert(out, n)
	end
	return out
end

local function quickInfo(s: State, ref: Ref): ({ [string]: any }, any)
	local obj = State.findObject(s, ref)
	local ports = State.ports(obj)
	local selector = if type(obj) == "table" and type(obj.spec) == "table"
		then Query.selectorString(obj.spec.selector)
		else nil
	local info: { [string]: any } = { source = "explore", ports = ports, selector = selector }
	if ref.kind == "Pod" then
		info.pod = ref.name
	end
	return info, obj
end

local QUICK_KEYS: { [string]: string } = { shell = "s", ["logs-follow"] = "l", ["port-forward"] = "F", edit = "e" }

-- Pause or Resume, Cordon or Uncordon: what the loaded object says; unknown
-- without one (both chips show).
local function objState(obj: any): Link.ObjState?
	if type(obj) ~= "table" or type(obj.spec) ~= "table" then
		return nil
	end
	return { paused = obj.spec.paused == true, unschedulable = obj.spec.unschedulable == true }
end

local function actionChips(s: State, ref: Ref): Node
	local chips: { Node } = {
		chip("Describe (d)", "nav=describe", { key = "a-describe" }),
		chip("Object (y)", "nav=detail", { key = "a-detail" }),
		chip("Relations (R)", "nav=relations", { key = "a-relations" }),
	}
	local workload = ref.kind == "Pod"
		or ref.kind == "Deployment"
		or ref.kind == "StatefulSet"
		or ref.kind == "DaemonSet"
		or ref.kind == "ReplicaSet"
		or ref.kind == "Job"
	if workload then
		table.insert(chips, chip("Logs (L)", "nav=logs", { key = "a-logs" }))
	end
	table.insert(
		chips,
		chip("Events (V)", "nav=events", { key = "a-events", title = "Its events timeline (with what it owns)" })
	)
	local info, obj = quickInfo(s, ref)
	-- Workload shells pick a ready pod at run time; offer them like pod shells.
	if ref.kind ~= "Pod" and workload then
		info.pod = info.pod or "?"
	end
	local mutations = s.config.mutations.enabled
	info.allowMutations = mutations
	for _, action in Quick.available(ref.kind, ref, info :: any) do
		if Quick.gate(action.id) == "editor" then
			table.insert(
				chips,
				chip(action.label .. " (" .. QUICK_KEYS[action.id] .. ")", "quick=" .. action.id, {
					key = "q-" .. action.id,
					tone = "warning",
					title = "Opens kubectl edit in a new split; after you save, the approve block previews the change",
				})
			)
		elseif not action.mutates and QUICK_KEYS[action.id] then
			table.insert(
				chips,
				chip(action.label .. " (" .. QUICK_KEYS[action.id] .. ")", "quick=" .. action.id, {
					key = "q-" .. action.id,
					tone = "accent",
					title = "Opens a new split running the kubectl command",
				})
			)
		elseif action.mutates then
			table.insert(
				chips,
				chip(action.label, "quick=" .. action.id, {
					key = "q-" .. action.id,
					tone = "warning",
					title = "Previews in the approve block; confirm to open a new split running it",
				})
			)
		end
	end
	if mutations then
		local origin: Link.Origin = {
			context = s.target.context,
			source = Link.sourceOf(s.target.contextSource, s.target.confirmed),
			kubeconfig = s.target.kubeconfig,
		}
		for _, m in Link.chips(ref, origin, objState(obj)) do
			table.insert(
				chips,
				chip(m.label .. " (" .. m.key .. ")", "mutate=" .. m.op, {
					key = "m-" .. m.op,
					tone = "warning",
					title = m.title,
				})
			)
		end
	end
	table.insert(
		chips,
		chip("Manifest (m)", "gitops=manifest", { key = "g-manifest", title = "Open its manifest at the line" })
	)
	table.insert(
		chips,
		chip("Diff vs manifest (=)", "gitops=diff", { key = "g-diff", title = "kubectl diff of its manifest" })
	)
	table.insert(
		chips,
		chip(
			"Export (E)",
			"gitops=export",
			{ key = "g-export", title = "Write it as a clean manifest (preview first)" }
		)
	)
	table.insert(chips, chip("Copy id", "copy=id", { key = "a-id" }))
	table.insert(chips, chip("Copy command (Y)", "copy=cmd", { key = "a-cmd" }))
	if ref.kind == "Pod" then
		table.insert(chips, chip("Copy exec command", "copy=exec", { key = "a-exec", tone = "warning" }))
	end
	local children: { Node } = { ui.row(chips, { key = "chips", wrap = true, role = "tern-kube.chips" }) }
	if ref.kind == "Pod" then
		table.insert(
			children,
			ui.text({
				ui.span(
					"exec runs a shell inside the container on "
						.. (if s.target.context then "context " .. s.target.context else "the current context"),
					"warning"
				),
			}, { key = "exec-warning" })
		)
	end
	return ui.col(children, { key = "actions" })
end

type KvItem = { { ui.SpanLike } }

local function pair(k: { ui.SpanLike }, v: { ui.SpanLike }): KvItem
	return { k, v }
end

local function metaItems(obj: any, ref: Ref): ({ KvItem }, { Node })
	local items: { KvItem } = {
		pair({ "Kind" }, { (if ref.group then ref.group .. "/" else "") .. ref.kind }),
		pair({ "Name" }, { ui.span(ref.name, "strong") }),
	}
	if ref.namespace then
		table.insert(items, pair({ "Namespace" }, { ref.namespace }))
	end
	local owners: { Node } = {}
	local md = if type(obj) == "table" and type(obj.metadata) == "table" then obj.metadata else nil
	if md then
		if type(md.creationTimestamp) == "string" then
			table.insert(items, pair({ "Created" }, { md.creationTimestamp }))
		end
		if type(md.labels) == "table" then
			local parts: { string } = {}
			for k, v in md.labels do
				table.insert(parts, tostring(k) .. "=" .. tostring(v))
			end
			table.sort(parts)
			if #parts > 0 then
				table.insert(items, pair({ "Labels" }, { ui.span(table.concat(parts, "  "), "mono") }))
			end
		end
		if type(md.ownerReferences) == "table" then
			for i, o in md.ownerReferences do
				if type(o) == "table" and type(o.kind) == "string" and type(o.name) == "string" then
					local group = if type(o.apiVersion) == "string"
						then string.match(o.apiVersion, "^([^/]+)/")
						else nil
					local owner: Ref = {
						kind = o.kind,
						group = group,
						name = o.name,
						namespace = ref.namespace,
						source = "live",
					}
					table.insert(
						owners,
						chip(
							"owner " .. o.kind .. "/" .. o.name,
							"goto=" .. State.encodeRef(owner),
							{ key = "owner" .. i }
						)
					)
				end
			end
		end
	end
	return items, owners
end

local function noticeNodes(s: State, sensitive: boolean, masked: boolean): { Node }
	local out: { Node } = {}
	for i, notice in Redact.notices(Redact.fromConfig(s.config), sensitive, masked, M.SENSITIVE) do
		table.insert(
			out,
			ui.text(
				{ ui.span(notice, "warning") },
				{ key = if i == 1 then "sensitive" else "sensitive" .. i, role = "tern-kube.sensitive" }
			)
		)
	end
	return out
end

local function detailBody(s: State, route: Route, load: Load?): { Node }
	local ref = route.ref :: Ref
	local data = if load and load.status == "ok" and load.data then load.data :: State.DetailData else nil
	local obj = if data then data.object else nil
	local out: { Node } = {}
	if obj == nil then
		local pending = pendingNode(s, load)
		if pending then
			table.insert(out, pending)
		end
	end
	local items, owners = metaItems(obj, ref)
	local meta = ui.kv(items);
	(meta.p :: any).key = "meta"
	table.insert(out, meta)
	if #owners > 0 then
		table.insert(out, ui.row(owners, { key = "owners", wrap = true, role = "tern-kube.chips" }))
	end
	table.insert(out, actionChips(s, ref))
	local controller = GitopsView.controllerLine(gitopsView(s, route, obj), obj)
	if controller then
		table.insert(out, controller)
	end
	local helmOwner = HelmView.ownerLine(helmView(s, route), obj)
	if helmOwner then
		table.insert(out, helmOwner)
	end
	if data and obj then
		local sensitive = type(obj) == "table" and obj.kind == "Secret"
		for _, n in noticeNodes(s, sensitive, data.masked) do
			table.insert(out, n)
		end
		local tree = ObjTree.tree(obj, { id = "obj", policy = Redact.fromConfig(s.config) });
		(tree.p :: any).key = "tree"
		table.insert(out, tree)
	end
	return out
end

local function relationsBody(s: State, route: Route, load: Load?): { Node }
	if load and load.status == "loading" then
		local data = load.data :: State.RelationsData?
		local asked = if data then data.asked else 0
		return {
			ui.muted(string.format("Querying related objects (%d queries so far) …", asked), { key = "loading" }),
		}
	end
	local pending = pendingNode(s, load)
	if pending or load == nil then
		return { pending :: Node }
	end
	local graph = (load.data :: State.RelationsData).graph
	if graph == nil then
		return { ui.muted("No relations computed.") }
	end
	local f = string.lower(s.filter[State.currentKey(s)] or "")
	local rows: { GridRow } = {}
	local keys: { string } = {}
	local rootNs = if graph.nodes[1] then graph.nodes[1].ref.namespace else nil
	for _, node in graph.nodes do
		local ref = node.ref
		local hay = string.lower(ref.kind .. " " .. ref.name .. " " .. (node.provenance or ""))
		if f == "" or string.find(hay, f, 1, true) then
			local indent = string.rep("  ", node.depth) .. (if node.depth > 0 then "↳ " else "")
			local name = indent .. ref.name
			if ref.namespace and ref.namespace ~= rootNs then
				name ..= "  (" .. ref.namespace .. ")"
			end
			local relation = node.relation or (if node.depth == 0 then "root" else "")
			local status = node.summary or ""
			if node.missing then
				status = if status == "" then "not found" else status .. " (not found)"
			end
			local n = #rows + 1
			rows[n] = {
				key = node.key,
				cells = { name, ref.kind, relation, M.provenanceLabel(node.provenance or ""), status },
				action = "open=" .. node.key,
			}
			keys[n] = node.key
		end
	end
	local out: { Node } = {
		ui.text({
			ui.span(string.format("%d objects, %d edges", #graph.nodes, #graph.edges), "muted"),
		}, { key = "count" }),
	}
	local root = if route.ref then State.findObject(s, route.ref) else nil
	local helmOwner = HelmView.ownerLine(helmView(s, route), root)
	if helmOwner then
		table.insert(out, helmOwner)
	end
	if graph.truncated then
		table.insert(
			out,
			ui.badge("truncated: node budget reached (explore.relationship_max_nodes)", "warning", { key = "trunc" })
		)
	end
	if #rows > 0 then
		local types: { Types.ColumnType } = { "text", "text", "text", "text", "status" }
		for _, n in
			pagedGrid(
				"rel",
				{ "NAME", "KIND", "RELATION", "VIA", "STATUS" },
				types,
				rows,
				selectedIndexIn(s, keys),
				s,
				provenanceCell
			)
		do
			table.insert(out, n)
		end
	end
	for i, note in graph.notes do
		table.insert(out, ui.muted(note, { key = "note" .. i }))
	end
	return out
end

local function describeBody(s: State, load: Load?): { Node }
	local pending = pendingNode(s, load)
	if pending or load == nil then
		return { pending :: Node }
	end
	local capture = load.data :: any
	local out = noticeNodes(s, false, capture.masked == true)
	table.insert(out, DescribeView.render(capture, Viewstate.default(), Viewstate))
	return out
end

-- Logs -----------------------------------------------------------------------

local LEVEL_TONE: { [string]: string } = {
	fatal = "error",
	error = "error",
	warn = "warning",
	info = "info",
	debug = "neutral",
	trace = "neutral",
}

M.MESSAGE_CAP = 1000
M.INSPECT_CAP = 65536
M.FIELDS_INLINE = 6

local function cap(text: string, n: number): string
	if #text <= n then
		return text
	end
	return string.sub(text, 1, n) .. " …"
end

-- HH:MM:SS.mmm of a kubelet RFC3339 time (UTC, as kubectl prints it).
function M.clock(ts: string?): string
	if ts == nil then
		return ""
	end
	local hms, frac = string.match(ts, "T(%d%d:%d%d:%d%d)%.?(%d*)")
	if hms == nil then
		return ts
	end
	return if frac and frac ~= "" then hms .. "." .. string.sub(frac .. "000", 1, 3) else hms
end

local function levelCount(counts: { [LogsTypes.Level]: number }, level: LogsTypes.Level): number
	return counts[level] or 0
end

-- The message, its first fields and how many continuation lines it carries.
function M.messageText(rec: LogsTypes.Record): string
	local parts = { rec.message }
	local fields: { LogsTypes.Field } = rec.fields or {}
	for i, f in fields do
		if i > M.FIELDS_INLINE then
			break
		end
		table.insert(parts, f.key .. "=" .. f.value)
	end
	local text = table.concat(parts, "  ")
	local more = (if rec.extra then #rec.extra else 0) + (rec.more or 0)
	if more > 0 then
		text ..= string.format("  +%d lines", more)
	end
	return cap(text, M.MESSAGE_CAP)
end

local function onePod(store: LogsStore.Store): boolean
	local pod: string? = nil
	for _, src in store.sources do
		if src.pod and pod and src.pod ~= pod then
			return false
		end
		pod = src.pod or pod
	end
	return true
end

local function sourceText(store: LogsStore.Store, index: number, single: boolean): string
	local src = store.sources[index]
	if src == nil then
		return ""
	end
	if single then
		return src.container or src.pod or ""
	end
	return (src.pod or "?") .. " · " .. (src.container or "?")
end

local function logCell(col: string, columnType: Types.ColumnType, value: string, finished: boolean): Node
	if col == "LEVEL" then
		if value == "" or value == "none" then
			return ui.text({ "" })
		end
		return ui.badge(string.upper(value), LEVEL_TONE[value] or "neutral", { role = "tern-kube.level" })
	elseif col == "TIME" then
		return ui.text({ ui.span(value, "muted mono") })
	end
	return Cells.cell(col, columnType, value, finished)
end

local function recordInspector(store: LogsStore.Store, rec: LogsTypes.Record): Node
	local items: { KvItem } = {}
	if rec.ts then
		table.insert(items, pair({ "Time" }, { ui.span(rec.ts, "mono") }))
	end
	if rec.appTime then
		table.insert(items, pair({ "Logged at" }, { ui.span(rec.appTime, "mono") }))
	end
	local src = store.sources[rec.source]
	if src then
		table.insert(
			items,
			pair({ "Source" }, { "pod " .. (src.pod or "?") .. ", container " .. (src.container or "?") })
		)
	end
	table.insert(items, pair({ "Level" }, { rec.level .. " (" .. rec.format .. ")" }))
	if rec.location then
		table.insert(items, pair({ "Location" }, { ui.span(rec.location, "mono") }))
	end
	local fields: { LogsTypes.Field } = rec.fields or {}
	for _, f in fields do
		table.insert(items, pair({ ui.span(f.key, "mono") }, { ui.span(cap(f.value, 2000), "mono") }))
	end
	local text = rec.message
	if rec.extra then
		text ..= "\n" .. table.concat(rec.extra, "\n")
	end
	if rec.more then
		text ..= string.format("\n… %d more lines (Copy line has them)", rec.more)
	end
	local kv = ui.kv(items);
	(kv.p :: any).key = "insp-kv"
	local i = tostring(rec.index)
	local chips: { Node } = {
		chip("Copy line", "lcopy=line:" .. i, { key = "c-line", title = "The line as kubectl printed it" }),
		chip("Copy message", "lcopy=msg:" .. i, { key = "c-msg" }),
	}
	if rec.format == "json" then
		table.insert(chips, chip("Copy JSON", "lcopy=json:" .. i, { key = "c-json" }))
	end
	table.insert(chips, chip("Close (enter)", "logs-inspect=", { key = "c-close" }))
	return ui.col({
		kv,
		ui.code(cap(text, M.INSPECT_CAP), nil, nil, { key = "insp-msg" }),
		ui.row(chips, { key = "insp-chips", wrap = true, role = "tern-kube.chips" }),
	}, { key = "insp", role = "tern-kube.log-inspector" })
end

local function noticeText(store: LogsStore.Store, n: LogsTypes.Notice): string
	if n.kind == "dropped" then
		return string.format("%d older lines dropped (general.max_rows / general.max_capture_bytes)", store.dropped)
	end
	return n.text
end

local function logsChips(s: State, route: Route): Node
	local chips: { Node } = {}
	local containers = State.logContainers(s, route)
	if #containers > 1 or route.container then
		table.insert(
			chips,
			chip("all containers", "container=", {
				key = "ct-",
				tone = if route.container then "neutral" else "accent",
				title = "a cycles the containers",
			})
		)
		for _, name in containers do
			table.insert(
				chips,
				chip(name, "container=" .. name, {
					key = "ct-" .. name,
					tone = if route.container == name then "accent" else "neutral",
				})
			)
		end
	end
	table.insert(
		chips,
		chip(if route.previous then "previous: on (o)" else "previous: off (o)", "previous", {
			key = "prev",
			tone = if route.previous then "accent" else "neutral",
			title = "Logs of the previous (crashed) container instance",
		})
	)
	for _, f in { { "", "All levels" }, { "warn", "Warnings+" }, { "error", "Errors+" } } do
		table.insert(
			chips,
			chip(f[2], "logs-floor=" .. f[1], {
				key = "lv-" .. f[1],
				tone = if (route.floor or "") == f[1] then "accent" else "neutral",
				title = "x cycles the level floor",
			})
		)
	end
	table.insert(chips, chip("◂ Prev error ([)", "logs-jump=prev", { key = "err-prev" }))
	table.insert(chips, chip("Next error (]) ▸", "logs-jump=next", { key = "err-next" }))
	table.insert(
		chips,
		chip("Wrap (w)", "logs-wrap", { key = "wrap", tone = if route.wrap then "accent" else "neutral" })
	)
	table.insert(chips, chip("Follow in split (l)", "quick=logs-follow", { key = "follow", tone = "accent" }))
	return ui.row(chips, { key = "chips", wrap = true, role = "tern-kube.chips" })
end

local function logsBody(s: State, route: Route, load: Load?): { Node }
	local out: { Node } = { logsChips(s, route) }
	local pending = pendingNode(s, load)
	if pending or load == nil then
		table.insert(out, pending :: Node)
		return out
	end
	local data = load.data :: State.LogsData
	local store = data.store
	local size = LogsStore.size(store)
	local f = s.filter[State.currentKey(s)] or ""
	local indices = State.logIndices(route, data, f)
	local counts = store.counts
	local summary = string.format(
		"%d lines · %d errors · %d warnings",
		size,
		levelCount(counts, "error") + levelCount(counts, "fatal"),
		levelCount(counts, "warn")
	)
	if #store.sources > 1 then
		summary ..= string.format(" · %d sources", #store.sources)
	end
	summary ..= " · --tail=" .. State.logsTail(s, route)
	if route.since then
		summary ..= " --since=" .. route.since
	end
	if route.previous then
		summary ..= " · previous instance"
	end
	if f ~= "" or route.floor then
		summary ..= string.format(" · %d shown", #indices)
	end
	table.insert(out, ui.text({ ui.span(summary, "muted") }, { key = "count", role = "tern-kube.logs-summary" }))
	for i, n in store.notices do
		local tone = if n.kind == "error" or n.kind == "warning" or n.kind == "dropped" then "warning" else "muted"
		table.insert(
			out,
			ui.text({ ui.span(noticeText(store, n), tone) }, { key = "notice" .. i, role = "tern-kube.notice" })
		)
	end
	if size == 0 then
		table.insert(out, ui.muted("No log lines.", { key = "empty" }))
		return out
	end
	if #indices == 0 then
		table.insert(out, ui.muted("Nothing matches. / edits the search; x widens the level.", { key = "empty" }))
		return out
	end
	local single = onePod(store)
	local withSource = #store.sources > 1
	local headers = if withSource then { "TIME", "SOURCE", "LEVEL", "MESSAGE" } else { "TIME", "LEVEL", "MESSAGE" }
	local types: { Types.ColumnType } = table.create(#headers, "text" :: Types.ColumnType)
	local want = tonumber(s.sel[State.currentKey(s)] or "")
	local selected = #indices
	if want then
		selected = table.find(indices, want) or selected
	end
	local grid = windowGrid(s, {
		key = "log",
		headers = headers,
		types = types,
		total = #indices,
		rowAt = function(i: number): GridRow
			local idx = indices[i]
			local rec = store.records[idx]
			local cells = { M.clock(rec.ts) }
			if withSource then
				table.insert(cells, sourceText(store, rec.source, single))
			end
			table.insert(cells, rec.level)
			table.insert(cells, M.messageText(rec))
			return { key = tostring(idx), cells = cells, action = "logs-inspect=" .. idx }
		end,
		selected = selected,
		cell = logCell,
		inspector = if route.inspect
			then function(rowKey: string): Node?
				local rec = LogsStore.get(store, tonumber(rowKey) or 0)
				return if rec then recordInspector(store, rec) else nil
			end
			else nil,
		separator = nil,
	})
	table.insert(
		out,
		ui.el("div", { key = "records", class = if route.wrap then "tk-logwrap" else "tk-lognowrap" }, grid)
	)
	return out
end

-- Events ---------------------------------------------------------------------

local TONE_STYLE: { [string]: string } = { error = "error strong", warning = "warning strong", success = "success" }
local TONE_RANK: { [string]: number } = { neutral = 0, success = 1, warning = 2, error = 3 }

-- Compact age: 42s, 7m, 3h, 2d.
function M.ageText(seconds: number): string
	local d = math.max(0, math.floor(seconds))
	if d < 60 then
		return d .. "s"
	elseif d < 3600 then
		return (d // 60) .. "m"
	elseif d < 86400 then
		return (d // 3600) .. "h"
	end
	return (d // 86400) .. "d"
end

local function eventTime(e: EventsModel.Event): number?
	return (if e.last then Timeline.parseTime(e.last) else nil)
		or (if e.first then Timeline.parseTime(e.first) else nil)
end

local function eventAge(e: EventsModel.Event, now: number?): string
	local t = eventTime(e)
	if t and now then
		return M.ageText(now - t)
	end
	return e.lastSeen or "?"
end

local function eventsScopeText(s: State, route: Route): string
	local ref = route.ref
	if ref then
		local text = string.lower(ref.kind) .. "/" .. ref.name
		return if State.related(route) then text .. " and what it owns" else text
	end
	local sc = State.eventsScope(s, route)
	if sc.all then
		return "all namespaces"
	end
	return if sc.namespace then "ns " .. sc.namespace else "ns (context default)"
end

local function eventsChips(route: Route, reasons: { { reason: string, count: number, tone: string } }, f: string): Node
	local chips: { Node } = {
		chip("Warnings only (x)", "events-warnings", {
			key = "warn",
			tone = if route.warnings then "accent" else "neutral",
		}),
	}
	if route.ref then
		table.insert(
			chips,
			chip("Include related", "events-related", {
				key = "related",
				tone = if State.related(route) then "accent" else "neutral",
				title = "Also events of what it owns (ReplicaSets, Pods, Jobs)",
			})
		)
		table.insert(
			chips,
			chip("Whole namespace", "events-scope", { key = "scope", title = "Every event of the object's namespace" })
		)
	end
	for _, r in reasons do
		table.insert(
			chips,
			chip(r.reason .. " " .. r.count, "events-reason=" .. r.reason, {
				key = "r-" .. r.reason,
				tone = if f == r.reason then "accent" else (if r.tone == "neutral" then "neutral" else r.tone),
				title = "Filter by this reason",
			})
		)
	end
	return ui.row(chips, { key = "chips", wrap = true, role = "tern-kube.chips" })
end

M.TOP_REASONS = 6

local function eventsBody(s: State, route: Route, load: Load?): { Node }
	local f = s.filter[State.currentKey(s)] or ""
	local pending = pendingNode(s, load)
	if pending or load == nil then
		return { eventsChips(route, {}, f), pending :: Node }
	end
	local data = load.data :: State.EventsData
	local scoped = Timeline.filter(data.events, { warnings = false, text = nil, scope = data.scope })
	local shown = State.eventList(route, data, f)
	local byReason: { [string]: { reason: string, count: number, tone: string } } = {}
	local reasons: { { reason: string, count: number, tone: string } } = {}
	local warnings = 0
	for _, e in scoped do
		if e.type == "Warning" then
			warnings += 1
		end
		if e.reason ~= "" then
			local r = byReason[e.reason]
			if r == nil then
				r = { reason = e.reason, count = 0, tone = "neutral" }
				byReason[e.reason] = r
				table.insert(reasons, r)
			end
			r.count += 1
			local tone = EventsModel.reasonTone(e.reason, e.type)
			if TONE_RANK[tone] > TONE_RANK[r.tone] then
				r.tone = tone
			end
		end
	end
	table.sort(reasons, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.reason < b.reason
	end)
	local top: { { reason: string, count: number, tone: string } } =
		table.move(reasons, 1, math.min(#reasons, M.TOP_REASONS), 1, {})
	local out: { Node } = { eventsChips(route, top, f) }
	local now = s.now or load.fetchedAt
	local parts = { "events", eventsScopeText(s, route), tostring(#scoped), warnings .. " Warning" }
	local newest = if scoped[1] then eventTime(scoped[1]) else nil
	if newest and now then
		table.insert(parts, "newest " .. M.ageText(now - newest) .. " ago")
	end
	if f ~= "" or route.warnings then
		table.insert(parts, #shown .. " shown")
	end
	table.insert(
		out,
		ui.text({ ui.span(table.concat(parts, " · "), "muted") }, { key = "count", role = "tern-kube.events-summary" })
	)
	if data.note then
		table.insert(out, ui.text({ ui.span(data.note, "warning") }, { key = "note", role = "tern-kube.notice" }))
	end
	if #scoped == 0 then
		table.insert(
			out,
			ui.muted(
				"No events for " .. eventsScopeText(s, route) .. ". The cluster keeps events for about an hour.",
				{ key = "empty" }
			)
		)
		return out
	end
	if #shown == 0 then
		table.insert(
			out,
			ui.muted("Nothing matches. / edits the filter; x shows Normal events too.", { key = "empty" })
		)
		return out
	end
	local groupOf: { string } = table.create(#shown)
	local starts: { [number]: boolean } = {}
	if now then
		local at = 1
		for _, g in Timeline.groups(shown, now) do
			starts[at] = true
			local label = g.label .. " · " .. #g.events
			if g.warnings > 0 then
				label ..= " (" .. g.warnings .. " Warning)"
			end
			for _ = 1, #g.events do
				groupOf[at] = label
				at += 1
			end
		end
	end
	local allNs = route.ref == nil and State.eventsScope(s, route).all
	local headers = { "AGE", "TYPE", "REASON", "OBJECT", "MESSAGE", "COUNT" }
	if allNs then
		table.insert(headers, 2, "NAMESPACE")
	end
	local types: { Types.ColumnType } = table.create(#headers, "text" :: Types.ColumnType)
	local function cell(col: string, columnType: Types.ColumnType, value: string, finished: boolean): Node
		if col == "TYPE" then
			return if value == "Warning"
				then ui.badge(value, "warning", { role = "tern-kube.event-type" })
				else ui.text({ ui.span(value, "muted") })
		elseif col == "REASON" then
			local r = byReason[value]
			return ui.text({ ui.span(value, if r then TONE_STYLE[r.tone] else nil) })
		elseif col == "AGE" or col == "COUNT" then
			return ui.text({ ui.span(value, "muted mono") })
		end
		return Cells.cell(col, columnType, value, finished)
	end
	local keys: { string } = table.create(#shown)
	for i, e in shown do
		keys[i] = e.key
	end
	local grid = windowGrid(s, {
		key = "events",
		headers = headers,
		types = types,
		total = #shown,
		rowAt = function(i: number): GridRow
			local e = shown[i]
			local object = e.object
			local cells = {
				eventAge(e, now),
				e.type,
				e.reason,
				if object then object.kind .. "/" .. object.name else "",
				cap(e.message, M.MESSAGE_CAP),
				if e.count > 1 then "×" .. e.count else "",
			}
			if allNs then
				table.insert(cells, 2, e.namespace or "")
			end
			return { key = e.key, cells = cells, action = "open=" .. e.key }
		end,
		selected = selectedIndexIn(s, keys),
		cell = cell,
		inspector = nil,
		separator = function(i: number, first: boolean): string?
			return if starts[i] or first then groupOf[i] else nil
		end,
	})
	for _, n in grid do
		table.insert(out, n)
	end
	return out
end

local function namesBody(s: State, route: Route, load: Load?): { Node }
	local out: { Node } = {}
	if route.kind == "contexts" and s.targetError then
		table.insert(out, targetErrorNode(s))
	end
	local items = State.items(s, route)
	local rows: { GridRow } = {}
	local keys: { string } = {}
	for i, item in items do
		local label = item.key
		local note = ""
		if route.kind == "contexts" and item.key == s.target.context then
			note = "current target"
		elseif route.kind == "namespaces" then
			if item.key == "*" then
				label = "all namespaces"
				note = if s.target.allNamespaces then "current scope" else ""
			elseif item.key == s.target.namespace then
				note = "current scope"
			end
		end
		rows[i] = { key = item.key, cells = { label, note }, action = "open=" .. item.key }
		keys[i] = item.key
	end
	local pending = pendingNode(s, load)
	if pending then
		table.insert(out, pending)
	end
	if #rows > 0 then
		for _, n in pagedGrid("names", { "NAME", "NOTE" }, { "text", "text" }, rows, selectedIndexIn(s, keys), s) do
			table.insert(out, n)
		end
	elseif pending == nil then
		table.insert(out, ui.muted("Nothing to pick.", { key = "empty" }))
	end
	return out
end

local function body(s: State): Node
	local route = s.stack[#s.stack]
	local load = State.currentLoad(s)
	local children: { Node }
	if route.kind == "list" then
		children = listBody(s, route, load)
	elseif route.kind == "detail" then
		children = detailBody(s, route, load)
	elseif route.kind == "relations" then
		children = relationsBody(s, route, load)
	elseif route.kind == "describe" then
		children = describeBody(s, load)
	elseif route.kind == "logs" then
		children = logsBody(s, route, load)
	elseif route.kind == "events" then
		children = eventsBody(s, route, load)
	elseif Gitops.isRoute(route.kind) then
		local ref = route.ref
		children = GitopsView.body(gitopsView(s, route, if ref then State.findObject(s, ref) else nil))
	elseif Helm.isRoute(route.kind) then
		children = HelmView.body(helmView(s, route))
	else
		children = namesBody(s, route, load)
	end
	return ui.col(children, { key = "body", role = "tern-kube.explore-" .. route.kind })
end

-- Dock and help --------------------------------------------------------------

local HINTS: { [string]: string } = {
	list = "j/k move · enter open · / filter · d describe · y object · R relations · s shell · l logs · F port-forward · : kinds · H helm · ? help",
	detail = "enter relations · d describe · L logs · s shell · l follow logs · F port-forward · e edit · ctrl+d delete · ctrl+r restart · S scale · H helm release · ? more · esc back",
	relations = "j/k move · enter open · / filter · r refresh · esc back",
	describe = "y object · R relations · r refresh · esc back",
	logs = "j/k move · enter inspect · / search · ] [ next/prev error · x level · w wrap · a container · o previous · l follow · esc back",
	events = "j/k move · enter open object · / filter · x Warning only · ] [ next/prev Warning · V object events · r refresh · esc back",
	contexts = "j/k move · enter choose · / filter · esc back",
	namespaces = "j/k move · enter choose · / filter · esc back",
	kinds = "j/k move · enter list · / filter · esc back",
}

local function dock(s: State): Node
	local route = s.stack[#s.stack]
	local load = State.currentLoad(s)
	local spans: { ui.SpanLike }
	if s.editing and s.field then
		spans = { ui.span(s.field .. ": ", "accent"), ui.span("type · enter applies · esc cancels", "muted") }
	elseif s.editing then
		spans = { ui.span("filter: ", "accent"), ui.span("type to narrow · enter keep · esc done", "muted") }
	elseif s.targetError then
		-- The error itself is in the main area; repeating it here showed it twice.
		if s.targetErrorKind == "spawn" then
			spans = { ui.span("kubectl could not run", "error"), ui.span("  · r retry", "muted") }
		elseif s.targetErrorKind == "disabled" then
			spans = { ui.span("live queries are off", "muted") }
		else
			spans = { ui.span("no usable cluster target", "error"), ui.span("  · c contexts · r retry", "muted") }
		end
	elseif load and load.status == "loading" then
		spans = { ui.span("loading … ", "accent"), ui.span(typed(load.argv), "muted mono") }
	elseif load and load.status == "error" then
		local first = string.match(load.error or "", "^[^\n]*") or ""
		spans = { ui.span(first, "error"), ui.span("  · r retry · c contexts", "muted") }
	else
		local hint = if Gitops.isRoute(route.kind)
			then GitopsView.hint(route)
			elseif Helm.isRoute(route.kind) then HelmView.hint(route)
			else HINTS[route.kind]
		spans = { ui.span(hint or "? help", "muted") }
	end
	return ui.col(
		{ ui.text(spans, { key = "status", role = "tern-kube.status" }) },
		{ role = "tern-kube.explore-dock" }
	)
end

M.KEYS = {
	{ "j / k, down / up", "Move the selection", "Click a row" },
	{ "gg / G", "First / last row", "" },
	{ "pagedown / pageup", "Move by a window (also ctrl+f / ctrl+b)", "" },
	{ "enter", "Open the selected object (in an object: its relations)", "Click a row" },
	{ "esc / backspace", "Back; at the root clear the filter, then close", "Breadcrumbs" },
	{ "/", "Filter rows (enter keeps, esc ends editing)", "Click the filter" },
	{ "r", "Refresh this view (the only way data is re-read)", "Refresh" },
	{ "c", "Choose the context", "context chip" },
	{ "n", "Choose the namespace scope", "namespace chip" },
	{ ":", "Choose a resource kind", "" },
	{ "d", "Describe (native view)", "Describe" },
	{ "y", "Object view (fields as a tree)", "Object" },
	{ "R", "Related objects with provenance", "Relations" },
	{ "L", "Log records: the last explore.logs_tail lines with level, source and time", "Logs" },
	{ "v / V", "Events timeline of the namespace / of the focused object (with what it owns)", "Events" },
	{ "] / [", "Logs: next / previous error; events: next / previous Warning", "Next error" },
	{ "x", "Logs: level floor (all, warnings+, errors+); events: Warning only", "Level chips" },
	{ "w / o / a", "Logs: wrap long lines, previous instance, cycle the container", "Wrap, previous, containers" },
	{ "enter", "Logs: inspect the selected line (fields, stack, copy line / message / JSON)", "Click a line" },
	{ "s", "Shell in a new split (workloads: a ready pod)", "Shell" },
	{ "l", "Follow logs in a new split", "Follow logs" },
	{ "shift+f", "Port-forward in a new split", "Port-forward" },
	{ "ctrl+d", "Delete: preview, then typed confirmation in the approve block", "Delete" },
	{ "ctrl+r", "Rollout restart (deployments, statefulsets, daemonsets): preview, then confirm", "Restart" },
	{ "shift+s", "Scale: asks for replicas, previews, then confirm", "Scale" },
	{ "e", "Edit in a new split (kubectl edit); the approve block previews after you save", "Edit" },
	{ "t / T", "Label / annotate: asks for KEY=VALUE or KEY-, previews, then confirm", "Label, Annotate" },
	{ "X", "Patch: asks for [--type=strategic|merge|json] JSON, previews, then confirm", "Patch" },
	{ "U", "Rollout undo (deployments, statefulsets, daemonsets): diff to the target revision", "Undo" },
	{ "p / P", "Rollout pause / resume (deployments)", "Pause, Resume" },
	{ "C / u", "Cordon / uncordon the node", "Cordon, Uncordon" },
	{ "D", "Drain the node: asks for options, previews evictions and PodDisruptionBudgets", "Drain" },
	{ "Y", "Copy the kubectl command of this view", "Copy command" },
	{ "m", "Open the object's manifest at its line (indexes the repository first)", "Manifest" },
	{ "=", "Diff the live object against its manifest (kubectl diff)", "Diff vs manifest" },
	{ "ctrl+g", "Drift report: choose a manifest source, compare it with the cluster", "" },
	{ "E", "Export the object (or the filtered list) as clean manifests: preview, then w writes", "Export" },
	{ "f / a / A / X", "Drift: filter, apply the selected manifest / the source, export all shown", "" },
	{ "t / w / b", "Export: change directory, write the files, branch and commit", "" },
	{ "b e p P o", "Git: branch, message, push, pull request, only exported files (enter runs)", "" },
	{ "H", "Helm releases; on an object managed by Helm: its release", "Helm release chip" },
	{
		"h / v / M / N / K / R",
		"Helm: history, values (v again: next mode), manifest, notes, hooks, resources of the release",
		"Release chips",
	},
	{ "enter", "Helm: open the release, the revision or the object", "Click a row" },
	{ "space", "Helm: mark a history revision for =", "" },
	{ "=", "Helm: diff the selected revision against the latest (or the marked one)", "Diff vs previous" },
	{
		"ctrl+r",
		"Helm: roll back to the selected revision (release: the last good one); previews in the approve block",
		"Rollback",
	},
	{ "ctrl+g", "Helm: drift of the auto-detected chart directory", "" },
	{ "Y", "Helm: copy the pinned helm command of this view", "Copy command" },
	{ "?", "This help", "?" },
}

local function help(): Node
	local items: { KvItem } = {}
	for _, k in M.KEYS do
		local pointer = if k[3] ~= "" then "  ·  " .. k[3] else ""
		table.insert(items, pair({ ui.span(k[1], "mono strong") }, { k[2], ui.span(pointer, "muted") }))
	end
	local kv = ui.kv(items)
	return ui.col({
		ui.text(
			{ ui.span("Tern Kube Explore keys", "strong"), ui.span("   esc or ? closes", "muted") },
			{ key = "title" }
		),
		kv,
		ui.muted("Context changes only through the chooser; every query pins --context."),
	}, { key = "help", role = "tern-kube.explore-help" })
end

-- View -----------------------------------------------------------------------

function M.view(s: State, _cols: number, _rows: number): View
	local route = s.stack[#s.stack]
	local children: { Node } = { header(s) }
	if s.targetError and route.kind ~= "contexts" then
		table.insert(children, targetErrorNode(s))
	end
	if State.FILTERABLE[route.kind] then
		local text = s.filter[State.currentKey(s)] or ""
		table.insert(children, {
			k = "input",
			p = {
				key = "filter",
				text = text,
				cursor = Textfield.caretFor(if s.editing and s.field == nil then s.input else nil, text),
				placeholder = if route.kind == "logs"
					then "press / to search messages, fields and sources"
					else "press / to filter",
				prompt = "/",
			},
		})
	end
	local editing = if s.editing then s.field else nil
	for _, n in GitopsView.inputs(s.gitops, route, editing, if editing then s.input else nil) do
		table.insert(children, n)
	end
	table.insert(children, body(s))
	return {
		main = ui.col(children, { role = "tern-kube.explore" }),
		dock = dock(s),
		layer = if s.help then ui.col({ help() }, { role = "tern-kube.explore-layer" }) else nil,
	}
end

function M.title(s: State): string
	local route = s.stack[#s.stack]
	local ctx = s.target.context or "?"
	return "Tern Kube Explore · " .. crumbLabel(s, route) .. " · " .. ctx
end

return M
