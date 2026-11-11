--!strict
-- Table, `-o name` and `-o json` snapshots: filter chips, one grid per
-- kubectl table (kind subheadings when there are several), the compact
-- inline inspector, the full Inspect view and pages of 500 rendered rows.

local Capture = require("../lens/capture")
local Command = require("../kubectl/command")
local Link = require("../mutation/link")
local Quick = require("../actions/quick")
local Grid = require("./grid")
local HelmChip = require("./helm_chip")
local LensChips = require("./lens_chips")
local Objtree = require("./objtree")
local Owner = require("../helm/owner")
local Query = require("../lens/query")
local SecretData = require("../model/secretdata")
local SecretDataView = require("./secret_data")
local Summary = require("./summary")
local Types = require("../model/types")
local Values = require("../model/values")
local Viewstate = require("../lens/viewstate")
local ui = require("../ui")

type Capture = Capture.Capture
type Node = ui.Node
type ResourceRow = Types.ResourceRow
type SnapshotTable = Types.SnapshotTable
type ViewState = Viewstate.ViewState

export type Counts = { shown: number, matched: number, total: number }
-- pageSize: rows drawn per page (config general.max_rendered_rows).
-- mutations: config mutations.enabled; offers the mutating chips (Delete,
-- Restart, Scale, debug, CronJob run-now), each previewed in the approve block.
-- quick: this host's quick_actions settings, written into quick-action links.
export type Options = { pageSize: number?, mutations: boolean?, quick: Quick.Settings? }

local M = {}

M.PAGE_SIZE = 500
M.FACET_VALUES = 8

local FACET_COLUMNS = { "STATUS", "NAMESPACE", "TYPE" }

local function chip(label: string, action: string, active: boolean, title: string?, key: string?): Node
	return ui.badge(label, if active then "accent" else "neutral", {
		key = key,
		title = title,
		actions = { click = action },
		role = if active then "tern-kube.chip-on" else "tern-kube.chip",
	})
end

local function columnIndex(tbl: SnapshotTable, name: string): number?
	for i, h in tbl.headers do
		if h == name then
			return i
		end
	end
	return nil
end

type Facet = { col: string, values: { { value: string, count: number } } }

