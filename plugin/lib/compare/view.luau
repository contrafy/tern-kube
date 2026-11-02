--!strict
-- Views of the compare routes: the context picker, the object fan-out (one
-- row per context), the list / drift matrix (rows = objects, columns =
-- contexts, base first) and the pairwise object diff. Every state is spelled
-- out in the cell (colour only repeats it), and every side says which
-- context and server it came from. Pure: plain `{k,p,c}` tables.

local Contexts = require("./contexts")
local Grid = require("../render/grid")
local Model = require("./model")
local Objdiff = require("../mutation/objdiff")
local SegCard = require("../render/segcard")
local Types = require("../model/types")
local ui = require("../ui")

type Node = ui.Node
type Cell = Model.Cell
type Column = Model.Column
type Matrix = Model.Matrix
type Filter = Model.Filter
type Choice = Contexts.Choice
type GridRow = Grid.GridRow
type ColumnType = Types.ColumnType

-- Rows first..last of a long matrix (the caller's scrolled window).
export type Window = { first: number, last: number }

export type MatrixOpts = {
	narrow: boolean,
	filter: Filter,
	title: string,
	-- The other context [ and ] selected (its column is marked); nil = none.
	context: string?,
	window: Window?,
	-- Shown instead of the filter's own text when no row is left.
	empty: string?,
}

local M = {}

M.STATE_TEXT = {
	base = "present",
	same = "same",
	changed = "changed",
	missing = "missing",
	extra = "extra",
	insync = "in sync",
	unmanaged = "unmanaged",
	absent = "-",
	error = "error",
	pending = "pending",
} :: { [string]: string }

local STATE_STYLE: { [string]: string } = {
	base = "muted",
	same = "muted",
	insync = "success",
	changed = "info strong",
	missing = "warning strong",
	extra = "warning strong",
	unmanaged = "warning strong",
	absent = "muted",
	error = "error strong",
	pending = "muted",
}

-- The f filter's chip text.
M.FILTER_TEXT = {
	all = "all",
	differs = "differs",
	presence = "missing or extra",
} :: { [string]: string }

local FILTER_EMPTY: { [string]: string } = {
	all = "Nothing to compare: no objects on any side.",
	differs = "No object differs between the contexts (f shows all).",
	presence = "No object is missing or extra in any context (f shows all).",
}

local function clock(at: number?): string
	return if at then os.date("!%H:%M:%S UTC", at) :: string else ""
end

-- `changed +4 -3` when the cell knows its line counts.
function M.cellText(cell: Cell): string
	local text = M.STATE_TEXT[cell.state] or cell.state
	if cell.state == "changed" and cell.added and cell.removed then
		text ..= string.format(" +%d -%d", cell.added, cell.removed)
	end
	return text
end

-- The tone class sits on an `el`: Tern drops `class` on text nodes.
local function cellNode(cell: Cell): Node
	return ui.el("div", {
		class = "tk-cmp tk-cmp-" .. cell.state,
		title = if cell.paths then table.concat(cell.paths, "\n") else nil,
	}, { ui.text({ ui.span(M.cellText(cell), STATE_STYLE[cell.state]) }) })
end

local function objectName(row: Model.Row): string
	local ref = row.ref
	return string.lower(ref.kind) .. "/" .. ref.name
end

-- Marks the selected row and the selected column's header.
local function mark(grid: Node, selKey: string?, colIndex: number?)
	local inner = grid.c and grid.c[1]
	local children: { Node } = if inner and inner.c then inner.c else {}
	for _, child in children do
		local p = child.p
		if p == nil then
			continue
		end
		if selKey and p.key == selKey then
			p.class ..= " tk-sel"
		elseif colIndex and p.key == "h" .. colIndex then
			p.class ..= " tk-cmp-col"
		end
	end
end

local function paged(grid: Node, first: number, last: number, total: number): { Node }
	local out: { Node } = {}
	if first > 1 then
		table.insert(
			out,
			ui.muted(
				string.format("↑ %d above (k, pageup, gg)", first - 1),
				{ key = "above", role = "tern-kube.overflow", actions = { click = "page=up" } }
			)
		)
	end
	table.insert(out, grid)
	if last < total then
		table.insert(
			out,
			ui.muted(
				string.format("↓ %d below (j, pagedown, G; / filters)", total - last),
				{ key = "overflow", role = "tern-kube.overflow", actions = { click = "page=down" } }
			)
		)
	end
	return out
end

local function keepAll(headers: { string }): { [string]: boolean }
	local keep: { [string]: boolean } = {}
	for _, h in headers do
		keep[h] = true
	end
	return keep
end

-- `role` is on the wrapper: Tern exposes roles and classes, not keys.
local function grid(key: string, role: string, headers: { string }, rows: { GridRow }): Node
	local types: { ColumnType } = table.create(#headers, "text" :: ColumnType)
	local g = Grid.grid({
		key = key,
		headers = headers,
		types = types,
		rows = rows,
		sortCol = nil,
		desc = false,
		sortAction = function(_col: string): string
			return "noop"
		end,
		sortable = false,
		keep = keepAll(headers),
		class = "tk-cmp-grid",
	});
	(g.p :: { [string]: any }).role = role
	return g
end

local function columnSummary(m: Matrix, i: number): string
	local c = m.columns[i]
	if c.status == "error" then
		return c.label .. ": error: " .. (c.error or "kubectl failed")
	elseif c.status ~= "ok" then
		return c.label .. ": " .. (if c.status == "running" then "fetching …" else "waiting")
	end
	local counts: { [string]: number } = {}
	for _, row in m.rows do
		local cell = row.cells[i]
		if cell then
			counts[cell.state] = (counts[cell.state] or 0) + 1
		end
	end
	local parts: { string } = {}
	for _, state in { "same", "insync", "changed", "missing", "extra", "unmanaged", "error" } do
		local n = counts[state]
		if n then
			table.insert(parts, string.format("%d %s", n, M.STATE_TEXT[state]))
		end
	end
	return c.label .. ": " .. (if #parts > 0 then table.concat(parts, ", ") else "nothing")
end

-- Rows = objects, columns = contexts (base first). `sel` is a row key.
function M.matrix(m: Matrix, sel: string?, opts: MatrixOpts): { Node }
	local out: { Node } = { ui.text({ ui.span(opts.title, "strong") }, { key = "title" }) }
	local headers: { string } = { "OBJECT" }
	local colIndex: number? = nil
	for i, c in m.columns do
		headers[i + 1] = if opts.narrow then c.label else c.context
		if opts.context == c.context and i > 1 then
			colIndex = i + 1
		end
	end
	local shortened = false
	for _, c in m.columns do
		if c.label ~= c.context then
			shortened = true
		end
	end
	if opts.narrow and shortened then
		local legend: { string } = {}
		for _, c in m.columns do
			table.insert(legend, c.label .. " = " .. c.context)
		end
		table.insert(out, ui.muted(table.concat(legend, " · "), { key = "legend", role = "tern-kube.compare-legend" }))
	end
	local counts: { Node } = {}
	-- A drift matrix's first column holds states too; a compare base holds
	-- only present / absent.
	local baseStates = false
	for _, row in m.rows do
		local state = if row.cells[1] then row.cells[1].state else "pending"
		if state ~= "base" and state ~= "absent" and state ~= "error" and state ~= "pending" then
			baseStates = true
			break
		end
	end
	for i = if baseStates then 1 else 2, #m.columns do
		table.insert(counts, ui.muted(columnSummary(m, i), { key = "n" .. i }))
	end
	table.insert(out, ui.col(counts, { key = "counts", role = "tern-kube.compare-counts" }))
	for i, note in m.notes do
		table.insert(out, ui.muted(note, { key = "note" .. i }))
	end
	local total = #m.rows
	if total == 0 then
		table.insert(out, ui.muted(opts.empty or FILTER_EMPTY[opts.filter] or FILTER_EMPTY.all, { key = "empty" }))
		return out
	end
	local w = opts.window
	local first = if w then math.max(1, w.first) else 1
	local last = if w then math.min(total, w.last) else total
	local rows: { GridRow } = table.create(math.max(0, last - first + 1))
	for r = first, last do
		local row = m.rows[r]
		local cells: { string } = { objectName(row) }
		local built: { [number]: Node } = {}
		for i = 1, #m.columns do
			local cell: Cell = row.cells[i] or { state = "pending" }
			cells[i + 1] = M.cellText(cell)
			built[i + 1] = cellNode(cell)
		end
		table.insert(rows, { key = row.key, cells = cells, nodes = built, action = "open=" .. row.key })
	end
	local g = grid("matrix", "tern-kube.compare-matrix", headers, rows)
	mark(g, sel, colIndex)
	for _, n in paged(g, first, last, total) do
		table.insert(out, n)
	end
	return out
end

-- One object across contexts: one row per context, base first. `sel` is a
-- context name; rows open the pairwise diff (act `open=<context>`).
function M.fanout(m: Matrix, sel: string?, opts: MatrixOpts): { Node }
	local out: { Node } = { ui.text({ ui.span(opts.title, "strong") }, { key = "title" }) }
	for i, note in m.notes do
		table.insert(out, ui.muted(note, { key = "note" .. i }))
	end
	local row = m.rows[1]
	local rows: { GridRow } = {}
	for i, c in m.columns do
		local cell: Cell = if row and row.cells[i]
			then row.cells[i]
			elseif c.status == "error" then { state = "error" }
			else { state = "pending" }
		local state = if i == 1 then "base" else M.cellText(cell)
		local changes = if c.status == "error"
			then c.error or "kubectl failed"
			elseif cell.paths then table.concat(cell.paths, ", ")
			else ""
		table.insert(rows, {
			key = c.context,
			cells = { c.context, c.server or "", state, changes, clock(c.fetchedAt) },
			nodes = { [3] = if i == 1 then ui.text({ ui.span("base", "muted") }) else cellNode(cell) },
			action = "open=" .. c.context,
		})
	end
	local g = grid("fanout", "tern-kube.compare-fanout", { "CONTEXT", "SERVER", "STATE", "CHANGES", "FETCHED" }, rows)
	mark(g, sel, nil)
	table.insert(out, g)
	return out
end

-- The other side(s) to compare with: one row per choice, `sel` a choice id.
function M.picker(choices: { Choice }, sel: string?): { Node }
	local out: { Node } = {
		ui.muted("Compare with which context? enter picks, / filters, esc goes back.", { key = "ask" }),
	}
	if #choices == 0 then
		table.insert(out, ui.muted("The kubeconfig has no other context.", { key = "empty" }))
		return out
	end
	local rows: { GridRow } = {}
	for _, c in choices do
		local note = c.disabled or c.warning or ""
		local style = if c.disabled then "error" elseif c.warning then "warning" else "muted"
		table.insert(rows, {
			key = c.id,
			cells = { c.label, c.note or "", note },
			nodes = { [3] = ui.text({ ui.span(note, style) }) },
			action = "open=" .. c.id,
			class = if c.disabled then "tk-cmp-disabled" else nil,
		})
	end
	local g = grid("picker", "tern-kube.compare-picker", { "COMPARE WITH", "SERVER", "NOTE" }, rows)
	mark(g, sel, nil)
	table.insert(out, g)
	return out
end

local function sideLine(word: string, c: Column): Node
	local spans: { ui.SpanLike } = { ui.span(word .. " ", "muted"), ui.span(c.context, "strong") }
	if c.server then
		table.insert(spans, ui.span("  " .. c.server, "muted mono"))
	end
	if c.status == "ok" then
		table.insert(spans, ui.span("  fetched " .. clock(c.fetchedAt), "muted"))
	elseif c.status == "error" then
		table.insert(spans, ui.span("  error: " .. (c.error or "kubectl failed"), "error"))
	else
		table.insert(spans, ui.span("  fetching …", "muted"))
	end
	return ui.text(spans, { key = "side-" .. word, role = "tern-kube.compare-side" })
end

local function statusLine(cell: Cell, cols: { Column }): Node
	local base, other = cols[1], cols[2]
	local text: string
	local style: string
	if cell.state == "same" then
		text, style = "same", "success strong"
	elseif cell.state == "changed" then
		text = if cell.added and cell.removed
			then string.format("differs (+%d -%d)", cell.added, cell.removed)
			else "differs"
		style = "info strong"
	elseif cell.state == "missing" then
		text, style = "missing in " .. other.context, "warning strong"
	elseif cell.state == "extra" then
		text, style = "missing in " .. base.context, "warning strong"
	elseif cell.state == "error" then
		text, style = "could not compare: a side failed", "error strong"
	else
		text, style = "fetching both sides …", "muted"
	end
	return ui.text({ ui.span(text, style) }, { key = "status", role = "tern-kube.compare-status" })
end

-- base vs one other context: provenance, state, the changed paths and the
-- diff (`-` base, `+` other). A missing object shows the present side,
-- collapsed.
function M.pair(cell: Cell, result: Objdiff.Result?, cols: { Column }, notice: string?): { Node }
	local out: { Node } = {
		sideLine("base", cols[1]),
		sideLine("other", cols[2]),
		statusLine(cell, cols),
	}
	if notice then
		table.insert(out, ui.muted(notice, { key = "notice", role = "tern-kube.notice" }))
	end
	local paths = cell.paths
	if paths and #paths > 0 then
		local items: { Node } = {}
		for i, p in paths do
			table.insert(items, ui.text({ ui.span(p, "mono") }, { key = "p" .. i }))
		end
		table.insert(out, ui.section({ "Differences" }, items, { key = "paths", role = "tern-kube.compare-paths" }))
	end
	if result then
		local presence = cell.state == "missing" or cell.state == "extra"
		for i, seg in result.summary.segments do
			table.insert(out, SegCard.card(seg, "seg" .. i, presence))
		end
	end
	return out
end

return M
