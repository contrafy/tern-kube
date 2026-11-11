--!strict
-- `kubectl api-resources` as data: the Explore `:` prompt resolves aliases
-- against it and the api-resources lens renders it. Pure.
--
-- Alias rules follow k9s: built-in groups register before the rest and the
-- first definition of a bare name wins; metrics.k8s.io never gets bare names
-- (its `pods`/`nodes` would shadow core); `plural.group` always resolves.

local KindsData = require("./kinds_data")
local Kinds = require("./kinds")
local TableParse = require("../parse/table")
local Types = require("../model/types")

type Diagnostic = Types.Diagnostic

export type KindRow = {
	-- Canonical resource token: `plural` (core) or `plural.group`.
	name: string,
	plural: string,
	group: string?,
	version: string?,
	-- "" when the output had no KIND column and the static table does not know it.
	kind: string,
	short: { string },
	namespaced: boolean?,
	verbs: { string }?,
	categories: { string }?,
	-- Core or a Kubernetes group (no dot, or `*.k8s.io`).
	standard: boolean,
	-- 1-based stdout line (nil for static rows).
	line: number?,
}

export type Parsed = {
	rows: { KindRow },
	-- Group/versions kubectl could not read ("a/v1, b/v1"); nil when complete.
	partial: string?,
	diagnostics: { Diagnostic },
}

export type Index = {
	-- Rows in alias precedence order: core, standard groups, the rest.
	rows: { KindRow },
	byAlias: { [string]: KindRow },
	aliases: { [KindRow]: { string } },
}

export type Suggestion = { row: KindRow, score: number }

local M = {}

M.ARGV = { "api-resources", "--verbs=list", "-o", "wide" }

local PARTIAL = "unable to retrieve the complete list of server APIs:"
local METRICS = "metrics.k8s.io"

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s)
end

local function splitLines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(out, (string.gsub(line, "\r$", "")))
	end
	while #out > 0 and string.find(out[#out], "^%s*$") do
		table.remove(out)
	end
	return out
end

local function commaList(cell: string): { string }
	local out: { string } = {}
	for part in string.gmatch(cell, "[^,%s]+") do
		table.insert(out, part)
	end
	return out
end

function M.isStandard(group: string?): boolean
	if group == nil or group == "" then
		return true
	end
	return string.find(group, ".", 1, true) == nil or string.sub(group, -8) == ".k8s.io"
end

local function makeRow(plural: string, group: string?, fields: { [string]: any }): KindRow
	local g = if group == "" then nil else group
	return {
		name = if g then plural .. "." .. g else plural,
		plural = plural,
		group = g,
		version = fields.version,
		kind = fields.kind or "",
		short = fields.short or {},
		namespaced = fields.namespaced,
		verbs = fields.verbs,
		categories = fields.categories,
		standard = M.isStandard(g),
		line = fields.line,
	}
end

