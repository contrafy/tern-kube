--!strict
-- Reads `kubectl config get-contexts`: the table (`CURRENT NAME CLUSTER
-- AUTHINFO NAMESPACE`, names may hold single spaces, `:` and `/`), its
-- `--no-headers` form (a 6-column marker field, then cells split on runs of
-- 2+ spaces) and `-o name` (names only, current unknown). The `*` marks the
-- kubeconfig's current-context, whatever --context says.

local TableParser = require("./table")
local Types = require("../model/types")

type Diagnostic = Types.Diagnostic

export type Form = "table" | "noheaders" | "name"

export type ContextRow = {
	-- nil for `-o name`, which does not say.
	current: boolean?,
	name: string,
	cluster: string?,
	authinfo: string?,
	namespace: string?,
	-- Cells as printed, in `headers` order.
	cells: { string },
	line: number,
}

export type ContextsParse = { headers: { string }, rows: { ContextRow }, diagnostics: { Diagnostic } }

local M = {}

M.HEADERS = table.freeze({ "CURRENT", "NAME", "CLUSTER", "AUTHINFO", "NAMESPACE" })

local function rtrim(s: string): string
	return (string.gsub(s, "%s+$", ""))
end

local function blankToNil(s: string?): string?
	return if s == nil or s == "" then nil else s
end

local function rowOf(cells: { string }, line: number): ContextRow
	return {
		current = cells[1] == "*",
		name = cells[2],
		cluster = blankToNil(cells[3]),
		authinfo = blankToNil(cells[4]),
		namespace = blankToNil(cells[5]),
		cells = cells,
		line = line,
	}
end

local function parseTable(lines: { string }): ContextsParse
	local result = TableParser.parse(lines, { expectedHeaders = M.HEADERS :: any })
	local rows: { ContextRow } = {}
	local diagnostics: { Diagnostic } = result.diagnostics
	local headers: { string } = table.clone(M.HEADERS :: any)
	for _, tbl in result.tables do
		local names: { string } = {}
		for i, col in tbl.columns do
			names[i] = col.name
		end
		if table.concat(names, "\t") ~= table.concat(M.HEADERS, "\t") then
			for _, row in tbl.rows do
				table.insert(diagnostics, { line = row.line, severity = "info", text = rtrim(lines[row.line] or "") })
			end
			continue
		end
		for _, row in tbl.rows do
			table.insert(rows, rowOf(row.cells, row.line))
		end
	end
	return { headers = headers, rows = rows, diagnostics = diagnostics }
end

-- Splits on runs of 2+ spaces.
local function tokens(s: string): { string }
	local out: { string } = {}
	local pos = 1
	while true do
		local from = string.find(s, "%S", pos)
		if from == nil then
			break
		end
		local gap = string.find(s, "  ", from, true)
		local to = if gap then gap - 1 else #s
		table.insert(out, rtrim(string.sub(s, from, to)))
		pos = to + 1
	end
	return out
end

local function parseNoHeaders(lines: { string }): ContextsParse
	local rows: { ContextRow } = {}
	local diagnostics: { Diagnostic } = {}
	for n, raw in lines do
		local line = rtrim(raw)
		if line == "" then
			continue
		end
		local d = TableParser.classify(line, n)
		if d then
			table.insert(diagnostics, d)
			continue
		end
		local marker = string.sub(line, 1, 1)
		local rest = string.sub(line, 2)
		local cells = tokens(rest)
		if (marker ~= "*" and marker ~= " ") or string.find(rest, "^%S") or #cells < 3 or #cells > 4 then
			table.insert(diagnostics, { line = n, severity = "info", text = line })
			continue
		end
		table.insert(
			rows,
			rowOf({ if marker == "*" then "*" else "", cells[1], cells[2], cells[3], cells[4] or "" }, n)
		)
	end
	return { headers = table.clone(M.HEADERS :: any), rows = rows, diagnostics = diagnostics }
end

local function parseNames(lines: { string }): ContextsParse
	local rows: { ContextRow } = {}
	local diagnostics: { Diagnostic } = {}
	for n, raw in lines do
		local line = rtrim(raw)
		if line == "" then
			continue
		end
		local d = TableParser.classify(line, n)
		if d then
			table.insert(diagnostics, d)
			continue
		end
		table.insert(rows, {
			current = nil,
			name = line,
			cluster = nil,
			authinfo = nil,
			namespace = nil,
			cells = { line },
			line = n,
		})
	end
	return { headers = { "NAME" }, rows = rows, diagnostics = diagnostics }
end

function M.parse(lines: { string }, form: Form): ContextsParse
	if form == "name" then
		return parseNames(lines)
	elseif form == "noheaders" then
		return parseNoHeaders(lines)
	end
	return parseTable(lines)
end

return M
