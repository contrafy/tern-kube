--!strict
-- One manifest source against several contexts: the drift report of each
-- context folded into a matrix (rows = resource keys of every report,
-- columns = contexts in the caller's order, base first). Each cell is that
-- context's drift of the row: in sync, changed (+a -r), missing, unmanaged,
-- absent (neither declared nor listed there), or the column's error or
-- pending state while its report is not there.
local Drift = require("./drift")
local Model = require("../compare/model")
local Types = require("../model/types")

type Ref = Types.ResourceRef

export type Cell = Model.Cell
export type Column = Model.Column
export type Row = Model.Row
export type Matrix = Model.Matrix

-- all; drifted: some context disagrees with the source; differs: the
-- contexts disagree with each other.
export type Filter = "all" | "drifted" | "differs"

local M = {}

M.FILTERS = { "all", "drifted", "differs" } :: { Filter }

local function refOf(key: string): Ref?
	local group, kind, ns, name = string.match(key, "^([^/]*)/([^/]+)/([^/]*)/(.+)$")
	if kind == nil or name == nil then
		return nil
	end
	return {
		group = if group == "" then nil else group,
		kind = kind :: string,
		namespace = if ns == "" then nil else ns,
		name = name :: string,
		source = "live",
	}
end

local function cellsOf(report: Drift.Report): ({ [string]: Cell }, { [string]: Ref })
	local cells: { [string]: Cell } = {}
	local refs: { [string]: Ref } = {}
	for _, c in report.changed do
		cells[c.key] = { state = "changed", added = c.segment.added, removed = c.segment.removed }
		refs[c.key] = c.ref
	end
	for _, m in report.missing do
		cells[m.key] = { state = "missing" }
		refs[m.key] = m.ref
	end
	for _, u in report.unmanaged do
		cells[u.key] = { state = "unmanaged" }
		refs[u.key] = u.ref
	end
	for _, key in report.inSync do
		if cells[key] == nil then
			cells[key] = { state = "insync" }
		end
	end
	return cells, refs
end

local function columnCell(col: Column): Cell
	if col.status == "error" then
		return { state = "error", error = col.error }
	end
	return { state = "pending" }
end

function M.fromReports(columns: { Column }, reports: { Drift.Report? }): Matrix
	local perColumn: { { [string]: Cell }? } = {}
	local refs: { [string]: Ref } = {}
	local keys: { string } = {}
	local seen: { [string]: boolean } = {}
	local notes: { string } = {}
	for i, col in columns do
		local report = reports[i]
		if report == nil then
			perColumn[i] = nil
			continue
		end
		local cells, colRefs = cellsOf(report)
		perColumn[i] = cells
		for key in cells do
			if not seen[key] then
				seen[key] = true
				table.insert(keys, key)
			end
			refs[key] = refs[key] or colRefs[key]
		end
		for _, n in report.notes do
			table.insert(notes, col.context .. ": " .. n)
		end
	end
	table.sort(keys)
	local rows: { Row } = {}
	for _, key in keys do
		local ref = refs[key] or refOf(key)
		if ref == nil then
			continue
		end
		local cells: { Cell } = {}
		for i, col in columns do
			local found = perColumn[i]
			cells[i] = if found then found[key] or { state = "absent" } else columnCell(col)
		end
		table.insert(rows, { key = key, ref = ref, cells = cells })
	end
	return { columns = columns, rows = rows, notes = notes }
end

local DRIFTED: { [string]: boolean } = { changed = true, missing = true, unmanaged = true, error = true }

local function drifted(row: Row): boolean
	for _, c in row.cells do
		if DRIFTED[c.state] then
			return true
		end
	end
	return false
end

-- Pending cells say nothing yet; changed cells differ by their size too.
local function differs(row: Row): boolean
	local first: string? = nil
	for _, c in row.cells do
		if c.state ~= "pending" then
			local id = c.state .. ":" .. tostring(c.added or "") .. ":" .. tostring(c.removed or "")
			if first == nil then
				first = id
			elseif first ~= id then
				return true
			end
		end
	end
	return false
end

function M.filter(m: Matrix, f: Filter): Matrix
	if f == "all" then
		return m
	end
	local keep: (Row) -> boolean = if f == "drifted" then drifted else differs
	local rows: { Row } = {}
	for _, row in m.rows do
		if keep(row) then
			table.insert(rows, row)
		end
	end
	return { columns = m.columns, rows = rows, notes = m.notes }
end

function M.nextFilter(f: Filter): Filter
	local i = table.find(M.FILTERS, f) or 1
	return M.FILTERS[i % #M.FILTERS + 1]
end

local SUMMARY_ORDER = { "changed", "missing", "unmanaged" }

-- "2 changed, 1 missing, 1 unmanaged" / "in sync" for column i.
function M.summary(m: Matrix, i: number): string
	local col = m.columns[i]
	if col == nil then
		return ""
	elseif col.status == "error" then
		return "error"
	elseif col.status ~= "ok" then
		return col.status
	end
	local counts: { [string]: number } = {}
	for _, row in m.rows do
		local c = row.cells[i]
		if c then
			counts[c.state] = (counts[c.state] or 0) + 1
		end
	end
	local parts: { string } = {}
	for _, state in SUMMARY_ORDER do
		local n = counts[state]
		if n then
			table.insert(parts, string.format("%d %s", n, state))
		end
	end
	return if #parts == 0 then "in sync" else table.concat(parts, ", ")
end

return M
