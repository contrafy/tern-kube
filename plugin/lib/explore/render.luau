--!strict
-- The Explore block's view: a live header that cannot be mistaken for a lens
-- snapshot ("Live" badge, fetch age, pinned target with its provenance),
-- breadcrumbs, the filter input, one body per route, a status dock and the
-- help layer. Pure: plain `{k,p,c}` tables, no `tern` global.

local Cells = require("../render/cells")
local Command = require("../kubectl/command")
local Compare = require("./compare")
local CompareModel = require("../compare/model")
local CompareView = require("../compare/view")
local Contexts = require("../compare/contexts")
local DescribeView = require("../render/describe_view")
local EventsModel = require("../events/model")
local ExploreCommand = require("./command")
local Gitops = require("./gitops")
local GitopsView = require("../gitops/view")
local Grid = require("../render/grid")
local Helm = require("./helm")
local HelmView = require("../helm/view")
local ObjTree = require("../render/objtree")
local Keys = require("./keys")
local Link = require("../mutation/link")
local LogsStore = require("../logs/store")
local LogsTypes = require("../logs/types")
local Query = require("./query")
local Quick = require("../actions/quick")
local Redact = require("../model/redact")
local SecretData = require("../model/secretdata")
local SecretDataView = require("../render/secret_data")
local State = require("./state")
local Table = require("../render/table")
local Textfield = require("../textfield")
local Types = require("../model/types")
local Values = require("../model/values")
local Viewstate = require("../lens/viewstate")
local Timeline = require("../events/timeline")
local Usage = require("./usage")
local UsageView = require("../usage/view")
local UsageSeries = require("../usage/series")
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

M.SENSITIVE = SecretData.MASKED

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
	compare = "Compare",
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

-- Explore shows local time everywhere, like the rest of the desktop.
function M.localTime(s: State, at: number, fmt: string?): string
	return os.date("!" .. (fmt or "%H:%M:%S"), at + s.utcOffset) :: string
end

local function clock(s: State, at: number?): string
	if at == nil then
		return "open time"
	end
	return M.localTime(s, at)
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
		provenance = "inferred: current-context at " .. clock(s, t.inferredAt)
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

-- `Compare deployment/web · dev2`, a drill-in `web vs dev2`.
local function compareCrumb(route: Route): string
	if route.item then
		local name = string.match(route.item, "([^/]+)$") or route.item
		return name .. " vs " .. (route.context or "?")
	end
	local ref = route.ref
	local label = "Compare " .. (if ref then string.lower(ref.kind) .. "/" .. ref.name else route.resource or "pods")
	local across = route.across
	if across == "*" then
		return label .. " · all contexts"
	elseif across == "@" then
		return label .. " · configured"
	elseif across then
		return label .. " · " .. string.sub(across, 2)
	end
	return label
end

