--!strict
-- Lens captures of the k9s-parity commands: `rollout history` (list and
-- `--revision=N`), `config get-contexts`, `api-resources` and `auth can-i`
-- (single question and `--list`). Pure; capture.luau dispatches here and
-- copies the result into the Capture.

local Cani = require("../parse/cani")
local Contexts = require("../parse/contexts")
local Discovery = require("../kubectl/discovery")
local RolloutHistory = require("../parse/rollout_history")
local TableParser = require("../parse/table")
local Types = require("../model/types")
local Values = require("../model/values")

type Diagnostic = Types.Diagnostic
type Invocation = Types.Invocation
type ResourceRow = Types.ResourceRow
type SnapshotTable = Types.SnapshotTable

export type Mode = "history" | "revision" | "contexts" | "apiresources" | "cani" | "canilist"

export type HistoryRow = {
	object: RolloutHistory.HistoryObject,
	revision: number,
	cause: string?,
	-- The highest listed revision: what the workload runs now.
	current: boolean,
}

export type RevisionInfo = {
	ref: Types.ResourceRef,
	-- TYPE as printed (`deployment.apps`).
	type: string,
	revision: number,
	cause: string?,
	images: { string },
}

export type CaniInfo = { answer: Cani.Answer, question: Cani.Question }

export type Detail = {
	mode: Mode,
	history: { [string]: HistoryRow }?,
	contexts: { [string]: Contexts.ContextRow }?,
	kinds: { [string]: Discovery.KindRow }?,
	rules: { [string]: Cani.Rule }?,
	revision: RevisionInfo?,
	cani: CaniInfo?,
	-- Muted cell suffixes by row key and header (`current`, `all`).
	notes: { [string]: { [string]: string } },
	-- Muted lines under the header bar.
	headerNotes: { string },
}

export type Built = {
	detail: Detail,
	tables: { SnapshotTable }?,
	diagnostics: { Diagnostic },
	unparsed: number,
	describe: Types.DescribeParse?,
}

local M = {}

M.CONTEXT_NOTE = "* is the kubeconfig's current-context, not --context"
M.IMPERSONATED_NOTE = "Explore runs as the context's own user, not as the one asked about; its chips are hidden"

