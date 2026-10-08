--!strict
-- Span-based reader for kubectl's whitespace-aligned tables: each column
-- starts where its header word starts, so cells with inner spaces such as
-- "2 (5h ago)" stay whole.

export type Column = { id: string, head: string, from: number }
export type Row = { id: string, cells: { [string]: string } }
export type Table = { cols: { Column }, rows: { Row } }

local M = {}

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

function M.header(line: string): { Column }?
	local cols: { Column } = {}
	local pos = 1
	while true do
		local from, to = string.find(line, "%S+", pos)
		if from == nil or to == nil then
			break
		end
		local head = string.sub(line, from, to)
		if string.upper(head) ~= head then
			return nil
		end
		table.insert(cols, { id = head, head = head, from = from })
		pos = to + 1
	end
	if #cols < 2 then
		return nil
	end
	return cols
end

function M.row(cols: { Column }, line: string): { [string]: string }
	local cells: { [string]: string } = {}
	for i, col in cols do
		local next_col = cols[i + 1]
		local to = if next_col then next_col.from - 1 else #line
		cells[col.id] = trim(string.sub(line, col.from, to))
	end
	return cells
end

function M.parse(lines: { string }): Table?
	local first = lines[1]
	if first == nil then
		return nil
	end
	local cols = M.header(first)
	if cols == nil then
		return nil
	end
	local rows: { Row } = {}
	local seen: { [string]: boolean } = {}
	for i = 2, #lines do
		local line = lines[i]
		if string.find(line, "%S") then
			local cells = M.row(cols, line)
			local id = cells[cols[1].id]
			if seen[id] then
				id = id .. "#" .. i
			end
			seen[id] = true
			table.insert(rows, { id = id, cells = cells })
		end
	end
	return { cols = cols, rows = rows }
end

return M