local function crumbLabel(s: State, route: Route): string
	if route.kind == "list" then
		local resource = route.resource or "pods"
		return if route.selector then resource .. " -l " .. route.selector else resource
	end
	if Gitops.isRoute(route.kind) then
		return GitopsView.crumb(s.gitops, route)
	end
	if Helm.isRoute(route.kind) then
		return HelmView.crumb(route)
	end
	if Compare.isRoute(route.kind) then
		return compareCrumb(route)
	end
	if Usage.isRoute(route.kind) then
		local sc = Usage.podScope(route, State.scope(s, route))
		return Usage.crumb(
			route,
			if sc.all then "all namespaces" elseif sc.namespace then "ns " .. sc.namespace else "ns (context default)"
		)
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
	local live: { Node } = {}
	-- With live queries off nothing is fetched: no Live badge, no Refresh.
	if s.config.explore.allow_live_queries then
		table.insert(
			live,
			ui.badge("Live", "accent", {
				key = "live",
				role = "tern-kube.live",
				title = "Fetched from the cluster on request; never refreshed on its own",
			})
		)
		if load and load.status == "loading" then
			table.insert(live, ui.text({ ui.span("fetching via " .. (s.target.context or "kubeconfig"), "muted") }))
		elseif load and load.fetchedAt then
			local age = State.age(s.now, load.fetchedAt) or "just now"
			table.insert(
				live,
				ui.text(
					{ ui.span("fetched " .. age .. " via " .. (s.target.context or "kubeconfig"), "muted") },
					{ key = "age", role = "tern-kube.fetched", title = "Fetched at " .. clock(s, load.fetchedAt) }
				)
			)
		end
		table.insert(live, chip("Refresh", "refresh", { key = "refresh", title = "Run the query again (r)" }))
		local top = s.stack[#s.stack]
		if Usage.isRoute(top.kind) then
			local data = if load and load.status == "ok" then load.data else nil
			for _, n in
				Usage.headerNodes(s.usage, data, s.now, function(at: number): string
					return M.localTime(s, at)
				end)
			do
				table.insert(live, n)
			end
		end
	end
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
	local last = s.stack[#s.stack]
	if last.kind == "list" and last.selector then
		table.insert(
			crumbs,
			chip(
				"Clear -l",
				"selector-clear",
				{ key = "selector-clear", title = "List every object, not only -l matches" }
			)
		)
	end
	return ui.col({
		ui.row(live, { key = "bar", wrap = true, role = "tern-kube.bar" }),
		ui.row(crumbs, { key = "crumbs", wrap = true, role = "tern-kube.breadcrumb" }),
	}, { key = "header", role = "tern-kube.explore-header" })
end

-- Bodies ---------------------------------------------------------------------

local function errorNode(text: string, key: string?): Node
	return ui.text({ ui.span(text, "error") }, { key = key or "error", role = "tern-kube.error" })
end

-- The target error, shown once; kubectl that could not run gets the ways out.
-- Its key differs from a load error's: the contexts view can show both.
local function targetErrorNode(s: State): Node
	local text = errorNode(s.targetError or "", "target-error")
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
		if not s.config.explore.allow_live_queries then
			return ui.muted("Turn on explore.allow_live_queries in Tern Kube Settings to browse the cluster here.")
		elseif s.targetError then
			return ui.muted("Nothing is queried until the target is resolved.")
		end
		return ui.muted(if State.resolved(s) then "Not loaded. Press r." else "Resolving the cluster context …")
	end
	if load.status == "loading" then
		return loadingNode(load)
	elseif load.status == "error" then
		return errorNode(load.error or "kubectl failed", "load-error")
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
			ui.muted(string.format("↑ %d above (k, PageUp, gg)", first - 1), {
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
			ui.muted(string.format("↓ %d below (j, PageDown, G; / filters)", total - last), {
				key = "overflow",
				role = "tern-kube.overflow",
				actions = { click = "page=down" },
			})
		)
	end
	return out
end

export type TableSpec = {
	key: string,
	headers: { string },
	types: { Types.ColumnType },
	rows: { GridRow },
	selected: number,
	cell: ((string, Types.ColumnType, string, boolean) -> Node)?,
	sortable: boolean?,
	sort: State.Sort?,
	hide: { [string]: boolean }?,
	now: number?,
	-- Holder of the last built table (a list load's data): with the same
	-- source rows and window only `selected` changes, so a key press does
	-- not rebuild hundreds of rows.
	cache: { view: any? }?,
	source: any?,
	-- Changes when cells outside `source` changed (usage trends): the
	-- cached table is rebuilt.
	rev: number?,
	unsortable: { [string]: boolean }?,
	-- Finishes a visible row before it is built (usage trend cells).
	decorate: ((row: GridRow) -> GridRow)?,
}

-- A native table in its own scroller (explore.css makes it fill the pane
-- under a sticky head). Up to general.max_rendered_rows rows around the
-- selection; the rest are counted in clickable notes that page.
local function tableNodes(s: State, spec: TableSpec): { Node }
	local rows = spec.rows
	local total = #rows
	local first, last = State.window(spec.selected, total, s.offset[State.currentKey(s)], State.windowSize(s))
	local shown = rows
	if first > 1 or last < total then
		shown = table.move(rows, first, last, 1, table.create(last - first + 1))
	end
	local selected = rows[spec.selected]
	local selectedKey = if selected then selected.key else nil
	local cache = spec.cache
	local view = if cache then cache.view else nil
	local node: Node
	if
		view
		and spec.source ~= nil
		and view.source == spec.source
		and view.first == first
		and view.last == last
		and view.now == spec.now
		and view.hide == (if spec.hide then "ns" else "")
		and view.rev == spec.rev
	then
		local p = table.clone(view.node.p)
		p.selected = selectedKey
		node = { k = "table", p = p }
	else
		local decorate = spec.decorate
		if decorate then
			local finished: { GridRow } = table.create(#shown)
			for i, r in shown do
				finished[i] = decorate(r)
			end
			shown = finished
		end
		node = Table.table({
			key = spec.key,
			headers = spec.headers,
			types = spec.types,
			rows = shown :: { any },
			selected = selectedKey,
			cell = spec.cell,
			sortable = spec.sortable,
			sort = spec.sort,
			hide = spec.hide,
			now = spec.now,
			empty = nil,
			unsortable = spec.unsortable,
		})
		if cache and spec.source ~= nil then
			cache.view = {
				source = spec.source,
				first = first,
				last = last,
				now = spec.now,
				hide = if spec.hide then "ns" else "",
				rev = spec.rev,
				node = node,
			}
		end
	end
	local out: { Node } = {}
	if first > 1 then
		table.insert(
			out,
			ui.muted(string.format("↑ %d earlier rows (gg, PageUp)", first - 1), {
				key = "above",
				role = "tern-kube.overflow",
				actions = { click = "page=up" },
			})
		)
	end
	table.insert(out, ui.el("div", { key = spec.key .. "-scroll", role = "tern-kube.scroller" }, { node }))
	if last < total then
		table.insert(
			out,
			ui.muted(string.format("↓ %d more rows (G, PageDown; / filters)", total - last), {
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
	return tableNodes(s, {
		key = key,
		headers = headers,
		types = types,
		rows = rows,
		selected = selected,
		cell = cell,
		sortable = false,
		sort = nil,
		hide = nil,
		now = nil,
		cache = nil,
		source = nil,
	})
end

-- Rows first..last of a matrix over the route's items. Sized by
-- general.max_rendered_rows alone, not the block height: the counts, notes
-- and legend above a matrix vary with its columns, so CHROME_LINES cannot
-- predict them and a height-sized window hid rows on a half-empty pane.
local function itemWindow(s: State): CompareView.Window
	local items = State.items(s)
	local size = s.config.general.max_rendered_rows
	local first, last = State.window(State.selectedIndex(s, items), #items, s.offset[State.currentKey(s)], size)
	return { first = first, last = last }
end

-- What the GitOps views need: the shared paged grid and chip builders.
local function gitopsView(s: State, route: Route, object: any?, cols: number?): GitopsView.Ctx
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
		width = cols,
		window = if route.kind == "matrix" then itemWindow(s) else nil,
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

local RANK: { [string]: number } = { muted = 0, neutral = 0, success = 1, warning = 2, error = 3 }

-- Head tiles of a list with a health column: how many rows are ready, not
-- ready or failing, and the restarts; nil for kinds without one.
function M.listStats(data: State.ListData, rows: { State.Row }, resource: string): Node?
	local health: { number } = {}
	for i, t in data.types do
		if t == "status" or t == "ratio" then
			table.insert(health, i)
		end
	end
	if #health == 0 then
		return nil
	end
	local restartsAt = table.find(data.headers, "RESTARTS")
	local ready, waiting, failing, restarts = 0, 0, 0, 0
	for _, row in rows do
		if Cells.rowFinished(data.types, row.cells) then
			continue
		end
		local worst = "neutral"
		for _, i in health do
			local tone = Values.statusTone(data.headers[i], row.cells[i] or "")
			if (RANK[tone] or 0) > RANK[worst] then
				worst = tone
			end
		end
		if worst == "success" then
			ready += 1
		elseif worst == "warning" then
			waiting += 1
		elseif worst == "error" then
			failing += 1
		end
		if restartsAt then
			restarts += Values.count(row.cells[restartsAt] or "") or 0
		end
	end
	local items: { { [string]: any } } = {
		{ label = { { t = resource } }, value = { { t = tostring(#rows) } } },
		{ label = { { t = "Ready" } }, value = { { t = tostring(ready) } } },
		{
			label = { { t = "Not ready" } },
			value = { { t = tostring(waiting + failing) } },
			sub = if failing > 0 then { { t = failing .. " failing" } } else nil,
			tone = if failing > 0 then "error" elseif waiting > 0 then "warning" else nil,
		},
	}
	if restartsAt then
		table.insert(items, {
			label = { { t = "Restarts" } },
			value = { { t = tostring(restarts) } },
			tone = if restarts > 0 then "warning" else nil,
		})
	end
	return { k = "stats", p = { key = "stats", items = items } }
end

-- A usage view: tiles, notes and the table; trend cells only for the rows
-- on screen.
local function usageBody(s: State, route: Route, load: Load?): { Node }
	local pending = pendingNode(s, load)
	if pending or load == nil then
		return { pending :: Node }
	end
	local data = load.data :: Usage.Data
	local built = data.built :: UsageView.Built
	local key = State.currentKey(s)
	local f = string.lower(s.filter[key] or "")
	local list = State.listRows(s, route, data :: any) :: { any }
	local out = Usage.head(s.usage, route, data, {
		shown = #list,
		filter = f,
		chip = chip,
		allowLive = s.config.explore.allow_live_queries,
	})
	if #data.rows == 0 then
		local sc = Usage.podScope(route, State.scope(s, route))
		local where = if route.node
			then "on node " .. route.node
			elseif sc.all then "in all namespaces"
			elseif sc.namespace then "in " .. sc.namespace
			else "in the context default namespace"
		table.insert(out, ui.muted(string.format("No %s %s.", built.kind, where), { key = "empty" }))
		return out
	end
	if #list == 0 then
		table.insert(out, ui.muted("Nothing matches the filter. Esc clears it.", { key = "empty" }))
		return out
	end
	local rows: { any } = table.create(#list)
	local keys: { string } = table.create(#list)
	for i, row in list do
		rows[i] = { key = row.key, cells = row.cells, action = "open=" .. row.key, raw = row.raw, urow = row }
		keys[i] = row.key
	end
	local trends: UsageView.TrendOpts = {
		store = s.usage.store,
		clock = function(at: number): string
			return M.localTime(s, at)
		end,
		off = #data.rows > UsageSeries.MAX_ROWS,
	}
	local all = Usage.podScope(route, State.scope(s, route)).all
	for _, n in
		tableNodes(s, {
			key = "grid",
			headers = data.headers,
			types = data.types,
			rows = rows :: any,
			selected = selectedIndexIn(s, keys),
			cell = nil,
			sortable = true,
			sort = s.sort[key],
			hide = if all or built.kind ~= "pods" then nil else { NAMESPACE = true },
			now = nil,
			cache = data,
			source = list,
			rev = s.usage.rev,
			unsortable = built.unsortable,
			decorate = function(r: GridRow): GridRow
				local d = table.clone(r) :: any
				d.raw = UsageView.withTrends(built, d.urow, trends)
				return d
			end,
		})
	do
		table.insert(out, n)
	end
	return out
end

local function listBody(s: State, route: Route, load: Load?): { Node }
	local pending = pendingNode(s, load)
	if pending or load == nil then
		return { pending :: Node }
	end
	local data = load.data :: State.ListData
	local key = State.currentKey(s)
	local f = string.lower(s.filter[key] or "")
	local list = State.listRows(s, route, data)
	local rows: { GridRow } = table.create(#list)
	local keys: { string } = table.create(#list)
	for i, row in list do
		rows[i] = { key = row.key, cells = row.cells, action = "open=" .. row.key }
		keys[i] = row.key
	end
	local resource = route.resource or "pods"
	if #data.rows == 0 then
		return { ui.muted(string.format("No %s in %s.", resource, scopeText(s, route)), { key = "empty" }) }
	end
	local summary = string.format("%d %s", #data.rows, resource)
	if f ~= "" then
		summary ..= string.format(" · %d match /%s", #rows, f)
	end
	local countRow: { Node } = { ui.text({ ui.span(summary, "muted") }, { key = "count" }) }
	if not State.singleContext(s) then
		table.insert(
			countRow,
			chip("Compare list (x)", "nav=compare", {
				key = "compare",
				title = "This list in other contexts of the kubeconfig: present, same, changed, missing (read-only)",
			})
		)
	end
	if resource == "pods" or resource == "nodes" then
		table.insert(
			countRow,
			chip("Usage (%)", "usage-key=%", {
				key = "usage",
				title = if resource == "nodes"
					then "Nodes against allocatable: used, requested and limits (runs kubectl)"
					else "These pods against their requests and limits (runs kubectl)",
			})
		)
	end
	local out: { Node } = { ui.row(countRow, { key = "count-row", wrap = true, role = "tern-kube.chips" }) }
	local stats = M.listStats(data, list, resource)
	if stats then
		table.insert(out, stats)
	end
	if #rows == 0 then
		table.insert(out, ui.muted("Nothing matches the filter. Esc clears it.", { key = "empty" }))
		return out
	end
	for _, n in
		tableNodes(s, {
			key = "grid",
			headers = data.headers,
			types = data.types,
			rows = rows,
			selected = selectedIndexIn(s, keys),
			cell = nil,
			sortable = true,
			sort = s.sort[key],
			hide = if State.scope(s, route).all then nil else { NAMESPACE = true },
			now = load.fetchedAt,
			cache = data,
			source = list,
		})
	do
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

-- `decode`: the Secret decode chip (object view of a decodable Secret).
local function actionChips(s: State, ref: Ref, decode: Node?): Node
	local chips: { Node } = {
		chip("Describe (d)", "nav=describe", { key = "a-describe" }),
		chip("Object (y)", "nav=detail", { key = "a-detail" }),
		chip("Relations (R)", "nav=relations", { key = "a-relations" }),
	}
	if not State.singleContext(s) then
		table.insert(
			chips,
			chip("Compare across contexts (x)", "nav=compare", {
				key = "a-compare",
				title = "This object in other contexts of the kubeconfig, side by side (read-only)",
			})
		)
	end
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
	if decode then
		table.insert(chips, decode)
	end
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
			origin = s.origin,
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

local function metaItems(s: State, obj: any, ref: Ref): ({ KvItem }, { Node })
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
			local at = Values.timestamp(md.creationTimestamp)
			local text = if at
				then M.localTime(s, math.floor(at), "%Y-%m-%d %H:%M:%S") .. (if s.now
					then " (" .. Table.age(s.now - at) .. " ago)"
					else "")
				else md.creationTimestamp
			table.insert(items, pair({ "Created" }, { text }))
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
	local items, owners = metaItems(s, obj, ref)
	local meta = ui.kv(items);
	(meta.p :: any).key = "meta"
	table.insert(out, meta)
	if #owners > 0 then
		table.insert(out, ui.row(owners, { key = "owners", wrap = true, role = "tern-kube.chips" }))
	end
	-- Two gates: show_secret_values (else the values are masked) and z.
	local decodable = obj ~= nil and Redact.fromConfig(s.config).showSecrets and SecretData.decodable(obj)
	local decoded = decodable and route.decoded == true
	local decode = if decodable
		then chip(SecretDataView.label(decoded, "z"), "decode=1", {
			key = "a-decode",
			tone = if decoded then "accent" else "warning",
			title = if decoded
				then "Hide the decoded values"
				else "Show the values decoded in a separate card (display only; the tree stays base64)",
		})
		else nil
	table.insert(out, actionChips(s, ref, decode))
	local controller = GitopsView.controllerLine(gitopsView(s, route, obj, nil), obj)
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
		if decoded then
			table.insert(
				out,
				SecretDataView.card(SecretData.entries(obj), { key = "decoded", hint = "z / Hide decoded" })
			)
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
			-- Em spaces: table cells collapse leading ASCII spaces.
			local indent = if node.depth > 0 then string.rep(utf8.char(0x2003), node.depth - 1) .. "↳ " else ""
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

-- HH:MM:SS.mmm of a kubelet RFC3339 time, in local time (`offset` seconds
-- east of UTC).
function M.clock(ts: string?, offset: number?): string
	if ts == nil then
		return ""
	end
	local frac = string.match(ts, "T%d%d:%d%d:%d%d%.(%d+)")
	local at = Values.timestamp(ts)
	if at == nil then
		return ts
	end
	local hms = os.date("!%H:%M:%S", math.floor(at) + (offset or 0)) :: string
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
			local cells = { M.clock(rec.ts, s.utcOffset) }
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

-- The `:` prompt's picker: matching commands, then kinds ranked for the
-- prompt text (kubectl's static kinds until discovery answers).
local function kindsBody(s: State, route: Route, load: Load?): { Node }
	local out: { Node } = {}
	local data = if load and load.status == "ok" then load.data :: State.KindsData else nil
	if data and data.partial then
		table.insert(
			out,
			ui.text({
				ui.span("Partial discovery: ", "warning"),
				ui.span("kubectl could not read " .. data.partial .. "; those kinds are missing.", "muted"),
			}, { key = "partial", role = "tern-kube.notice" })
		)
	end
	if s.pendingCommand then
		table.insert(out, ui.muted("resolving " .. s.pendingCommand.text .. " …", { key = "resolving" }))
	elseif load and load.status ~= "ok" then
		local pending = pendingNode(s, load)
		if pending then
			table.insert(out, pending)
		end
	end
	local rows: { GridRow } = {}
	local keys: { string } = {}
	for i, row in State.kindRows(s, route) do
		rows[i] = { key = row.key, cells = row.cells, action = "open=" .. row.key }
		keys[i] = row.key
	end
	if #rows == 0 then
		table.insert(out, ui.muted("No kind or command matches.", { key = "empty" }))
		return out
	end
	for _, n in
		pagedGrid(
			"kinds",
			{ "NAME", "ALIASES", "KIND", "SCOPE" },
			{ "text", "text", "text", "text" },
			rows,
			selectedIndexIn(s, keys),
			s
		)
	do
		table.insert(out, n)
	end
	return out
end

local function namesBody(s: State, route: Route, load: Load?): { Node }
	if route.kind == "kinds" then
		return kindsBody(s, route, load)
	end
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

-- Compare ----------------------------------------------------------------------

local function compareSubject(s: State, route: Route): string
	local ref = route.ref
	if ref then
		return string.lower(ref.kind) .. "/" .. ref.name .. (if ref.namespace then " in " .. ref.namespace else "")
	end
	local sc = Compare.scope(State.compareCtx(s), route)
	local where = if sc.all
		then "all namespaces"
		elseif sc.namespace then sc.namespace
		else "the context default namespace"
	return (route.resource or "pods") .. " in " .. where .. (if route.match then " matching /" .. route.match else "")
end

-- The notice a compare carries: Secret values masked (or shown), strict mode.
local function compareNotice(s: State, secret: boolean): string?
	local policy = Redact.fromConfig(s.config)
	if secret then
		return if policy.showSecrets then Redact.REVEALED else M.SENSITIVE
	end
	return if policy.strict then Redact.STRICT else nil
end

local function compareChips(s: State, route: Route, l: Compare.Load): Node
	local out: { Node } = {}
	if l.ref == nil and route.item == nil then
		local f = Compare.filter(s.compare, State.compareCtx(s), route)
		table.insert(
			out,
			chip("Show: " .. CompareView.FILTER_TEXT[f] .. " (f)", "compare-key=f", {
				key = "c-filter",
				tone = if f == "all" then "neutral" else "accent",
				title = "All objects / only those that differ / only missing or extra",
			})
		)
	end
	if #l.columns > 2 then
		table.insert(out, chip("Next context (])", "compare-key=]", { key = "c-next" }))
	end
	table.insert(out, chip("Pick again (x)", "compare-key=x", { key = "c-pick" }))
	table.insert(out, chip("Copy commands (Y)", "copy=cmd", { key = "c-copy" }))
	return ui.row(out, { key = "c-chips", wrap = true, role = "tern-kube.chips" })
end

-- The base side of a list compare failed or was over compare.max_objects:
-- nothing was compared, but the other sides were read; say so per side
-- rather than "nothing" (B6).
local function refusedBase(m: CompareModel.Matrix, l: Compare.Load): { Node }
	local out: { Node } = {}
	local legend: { string } = {}
	for _, c in m.columns do
		table.insert(legend, c.label .. " = " .. c.context)
	end
	table.insert(out, ui.muted(table.concat(legend, " · "), { key = "legend", role = "tern-kube.compare-legend" }))
	for i, note in m.notes do
		table.insert(out, ui.muted(note, { key = "note" .. i }))
	end
	local base = m.columns[1]
	if #m.notes == 0 then
		table.insert(out, ui.muted(base.label .. ": error: " .. (base.error or "kubectl failed"), { key = "base" }))
	end
	local lines: { Node } = {}
	for i = 2, #m.columns do
		local c = m.columns[i]
		local text = if c.status == "ok"
			then string.format("%s: %d objects read, not compared", c.label, l.counts[i] or 0)
			else c.label .. ": error: " .. (c.error or "kubectl failed")
		table.insert(lines, ui.muted(text, { key = "n" .. i }))
	end
	table.insert(out, ui.col(lines, { key = "counts", role = "tern-kube.compare-counts" }))
	local over = string.find(base.error or "", "compare.max_objects", 1, true) ~= nil
	table.insert(
		out,
		ui.text({
			ui.span(
				if over
					then "Nothing compared: the base side is over compare.max_objects. Filter the list (/) before x, or raise compare.max_objects."
					else "Nothing compared: the base context failed. r fetches every side again.",
				"warning"
			),
		}, { key = "empty", role = "tern-kube.compare-refused" })
	)
	return out
end

local function compareBody(s: State, route: Route): { Node }
	if not s.config.explore.allow_live_queries then
		return { ui.muted("Live queries are disabled (explore.allow_live_queries = false).", { key = "off" }) }
	end
	local cctx = State.compareCtx(s)
	local out: { Node } = {
		ui.text({ ui.span("Comparing " .. compareSubject(s, route), "strong") }, { key = "head" }),
	}
	if route.reloaded then
		table.insert(
			out,
			ui.muted(
				"Tern Kube was reloaded: this compare was not fetched again. r fetches every side, x picks again, esc goes back.",
				{ key = "reloaded", role = "tern-kube.compare-reloaded" }
			)
		)
		return out
	end
	local cl = Compare.contextsLoad(s.compare, cctx)
	if cl == nil or cl.status == "loading" then
		table.insert(
			out,
			ui.muted(
				if cl
					then "Running " .. typed(cl.argv) .. " …"
					elseif State.resolved(s) then "Not loaded. Press r."
					else "Resolving the cluster context …",
				{ key = "loading" }
			)
		)
		return out
	elseif cl.status == "error" then
		table.insert(out, errorNode(cl.error or "kubectl config view failed"))
		return out
	end
	local selected = State.selectedItem(s)
	local sel = if selected then selected.key else nil
	if route.across == nil then
		local f = string.lower(s.filter[State.currentKey(s)] or "")
		local choices: { Contexts.Choice } = {}
		for _, ch in Compare.choices(s.compare, cctx) do
			if f == "" or string.find(string.lower(ch.label), f, 1, true) then
				table.insert(choices, ch)
			end
		end
		for _, n in CompareView.picker(choices, sel) do
			table.insert(out, n)
		end
		return out
	end
	local l = Compare.load(s.compare, cctx, route)
	if l == nil then
		table.insert(out, ui.muted("Not loaded. Press r.", { key = "idle" }))
		return out
	elseif l.error then
		table.insert(out, errorNode(l.error))
		table.insert(out, ui.muted("x picks another context.", { key = "again" }))
		return out
	end
	table.insert(out, compareChips(s, route, l))
	if l.matrix == nil then
		local lines: { Node } = {}
		for i, c in l.columns do
			local state = if c.status == "running"
				then "fetching …"
				elseif c.status == "pending" then "waiting (compare.max_parallel)"
				elseif c.status == "ok" then "done"
				else "error: " .. (c.error or "kubectl failed")
			table.insert(lines, ui.muted(c.context .. ": " .. state, { key = "w" .. i }))
		end
		table.insert(out, ui.col(lines, { key = "progress", role = "tern-kube.compare-progress" }))
		return out
	end
	local notice = compareNotice(s, l.secret)
	if Compare.isPair(s.compare, cctx, route) then
		local p, pcols = Compare.pair(s.compare, cctx, route)
		if p == nil or pcols == nil or #pcols < 2 then
			table.insert(out, ui.muted("No other context to diff with.", { key = "none" }))
			return out
		end
		for _, n in CompareView.pair(p.cell, p.result, pcols, notice) do
			table.insert(out, n)
		end
		return out
	end
	if notice then
		table.insert(out, ui.muted(notice, { key = "notice", role = "tern-kube.notice" }))
	end
	local m = l.matrix :: CompareModel.Matrix
	local opts: CompareView.MatrixOpts = {
		-- Short labels and a legend at every width: the block's reported
		-- columns did not follow the split on Tern 0.9.8, and full context
		-- names were cut by the grid either way.
		narrow = true,
		filter = Compare.filter(s.compare, cctx, route),
		title = if l.ref
			then string.format("%d contexts", #m.columns)
			else string.format("%d objects across %d contexts", #m.rows, #m.columns),
		context = route.context,
		window = nil,
		empty = nil,
	}
	local nodes: { Node }
	if l.ref then
		nodes = CompareView.fanout(m, sel, opts)
	else
		local base = m.columns[1]
		if base and base.status == "error" then
			for _, n in refusedBase(m, l) do
				table.insert(out, n)
			end
			return out
		end
		opts.window = itemWindow(s)
		nodes = CompareView.matrix(
			Compare.visible(s.compare, cctx, route, s.filter[State.currentKey(s)]) :: CompareModel.Matrix,
			sel,
			opts
		)
	end
	for _, n in nodes do
		table.insert(out, n)
	end
	return out
end

local function body(s: State, cols: number?): Node
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
		children = GitopsView.body(gitopsView(s, route, if ref then State.findObject(s, ref) else nil, cols))
	elseif Helm.isRoute(route.kind) then
		children = HelmView.body(helmView(s, route))
	elseif Compare.isRoute(route.kind) then
		children = compareBody(s, route)
	elseif Usage.isRoute(route.kind) then
		children = usageBody(s, route, load)
	else
		children = namesBody(s, route, load)
	end
	return ui.col(children, { key = "body", role = "tern-kube.explore-" .. route.kind })
end

-- Dock and help --------------------------------------------------------------

local HINTS: { [string]: string } = {
	relations = "j/k move · enter open · / filter · r refresh · esc back",
	describe = "y object · R relations · r refresh · esc back",
	logs = "j/k move · enter inspect · / search · ] [ next/prev error · x level · w wrap · a container · o previous · l follow · esc back",
	events = "j/k move · enter open object · / filter · x Warning only · ] [ next/prev Warning · V object events · r refresh · esc back",
	contexts = "j/k move · enter choose · / filter · esc back",
	namespaces = "j/k move · enter choose · / filter · esc back",
	kinds = "j/k move · enter run · : or / edit · r refetch kinds · esc back",
	["compare-pick"] = "j/k move · enter pick · / filter · esc back",
	compare = "j/k move · enter diff · f filter · [ ] context · x pick again · r refetch all · Y copy commands · esc back",
	["compare-pair"] = "[ ] other context · x pick again · r refetch all · Y copy commands · esc back",
}

local function compareHint(s: State, route: Route): string
	if route.across == nil then
		return HINTS["compare-pick"]
	end
	return HINTS[if Compare.isPair(s.compare, State.compareCtx(s), route) then "compare-pair" else "compare"]
end

-- Load errors a context change can fix; others only offer retry.
local CONTEXT_ERRORS: { [string]: boolean } = { context = true, forbidden = true, unreachable = true, timeout = true }

local LOG_KINDS: { [string]: boolean } =
	{ Pod = true, Deployment = true, StatefulSet = true, DaemonSet = true, ReplicaSet = true, Job = true }

local QUICK_WORDS: { [string]: string } =
	{ shell = "shell", ["logs-follow"] = "follow logs", ["port-forward"] = "port-forward", edit = "edit" }

-- The list and object hints name only the keys that apply to the focused
-- object's kind and state (no shell on a ConfigMap, no Resume when running).
local function objectHint(s: State, route: Route): string
	local list = route.kind == "list"
	local parts: { string } = if list
		then { "j/k move", "enter open", "/ filter", "d describe", "y object", "R relations" }
		else { "enter relations", "d describe" }
	local ref = State.focusRef(s)
	if ref then
		if LOG_KINDS[ref.kind] then
			table.insert(parts, "L logs")
		end
		local info, obj = quickInfo(s, ref)
		if ref.kind ~= "Pod" and LOG_KINDS[ref.kind] then
			info.pod = info.pod or "?"
		end
		local mutations = s.config.mutations.enabled
		info.allowMutations = mutations
		for _, action in Quick.available(ref.kind, ref, info :: any) do
			local key, word = QUICK_KEYS[action.id], QUICK_WORDS[action.id]
			local editor = Quick.gate(action.id) == "editor"
			if key and word and (not list or not (action.mutates or editor)) then
				table.insert(parts, key .. " " .. word)
			end
		end
		if not list and mutations then
			local origin: Link.Origin = {
				context = s.target.context,
				source = Link.sourceOf(s.target.contextSource, s.target.confirmed),
				origin = s.origin,
				kubeconfig = s.target.kubeconfig,
			}
			for _, m in Link.chips(ref, origin, objState(obj)) do
				table.insert(parts, m.key .. " " .. string.lower(m.label))
			end
		end
	end
	if list then
		table.insert(parts, ": command")
		table.insert(parts, "H helm")
		table.insert(parts, "? help")
	else
		table.insert(parts, "H helm release")
		table.insert(parts, "? more")
		table.insert(parts, "esc back")
	end
	return table.concat(parts, " · ")
end

-- Words of a hint segment ("ctrl+d delete", "A apply source") that name a
-- mutation; with mutations.enabled false those segments are not offered.
local MUTATION_WORDS: { [string]: boolean } = {
	delete = true,
	restart = true,
	scale = true,
	edit = true,
	rollback = true,
	roll = true,
	apply = true,
	label = true,
	annotate = true,
	patch = true,
	undo = true,
	pause = true,
	resume = true,
	cordon = true,
	uncordon = true,
	drain = true,
}

function M.withoutMutations(hint: string): string
	local kept: { string } = {}
	for _, segment in string.split(hint, " · ") do
		local verb = string.match(segment, "^%S+%s+(%a+)")
		if not (verb and MUTATION_WORDS[verb]) then
			table.insert(kept, segment)
		end
	end
	return table.concat(kept, " · ")
end

local function dock(s: State): Node
	local route = s.stack[#s.stack]
	local load = State.currentLoad(s)
	local spans: { ui.SpanLike }
	if s.editing and s.field then
		spans = { ui.span(s.field .. ": ", "accent"), ui.span("type · enter applies · esc cancels", "muted") }
	elseif s.editing and route.kind == "kinds" then
		spans = {
			ui.span("command: ", "accent"),
			ui.span("enter runs · tab completes · ↑↓ pick · esc back", "muted"),
		}
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
		local ways = if CONTEXT_ERRORS[load.errorKind or ""] then "  · r retry · c contexts" else "  · r retry"
		spans = { ui.span(first, "error"), ui.span(ways, "muted") }
	else
		local hint = if Gitops.isRoute(route.kind)
			then GitopsView.hint(route, s.gitops, State.gitopsCtx(s))
			elseif Helm.isRoute(route.kind) then HelmView.hint(route, s.helm)
			elseif Compare.isRoute(route.kind) then compareHint(s, route)
			elseif Usage.isRoute(route.kind) then Usage.hint(s.usage, route)
			elseif route.kind == "list" or route.kind == "detail" then objectHint(s, route)
			else HINTS[route.kind]
		if hint and not s.config.mutations.enabled then
			hint = M.withoutMutations(hint)
		end
		spans = { ui.span(hint or "? help", "muted") }
	end
	return ui.col(
		{ ui.text(spans, { key = "status", role = "tern-kube.status" }) },
		{ role = "tern-kube.explore-dock" }
	)
end

M.KEYS = Keys.KEYS
-- The current view's keys first; j/k and the page keys scroll (the layer
-- is longer than a pane and Tern does not scroll it from the keyboard).
local function help(s: State): Node
	local mutations = s.config.mutations.enabled
	local kind = s.stack[#s.stack].kind
	local skip = math.clamp(s.helpTop, 0, math.max(0, Keys.rows(kind, mutations) - 1))
	local children: { Node } = {
		ui.text({
			ui.span("Tern Kube Explore keys", "strong"),
			ui.span("   j/k, PageDown/PageUp scroll · esc or ? closes", "muted"),
		}, { key = "title" }),
	}
	if skip > 0 then
		table.insert(children, ui.muted(string.format("↑ %d rows above (k, gg)", skip), { key = "help-above" }))
	end
	local row = 0
	for i, sec in Keys.sections(kind, mutations) do
		row += 1
		if row > skip then
			table.insert(children, ui.text({ ui.span(sec.title, "accent strong") }, { key = "sec" .. i }))
		end
		local items: { KvItem } = {}
		for _, k in sec.entries do
			row += 1
			if row > skip then
				local pointer = if k[3] ~= "" then "  ·  " .. k[3] else ""
				table.insert(items, pair({ ui.span(k[1], "mono strong") }, { k[2], ui.span(pointer, "muted") }))
			end
		end
		if #items > 0 then
			local kv = ui.kv(items);
			(kv.p :: any).key = "keys" .. i
			table.insert(children, kv)
		end
	end
	table.insert(
		children,
		ui.muted(
			if mutations
				then "Context changes only through the chooser (c or :ctx); every query pins --context."
				else "Context changes only through the chooser (c or :ctx); every query pins --context. Mutation keys are hidden (mutations.enabled is false)."
		)
	)
	return ui.col(children, { key = "help", role = "tern-kube.explore-help" })
end

-- View -----------------------------------------------------------------------

function M.view(s: State, cols: number, _rows: number): View
	local route = s.stack[#s.stack]
	local children: { Node } = { header(s) }
	if s.targetError and route.kind ~= "contexts" then
		table.insert(children, targetErrorNode(s))
	end
	if State.FILTERABLE[route.kind] and s.config.explore.allow_live_queries then
		local text = s.filter[State.currentKey(s)] or ""
		table.insert(children, {
			k = "input",
			p = {
				key = "filter",
				text = text,
				cursor = Textfield.caretFor(if s.editing and s.field == nil then s.input else nil, text),
				placeholder = if route.kind == "logs"
					then "search messages, fields and sources"
					elseif route.kind == "kinds" then ExploreCommand.PLACEHOLDER
					else "filter rows",
				prompt = if route.kind == "kinds" then ":" else "/",
			},
		})
	end
	local editing = if s.editing then s.field else nil
	for _, n in GitopsView.inputs(s.gitops, route, editing, if editing then s.input else nil) do
		table.insert(children, n)
	end
	table.insert(children, body(s, cols))
	return {
		main = ui.col(children, { role = "tern-kube.explore" }),
		dock = dock(s),
		layer = if s.help then ui.col({ help(s) }, { role = "tern-kube.explore-layer" }) else nil,
	}
end

function M.title(s: State): string
	local route = s.stack[#s.stack]
	local ctx = s.target.context or "?"
	return "Tern Kube Explore · " .. crumbLabel(s, route) .. " · " .. ctx
end

return M
