--!strict
-- The shared clickable table: a CSS grid of `el` divs (Tern's `table` node
-- has no row actions and `el` tables ignore colspan). Rows are
-- `display: contents` so their cells align while the row keeps its click
-- action; the inline inspector spans every column. Built from plain tables:
-- a 500-row grid is thousands of nodes.
--
-- Narrow panes hide low-priority columns through container queries in
-- kube-lens.css. Hidden cells leave the grid flow, so the grid also carries
-- the visible column count for each width tier (kl-a-N, kl-b-N, kl-c-N).

local Cells = require("./cells")
local Types = require("../model/types")
local ui = require("../ui")

type ColumnType = Types.ColumnType
type Node = ui.Node

export type GridRow = { key: string, cells: { string }, action: string, open: boolean? }

export type Spec = {
	key: string,
	headers: { string },
	types: { ColumnType },
	rows: { GridRow },
	sortCol: string?,
	desc: boolean,
	sortAction: (col: string) -> string,
	inspector: ((rowKey: string) -> Node?)?,
	cell: ((col: string, columnType: ColumnType, value: string) -> Node)?,
}

local M = {}

M.MAX_COLUMNS = 16

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

local function columnClasses(headers: { string }): ({ string }, string)
	local n = math.min(#headers, M.MAX_COLUMNS)
	local hide = { 0, 0, 0 }
	local classes: { string } = table.create(n)
	for i = 1, n do
		local p = M.priority(headers[i], i)
		classes[i] = "kl-p" .. p
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
		"kl-grid kl-cols-%d kl-a-%d kl-b-%d kl-c-%d",
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
	local classes, gridClass = columnClasses(headers)
	local cellFn: (string, ColumnType, string) -> Node = spec.cell or Cells.cell
	local numeric = Cells.NUMERIC
	local cellClass: { string } = table.create(ncol)
	for i = 1, ncol do
		cellClass[i] = if numeric[types[i] or "text"] then "kl-c kl-num " .. classes[i] else "kl-c " .. classes[i]
	end

	local children: { Node } = table.create(ncol + #spec.rows + 1)
	for i = 1, ncol do
		local h = headers[i]
		local sorted = spec.sortCol == h
		local label = if sorted then h .. (if spec.desc then " ▼" else " ▲") else h
		children[i] = {
			k = "el",
			p = {
				tag = "div",
				key = "h" .. i,
				class = if sorted then "kl-h kl-sorted " .. classes[i] else "kl-h " .. classes[i],
				text = label,
				title = "Sort by " .. h,
				actions = { click = spec.sortAction(h) },
			},
		}
	end

	local inspector = spec.inspector
	for _, row in spec.rows do
		local cells: { Node } = table.create(ncol)
		local values = row.cells
		for i = 1, ncol do
			local v = values[i] or ""
			cells[i] = {
				k = "el",
				p = { tag = "div", class = cellClass[i], title = v },
				c = { cellFn(headers[i], types[i] or "text", v) },
			}
		end
		table.insert(children, {
			k = "el",
			p = {
				tag = "div",
				key = row.key,
				class = if row.open then "kl-r kl-open" else "kl-r",
				actions = { click = row.action },
			},
			c = cells,
		})
		if row.open and inspector then
			local body = inspector(row.key)
			if body then
				table.insert(children, {
					k = "el",
					p = { tag = "div", key = row.key .. "/insp", class = "kl-insp" },
					c = { body },
				})
			end
		end
	end

	return ui.el("div", { key = spec.key, class = "kl-wrap" }, {
		ui.el("div", { class = gridClass, role = "kube-lens.grid" }, children),
	})
end

return M
