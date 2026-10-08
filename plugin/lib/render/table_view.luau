--!strict
-- Table, `-o name` and `-o json` snapshots: filter chips, one grid per
-- kubectl table (kind subheadings when there are several), the compact
-- inline inspector, the full Inspect view and pages of 500 rendered rows.

local Capture = require("../lens/capture")
local Command = require("../kubectl/command")
local Link = require("../mutation/link")
local Quick = require("../actions/quick")
local Grid = require("./grid")
local Objtree = require("./objtree")
local Query = require("../lens/query")
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
export type Options = { pageSize: number?, mutations: boolean? }

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

local function facets(tables: { SnapshotTable }): { Facet }
	local out: { Facet } = {}
	local cols = table.clone(FACET_COLUMNS)
	table.insert(cols, 3, Query.KIND)
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

local function chipsNode(tables: { SnapshotTable }, vs: ViewState): Node?
	local groups: { Node } = {}
	local problems = problemCount(tables)
	if problems > 0 or vs.problems then
		table.insert(
			groups,
			chip(
				"Problems " .. problems,
				Viewstate.action(Viewstate.toggledProblems(vs)),
				vs.problems,
				"Only rows that are failing, not ready or restarting",
				"problems"
			)
		)
	end
	for _, f in facets(tables) do
		local items: { Node } = { ui.text({ ui.span(f.col, "muted") }) }
		local shown = 0
		local active: { [string]: boolean } = {}
		for _, filter in vs.filters do
			local col, value = Viewstate.splitFilter(filter)
			if col == f.col then
				active[value] = true
			end
		end
		for _, entry in f.values do
			local on = active[entry.value] == true
			if shown >= M.FACET_VALUES and not on then
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
		if #f.values > shown then
			table.insert(items, ui.text({ ui.span("+" .. (#f.values - shown), "muted") }))
		end
		table.insert(groups, ui.row(items, { key = "facet-" .. f.col }))
	end
	if #vs.filters > 0 or vs.problems then
		table.insert(groups, chip("Clear filters", Viewstate.action(Viewstate.clearedFilters(vs)), false, nil, "clear"))
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
	mutations: boolean
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
		})
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

-- Delete / Restart / Scale chips: tern-kube://mutate links the window routes
-- to the approve block, which previews before anything runs.
local function mutationChips(capture: Capture, ref: Types.ResourceRef): { Node }
	local inv = capture.invocation
	local origin: Link.Origin = {
		context = inv.context,
		source = if inv.context then "flag" else nil,
		kubeconfig = inv.kubeconfig,
	}
	local out: { Node } = {}
	for _, m in Link.chips(ref, origin) do
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

local function actionChips(
	capture: Capture,
	tbl: SnapshotTable,
	row: ResourceRow,
	vs: ViewState,
	mutations: boolean
): { Node }
	local out: { Node } = {}
	if not vs.full then
		table.insert(
			out,
			chip("Inspect", Viewstate.action(Viewstate.inspect(vs, row.key)), false, "All details for this row")
		)
	end
	local ref = row.ref
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
		for _, n in quickChips(capture, tbl, row, ref, mutations) do
			table.insert(out, n)
		end
		if mutations then
			for _, n in mutationChips(capture, ref) do
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

local function cellItems(tbl: SnapshotTable, row: ResourceRow): { { { ui.SpanLike } } }
	local items: { { { ui.SpanLike } } } = table.create(#tbl.headers)
	for i, h in tbl.headers do
		local v = row.cells[i] or ""
		items[i] = { { ui.span(h, "muted") }, { if Values.isPlaceholder(v) then ui.span(v, "muted") else ui.span(v) } }
	end
	return items
end

local function inspector(
	capture: Capture,
	tbl: SnapshotTable,
	row: ResourceRow,
	vs: ViewState,
	mutations: boolean
): Node
	return ui.col({
		ui.kv(cellItems(tbl, row)),
		ui.row(actionChips(capture, tbl, row, vs, mutations), { wrap = true }),
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

function M.inspectView(capture: Capture, tbl: SnapshotTable, row: ResourceRow, vs: ViewState, mutations: boolean?): Node
	local back = Viewstate.action(Viewstate.back(vs))
	local name = if row.ref then row.ref.name else row.cells[1] or row.key
	local crumbs = ui.row({
		ui.badge("Snapshot", "neutral", { actions = { click = back }, title = "Back to the table" }),
		ui.text({ ui.span("›", "muted") }),
		ui.text({ ui.span(tbl.kind or "rows", "muted") }),
		ui.text({ ui.span("›", "muted") }),
		ui.text({ ui.span(name, "strong") }),
	}, { key = "crumbs", role = "tern-kube.breadcrumb" })
	local children: { Node } = {
		crumbs,
		ui.row(actionChips(capture, tbl, row, vs, mutations == true), { key = "actions", wrap = true }),
		ui.section({ "Columns" }, { ui.kv(cellItems(tbl, row)) }, { key = "cells" }),
	}
	local source = sourceLines(capture, row)
	if source then
		table.insert(children, ui.section({ "Source" }, { ui.code(source) }, { key = "source", collapsible = true }))
	end
	local object = if capture.objects then capture.objects[row.key] else nil
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

function M.render(capture: Capture, vs: ViewState, opts: Options?): (Node?, Counts)
	local size = if opts and opts.pageSize and opts.pageSize >= 1 then opts.pageSize else M.PAGE_SIZE
	local mutations = opts ~= nil and opts.mutations == true
	local snapshot = capture.snapshot
	local tables: { SnapshotTable } = if snapshot then snapshot.tables else {}
	local total = 0
	for _, tbl in tables do
		total += #tbl.rows
	end
	if #tables == 0 then
		return nil, { shown = 0, matched = 0, total = 0 }
	end

	if vs.full and vs.open then
		local row, tbl = Capture.findRow(capture, vs.open)
		if row and tbl then
			return M.inspectView(capture, tbl, row, vs, mutations), { shown = 1, matched = 1, total = total }
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
	local chips = chipsNode(tables, vs)
	if chips then
		table.insert(children, chips)
	end
	local multi = #tables > 1
	local shown = 0
	local sortAction = function(col: string): string
		return Viewstate.action(Viewstate.sortedBy(vs, col))
	end
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
		local count = math.max(0, to - from + 1)
		budget -= count
		shown += count
		if multi then
			if count == 0 and (#vs.filters > 0 or vs.problems) then
				continue
			end
			local head: { Node } = {
				ui.text({ ui.span(tbl.kind or ("Table " .. slice.index), "strong") }),
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
		local gridRows: { Grid.GridRow } = table.create(count)
		for i = from, to do
			local row = rows[i]
			local open = vs.open == row.key
			gridRows[i - from + 1] = {
				key = row.key,
				cells = row.cells,
				action = Viewstate.action(Viewstate.opened(vs, row.key)),
				open = open,
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
				inspector = function(rowKey: string): Node?
					local row = Capture.findRow(capture, rowKey)
					return if row then inspector(capture, tbl, row, vs, mutations) else nil
				end,
			})
		)
	end
	if matched == 0 then
		table.insert(children, ui.text({ ui.span("No rows match the filters", "muted") }, { key = "nomatch" }))
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
