--!strict
-- Parses kubectl's text/tabwriter tables. Column spans come from the header
-- (positions in runes, as tabwriter counts runes); rows are cut by span and
-- verified, then fall back to splitting on 2+ spaces. Anything else becomes a
-- diagnostic; cells are never invented.

local Types = require("../model/types")

type Column = Types.Column
type Diagnostic = Types.Diagnostic
type ParsedTable = Types.ParsedTable
type RawLine = Types.RawLine
type TableRow = Types.TableRow

export type Options = {
	expectedHeaders: { string }?,
	noHeaders: boolean?,
	knownColumns: { string }?,
}

export type Result = {
	tables: { ParsedTable },
	diagnostics: { Diagnostic },
}

type Token = { text: string, byteStart: number }

local M = {}

local function isBlank(line: string): boolean
	return string.find(line, "%S") == nil
end

local function rtrim(s: string): string
	return (string.gsub(s, "%s+$", ""))
end

local KLOG = "^([EWIF])%d%d%d%d %d%d:%d%d:%d%d%.%d+%s+%d+ [^%]]+%]"

local KLOG_SEVERITY: { [string]: "error" | "warning" | "info" } = {
	E = "error",
	F = "error",
	W = "warning",
	I = "info",
}

local PREFIXES: { { prefix: string, severity: "error" | "warning" | "info" } } = {
	{ prefix = "Warning: ", severity = "warning" },
	{ prefix = "Error from server", severity = "error" },
	{ prefix = "error: ", severity = "error" },
	{ prefix = "Error: ", severity = "error" },
	{ prefix = "Unable to connect to the server", severity = "error" },
	{ prefix = "The connection to the server ", severity = "error" },
	{ prefix = "No resources found", severity = "info" },
	{ prefix = "Flag --", severity = "warning" },
}

