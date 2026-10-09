--!strict
-- The Explore block's view: a live header that cannot be mistaken for a lens
-- snapshot ("Live" badge, fetch age, pinned target with its provenance),
-- breadcrumbs, the filter input, one body per route, a status dock and the
-- help layer. Pure: plain `{k,p,c}` tables, no `tern` global.

local Cells = require("../render/cells")
local Command = require("../kubectl/command")
local DescribeView = require("../render/describe_view")
local Gitops = require("./gitops")
local GitopsView = require("../gitops/view")
local Grid = require("../render/grid")
local ObjTree = require("../render/objtree")
local Link = require("../mutation/link")
local Query = require("./query")
local Quick = require("../actions/quick")
local Redact = require("../model/redact")
local State = require("./state")
local Types = require("../model/types")
local Viewstate = require("../lens/viewstate")
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

local function provenanceCell(col: string, columnType: Types.ColumnType, value: string): Node
	if col ~= "VIA" or value == "" then
		return Cells.cell(col, columnType, value)
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
	if route.kind == "list" then
		local sc = State.scope(s, route)
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
	local title = ROUTE_TITLE[route.kind] or route.kind
	local ref = route.ref
	if ref then
		return title .. " " .. string.lower(ref.kind) .. "/" .. ref.name
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

-- The visible window of a long list (State.window: sized from the block's
-- height, selection kept SCROLLOFF rows from the edges), with clickable
-- "N above" / "N below" rows that page.
local function pagedGrid(
	key: string,
	headers: { string },
	types: { Types.ColumnType },
	rows: { GridRow },
	selected: number,
	s: State,
	cell: ((string, Types.ColumnType, string) -> Node)?
): { Node }
	local size = State.viewport(s.rows, s.config.general.max_rendered_rows)
	local first, last = State.window(selected, #rows, s.offset[State.currentKey(s)], size)
	local shown: { GridRow } = if first == 1 and last == #rows
		then rows
		else table.move(rows, first, last, 1, table.create(last - first + 1))
	local selKey = if rows[selected] then rows[selected].key else nil
	for _, r in shown do
		if r.key == selKey then
			r.open = true
		end
	end
	local grid = Grid.grid({
		key = key,
		headers = headers,
		types = types,
		rows = shown,
		sortCol = nil,
		desc = false,
		sortAction = noSort,
		cell = cell,
	})
	markSelected(grid, selKey)
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
	if last < #rows then
		table.insert(
			out,
			ui.muted(string.format("↓ %d below (j, pagedown, G; / filters)", #rows - last), {
				key = "overflow",
				role = "tern-kube.overflow",
				actions = { click = "page=down" },
			})
		)
	end
	return out
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

local QUICK_KEYS: { [string]: string } = { shell = "s", ["logs-follow"] = "l", ["port-forward"] = "F" }

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
	local info = quickInfo(s, ref)
	-- Workload shells pick a ready pod at run time; offer them like pod shells.
	if ref.kind ~= "Pod" and workload then
		info.pod = info.pod or "?"
	end
	local mutations = s.config.mutations.enabled
	info.allowMutations = mutations
	for _, action in Quick.available(ref.kind, ref, info :: any) do
		if not action.mutates and QUICK_KEYS[action.id] then
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
		for _, m in Link.chips(ref, origin) do
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

local function relationsBody(s: State, load: Load?): { Node }
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

local function logsBody(s: State, route: Route, load: Load?): { Node }
	local ref = route.ref :: Ref
	local out: { Node } = {}
	local chips: { Node } = {}
	local containers = State.containers(State.findObject(s, ref))
	if #containers > 1 then
		table.insert(
			chips,
			chip(
				"default container",
				"container=",
				{ key = "ct-", tone = if route.container then "neutral" else "accent" }
			)
		)
	end
	for _, name in containers do
		if #containers > 1 then
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
		chip(if route.previous then "previous: on" else "previous: off", "previous", {
			key = "prev",
			tone = if route.previous then "accent" else "neutral",
			title = "Logs of the previous (crashed) container instance",
		})
	)
	table.insert(chips, chip("Follow in split (l)", "quick=logs-follow", { key = "follow", tone = "accent" }))
	table.insert(out, ui.row(chips, { key = "chips", wrap = true, role = "tern-kube.chips" }))
	local pending = pendingNode(s, load)
	if pending or load == nil then
		table.insert(out, pending :: Node)
		return out
	end
	local lines = (load.data :: State.LogsData).lines
	if #lines == 0 then
		table.insert(out, ui.muted("No log lines.", { key = "empty" }))
		return out
	end
	table.insert(out, ui.muted(string.format("last %d lines (--tail=%d)", #lines, 500), { key = "count" }))
	table.insert(out, ui.code(table.concat(lines, "\n"), nil, nil, { key = "log" }))
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
		children = relationsBody(s, load)
	elseif route.kind == "describe" then
		children = describeBody(s, load)
	elseif route.kind == "logs" then
		children = logsBody(s, route, load)
	elseif Gitops.isRoute(route.kind) then
		local ref = route.ref
		children = GitopsView.body(gitopsView(s, route, if ref then State.findObject(s, ref) else nil))
	else
		children = namesBody(s, route, load)
	end
	return ui.col(children, { key = "body", role = "tern-kube.explore-" .. route.kind })
end

-- Dock and help --------------------------------------------------------------

local HINTS: { [string]: string } = {
	list = "j/k move · enter open · / filter · d describe · y object · R relations · s shell · l logs · F port-forward · : kinds · ? help",
	detail = "enter relations · d describe · L logs · s shell · l follow logs · F port-forward · ctrl+d delete · ctrl+r restart · S scale · esc back",
	relations = "j/k move · enter open · / filter · r refresh · esc back",
	describe = "y object · R relations · r refresh · esc back",
	logs = "r refresh · l follow in split · esc back",
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
		local hint = if Gitops.isRoute(route.kind) then GitopsView.hint(route) else HINTS[route.kind]
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
	{ "L", "Last 500 log lines", "Logs" },
	{ "s", "Shell in a new split (workloads: a ready pod)", "Shell" },
	{ "l", "Follow logs in a new split", "Follow logs" },
	{ "shift+f", "Port-forward in a new split", "Port-forward" },
	{ "ctrl+d", "Delete: preview, then typed confirmation in the approve block", "Delete" },
	{ "ctrl+r", "Rollout restart (deployments, statefulsets, daemonsets): preview, then confirm", "Restart" },
	{ "shift+s", "Scale: asks for replicas, previews, then confirm", "Scale" },
	{ "Y", "Copy the kubectl command of this view", "Copy command" },
	{ "m", "Open the object's manifest at its line (indexes the repository first)", "Manifest" },
	{ "=", "Diff the live object against its manifest (kubectl diff)", "Diff vs manifest" },
	{ "ctrl+g", "Drift report: choose a manifest source, compare it with the cluster", "" },
	{ "E", "Export the object (or the filtered list) as clean manifests: preview, then w writes", "Export" },
	{ "f / a / A / X", "Drift: filter, apply the selected manifest / the source, export all shown", "" },
	{ "t / w / b", "Export: change directory, write the files, branch and commit", "" },
	{ "b e p P o", "Git: branch, message, push, pull request, only exported files (enter runs)", "" },
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

local FILTERABLE: { [string]: boolean } =
	{ list = true, contexts = true, namespaces = true, kinds = true, relations = true }

function M.view(s: State, _cols: number, _rows: number): View
	local route = s.stack[#s.stack]
	local children: { Node } = { header(s) }
	if s.targetError and route.kind ~= "contexts" then
		table.insert(children, targetErrorNode(s))
	end
	if FILTERABLE[route.kind] then
		local text = s.filter[State.currentKey(s)] or ""
		table.insert(children, {
			k = "input",
			p = {
				key = "filter",
				text = text,
				cursor = #text,
				placeholder = "press / to filter",
				prompt = "/",
			},
		})
	end
	for _, n in GitopsView.inputs(s.gitops, route, if s.editing then s.field else nil) do
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
