--!strict
-- Filter, "problems only" and sort over one snapshot table. Pure and
-- allocation-light: sort keys are computed once per row, not per comparison.

local Types = require("../model/types")
local Values = require("../model/values")
local Viewstate = require("./viewstate")

type ResourceRow = Types.ResourceRow
type SnapshotTable = Types.SnapshotTable
type ViewState = Viewstate.ViewState

export type Result = { rows: { ResourceRow }, total: number, matched: number }

local M = {}

-- Facet pseudo-column matched against the table's kind, so `get all` can be
-- narrowed to one kind like any other column.
M.KIND = "KIND"

local function columnIndex(tbl: SnapshotTable, name: string): number?
	for i, h in tbl.headers do
		if h == name then
			return i
		end
	end
	return nil
end

-- A row is a problem when kubectl's own columns say so: a status-typed cell
-- with a warning/error tone, a ratio short of its target (READY 0/1), or
-- restarts above zero.
function M.isProblem(tbl: SnapshotTable, row: ResourceRow): boolean
	for i, t in tbl.types do
		local cell = row.cells[i] or ""
		if t == "status" then
			local tone = Values.statusTone(tbl.headers[i], cell)
			if tone == "error" or tone == "warning" then
				return true
			end
		elseif t == "ratio" then
			local num, den = Values.ratio(cell)
			if num and den and num < den then
				return true
			end
		elseif t == "count" and tbl.headers[i] == "RESTARTS" then
			local n = Values.count(cell)
			if n and n > 0 then
				return true
			end
		end
	end
	return false
end

type Clause = { index: number?, kind: boolean, values: { [string]: boolean } }

-- AND across columns, OR within one column. A filter on a column this table
-- lacks excludes the whole table.
local function clauses(tbl: SnapshotTable, filters: { string }): { Clause }?
	local byCol: { [string]: Clause } = {}
	local out: { Clause } = {}
	for _, f in filters do
		local col, value = Viewstate.splitFilter(f)
		local clause = byCol[col]
		if clause == nil then
			local index = columnIndex(tbl, col)
			local isKind = index == nil and col == M.KIND
			if index == nil and not isKind then
				return nil
			end
			local created: Clause = { index = index, kind = isKind, values = {} }
			clause = created
			byCol[col] = created
			table.insert(out, created)
		end
		(clause :: Clause).values[value] = true
	end
	return out
end

local function matches(tbl: SnapshotTable, row: ResourceRow, cs: { Clause }): boolean
	for _, c in cs do
		local value = if c.kind then tbl.kind or "" else row.cells[c.index :: number] or ""
		if not c.values[value] then
			return false
		end
	end
	return true
end

local function sorted(tbl: SnapshotTable, rows: { ResourceRow }, col: string, desc: boolean): { ResourceRow }
	local index = columnIndex(tbl, col)
	if index == nil then
		return rows
	end
	local columnType: Types.ColumnType = tbl.types[index] or "text"
	local n = #rows
	local keys: { [ResourceRow]: any } = {}
	local order: { [ResourceRow]: number } = {}
	for i, row in rows do
		keys[row] = Values.sortKey(columnType, row.cells[index] or "")
		order[row] = i
	end
	local out = table.move(rows, 1, n, 1, table.create(n))
	table.sort(out, function(a: ResourceRow, b: ResourceRow): boolean
		local ka, kb = keys[a], keys[b]
		if ka ~= kb then
			if ka == nil then
				return false
			elseif kb == nil then
				return true
			end
			if desc then
				return kb < ka
			end
			return ka < kb
		end
		return order[a] < order[b]
	end)
	return out
end

function M.apply(tbl: SnapshotTable, vs: ViewState): Result
	local total = #tbl.rows
	local rows = tbl.rows
	if #vs.filters > 0 or vs.problems then
		local cs = clauses(tbl, vs.filters)
		if cs == nil then
			return { rows = {}, total = total, matched = 0 }
		end
		local kept: { ResourceRow } = {}
		for _, row in rows do
			if matches(tbl, row, cs) and (not vs.problems or M.isProblem(tbl, row)) then
				table.insert(kept, row)
			end
		end
		rows = kept
	end
	local matched = #rows
	if vs.sort then
		rows = sorted(tbl, rows, vs.sort, vs.desc)
	end
	return { rows = rows, total = total, matched = matched }
end

return M
