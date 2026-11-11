--!strict
-- Tern's native `table` node for Explore's lists, built as a raw
-- `{k = "table", p = …}` table (the `tern.ui` builders cost ~50x more on
-- long lists, and only the node form takes `sort`/`sortable`).
--
-- Tern hides columns by the table's own width, lowest `priority` first, and
-- equal priorities hide the rightmost first, so every column gets a distinct
-- priority: NAME, then STATUS, READY, then the rest left to right, the long
-- `-o wide` columns last. Rows are keyed by the item key, so `select` and
-- `activate` events name the item and `selected` draws the cursor.

local Cells = require("./cells")
local Types = require("../model/types")
local Values = require("../model/values")
local ui = require("../ui")

type ColumnType = Types.ColumnType
type Node = ui.Node

export type Row = {
	key: string,
	cells: { string },
	action: string?,
	open: boolean?,
	-- Prebuilt cell nodes by column index, used instead of `cell`.
	nodes: { [number]: Node }?,
	-- Muted suffix appended to a cell, by column index.
	notes: { [number]: string }?,
	-- Prebuilt Tern table cells by column index (sparks, toned text with a
	-- title), used as they are.
	raw: { [number]: any }?,
}

export type Sort = { col: string, dir: string }

export type Spec = {
	key: string,
	headers: { string },
	types: { ColumnType },
	rows: { Row },
	selected: string?,
	cell: ((col: string, columnType: ColumnType, value: string, finished: boolean) -> Node)?,
	-- Headers take clicks (`action sort`); the caller sorts the rows.
	sortable: boolean?,
	-- By header name; the node carries the column id.
	sort: Sort?,
	-- Headers left out (NAMESPACE of a single-namespace scope).
	hide: { [string]: boolean }?,
	-- os.time() the rows were fetched at: CREATED timestamps show as AGE.
	now: number?,
	empty: string?,
	-- Headers that take no sort click even when `sortable` (trend columns).
	unsortable: { [string]: boolean }?,
}

local M = {}

M.MAX_COLUMNS = 16

local ESSENTIAL: { [string]: number } = { STATUS = 900, READY = 890, STATE = 880 }

local SECONDARY: { [string]: boolean } = {
	NAMESPACE = true,
	AGE = true,
	CREATED = true,
	RESTARTS = true,
	TYPE = true,
	KIND = true,
	["CPU(cores)"] = true,
	["MEMORY(bytes)"] = true,
	["UP-TO-DATE"] = true,
	AVAILABLE = true,
	COMPLETIONS = true,
	REASON = true,
	PHASE = true,
	REVISION = true,
	CHART = true,
}

local EXTRA: { [string]: boolean } = {
	LABELS = true,
	SELECTOR = true,
	IMAGES = true,
	CONTAINERS = true,
	CONDITIONS = true,
	["NOMINATED NODE"] = true,
	["READINESS GATES"] = true,
	["NODE SELECTOR"] = true,
	["KERNEL-VERSION"] = true,
	["CONTAINER-RUNTIME"] = true,
	["OS-IMAGE"] = true,
}

-- Long identifiers: cut in the middle so both ends (a pod's hash suffix, a
-- file name) stay readable; Tern cuts the text itself, so the whole value is
-- the cell's title.
local MIDDLE: { [string]: boolean } = { NAME = true, PATH = true, FILE = true, SOURCE = true, OBJECT = true }

local DESC_FIRST: { [string]: boolean } = { count = true, quantity = true, percent = true, number = true }

-- Index of the column that names the row: NAME, else the first.
local function nameIndex(headers: { string }): number
	return table.find(headers, "NAME") or 1
end

-- Higher is kept longer; distinct for every column.
function M.priority(headers: { string }, index: number): number
	local h = headers[index]
	if index == nameIndex(headers) then
		return 1000
	elseif ESSENTIAL[h] then
		return ESSENTIAL[h]
	elseif EXTRA[h] then
		return 200 - index
	elseif SECONDARY[h] or h == "" then
		-- A header-less column holds short tags (Helm history's latest,
		-- running, marked): kept before the prose around it.
		return 600 - index
	end
	return 400 - index
end

