--!strict
-- Reads `kubectl rollout history` text. The list form prints one block per
-- object: a `deployment.apps/web ` header (kubectl leaves a trailing space),
-- a `REVISION  CHANGE-CAUSE` table and a blank line. Revisions need not be
-- contiguous (an undo renumbers the restored one) and causes are free text.
-- `--revision=N` prints `deployment.apps/web with revision #N` over a
-- describe-like `Pod Template:` block whose values follow raw tabs, or the
-- spaces a terminal expands them to; both normalize to describe text.

local Describe = require("./describe")
local Kinds = require("../kubectl/kinds")
local TableParser = require("./table")
local Types = require("../model/types")

type Diagnostic = Types.Diagnostic

export type Revision = { revision: number, cause: string?, line: number }

export type HistoryObject = {
	-- The TYPE as printed (`deployment.apps`), the Kind and group it names.
	type: string,
	kind: string,
	group: string?,
	name: string,
	line: number,
	revisions: { Revision },
}

export type ListParse = { objects: { HistoryObject }, diagnostics: { Diagnostic } }

export type RevisionParse = {
	type: string?,
	kind: string?,
	group: string?,
	name: string?,
	revision: number?,
	line: number?,
	describe: Types.DescribeParse,
	diagnostics: { Diagnostic },
}

local M = {}

local function rtrim(s: string): string
	return (string.gsub(s, "%s+$", ""))
end

local function objectOf(typ: string, name: string, line: number): HistoryObject
	local info = Kinds.normalize(typ)
	local group = info.group
	if not info.known then
		group = string.match(typ, "^[^.]+%.(.+)$")
	end
	return {
		type = typ,
		kind = info.kind,
		group = group,
		name = name,
		line = line,
		revisions = {},
	}
end

function M.parseList(lines: { string }): ListParse
	local objects: { HistoryObject } = {}
	local diagnostics: { Diagnostic } = {}
	local current: HistoryObject? = nil
	local header = false
	for n, raw in lines do
		local line = rtrim(raw)
		-- A block ends at the next `TYPE/NAME` header, not at a blank line:
		-- revisions printed after one still belong to the last object.
		if line == "" then
			continue
		end
		local d = TableParser.classify(line, n)
		if d then
			table.insert(diagnostics, d)
			continue
		end
		local typ, name = string.match(line, "^([%w][%w%.%-]*)/(%S+)$")
		if typ and name then
			local obj = objectOf(typ, name, n)
			table.insert(objects, obj)
			current = obj
			header = false
			continue
		end
		local obj = current
		if obj and not header and string.find(line, "^REVISION%s+CHANGE%-CAUSE$") then
			header = true
			continue
		end
		local rev, cause = string.match(line, "^(%d+)%s+(.+)$")
		if rev == nil then
			rev = string.match(line, "^(%d+)$")
		end
		local number = if rev and #rev <= 10 then tonumber(rev) else nil
		if obj and header and number then
			table.insert(obj.revisions, {
				revision = number,
				cause = if cause == nil or cause == "<none>" then nil else cause,
				line = n,
			})
			continue
		end
		table.insert(diagnostics, { line = n, severity = "info", text = line })
	end
	return { objects = objects, diagnostics = diagnostics }
end

-- Tab stops every 8 columns, as a terminal grid renders them.
function M.expandTabs(line: string): string
	if string.find(line, "\t", 1, true) == nil then
		return line
	end
	local out: { string } = {}
	local col = 0
	for _, code in utf8.codes(line) do
		if code == 9 then
			local n = 8 - col % 8
			table.insert(out, string.rep(" ", n))
			col += n
		else
			table.insert(out, utf8.char(code))
			col += 1
		end
	end
	return table.concat(out)
end

-- Fields whose further values kubectl prints on lines that start with a tab
-- (a column-8 indent once expanded), not under the value column.
local MULTI_VALUE: { [string]: boolean } = { Labels = true, Annotations = true }

-- Describe text the describe parser reads: the header line becomes `Name:`
-- (line numbers stay those of the output) and continuation values move to
-- their field's value column.
local function normalized(lines: { string }, headerLine: number, name: string): { string }
	local out: { string } = table.create(#lines)
	local valueColumn: number? = nil
	for i, raw in lines do
		if i == headerLine then
			out[i] = "Name:  " .. name
			valueColumn = nil
			continue
		end
		local line = M.expandTabs(raw)
		local indent = #(string.match(line, "^ *") or "")
		if valueColumn and indent == 8 and string.find(line, "%S") then
			out[i] = string.rep(" ", valueColumn) .. string.sub(line, 9)
			continue
		end
		valueColumn = nil
		local prefix, key, gap = string.match(line, "^( *)([^%s:][^:]-):( +)%S")
		if prefix and key and gap and MULTI_VALUE[key] then
			valueColumn = #prefix + #key + 1 + #gap
		end
		out[i] = line
	end
	return out
end

function M.parseRevision(lines: { string }): RevisionParse
	local headerLine: number? = nil
	local typ: string?, name: string?, rev: string? = nil, nil, nil
	for n, raw in lines do
		local line = rtrim(raw)
		if line == "" or TableParser.classify(line, n) then
			continue
		end
		typ, name, rev = string.match(line, "^([%w][%w%.%-]*)/(%S+) with revision #(%d+)$")
		if typ then
			headerLine = n
		end
		break
	end
	if headerLine == nil or typ == nil or name == nil then
		local parsed = Describe.parse(lines)
		return {
			type = nil,
			kind = nil,
			group = nil,
			name = nil,
			revision = nil,
			line = nil,
			describe = { objects = {}, diagnostics = parsed.diagnostics },
			diagnostics = parsed.diagnostics,
		}
	end
	local obj = objectOf(typ, name, headerLine)
	local parsed = Describe.parse(normalized(lines, headerLine, name))
	local objects: { Types.DescribeObject } = table.create(#parsed.objects)
	for i, o in parsed.objects do
		local copy = table.clone(o)
		copy.kind = obj.kind
		objects[i] = copy
	end
	return {
		type = typ,
		kind = obj.kind,
		group = obj.group,
		name = name,
		revision = tonumber(rev),
		line = headerLine,
		describe = { objects = objects, diagnostics = parsed.diagnostics },
		diagnostics = parsed.diagnostics,
	}
end

return M