local function facet(tables: { SnapshotTable }, col: string): Facet?
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, tbl in tables do
		local value: string? = nil
		local index = columnIndex(tbl, col)
		if col == Query.KIND then
			value = tbl.kind
			if value then
				if counts[value] == nil then
					counts[value] = 0
					table.insert(order, value)
				end
				counts[value] += #tbl.rows
			end
		elseif index then
			for _, row in tbl.rows do
				local v = row.cells[index] or ""
				if not Values.isPlaceholder(v) then
					if counts[v] == nil then
						counts[v] = 0
						table.insert(order, v)
					end
					counts[v] += 1
				end
			end
		elseif tbl.facets and table.find(tbl.facets, col) then
			for _, row in tbl.rows do
				local tags = row.tags
				for _, v in (if tags then tags[col] else nil) or {} :: { string } do
					if counts[v] == nil then
						counts[v] = 0
						table.insert(order, v)
					end
					counts[v] += 1
				end
			end
		end
	end
	-- NAMESPACE, KIND and TYPE only help when they split the rows.
	if col ~= "STATUS" and #order < 2 then
		return nil
	end
	if #order == 0 then
		return nil
	end
	local values: { { value: string, count: number } } = table.create(#order)
	for i, v in order do
		values[i] = { value = v, count = counts[v] }
	end
	table.sort(values, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.value < b.value
	end)
	local f: Facet = { col = col, values = values }
	return f
end

-- Events tables also split by REASON and, for `--output-watch-events`, by
-- EVENT (ADDED/MODIFIED).
local EVENT_FACETS = { "EVENT", "REASON" }

-- Tables that name their facets (lens/k9s) use those instead.
local function facetColumns(tables: { SnapshotTable }, events: boolean): { string }
	local own: { string }? = nil
	for _, tbl in tables do
		local named = tbl.facets
		if named then
			local list: { string } = own or {}
			for _, c in named do
				if not table.find(list, c) then
					table.insert(list, c)
				end
			end
			own = list
		end
	end
	if own then
		return own
	end
	local cols = table.clone(FACET_COLUMNS)
	table.insert(cols, 3, Query.KIND)
	if events then
		for _, c in EVENT_FACETS do
			table.insert(cols, c)
		end
	end
	return cols
end

local function facets(tables: { SnapshotTable }, events: boolean): { Facet }
	local out: { Facet } = {}
	local cols = facetColumns(tables, events)
	for _, col in cols do
		local f = facet(tables, col)
		if f then
			table.insert(out, f)
		end
	end
	return out
end

local function problemCount(tables: { SnapshotTable }): number
	local n = 0
	for _, tbl in tables do
		for _, row in tbl.rows do
			if Query.isProblem(tbl, row) then
				n += 1
			end
		end
	end
	return n
end

local function chipsNode(capture: Capture, tables: { SnapshotTable }, vs: ViewState, events: boolean): Node?
	local groups: { Node } = {}
	local problems = problemCount(tables)
	if problems > 0 or vs.problems then
		table.insert(
			groups,
			chip(
				"Problems " .. problems,
				Viewstate.action(Viewstate.toggledProblems(vs)),
				vs.problems,
				"Only rows that are failing, not ready, or restarted in the last hour",
				"problems"
			)
		)
	end
	for _, f in facets(tables, events) do
		local items: { Node } = { ui.text({ ui.span(f.col, "muted") }, { role = "tern-kube.facet-label" }) }
		local shown = 0
		local active: { [string]: boolean } = {}
		for _, filter in vs.filters do
			local col, value = Viewstate.splitFilter(filter)
			if col == f.col then
				active[value] = true
			end
		end
		local expanded = table.find(vs.expanded, f.col) ~= nil
		for _, entry in f.values do
			local on = active[entry.value] == true
			if not expanded and shown >= M.FACET_VALUES and not on then
				continue
			end
			shown += 1
			table.insert(
				items,
				chip(
					entry.value .. " " .. entry.count,
					Viewstate.action(Viewstate.toggledFilter(vs, f.col, entry.value)),
					on,
					nil,
					f.col .. "=" .. entry.value
				)
			)
		end
		local toggle = Viewstate.action(Viewstate.toggledExpanded(vs, f.col))
		if #f.values > shown then
			table.insert(
				items,
				ui.badge("+" .. (#f.values - shown), "neutral", {
					key = f.col .. "/more",
					title = "Show every " .. f.col .. " value",
					actions = { click = toggle },
					role = "tern-kube.more",
				})
			)
		elseif expanded and #f.values > M.FACET_VALUES then
			table.insert(
				items,
				ui.badge("Fewer", "neutral", {
					key = f.col .. "/more",
					title = "Show the " .. M.FACET_VALUES .. " most frequent " .. f.col .. " values",
					actions = { click = toggle },
					role = "tern-kube.more",
				})
			)
		end
		table.insert(groups, ui.row(items, { key = "facet-" .. f.col, wrap = true, role = "tern-kube.facet" }))
	end
	if #vs.filters > 0 or vs.problems then
		table.insert(groups, chip("Clear filters", Viewstate.action(Viewstate.clearedFilters(vs)), false, nil, "clear"))
	end
	-- Explore lists the same query and filters it by text; lenses take no input.
	if Command.exploreFilterUrl(capture.invocation) then
		table.insert(
			groups,
			ui.badge("Filter in Explore", "accent", {
				key = "explore-filter",
				title = "The same list in the Explore block with its text filter open (runs kubectl)",
				actions = { click = "explore-filter=1" },
				role = "tern-kube.explore-filter",
			})
		)
	end
	if Command.exploreUsageUrl(capture.invocation) then
		local title = "kubectl top shows usage only; Explore adds requests, limits and allocatable (runs kubectl)"
		if capture.invocation.flags["field-selector"] then
			title ..= "; --field-selector is not carried"
		end
		table.insert(
			groups,
			ui.badge("Usage vs requests in Explore", "accent", {
				key = "explore-usage",
				title = title,
				actions = { click = "explore-usage=1" },
				role = "tern-kube.explore-usage",
			})
		)
	end
	if #groups == 0 then
		return nil
	end
	return ui.row(groups, { key = "chips", wrap = true, role = "tern-kube.chips" })
end

local function containersOf(tbl: SnapshotTable, row: ResourceRow): number?
	local index = columnIndex(tbl, "READY")
	if index == nil then
		return nil
	end
	local _, den = Values.ratio(row.cells[index] or "")
	return den
end

-- Service ports from a PORT(S) cell (`80/TCP`, `80:30080/TCP,443/TCP`): the
-- service port of each entry, in order; `<none>` and junk give none.
function M.servicePorts(cell: string): { number }
	local out: { number } = {}
	for part in string.gmatch(cell, "[^,]+") do
		local digits = string.match(part, "^%s*(%d+)[:/]")
		local n = if digits then tonumber(digits) else nil
		if n and n >= 1 and n <= 65535 then
			table.insert(out, n)
		end
	end
	return out
end

-- Shell / Logs / Port-forward chips (plus debug and CronJob run-now when
-- mutations are enabled); each opens a new split through the window's
-- route.link. They never touch the view state.
local function quickChips(
	capture: Capture,
	tbl: SnapshotTable,
	row: ResourceRow,
	ref: Types.ResourceRef,
	mutations: boolean,
	quick: Quick.Settings?
): { Node }
	local ports: { number }? = nil
	local index = columnIndex(tbl, "PORT(S)")
	if ref.kind == "Service" and index then
		ports = M.servicePorts(row.cells[index] or "")
	end
	local inv = capture.invocation
	local out: { Node } = {}
	for _, c in
		Quick.chipsFor(ref.kind, ref, { context = inv.context, kubeconfig = inv.kubeconfig }, {
			source = "lens",
			ports = ports,
			allowMutations = mutations,
		}, quick)
	do
		table.insert(
			out,
			ui.badge(
				c.label,
				"info",
				{ title = c.title, actions = { click = "act=" .. c.url }, role = "tern-kube.quick" }
			)
		)
	end
	return out
end

-- What a Node row's STATUS says about scheduling (`Ready,SchedulingDisabled`);
-- nil when the row has no STATUS column. Deployments' paused state is not in
-- any table column, so it stays unknown (both Pause and Resume show).
function M.rowState(tbl: SnapshotTable, row: ResourceRow, ref: Types.ResourceRef): Link.ObjState?
	if ref.kind ~= "Node" then
		return nil
	end
	local index = columnIndex(tbl, "STATUS")
	if index == nil then
		return nil
	end
	local status = row.cells[index] or ""
	return { unschedulable = string.find(status, "SchedulingDisabled", 1, true) ~= nil }
end

-- Mutation chips: tern-kube://mutate links the window routes to the approve
-- block, which previews before anything runs.
local function mutationChips(capture: Capture, tbl: SnapshotTable, row: ResourceRow, ref: Types.ResourceRef): { Node }
	local inv = capture.invocation
	local origin: Link.Origin = {
		context = inv.context,
		source = if inv.context then "flag" else nil,
		kubeconfig = inv.kubeconfig,
	}
	local out: { Node } = {}
	for _, m in Link.chips(ref, origin, M.rowState(tbl, row, ref)) do
		table.insert(
			out,
			ui.badge(
				m.label,
				"warning",
				{ title = m.title, actions = { click = "mutate=" .. m.url }, role = "tern-kube.mutate" }
			)
		)
	end
	return out
end

-- `-o json` rows carry the object (release annotations); plain tables only
-- know the release from `--show-labels` (instance label, no namespace
-- annotation, so the row's namespace).
local function helmOwner(capture: Capture, tbl: SnapshotTable, row: ResourceRow, ref: Types.ResourceRef): Owner.Owner?
	local object = if capture.objects then capture.objects[row.key] else nil
	if object ~= nil then
		return Owner.fromObject(object)
	end
	local index = columnIndex(tbl, "LABELS")
	if index == nil then
		return nil
	end
	return Owner.fromObject({
		metadata = { labels = HelmChip.labels(row.cells[index] or ""), namespace = ref.namespace },
	})
end

local function actionChips(
	capture: Capture,
	tbl: SnapshotTable,
	row: ResourceRow,
	vs: ViewState,
	mutations: boolean,
	quick: Quick.Settings?
): { Node }
	local out: { Node } = {}
	if not vs.full then
		table.insert(
			out,
			chip("Inspect", Viewstate.action(Viewstate.inspect(vs, row.key)), false, "All details for this row")
		)
	end
	-- k9s-parity rows (history, contexts, api-resources, can-i) have their own chips.
	local own = LensChips.rowChips(capture, row.key, { mutations = mutations, quick = quick })
	for _, n in LensChips.nodes(own or {}) do
		table.insert(out, n)
	end
	local ref = if own then nil else row.ref
	if ref then
		table.insert(
			out,
			ui.badge("Explore live", "accent", {
				title = "Open the Explore block (may run kubectl)",
				actions = { click = "explore=" .. row.key },
			})
		)
		table.insert(
			out,
			ui.badge("Manifest", "accent", {
				title = "Find its manifest in this shell's repository and open it at the line",
				actions = { click = "explore-route=manifest|" .. row.key },
			})
		)
		table.insert(
			out,
			ui.badge("Diff vs manifest", "accent", {
				title = "kubectl diff of its manifest against the live object (Explore)",
				actions = { click = "explore-route=diff|" .. row.key },
			})
		)
		table.insert(
			out,
			ui.badge("Compare across contexts", "accent", {
				title = "This object in another context of the kubeconfig, side by side (Explore, read-only)",
				actions = { click = "explore-route=compare|" .. row.key },
			})
		)
		if Command.exploreUsageUrl(capture.invocation, nil, ref) then
			table.insert(
				out,
				ui.badge("Usage in Explore", "accent", {
					title = if ref.kind == "Node"
						then "The pods on this node against requests and allocatable (Explore, runs kubectl)"
						else "This pod's containers against requests and limits (Explore, runs kubectl)",
					actions = { click = "explore-route=usage|" .. row.key },
				})
			)
		end
		if capture.events then
			local label = string.lower(ref.kind) .. "/" .. ref.name
			table.insert(
				out,
				ui.badge("Events for " .. label, "accent", {
					title = "The events timeline of " .. label .. " in Explore (runs kubectl get events)",
					actions = { click = "explore-route=events|" .. row.key },
				})
			)
		end
		local helm = HelmChip.node(helmOwner(capture, tbl, row, ref), "helm")
		if helm then
			table.insert(out, helm)
		end
		for _, n in quickChips(capture, tbl, row, ref, mutations, quick) do
			table.insert(out, n)
		end
		if mutations then
			for _, n in mutationChips(capture, tbl, row, ref) do
				table.insert(out, n)
			end
		end
		local inv = capture.invocation
		local opts = { containers = containersOf(tbl, row) }
		local copies: { { string } } = {
			{ "name", "Copy name" },
			{ "id", "Copy id" },
			{ "describe", "Copy describe" },
			{ "logs", "Copy logs" },
			{ "get-yaml", "Copy get -o yaml" },
		}
		for _, c in copies do
			local text = Command.copyText(c[1] :: any, inv, ref, opts)
			if text then
				table.insert(
					out,
					ui.badge(c[2], "neutral", { title = text, actions = { click = "copy=" .. c[1] .. "|" .. row.key } })
				)
			end
		end
	end
	if vs.full then
		table.insert(out, chip("Back", Viewstate.action(Viewstate.back(vs)), false, "Back to the table"))
	else
		table.insert(out, chip("Close", Viewstate.action(Viewstate.opened(vs, row.key)), false))
	end
	return out
end

local function cellItems(capture: Capture, tbl: SnapshotTable, row: ResourceRow): { { { ui.SpanLike } } }
	local items: { { { ui.SpanLike } } } = table.create(#tbl.headers)
	local note = if capture.events then capture.events.notes[row.key] else nil
	for i, h in tbl.headers do
		local v = row.cells[i] or ""
		local value: { ui.SpanLike } = { if Values.isPlaceholder(v) then ui.span(v, "muted") else ui.span(v) }
		if note and h == "LAST SEEN" then
			table.insert(value, ui.span(" " .. note, "muted"))
		end
		items[i] = { { ui.span(h, "muted") }, value }
	end
	return items
end

local function inspector(
	capture: Capture,
	tbl: SnapshotTable,
	row: ResourceRow,
	vs: ViewState,
	mutations: boolean,
	quick: Quick.Settings?
): Node
	return ui.col({
		ui.kv(cellItems(capture, tbl, row)),
		ui.row(actionChips(capture, tbl, row, vs, mutations, quick), { wrap = true }),
	}, { role = "tern-kube.inspector" })
end

local function sourceLines(capture: Capture, row: ResourceRow): string?
	if #row.rawLines == 0 then
		return nil
	end
	local out: { string } = {}
	for _, n in row.rawLines do
		local l = capture.lines[n]
		if l then
			table.insert(out, l)
		end
	end
	return if #out > 0 then table.concat(out, "\n") else nil
end

-- `single`: the capture's only object (`-o json` of one name), shown
-- without a table to go back to.
function M.inspectView(
	capture: Capture,
	tbl: SnapshotTable,
	row: ResourceRow,
	vs: ViewState,
	mutations: boolean?,
	quick: Quick.Settings?,
	single: boolean?
): Node
	local back = Viewstate.action(Viewstate.back(vs))
	local name = if row.ref then row.ref.name else row.cells[1] or row.key
	local crumbs = ui.row({
		if single
			then ui.badge("Snapshot", "neutral")
			else ui.badge("Snapshot", "neutral", { actions = { click = back }, title = "Back to the table" }),
		ui.text({ ui.span("›", "muted") }),
		ui.text({ ui.span(tbl.kind or "rows", "muted") }),
		ui.text({ ui.span("›", "muted") }),
		ui.text({ ui.span(name, "strong") }),
	}, { key = "crumbs", role = "tern-kube.breadcrumb" })
	local chips = actionChips(capture, tbl, row, vs, mutations == true, quick)
	if single then
		table.remove(chips)
	end
	local object = if capture.objects then capture.objects[row.key] else nil
	-- Two gates: the policy shows Secret values, and this view asked for them.
	local decodable = object ~= nil and capture.policy.showSecrets and SecretData.decodable(object)
	if decodable then
		table.insert(
			chips,
			ui.badge(SecretDataView.label(vs.decoded, nil), if vs.decoded then "accent" else "warning", {
				key = "decode",
				title = if vs.decoded
					then "Hide the decoded values"
					else "Show this Secret's values decoded in a separate card (display only; the tree stays base64)",
				actions = { click = Viewstate.action(Viewstate.toggledDecoded(vs)) },
			})
		)
	end
	local children: { Node } = {
		crumbs,
		ui.row(chips, { key = "actions", wrap = true }),
		ui.section({ "Columns" }, { ui.kv(cellItems(capture, tbl, row)) }, { key = "cells", collapsible = single }),
	}
	local source = sourceLines(capture, row)
	if source then
		table.insert(children, ui.section({ "Source" }, { ui.code(source) }, { key = "source", collapsible = true }))
	end
	if decodable and vs.decoded then
		table.insert(
			children,
			SecretDataView.card(SecretData.entries(object), { key = "decoded", hint = "Hide decoded" })
		)
	end
	if object ~= nil then
		table.insert(
			children,
			ui.section(
				{ "Object" },
				{ Objtree.tree(object, { id = row.key, policy = capture.policy }) },
				{ key = "object", collapsible = true }
			)
		)
	end
	return ui.col(children, { key = "inspect", role = "tern-kube.inspect" })
end

type Slice = { tbl: SnapshotTable, index: number, rows: { ResourceRow }, matched: number }

local function pageChips(matched: number, vs: ViewState, size: number): Node
	local pages = math.ceil(matched / size)
	local first = vs.page * size + 1
	local last = math.min(matched, (vs.page + 1) * size)
	local items: { Node } = {
		ui.text({ ui.span(string.format("Rows %d-%d of %d", first, last, matched), "muted") }),
	}
	for p = 0, pages - 1 do
		local from = p * size + 1
		local to = math.min(matched, (p + 1) * size)
		table.insert(
			items,
			chip(from .. "-" .. to, Viewstate.action(Viewstate.paged(vs, p)), p == vs.page, nil, "page" .. p)
		)
	end
	return ui.row(items, { key = "pages", wrap = true, role = "tern-kube.pages" })
end

-- Counts and quantities are read for their largest values first.
local DESC_FIRST: { [Types.ColumnType]: boolean } = { count = true, quantity = true, percent = true, number = true }
local MIDDLE: { [string]: boolean } = { NAME = true }

-- Event listings read newest first (LAST SEEN ascending) unless the user
-- chose an order (a column click or kubectl's --sort-by).
local function effectiveView(capture: Capture, tables: { SnapshotTable }, vs: ViewState): ViewState
	if vs.sort ~= nil or capture.events == nil or capture.invocation.sortBy ~= nil then
		return vs
	end
	for _, tbl in tables do
		if columnIndex(tbl, "LAST SEEN") then
			local out = table.clone(vs)
			out.sort = "LAST SEEN"
			return out
		end
	end
	return vs
end

-- `kubectl top --sum` totals as one line under the rows (`Total 101m CPU ·
-- 835Mi memory`): kubectl's sum over the whole capture, so filters and
-- sorting leave it alone.
local function totalsNode(tables: { SnapshotTable }, totals: { [number]: { string } }): Node?
	local spans: { ui.SpanLike } = { ui.span("Total", "muted") }
	local parts = 0
	for i, tbl in tables do
		local cells = totals[i]
		if cells == nil then
			continue
		end
		for c, h in tbl.headers do
			local v = cells[c] or ""
			if v == "" then
				continue
			end
			local label = string.gsub(h, "%(.*%)$", "")
			if label ~= "CPU" then
				label = string.lower(label)
			end
			table.insert(spans, ui.span(if parts == 0 then " " else " · ", "muted"))
			table.insert(spans, ui.span(v, "strong mono"))
			table.insert(spans, ui.span(" " .. label))
			parts += 1
		end
	end
	if parts == 0 then
		return nil
	end
	return ui.text(spans, {
		key = "totals",
		role = "tern-kube.totals",
		title = "kubectl top --sum over every row of the capture, whatever the filters",
	})
end

function M.render(capture: Capture, given: ViewState, opts: Options?): (Node?, Counts)
	local size = if opts and opts.pageSize and opts.pageSize >= 1 then opts.pageSize else M.PAGE_SIZE
	local mutations = opts ~= nil and opts.mutations == true
	local quick = if opts then opts.quick else nil
	local snapshot = capture.snapshot
	local tables: { SnapshotTable } = if snapshot then snapshot.tables else {}
	local total = 0
	for _, tbl in tables do
		total += #tbl.rows
	end
	if #tables == 0 then
		return nil, { shown = 0, matched = 0, total = 0 }
	end
	local vs = effectiveView(capture, tables, given)

	if capture.mode == "json" and total == 1 then
		local tbl = tables[1]
		local row = tbl.rows[1]
		return M.inspectView(capture, tbl, row, Viewstate.inspect(vs, row.key), mutations, quick, true),
			{ shown = 1, matched = 1, total = 1 }
	end

	if vs.full and vs.open then
		local row, tbl = Capture.findRow(capture, vs.open)
		if row and tbl then
			return M.inspectView(capture, tbl, row, vs, mutations, quick), { shown = 1, matched = 1, total = total }
		end
	end

	local slices: { Slice } = {}
	local matched = 0
	for i, tbl in tables do
		local result = Query.apply(tbl, vs)
		matched += result.matched
		table.insert(slices, { tbl = tbl, index = i, rows = result.rows, matched = result.matched })
	end
	local pages = math.max(1, math.ceil(matched / size))
	local page = math.min(vs.page, pages - 1)
	local skip = page * size
	local budget = size

	local children: { Node } = {}
	local events = capture.events
	local chips = chipsNode(capture, tables, vs, events ~= nil)
	if chips then
		table.insert(children, chips)
	end
	local multi = #tables > 1
	local shown = 0
	for _, slice in slices do
		local tbl = slice.tbl
		local rows = slice.rows
		local from = 1
		if skip > 0 then
			local skipped = math.min(skip, #rows)
			skip -= skipped
			from = skipped + 1
		end
		local to = math.min(#rows, from + budget - 1)
		local function sortAction(col: string): string
			local index = columnIndex(tbl, col)
			local descFirst = index ~= nil and DESC_FIRST[tbl.types[index]] == true
			return Viewstate.action(Viewstate.sortedBy(vs, col, descFirst))
		end
		local count = math.max(0, to - from + 1)
		budget -= count
		shown += count
		if multi then
			if count == 0 and (#vs.filters > 0 or vs.problems) then
				continue
			end
			local head: { Node } = {
				ui.text({ ui.span(tbl.title or tbl.kind or ("Table " .. slice.index), "strong") }),
				ui.text({ ui.span(tostring(slice.matched), "muted") }),
			}
			for _, b in Summary.summarize(tbl) do
				table.insert(head, b)
			end
			table.insert(children, ui.row(head, { key = "kind" .. slice.index, role = "tern-kube.kind" }))
		else
			local badges = Summary.summarize(tbl)
			if #badges > 0 then
				table.insert(children, ui.row(badges, { key = "summary", role = "tern-kube.summary" }))
			end
		end
		if count == 0 then
			continue
		end
		local typeCol = if events then columnIndex(tbl, "TYPE") else nil
		local seenCol = if events then columnIndex(tbl, "LAST SEEN") else nil
		local gridRows: { Grid.GridRow } = table.create(count)
		for i = from, to do
			local row = rows[i]
			local open = vs.open == row.key
			local note = if events and seenCol then events.notes[row.key] else nil
			local notes: { [number]: string }? = if note and seenCol then { [seenCol] = note } else nil
			local k9sNotes = if capture.k9s then capture.k9s.notes[row.key] else nil
			if k9sNotes then
				local byIndex: { [number]: string } = notes or {}
				for col, text in k9sNotes do
					local index = columnIndex(tbl, col)
					if index then
						byIndex[index] = text
					end
				end
				notes = byIndex
			end
			gridRows[i - from + 1] = {
				key = row.key,
				cells = row.cells,
				action = Viewstate.action(Viewstate.opened(vs, row.key)),
				open = open,
				class = if typeCol and row.cells[typeCol] == "Warning" then "tk-lvl-warn" else nil,
				notes = notes,
			}
		end
		table.insert(
			children,
			Grid.grid({
				key = "g" .. slice.index,
				headers = tbl.headers,
				types = tbl.types,
				rows = gridRows,
				sortCol = vs.sort,
				desc = vs.desc,
				sortAction = sortAction,
				middle = MIDDLE,
				inspector = function(rowKey: string): Node?
					local row = Capture.findRow(capture, rowKey)
					return if row then inspector(capture, tbl, row, vs, mutations, quick) else nil
				end,
			})
		)
	end
	local totals = if capture.totals then totalsNode(tables, capture.totals) else nil
	if totals then
		table.insert(children, totals)
	end
	if matched == 0 then
		local text = if total == 0 then "No rows" else "No rows match the filters"
		table.insert(children, ui.text({ ui.span(text, "muted") }, { key = "nomatch" }))
	end
	if matched > size then
		table.insert(children, pageChips(matched, Viewstate.paged(vs, page), size))
	end
	return ui.col(children, { key = "table", role = "tern-kube.table" }),
		{
			shown = shown,
			matched = matched,
			total = total,
		}
end

return M
