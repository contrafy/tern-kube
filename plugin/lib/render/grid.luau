--!strict
-- The shared clickable table: a CSS grid of `el` divs (Tern's `table` node
-- has no row actions and `el` tables ignore colspan). Rows are
-- `display: contents` so their cells align while the row keeps its click
-- action; the inline inspector spans every column. Built from plain tables:
-- a 500-row grid is thousands of nodes.
--
-- Narrow panes hide low-priority columns through container queries in
-- tern-kube.css. Hidden cells leave the grid flow, so the grid also carries
-- the visible column count for each width tier (tk-a-N, tk-b-N, tk-c-N).
--
-- `middle` columns (NAME, a log's SOURCE) truncate in the middle: the head
-- shrinks with an ellipsis, the tail that tells rows apart stays, and its
-- width is the column's minimum, so NAME keeps priority over long cells.

local Cells = require("./cells")
local Types = require("../model/types")
local ui = require("../ui")

type ColumnType = Types.ColumnType
type Node = ui.Node

export type GridRow = {
	key: string,
	cells: { string },
	action: string,
	open: boolean?,
	-- Extra row classes (`tk-lvl-error`), styled per row in the sheets.
	class: string?,
	-- Prebuilt cell nodes by column index, used instead of `cell`.
	nodes: { [number]: Node }?,
	-- Muted suffix appended to a text cell, by column index.
	notes: { [number]: string }?,
	-- A full-width separator drawn above the row (a date change).
	divider: string?,
}

export type Spec = {
	key: string,
	headers: { string },
	types: { ColumnType },
	rows: { GridRow },
	sortCol: string?,
	desc: boolean,
	sortAction: (col: string) -> string,
	inspector: ((rowKey: string) -> Node?)?,
	cell: ((col: string, columnType: ColumnType, value: string, finished: boolean) -> Node)?,
	-- false: headers are labels only (rows keep their order, e.g. a log).
	sortable: boolean?,
	-- Extra classes on the grid element.
	class: string?,
	-- Columns never hidden on narrow windows (a log's LEVEL and MESSAGE).
	keep: { [string]: boolean }?,
	-- Columns truncated in the middle (see the top of this file).
	middle: { [string]: boolean }?,
}

local M = {}

M.MAX_COLUMNS = 16

local MIDDLE_MIN = 12
local TAIL_MIN = 4
local TAIL_MAX = 17
local TAIL_FALLBACK = 8

-- Head and tail of a value: the tail starts at the last separator that
-- leaves at least TAIL_MIN characters (`-6jsgc`, `-x-0`); without one, the
-- last TAIL_FALLBACK characters. Short values are not split ("" tail).
function M.splitMiddle(s: string): (string, string)
	local n = #s
	if n <= MIDDLE_MIN then
		return s, ""
	end
	local pos = n
	while pos > 1 do
		local at = string.find(string.sub(s, 1, pos - 1), "[%-%._/][^%-%._/]*$")
		if at == nil or n - at + 1 > TAIL_MAX then
			break
		end
		if n - at + 1 >= TAIL_MIN and at > 1 then
			return string.sub(s, 1, at - 1), string.sub(s, at)
		end
		pos = at
	end
	return string.sub(s, 1, n - TAIL_FALLBACK), string.sub(s, n - TAIL_FALLBACK + 1)
end

-- A middle-truncated cell body; `style` is the span style of both parts.
function M.middleNode(value: string, style: string?): Node
	local head, tail = M.splitMiddle(value)
	local function part(class: string, text: string): Node
		return {
			k = "el",
			p = { tag = "div", class = class },
			c = { { k = "text", p = { spans = { if style then { t = text, s = style } else { t = text } } } } },
		}
	end
	local parts: { Node } = { part("tk-mid-h", head) }
	if tail ~= "" then
		table.insert(parts, part("tk-mid-t", tail))
	end
	return { k = "el", p = { tag = "div", class = "tk-mid" }, c = parts }
end

-- Never hidden: what identifies the row and whether it is healthy.
local ESSENTIAL: { [string]: boolean } = { NAME = true, STATUS = true, READY = true }

-- Kept until the narrowest tier.
local SECONDARY: { [string]: boolean } = {
	NAMESPACE = true,
	AGE = true,
	RESTARTS = true,
	TYPE = true,
	["CPU(cores)"] = true,
	["MEMORY(bytes)"] = true,
	["CPU%"] = true,
	["MEMORY%"] = true,
	["CPU(%)"] = true,
	["MEMORY(%)"] = true,
	["UP-TO-DATE"] = true,
	AVAILABLE = true,
	COMPLETIONS = true,
	REASON = true,
	MESSAGE = true,
	PHASE = true,
}

-- First to go: long or rarely needed `-o wide` / `--show-labels` columns.
local EXTRA: { [string]: boolean } = {
	LABELS = true,
	SELECTOR = true,
	IMAGES = true,
	CONTAINERS = true,
	["NOMINATED NODE"] = true,
	["READINESS GATES"] = true,
	["NODE SELECTOR"] = true,
	["KERNEL-VERSION"] = true,
	["CONTAINER-RUNTIME"] = true,
	["OS-IMAGE"] = true,
}

-- 0 = always shown, 3 = hidden first.
function M.priority(header: string, index: number): number
	if index == 1 or ESSENTIAL[header] then
		return 0
	elseif EXTRA[header] then
		return 3
	elseif SECONDARY[header] then
		return 1
	end
	return 2
end

local function columnClasses(headers: { string }, keep: { [string]: boolean }?): ({ string }, string)
	local n = math.min(#headers, M.MAX_COLUMNS)
	local hide = { 0, 0, 0 }
	local classes: { string } = table.create(n)
	for i = 1, n do
		local p = if keep and keep[headers[i]] then 0 else M.priority(headers[i], i)
		classes[i] = "tk-p" .. p
		if p >= 1 then
			hide[3] += 1
		end
		if p >= 2 then
			hide[2] += 1
		end
		if p >= 3 then
			hide[1] += 1
		end
	end
	local gridClass = string.format(
		"tk-grid tk-cols-%d tk-a-%d tk-b-%d tk-c-%d",
		n,
		math.max(1, n - hide[1]),
		math.max(1, n - hide[2]),
		math.max(1, n - hide[3])
	)
	return classes, gridClass
end

function M.grid(spec: Spec): Node
	local headers = spec.headers
	local types = spec.types
	local ncol = math.min(#headers, M.MAX_COLUMNS)
	local classes, gridClass = columnClasses(headers, spec.keep)
	local cellFn: (string, ColumnType, string, boolean) -> Node = spec.cell or Cells.cell
	local numeric = Cells.NUMERIC
	local middle = spec.middle
	local isMiddle: { boolean } = table.create(ncol, false)
	local cellClass: { string } = table.create(ncol)
	for i = 1, ncol do
		isMiddle[i] = middle ~= nil and middle[headers[i]] == true
		cellClass[i] = (if numeric[types[i] or "text"] then "tk-c tk-num " else "tk-c ") .. classes[i]
	end

	local sortable = spec.sortable ~= false
	local children: { Node } = table.create(ncol + #spec.rows + 1)
	for i = 1, ncol do
		local h = headers[i]
		local sorted = sortable and spec.sortCol == h
		local label = if sorted then h .. (if spec.desc then " ▼" else " ▲") else h
		local p: { [string]: any } = {
			tag = "div",
			key = "h" .. i,
			class = if sorted then "tk-h tk-sorted " .. classes[i] else "tk-h " .. classes[i],
			text = label,
		}
		if sortable then
			p.title = "Sort by " .. h
			p.actions = { click = spec.sortAction(h) }
		end
		children[i] = { k = "el", p = p }
	end

	local inspector = spec.inspector
	for _, row in spec.rows do
		if row.divider then
			table.insert(children, {
				k = "el",
				p = { tag = "div", key = row.key .. "/div", class = "tk-divider", text = row.divider },
			})
		end
		local cells: { Node } = table.create(ncol)
		local values = row.cells
		local prebuilt = row.nodes
		local notes = row.notes
		local finished = Cells.rowFinished(types, values)
		for i = 1, ncol do
			local v = values[i] or ""
			local split = isMiddle[i] and #v > MIDDLE_MIN
			local node: Node
			if prebuilt and prebuilt[i] then
				node = prebuilt[i]
			elseif split then
				node = M.middleNode(v, Cells.style(headers[i], types[i] or "text", v, finished))
			else
				node = cellFn(headers[i], types[i] or "text", v, finished)
			end
			local note = if notes then notes[i] else nil
			if note and node.k == "text" and node.p then
				local spans = table.clone(node.p.spans)
				table.insert(spans, { t = " " .. note, s = "muted" })
				node = { k = "text", p = { spans = spans } }
			end
			cells[i] = {
				k = "el",
				p = {
					tag = "div",
					class = if split then cellClass[i] .. " tk-midc" else cellClass[i],
					title = if note then v .. " " .. note else v,
				},
				c = { node },
			}
		end
		local rowClass = if row.open then "tk-r tk-open" else "tk-r"
		if row.class then
			rowClass ..= " " .. row.class
		end
		table.insert(children, {
			k = "el",
			p = {
				tag = "div",
				key = row.key,
				class = rowClass,
				actions = { click = row.action },
			},
			c = cells,
		})
		if row.open and inspector then
			local body = inspector(row.key)
			if body then
				table.insert(children, {
					k = "el",
					p = { tag = "div", key = row.key .. "/insp", class = "tk-insp" },
					c = { body },
				})
			end
		end
	end

	return ui.el("div", { key = spec.key, class = "tk-wrap" }, {
		ui.el("div", {
			class = if spec.class then gridClass .. " " .. spec.class else gridClass,
			role = "tern-kube.grid",
		}, children),
	})
end

return M