local function truthy(inv: Invocation, name: string): boolean
	local list = inv.flags[name]
	local v = if list then list[#list] else nil
	return v ~= nil and v ~= "false"
end

-- The k9s-parity mode of a supported invocation; nil for any other command.
-- `rollout history -o name|json|yaml` keep the generic modes.
function M.modeOf(inv: Invocation): Mode?
	local verb = inv.verb
	if verb == "config" and inv.subverb == "get-contexts" then
		return "contexts"
	elseif verb == "api-resources" then
		return "apiresources"
	elseif verb == "auth" and inv.subverb == "can-i" then
		return if truthy(inv, "list") then "canilist" else "cani"
	elseif
		verb == "rollout"
		and inv.subverb == "history"
		and inv.output ~= "name"
		and inv.output ~= "json"
		and inv.output ~= "yaml"
	then
		return if inv.flags.revision ~= nil then "revision" else "history"
	end
	return nil
end

local function columnTypes(headers: { string }, rows: { { string } }): { Types.ColumnType }
	local types: { Types.ColumnType } = table.create(#headers)
	local samples: { string } = table.create(#rows)
	for c, h in headers do
		for r, cells in rows do
			samples[r] = cells[c] or ""
		end
		types[c] = Values.columnType(h, samples)
	end
	return types
end

local function withTypes(tbl: SnapshotTable): SnapshotTable
	local cellRows: { { string } } = table.create(#tbl.rows)
	for i, row in tbl.rows do
		cellRows[i] = row.cells
	end
	tbl.types = columnTypes(tbl.headers, cellRows)
	return tbl
end

local function uniqueKey(seen: { [string]: number }, key: string): string
	local n = seen[key]
	if n == nil then
		seen[key] = 1
		return key
	end
	n += 1
	seen[key] = n
	local candidate = key .. "#" .. n
	while seen[candidate] do
		n += 1
		seen[key] = n
		candidate = key .. "#" .. n
	end
	seen[candidate] = 1
	return candidate
end

-- Info lines no kubectl convention explains are output the view did not
-- understand.
local function unparsedOf(diagnostics: { Diagnostic }): number
	local n = 0
	for _, d in diagnostics do
		if d.severity == "info" and TableParser.classify(d.text) == nil then
			n += 1
		end
	end
	return n
end

local function newDetail(mode: Mode): Detail
	return {
		mode = mode,
		history = nil,
		contexts = nil,
		kinds = nil,
		rules = nil,
		revision = nil,
		cani = nil,
		notes = {},
		headerNotes = {},
	}
end

local function workloadRef(inv: Invocation, kind: string, group: string?, name: string): Types.ResourceRef
	return {
		clusterContext = inv.context,
		namespace = inv.namespace,
		group = group,
		version = nil,
		kind = kind,
		name = name,
		uid = nil,
		source = "snapshot",
	}
end

-- rollout history ---------------------------------------------------------------

local function buildHistory(inv: Invocation, lines: { string }): Built
	local parsed = RolloutHistory.parseList(lines)
	local detail = newDetail("history")
	local history: { [string]: HistoryRow } = {}
	detail.history = history
	local seen: { [string]: number } = {}
	local tables: { SnapshotTable } = {}
	for _, obj in parsed.objects do
		local top = 0
		for _, r in obj.revisions do
			top = math.max(top, r.revision)
		end
		local ref = workloadRef(inv, obj.kind, obj.group, obj.name)
		local rows: { ResourceRow } = table.create(#obj.revisions)
		for i, r in obj.revisions do
			local key = uniqueKey(seen, string.format("%s/%s@%d", obj.type, obj.name, r.revision))
			rows[i] = {
				key = key,
				ref = ref,
				cells = { tostring(r.revision), r.cause or "<none>" },
				rawLines = { r.line },
				warnings = {},
			}
			history[key] = { object = obj, revision = r.revision, cause = r.cause, current = r.revision == top }
			if r.revision == top then
				detail.notes[key] = { REVISION = "current" }
			end
		end
		table.insert(
			tables,
			withTypes({
				kind = obj.kind,
				group = obj.group,
				headers = { "REVISION", "CHANGE-CAUSE" },
				types = {},
				rows = rows,
				title = obj.type .. "/" .. obj.name,
				facets = {},
			})
		)
	end
	return {
		detail = detail,
		tables = tables,
		diagnostics = parsed.diagnostics,
		unparsed = unparsedOf(parsed.diagnostics),
		describe = nil,
	}
end

local function field(fields: { Types.DescribeField }, key: string): Types.DescribeField?
	for _, f in fields do
		if f.key == key then
			return f
		end
	end
	return nil
end

local CHANGE_CAUSE = "^%s*kubernetes%.io/change%-cause:%s*(.-)%s*$"

local function revisionFacts(describe: Types.DescribeParse): (string?, { string })
	local obj = describe.objects[1]
	local images: { string } = {}
	if obj == nil then
		return nil, images
	end
	local template = field(obj.fields, "Pod Template")
	local fields = if template then template.children else obj.fields
	local cause: string? = nil
	local annotations = field(fields, "Annotations")
	if annotations then
		for _, v in annotations.values do
			local c = string.match(v, CHANGE_CAUSE)
			if c then
				cause = c
			end
		end
	end
	for _, section in { "Init Containers", "Containers" } do
		local containers = field(fields, section)
		local list: { Types.DescribeField } = if containers then containers.children else {}
		for _, c in list do
			local image = field(c.children, "Image")
			if image and image.value ~= "" then
				table.insert(images, image.value)
			end
		end
	end
	return cause, images
end

local function buildRevision(inv: Invocation, lines: { string }): Built
	local parsed = RolloutHistory.parseRevision(lines)
	local detail = newDetail("revision")
	if parsed.kind and parsed.name and parsed.revision and parsed.type then
		local cause, images = revisionFacts(parsed.describe)
		detail.revision = {
			ref = workloadRef(inv, parsed.kind :: string, parsed.group, parsed.name :: string),
			type = parsed.type :: string,
			revision = parsed.revision :: number,
			cause = cause,
			images = images,
		}
	end
	return {
		detail = detail,
		tables = nil,
		diagnostics = parsed.diagnostics,
		unparsed = unparsedOf(parsed.diagnostics),
		describe = parsed.describe,
	}
end

-- config get-contexts -------------------------------------------------------------

local function buildContexts(inv: Invocation, lines: { string }): Built
	local form: Contexts.Form = if inv.output == "name" then "name" elseif inv.noHeaders then "noheaders" else "table"
	local parsed = Contexts.parse(lines, form)
	local detail = newDetail("contexts")
	local byKey: { [string]: Contexts.ContextRow } = {}
	detail.contexts = byKey
	if inv.context and form ~= "name" then
		table.insert(detail.headerNotes, M.CONTEXT_NOTE)
	end
	local seen: { [string]: number } = {}
	local rows: { ResourceRow } = table.create(#parsed.rows)
	for i, c in parsed.rows do
		local key = uniqueKey(seen, "context/" .. c.name)
		byKey[key] = c
		rows[i] = { key = key, ref = nil, cells = c.cells, rawLines = { c.line }, warnings = {} }
		if c.current then
			detail.notes[key] = { CURRENT = "current" }
		end
	end
	local tables: { SnapshotTable } = {}
	if #rows > 0 or form ~= "name" then
		table.insert(
			tables,
			withTypes({
				kind = nil,
				group = nil,
				headers = parsed.headers,
				types = {},
				rows = rows,
				title = nil,
				facets = { "CLUSTER", "AUTHINFO" },
			})
		)
	end
	return {
		detail = detail,
		tables = tables,
		diagnostics = parsed.diagnostics,
		unparsed = unparsedOf(parsed.diagnostics),
		describe = nil,
	}
end

-- api-resources --------------------------------------------------------------------

M.CORE = "core"

local function buildApiResources(lines: { string }, status: number?): Built
	-- The lens gets stdout and stderr interleaved: kubectl's messages go back
	-- to stderr for the parser (it reads partial discovery from there).
	local out: { string } = {}
	local origin: { number } = {}
	local errs: { string } = {}
	for n, line in lines do
		if TableParser.classify(line, n) then
			table.insert(errs, line)
		else
			table.insert(out, line)
			table.insert(origin, n)
		end
	end
	local parsed = Discovery.parse(table.concat(out, "\n"), table.concat(errs, "\n"), status)
	local diagnostics: { Diagnostic } = {}
	for _, d in parsed.diagnostics do
		local copy = table.clone(d)
		copy.line = if d.line then origin[d.line] else nil
		table.insert(diagnostics, copy)
	end
	if parsed.partial then
		table.insert(diagnostics, {
			line = nil,
			severity = "warning",
			text = "Partial discovery: " .. parsed.partial .. " could not be read; its resources are missing below",
		})
	end
	local tableForm = TableParser.parse(out)
	local headers: { string } = { "NAME" }
	local cellsByLine: { [number]: { string } } = {}
	local first = tableForm.tables[1]
	if first and first.columns[1] and first.columns[1].name == "NAME" and #tableForm.tables == 1 then
		headers = {}
		for i, c in first.columns do
			headers[i] = c.name
		end
		for _, r in first.rows do
			cellsByLine[r.line] = r.cells
		end
	end
	local detail = newDetail("apiresources")
	local kinds: { [string]: Discovery.KindRow } = {}
	detail.kinds = kinds
	local seen: { [string]: number } = {}
	local rows: { ResourceRow } = {}
	local wide, categorized = false, false
	for _, k in parsed.rows do
		local line = k.line or 0
		local key = uniqueKey(seen, "api/" .. k.name)
		kinds[key] = k
		local tags: { [string]: { string } } = { GROUP = { k.group or M.CORE } }
		if k.verbs then
			wide = true
			tags.VERB = table.clone(k.verbs)
		end
		if k.categories and #k.categories > 0 then
			categorized = true
			tags.CATEGORY = table.clone(k.categories)
		end
		local text = out[line] or k.name
		table.insert(rows, {
			key = key,
			ref = nil,
			cells = cellsByLine[line] or { (string.gsub(text, "%s+$", "")) },
			rawLines = { origin[line] },
			warnings = {},
			tags = tags,
		})
	end
	local facets = { "NAMESPACED", "GROUP" }
	if wide then
		table.insert(facets, "VERB")
	end
	if categorized then
		table.insert(facets, "CATEGORY")
	end
	return {
		detail = detail,
		tables = {
			withTypes({
				kind = nil,
				group = nil,
				headers = headers,
				types = {},
				rows = rows,
				title = nil,
				facets = facets,
			}),
		},
		diagnostics = diagnostics,
		unparsed = unparsedOf(diagnostics),
		describe = nil,
	}
end

-- auth can-i --------------------------------------------------------------------------

local function buildCani(inv: Invocation, lines: { string }, status: number?): Built
	local answer = Cani.answer(lines, status, truthy(inv, "quiet"))
	local detail = newDetail("cani")
	detail.cani = { answer = answer, question = Cani.question(inv) }
	return {
		detail = detail,
		tables = nil,
		diagnostics = answer.diagnostics,
		unparsed = unparsedOf(answer.diagnostics),
		describe = nil,
	}
end

M.ALL = "all"

local function buildCaniList(inv: Invocation, lines: { string }): Built
	local parsed = Cani.list(lines)
	local detail = newDetail("canilist")
	if Cani.question(inv).impersonated then
		table.insert(detail.headerNotes, M.IMPERSONATED_NOTE)
	end
	local rules: { [string]: Cani.Rule } = {}
	detail.rules = rules
	local seen: { [string]: number } = {}
	local rows: { ResourceRow } = table.create(#parsed.rules)
	for i, rule in parsed.rules do
		local key = uniqueKey(seen, "rule/" .. table.concat(rule.cells, " "))
		rules[key] = rule
		local resource = rule.resource ~= nil
		local tags: { [string]: { string } } = {
			TYPE = { if resource then "resource" else "non-resource" },
			VERB = table.clone(rule.verbs),
		}
		if resource then
			tags.GROUP = { rule.group or M.CORE }
		end
		local notes: { [string]: string } = {}
		if rule.resource == "*" then
			notes.Resources = M.ALL
		end
		if table.find(rule.urls, "*") then
			notes["Non-Resource URLs"] = M.ALL
		end
		if table.find(rule.verbs, "*") then
			notes.Verbs = M.ALL
		end
		if next(notes) then
			detail.notes[key] = notes
		end
		rows[i] = { key = key, ref = nil, cells = rule.cells, rawLines = { rule.line }, warnings = {}, tags = tags }
	end
	return {
		detail = detail,
		tables = {
			withTypes({
				kind = nil,
				group = nil,
				headers = table.clone(Cani.HEADERS :: any),
				types = {},
				rows = rows,
				title = nil,
				facets = { "TYPE", "VERB", "GROUP" },
			}),
		},
		diagnostics = parsed.diagnostics,
		unparsed = unparsedOf(parsed.diagnostics),
		describe = nil,
	}
end

function M.build(mode: Mode, inv: Invocation, lines: { string }, status: number?): Built
	if mode == "history" then
		return buildHistory(inv, lines)
	elseif mode == "revision" then
		return buildRevision(inv, lines)
	elseif mode == "contexts" then
		return buildContexts(inv, lines)
	elseif mode == "apiresources" then
		return buildApiResources(lines, status)
	elseif mode == "cani" then
		return buildCani(inv, lines, status)
	end
	return buildCaniList(inv, lines)
end

-- Table-shaped modes render through TableView.
M.TABLE_MODES =
	table.freeze({ history = true, contexts = true, apiresources = true, canilist = true } :: { [string]: boolean })

return M