-- Unique, DOM-safe column ids derived from the headers.
function M.ids(headers: { string }): { string }
	local out: { string } = table.create(#headers)
	local used: { [string]: boolean } = {}
	for i, h in headers do
		local id = string.gsub(string.gsub(string.lower(h), "[^%w]+", "-"), "^%-*(.-)%-*$", "%1")
		if id == "" or used[id] then
			id = (if id == "" then "c" else id .. "-") .. i
		end
		used[id] = true
		out[i] = id
	end
	return out
end

-- The direction a first click on a column asks for: counts largest first.
function M.firstDir(columnType: ColumnType): string
	return if DESC_FIRST[columnType] then "desc" else "asc"
end

-- Compact age: 42s, 7m, 3h, 2d.
function M.age(seconds: number): string
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

-- `list` sorted by column `index` (typed), ties in input order. A timestamp
-- column reads as AGE: ascending is the youngest first.
function M.sorted<T>(list: { T }, cellsOf: (T) -> { string }, types: { ColumnType }, index: number, dir: string): { T }
	local columnType: ColumnType = types[index] or "text"
	local desc = dir == "desc"
	if columnType == "timestamp" then
		desc = not desc
	end
	local order: { number } = table.create(#list)
	for i = 1, #list do
		order[i] = i
	end
	table.sort(order, function(a: number, b: number): boolean
		local x: string = cellsOf(list[a])[index] or ""
		local y: string = cellsOf(list[b])[index] or ""
		if Values.compare(columnType, x, y, desc) then
			return true
		elseif Values.compare(columnType, y, x, desc) then
			return false
		end
		return a < b
	end)
	local out: { T } = table.create(#list)
	for i, at in order do
		out[i] = list[at]
	end
	return out
end

-- A grid cell node as a table cell: text spans (with their tooltip) or a badge.
function M.cellOf(node: Node): any
	local p: { [string]: any } = node.p or {}
	if node.k == "badge" then
		return { badge = { text = p.text or "", tone = p.tone, title = p.title } }
	elseif node.k == "text" then
		local spans = p.spans or {}
		if p.title then
			return { text = spans, title = p.title }
		end
		return spans
	end
	return { { t = if type(p.text) == "string" then p.text else "" } }
end

local function withNote(cell: any, note: string): any
	local muted = { t = " " .. note, s = "muted" }
	if type(cell) == "table" and cell.text then
		local spans = table.clone(cell.text)
		table.insert(spans, muted)
		local out = table.clone(cell)
		out.text = spans
		return out
	elseif type(cell) == "table" and cell.badge then
		return cell
	end
	local spans = if type(cell) == "string" then { { t = cell } } else table.clone(cell)
	table.insert(spans, muted)
	return spans
end

function M.table(spec: Spec): Node
	local headers, types = spec.headers, spec.types
	local hide = spec.hide or {}
	local ids = M.ids(headers)
	local n = math.min(#headers, M.MAX_COLUMNS)
	local nameAt = nameIndex(headers)
	local shown: { number } = {}
	local cols: { any } = {}
	local sortId: string? = nil
	for i = 1, n do
		local h = headers[i]
		if hide[h] then
			continue
		end
		table.insert(shown, i)
		local columnType: ColumnType = types[i] or "text"
		local age = columnType == "timestamp" and spec.now ~= nil
		local c: { [string]: any } = { id = ids[i], head = if age then "AGE" else h, priority = M.priority(headers, i) }
		if Cells.NUMERIC[columnType] or age then
			c.align = "end"
			c.mono = true
		end
		if i == nameAt then
			c.grow = 1
		end
		if MIDDLE[h] then
			c.truncate = "middle"
		end
		if spec.sortable and not (spec.unsortable and spec.unsortable[h]) then
			c.sortable = true
		end
		if spec.sort and spec.sort.col == h then
			sortId = ids[i]
		end
		table.insert(cols, c)
	end

	local cellFn = spec.cell
	local now = spec.now
	local rows: { any } = table.create(#spec.rows)
	for r, row in spec.rows do
		local values = row.cells
		local prebuilt = row.nodes
		local raw = row.raw
		local notes = row.notes
		local finished = Cells.rowFinished(types, values)
		local cells: { [string]: any } = {}
		for _, i in shown do
			local v = values[i] or ""
			local columnType: ColumnType = types[i] or "text"
			local cell: any
			if raw and raw[i] ~= nil then
				cell = raw[i]
			elseif prebuilt and prebuilt[i] then
				cell = M.cellOf(prebuilt[i])
			elseif columnType == "timestamp" and now then
				local at = Values.timestamp(v)
				cell = if at then { { t = M.age(now - at), s = "mono" } } else { { t = v, s = "muted" } }
			elseif cellFn then
				cell = M.cellOf(cellFn(headers[i], columnType, v, finished))
			else
				local style = Cells.style(headers[i], columnType, v, finished)
				cell = { if style then { t = v, s = style } else { t = v } }
			end
			if MIDDLE[headers[i]] and v ~= "" and type(cell) == "table" and cell.text == nil and cell.badge == nil then
				cell = { text = cell, title = v }
			end
			local note = if notes then notes[i] else nil
			if note then
				cell = withNote(cell, note)
			end
			cells[ids[i]] = cell
		end
		rows[r] = { id = row.key, cells = cells }
	end

	local p: { [string]: any } = {
		key = spec.key,
		cols = cols,
		rows = rows,
		selectable = true,
		selected = spec.selected,
		role = "tern-kube.table",
	}
	if spec.empty then
		p.empty = spec.empty
	end
	if sortId and spec.sort then
		p.sort = { col = sortId, dir = if spec.sort.dir == "desc" then "desc" else "asc" }
	end
	return { k = "table", p = p }
end

return M