-- Recognises kubectl/klog stderr conventions; nil for anything else.
function M.classify(line: string, lineNumber: number?): Diagnostic?
	local text = rtrim(line)
	for _, entry in PREFIXES do
		if string.sub(text, 1, #entry.prefix) == entry.prefix then
			return { line = lineNumber, severity = entry.severity, text = text }
		end
	end
	local letter = string.match(text, KLOG)
	if letter then
		return { line = lineNumber, severity = KLOG_SEVERITY[letter], text = text }
	end
	return nil
end

-- Splits on runs of 2+ spaces; single spaces stay inside a token.
local function split(line: string): { Token }
	local tokens: { Token } = {}
	local pos = 1
	local len = #line
	while pos <= len do
		local s = string.find(line, "%S", pos)
		if s == nil then
			break
		end
		local gap = string.find(line, "  ", s, true)
		local stop = if gap then gap - 1 else len
		table.insert(tokens, { text = rtrim(string.sub(line, s, stop)), byteStart = s })
		pos = stop + 1
	end
	return tokens
end

local function runeCount(s: string): number
	local _, n = string.gsub(s, "[^\128-\191]", "")
	return n
end

local function runeColumn(line: string, byteStart: number): number
	return runeCount(string.sub(line, 1, byteStart - 1)) + 1
end

-- Byte offset of every rune start plus a sentinel; nil when the line is ASCII
-- and rune positions equal byte positions.
local function runeOffsets(line: string): { number }?
	if string.find(line, "[\128-\255]") == nil then
		return nil
	end
	local offsets: { number } = {}
	for i = 1, #line do
		local b = string.byte(line, i)
		if b < 0x80 or b >= 0xC0 then
			table.insert(offsets, i)
		end
	end
	table.insert(offsets, #line + 1)
	return offsets
end

local HEADER_WORD = "^[A-Z0-9][A-Z0-9_%-%./:]*$"

local function isHeaderWord(word: string): boolean
	local base, paren = string.match(word, "^([^%(]+)(%b())$")
	if base and paren then
		return string.find(base, HEADER_WORD) ~= nil and string.find(paren, "^%([%w%-%./%%]*%)$") ~= nil
	end
	return string.find((string.gsub(word, "%%$", "")), HEADER_WORD) ~= nil
end

local function isHeaderToken(text: string): boolean
	for word in string.gmatch(text, "[^ ]+") do
		if not isHeaderWord(word) then
			return false
		end
	end
	return string.find(text, "%u") ~= nil
end

local function columnsFrom(line: string, tokens: { Token }): { Column }
	local columns: { Column } = {}
	for i, token in tokens do
		local col: Column = { name = token.text, start = runeColumn(line, token.byteStart), stop = nil }
		columns[i] = col
		if i > 1 then
			columns[i - 1].stop = col.start - 1
		end
	end
	return columns
end

local function headerColumns(line: string, expected: { string }?): { Column }?
	if string.sub(line, 1, 1) == " " then
		return nil
	end
	local tokens = split(line)
	if expected and #tokens == #expected then
		local matches = true
		for i, token in tokens do
			if token.text ~= expected[i] then
				matches = false
				break
			end
		end
		if matches then
			return columnsFrom(line, tokens)
		end
	end
	if #tokens < 2 then
		return nil
	end
	for _, token in tokens do
		if not isHeaderToken(token.text) then
			return nil
		end
	end
	return columnsFrom(line, tokens)
end

local function sliceRunes(line: string, offsets: { number }?, from: number, to: number?): string
	if offsets == nil then
		return string.sub(line, from, to or -1)
	end
	local count = #offsets - 1
	if from > count then
		return ""
	end
	local last = if to == nil or to > count then count else to
	return string.sub(line, offsets[from], offsets[last + 1] - 1)
end

-- Cuts a row by column spans; nil when a cell spills over a boundary or does
-- not start at its column (tabwriter left-aligns every cell).
local function cutBySpans(line: string, columns: { Column }): { string }?
	local offsets = runeOffsets(line)
	local cells: { string } = table.create(#columns)
	for i, col in columns do
		local raw = sliceRunes(line, offsets, col.start, col.stop)
		if raw ~= "" then
			if string.sub(raw, 1, 1) == " " and string.find(raw, "%S") then
				return nil
			end
			if col.start > 1 then
				local before = sliceRunes(line, offsets, col.start - 1, col.start - 1)
				if before ~= " " and before ~= "" then
					return nil
				end
			end
		end
		cells[i] = rtrim(raw)
	end
	return cells
end

local function cutBySplit(line: string, count: number): { string }?
	local tokens = split(line)
	if #tokens ~= count then
		return nil
	end
	local cells: { string } = table.create(count)
	for i, token in tokens do
		cells[i] = token.text
	end
	return cells
end

local function misaligned(lineNumber: number, count: number): Diagnostic
	return {
		line = lineNumber,
		severity = "warning",
		text = string.format("row does not fit the %d table columns", count),
	}
end

local function parseWithHeaders(lines: { string }, expected: { string }?): Result
	local tables: { ParsedTable } = {}
	local diagnostics: { Diagnostic } = {}
	local current: ParsedTable? = nil
	for n, line in lines do
		if isBlank(line) then
			current = nil
			continue
		end
		local diagnostic = M.classify(line, n)
		if diagnostic then
			table.insert(diagnostics, diagnostic)
			continue
		end
		if current == nil then
			local columns = headerColumns(line, expected)
			if columns then
				local tbl: ParsedTable = { columns = columns, rows = {}, headerLine = n, unparsed = {} }
				table.insert(tables, tbl)
				current = tbl
			else
				table.insert(diagnostics, { line = n, severity = "info", text = rtrim(line) })
			end
			continue
		end
		local tbl = current :: ParsedTable
		local cells = cutBySpans(line, tbl.columns) or cutBySplit(line, #tbl.columns)
		if cells then
			table.insert(tbl.rows, { cells = cells, line = n })
		else
			table.insert(tbl.unparsed, { line = n, text = line })
			table.insert(diagnostics, misaligned(n, #tbl.columns))
		end
	end
	return { tables = tables, diagnostics = diagnostics }
end

local function parseHeaderless(lines: { string }, known: { string }?): Result
	local tables: { ParsedTable } = {}
	local diagnostics: { Diagnostic } = {}
	local current: ParsedTable? = nil
	local count = 0
	for n, line in lines do
		if isBlank(line) then
			current = nil
			continue
		end
		local diagnostic = M.classify(line, n)
		if diagnostic then
			table.insert(diagnostics, diagnostic)
			continue
		end
		local tokens = split(line)
		if current == nil then
			local tbl: ParsedTable = { columns = {}, rows = {}, headerLine = nil, unparsed = {} }
			table.insert(tables, tbl)
			current = tbl
			count = if known then #known else #tokens
		end
		local tbl = current :: ParsedTable
		if #tokens ~= count then
			table.insert(tbl.unparsed, { line = n, text = line })
			table.insert(diagnostics, misaligned(n, count))
			continue
		end
		local cells: { string } = table.create(count)
		for i, token in tokens do
			cells[i] = token.text
		end
		if #tbl.columns == 0 then
			for i, token in tokens do
				local col: Column =
					{ name = if known then known[i] else "", start = runeColumn(line, token.byteStart), stop = nil }
				tbl.columns[i] = col
				if i > 1 then
					tbl.columns[i - 1].stop = col.start - 1
				end
			end
		end
		table.insert(tbl.rows, { cells = cells, line = n })
	end
	return { tables = tables, diagnostics = diagnostics }
end

function M.parse(lines: { string }, opts: Options?): Result
	local options: Options = opts or {}
	if options.noHeaders then
		return parseHeaderless(lines, options.knownColumns)
	end
	return parseWithHeaders(lines, options.expectedHeaders)
end

return M