local function partialGroups(stderr: string): string?
	local at = string.find(stderr, PARTIAL, 1, true)
	if at == nil then
		return nil
	end
	local rest = string.sub(stderr, at + #PARTIAL)
	local groups: { string } = {}
	for gv in string.gmatch(rest, "([%w%.%-]+/v[%w]+):") do
		table.insert(groups, gv)
	end
	return if #groups > 0 then table.concat(groups, ", ") else trim((string.match(rest, "^[^\n]*") or ""))
end

local function stderrDiagnostics(stderr: string, into: { Diagnostic })
	for _, line in splitLines(stderr) do
		if string.find(line, "%S") then
			table.insert(into, TableParse.classify(line) or { severity = "error", text = trim(line) })
		end
	end
end

local function fromTable(lines: { string }, diagnostics: { Diagnostic }): { KindRow }
	local rows: { KindRow } = {}
	local parsed = TableParse.parse(lines)
	for _, d in parsed.diagnostics do
		table.insert(diagnostics, d)
	end
	for _, tbl in parsed.tables do
		local col: { [string]: number } = {}
		for i, c in tbl.columns do
			col[c.name] = i
		end
		if col.NAME == nil or col.KIND == nil then
			table.insert(
				diagnostics,
				{ line = tbl.headerLine, severity = "error", text = "not an api-resources table" }
			)
			continue
		end
		for _, r in tbl.rows do
			local cells = r.cells
			local function cell(name: string): string?
				local i = col[name]
				return if i then trim(cells[i] or "") else nil
			end
			local plural = cell("NAME") or ""
			if plural == "" then
				table.insert(diagnostics, { line = r.line, severity = "warning", text = "row without a NAME" })
				continue
			end
			local group: string?, version: string? = nil, nil
			local apiVersion = cell("APIVERSION")
			if apiVersion then
				local g, v = string.match(apiVersion, "^(.+)/([^/]+)$")
				if g then
					group, version = g, v
				elseif apiVersion ~= "" then
					version = apiVersion
				end
			else
				group = cell("APIGROUP")
			end
			local ns = cell("NAMESPACED")
			local verbs = cell("VERBS")
			local categories = cell("CATEGORIES")
			table.insert(
				rows,
				makeRow(plural, group, {
					version = version,
					kind = cell("KIND"),
					short = commaList(cell("SHORTNAMES") or ""),
					namespaced = if ns == "true" then true elseif ns == "false" then false else nil,
					verbs = if verbs then commaList(verbs) else nil,
					categories = if categories then commaList(categories) else nil,
					line = r.line,
				})
			)
		end
	end
	return rows
end

local function fromNames(lines: { string }, diagnostics: { Diagnostic }): { KindRow }
	local rows: { KindRow } = {}
	for n, line in lines do
		local text = trim(line)
		if text == "" then
			continue
		end
		local d = TableParse.classify(line, n)
		if d then
			table.insert(diagnostics, d)
			continue
		end
		if string.find(text, "%s") then
			table.insert(diagnostics, { line = n, severity = "info", text = text })
			continue
		end
		local plural, group = string.match(text, "^([^.]+)%.(.+)$")
		local info = Kinds.normalize(text)
		table.insert(
			rows,
			makeRow(plural or text, group, {
				kind = if info.known then info.kind else nil,
				short = if info.known then info.short else nil,
				namespaced = if info.known then info.namespaced else nil,
				line = n,
			})
		)
	end
	return rows
end

-- stdout of any `api-resources` table form (default, -o wide, APIVERSION
-- or the old APIGROUP header) or `-o name`. A partial discovery (rc 1 with
-- "unable to retrieve the complete list of server APIs") keeps its rows.
function M.parse(stdout: string, stderr: string?, status: number?): Parsed
	local diagnostics: { Diagnostic } = {}
	local lines = splitLines(stdout)
	local first: string? = nil
	for _, line in lines do
		if string.find(line, "%S") and TableParse.classify(line) == nil then
			first = line
			break
		end
	end
	local rows = if first and string.find(first, "^NAME%s")
		then fromTable(lines, diagnostics)
		else fromNames(lines, diagnostics)
	local partial = if stderr then partialGroups(stderr) else nil
	if stderr then
		stderrDiagnostics(stderr, diagnostics)
	end
	if status ~= nil and status ~= 0 and partial == nil and #diagnostics == 0 then
		table.insert(diagnostics, { severity = "error", text = "kubectl api-resources exited " .. tostring(status) })
	end
	return { rows = rows, partial = partial, diagnostics = diagnostics }
end

local function tier(row: KindRow): number
	if row.group == nil then
		return 0
	end
	return if row.standard then 1 else 2
end

local function aliasesOf(row: KindRow): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(a: string)
		local l = string.lower(a)
		if l ~= "" and not seen[l] then
			seen[l] = true
			table.insert(out, l)
		end
	end
	add(row.plural)
	add(row.kind)
	for _, s in row.short do
		add(s)
	end
	return out
end

function M.index(rows: { KindRow }): Index
	local ordered = table.clone(rows)
	local pos: { [KindRow]: number } = {}
	for i, row in rows do
		pos[row] = i
	end
	table.sort(ordered, function(a, b)
		local ta, tb = tier(a), tier(b)
		if ta ~= tb then
			return ta < tb
		end
		return pos[a] < pos[b]
	end)
	local byAlias: { [string]: KindRow } = {}
	local aliases: { [KindRow]: { string } } = {}
	for _, row in ordered do
		local bare = aliasesOf(row)
		local all = table.clone(bare)
		if row.group then
			for _, a in bare do
				table.insert(all, a .. "." .. row.group)
			end
		end
		aliases[row] = all
		for _, a in all do
			local qualified = string.find(a, ".", 1, true) ~= nil
			if byAlias[a] == nil and (qualified or row.group ~= METRICS) then
				byAlias[a] = row
			end
		end
	end
	return { rows = ordered, byAlias = byAlias, aliases = aliases }
end

local static: Index? = nil

-- Built-in kinds kubectl knows without asking the cluster.
function M.staticIndex(): Index
	if static then
		return static
	end
	local rows: { KindRow } = {}
	for _, r in KindsData do
		table.insert(
			rows,
			makeRow(r.plural, r.group, {
				kind = r.kind,
				short = table.clone(r.short),
				namespaced = r.namespaced,
			})
		)
	end
	local idx = M.index(rows)
	static = idx
	return idx
end

function M.aliases(index: Index, row: KindRow): { string }
	return index.aliases[row] or aliasesOf(row)
end

function M.resolve(index: Index, token: string): KindRow?
	local key = string.lower(trim(token))
	if key == "" then
		return nil
	end
	return index.byAlias[key]
end

-- Rows matching `text` (case-insensitive): 0 exact alias, 1 alias prefix,
-- 2 substring of the name, aliases or Kind. Ties keep index order.
function M.suggest(index: Index, text: string): { Suggestion }
	local needle = string.lower(trim(text))
	local out: { Suggestion } = {}
	for _, row in index.rows do
		local aliases = M.aliases(index, row)
		local score: number? = nil
		if needle == "" then
			score = 2
		else
			for _, a in aliases do
				if a == needle then
					score = 0
					break
				elseif score ~= 1 and string.sub(a, 1, #needle) == needle then
					score = 1
				end
			end
			if score == nil then
				local hay = string.lower(row.name) .. " " .. table.concat(aliases, " ")
				if string.find(hay, needle, 1, true) then
					score = 2
				end
			end
		end
		if score then
			table.insert(out, { row = row, score = score })
		end
	end
	local order: { [KindRow]: number } = {}
	for i, row in index.rows do
		order[row] = i
	end
	table.sort(out, function(a, b)
		if a.score ~= b.score then
			return a.score < b.score
		end
		return order[a.row] < order[b.row]
	end)
	return out
end

return M
