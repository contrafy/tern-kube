--!strict
-- Turns one captured kubectl run (argv, output lines, exit status) into the
-- immutable model every lens view renders. Pure: no clock, no I/O; the JSON
-- decoder is injected so the same code runs under standalone luau.

local Argv = require("../kubectl/argv")
local Describe = require("../parse/describe")
local Json = require("../parse/json")
local Kinds = require("../kubectl/kinds")
local Mutation = require("../parse/mutation")
local Resource = require("../model/resource")
local TableParser = require("../parse/table")
local Types = require("../model/types")
local Values = require("../model/values")
local Yaml = require("../parse/yaml")

export type Mode = "table" | "json" | "yaml" | "describe" | "mutation" | "name" | "raw"

export type Capture = {
	invocation: Types.Invocation,
	support: { supported: boolean, reason: string? },
	status: number?,
	lineCount: number,
	-- The lines the capture was built from (trailing ^C dropped); source for
	-- the Inspect view's raw excerpt.
	lines: { string },
	mode: Mode,
	snapshot: Types.Snapshot?,
	objects: { [string]: any }?,
	yaml: Yaml.SplitResult?,
	yamlLines: { string }?,
	describe: Types.DescribeParse?,
	mutation: Types.MutationParse?,
	diagnostics: { Types.Diagnostic },
	-- Output lines that were neither table rows nor recognised kubectl messages.
	unparsed: number,
	sensitive: boolean,
}

export type Run = { program: string, args: { string } }
export type Deps = { decode: (string) -> any }

type ParsedTable = Types.ParsedTable
type SnapshotTable = Types.SnapshotTable
type ResourceRow = Types.ResourceRow
type Invocation = Types.Invocation

local M = {}

local MUTATION_VERBS: { [string]: boolean } = { apply = true, delete = true, scale = true, rollout = true }

local function modeFor(inv: Invocation, supported: boolean): Mode
	if not supported then
		return "raw"
	end
	local verb = inv.verb
	if inv.output == "json" then
		return "json"
	elseif inv.output == "yaml" then
		return "yaml"
	elseif inv.output == "name" then
		return "name"
	elseif verb == "describe" then
		return "describe"
	elseif verb ~= nil and MUTATION_VERBS[verb] then
		return "mutation"
	elseif verb == "get" or verb == "top" then
		return "table"
	end
	return "raw"
end

-- Mode from argv alone (cheap): lets the host skip building captures that
-- are only meaningful once the command finished.
function M.modeOf(run: Run): Mode
	local inv = Argv.parse(run.program, run.args)
	return modeFor(inv, Argv.lensSupport(inv).supported)
end

local function withoutInterrupt(lines: { string }): { string }
	local n = #lines
	if n > 0 and string.find(lines[n], "^%^C") then
		return table.move(lines, 1, n - 1, 1, table.create(n - 1))
	end
	return lines
end

-- Columns kubectl prints for the common built-in kinds, used only to name
-- `--no-headers` output. Anything else gets numbered columns.
local BASE_HEADERS: { [string]: { string } } = {
	Pod = { "NAME", "READY", "STATUS", "RESTARTS", "AGE" },
	Deployment = { "NAME", "READY", "UP-TO-DATE", "AVAILABLE", "AGE" },
	Service = { "NAME", "TYPE", "CLUSTER-IP", "EXTERNAL-IP", "PORT(S)", "AGE" },
	Node = { "NAME", "STATUS", "ROLES", "AGE", "VERSION" },
	Namespace = { "NAME", "STATUS", "AGE" },
}

local WIDE_HEADERS: { [string]: { string } } = {
	Pod = { "IP", "NODE", "NOMINATED NODE", "READINESS GATES" },
	Deployment = { "CONTAINERS", "IMAGES", "SELECTOR" },
	Service = { "SELECTOR" },
	Node = { "INTERNAL-IP", "EXTERNAL-IP", "OS-IMAGE", "KERNEL-VERSION", "CONTAINER-RUNTIME" },
}

local function knownHeaders(inv: Invocation): { string }?
	local kind = if #inv.resources > 0 then inv.resources[1].kind else nil
	for _, r in inv.resources do
		if r.kind ~= kind then
			return nil
		end
	end
	local base = if kind then BASE_HEADERS[kind] else nil
	if kind == nil or base == nil then
		return nil
	end
	local out: { string } = {}
	if inv.allNamespaces and kind ~= "Node" and kind ~= "Namespace" then
		table.insert(out, "NAMESPACE")
	end
	for _, h in base do
		table.insert(out, h)
	end
	if inv.output == "wide" then
		local wide: { string } = WIDE_HEADERS[kind] or {}
		for _, h in wide do
			table.insert(out, h)
		end
	end
	if inv.showLabels then
		table.insert(out, "LABELS")
	end
	return out
end

local function parseTables(inv: Invocation, lines: { string }): TableParser.Result
	if not inv.noHeaders then
		return TableParser.parse(lines)
	end
	local known = knownHeaders(inv)
	if known then
		local result = TableParser.parse(lines, { noHeaders = true, knownColumns = known })
		local rows = 0
		for _, t in result.tables do
			rows += #t.rows
		end
		if rows > 0 then
			return result
		end
	end
	local result = TableParser.parse(lines, { noHeaders = true })
	for _, t in result.tables do
		for i, col in t.columns do
			if col.name == "" then
				col.name = "COLUMN " .. i
			end
		end
	end
	return result
end

local function indexOf(headers: { string }, name: string): number?
	for i, h in headers do
		if h == name then
			return i
		end
	end
	return nil
end

-- `get all`, `get pods,svc` and `--show-kind` print NAME as `kind[.group]/name`.
local function commonPrefix(rows: { Types.TableRow }, nameCol: number): string?
	local prefix: string? = nil
	for _, row in rows do
		local p = string.match(row.cells[nameCol] or "", "^([^/]+)/.+$")
		if p == nil or (prefix ~= nil and p ~= prefix) then
			return nil
		end
		prefix = p
	end
	return prefix
end

type KindGuess = { kind: string?, group: string?, namespaced: boolean? }

local function tableKind(inv: Invocation, parsed: ParsedTable, nameCol: number?): (KindGuess, boolean)
	if nameCol then
		local prefix = commonPrefix(parsed.rows, nameCol)
		if prefix then
			local info = Kinds.fromPrefix(prefix)
			return { kind = info.kind, group = info.group, namespaced = info.namespaced }, true
		end
	end
	local kinds: { [string]: boolean } = {}
	local first: Types.ResourceArg? = nil
	local count = 0
	for _, r in inv.resources do
		local id = r.kind .. "." .. (r.group or "")
		if not kinds[id] then
			kinds[id] = true
			count += 1
			first = first or r
		end
	end
	if inv.verb == "top" and count == 0 then
		local kind = if inv.subverb == "node" then "Node" elseif inv.subverb == "pod" then "Pod" else nil
		return { kind = kind, group = nil, namespaced = kind == "Pod" }, false
	end
	if count ~= 1 or first == nil or first.kind == "all" then
		return { kind = nil, group = nil, namespaced = nil }, false
	end
	local info = Kinds.normalize(first.kind)
	return {
		kind = first.kind,
		group = first.group,
		namespaced = if info.known then info.namespaced else nil,
	},
		false
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

local function snapshotTable(
	inv: Invocation,
	parsed: ParsedTable,
	tableIndex: number,
	seen: { [string]: number }
): SnapshotTable
	local headers: { string } = table.create(#parsed.columns)
	for i, col in parsed.columns do
		headers[i] = col.name
	end
	local cellRows: { { string } } = table.create(#parsed.rows)
	for i, row in parsed.rows do
		cellRows[i] = row.cells
	end
	local nameCol = indexOf(headers, "NAME")
	local nsCol = indexOf(headers, "NAMESPACE")
	local guess, prefixed = tableKind(inv, parsed, nameCol)
	local rows: { ResourceRow } = table.create(#parsed.rows)
	for i, row in parsed.rows do
		local name = if nameCol then row.cells[nameCol] else nil
		if name and prefixed then
			name = string.match(name, "^[^/]+/(.+)$")
		end
		local ref: Types.ResourceRef? = nil
		local key: string
		if guess.kind and name and name ~= "" and not Values.isPlaceholder(name) then
			local namespace: string? = nil
			if guess.namespaced ~= false then
				namespace = if nsCol then row.cells[nsCol] else inv.namespace
			end
			ref = {
				clusterContext = inv.context,
				namespace = namespace,
				group = guess.group,
				version = nil,
				kind = guess.kind :: string,
				name = name :: string,
				uid = nil,
				source = "snapshot",
			}
			key = Resource.key(ref :: Types.ResourceRef)
		else
			key = "t" .. tableIndex .. "#" .. i
		end
		rows[i] = {
			key = uniqueKey(seen, key),
			ref = ref,
			cells = row.cells,
			rawLines = { row.line },
			warnings = {},
		}
	end
	return {
		kind = guess.kind,
		group = guess.group,
		headers = headers,
		types = columnTypes(headers, cellRows),
		rows = rows,
	}
end

local function isUnrecognised(d: Types.Diagnostic): boolean
	return d.severity == "info" and TableParser.classify(d.text) == nil
end

local function confidenceOf(unparsed: number): Types.Confidence
	return if unparsed > 0 then "partial" else "high"
end

local function buildTable(inv: Invocation, lines: { string }, status: number?, capture: Capture)
	local result = parseTables(inv, lines)
	local seen: { [string]: number } = {}
	local tables: { SnapshotTable } = table.create(#result.tables)
	local unparsed = 0
	for i, parsed in result.tables do
		tables[i] = snapshotTable(inv, parsed, i, seen)
		unparsed += #parsed.unparsed
	end
	for _, d in result.diagnostics do
		if isUnrecognised(d) then
			unparsed += 1
		end
	end
	capture.diagnostics = result.diagnostics
	capture.unparsed = unparsed
	capture.snapshot = {
		invocation = inv,
		exitCode = status,
		tables = tables,
		diagnostics = result.diagnostics,
		truncated = false,
		confidence = confidenceOf(unparsed),
		reason = nil,
	}
end

local function buildName(inv: Invocation, lines: { string }, status: number?, capture: Capture)
	local diagnostics: { Types.Diagnostic } = {}
	local groups: { { prefix: string, rows: { Types.TableRow } } } = {}
	local byPrefix: { [string]: { prefix: string, rows: { Types.TableRow } } } = {}
	local unparsed = 0
	for n, line in lines do
		if string.find(line, "^%s*$") then
			continue
		end
		local d = TableParser.classify(line, n)
		if d then
			table.insert(diagnostics, d)
			continue
		end
		local text = string.match(line, "^(.-)%s*$") :: string
		local prefix = string.match(text, "^([^/%s]+)/%S+$")
		if prefix == nil then
			unparsed += 1
			table.insert(diagnostics, { line = n, severity = "info", text = text })
			continue
		end
		local group = byPrefix[prefix]
		if group == nil then
			group = { prefix = prefix, rows = {} }
			byPrefix[prefix] = group
			table.insert(groups, group)
		end
		table.insert(group.rows, { cells = { text }, line = n })
	end
	local seen: { [string]: number } = {}
	local tables: { SnapshotTable } = {}
	for i, group in groups do
		local parsed: ParsedTable = {
			columns = { { name = "NAME", start = 1, stop = nil } },
			rows = group.rows,
			headerLine = nil,
			unparsed = {},
		}
		table.insert(tables, snapshotTable(inv, parsed, i, seen))
	end
	capture.diagnostics = diagnostics
	capture.unparsed = unparsed
	capture.snapshot = {
		invocation = inv,
		exitCode = status,
		tables = tables,
		diagnostics = diagnostics,
		truncated = false,
		confidence = confidenceOf(unparsed),
		reason = nil,
	}
end

local function kubectlMessages(lines: { string }): { Types.Diagnostic }
	local out: { Types.Diagnostic } = {}
	for n, line in lines do
		local d = TableParser.classify(line, n)
		if d then
			table.insert(out, d)
		end
	end
	return out
end

local function buildJson(inv: Invocation, lines: { string }, status: number?, capture: Capture, deps: Deps)
	local diagnostics: { Types.Diagnostic }
	local tables: { SnapshotTable } = {}
	local objects: { [string]: any } = {}
	local unparsed = 0
	if #lines == 0 then
		diagnostics = {}
	else
		local result = Json.parse(table.concat(lines, "\n"), deps.decode)
		diagnostics = result.diagnostics
		if result.kind == "invalid" then
			local messages = kubectlMessages(lines)
			if #messages > 0 then
				diagnostics = messages
			else
				unparsed = #lines
			end
		end
		local byShape: { [string]: SnapshotTable } = {}
		local seen: { [string]: number } = {}
		for _, res in result.resources do
			local ref = table.clone(res.ref)
			ref.clusterContext = inv.context
			local shape = (ref.group or "") .. "/" .. ref.kind .. "/" .. table.concat(res.summary.headers, "\t")
			local tbl = byShape[shape]
			if tbl == nil then
				local created: SnapshotTable = {
					kind = ref.kind,
					group = ref.group,
					headers = res.summary.headers,
					types = {},
					rows = {},
				}
				tbl = created
				byShape[shape] = created
				table.insert(tables, created)
			end
			local key = uniqueKey(seen, Resource.key(ref))
			table.insert((tbl :: SnapshotTable).rows, {
				key = key,
				ref = ref,
				cells = res.summary.cells,
				rawLines = {},
				warnings = {},
			})
			objects[key] = Json.redactSecrets(res)
			if ref.kind == "Secret" then
				capture.sensitive = true
			end
		end
		for _, tbl in tables do
			local cellRows: { { string } } = table.create(#tbl.rows)
			for i, row in tbl.rows do
				cellRows[i] = row.cells
			end
			tbl.types = columnTypes(tbl.headers, cellRows)
		end
	end
	capture.diagnostics = diagnostics
	capture.unparsed = unparsed
	capture.objects = objects
	capture.snapshot = {
		invocation = inv,
		exitCode = status,
		tables = tables,
		diagnostics = diagnostics,
		truncated = false,
		confidence = confidenceOf(unparsed),
		reason = nil,
	}
end

local function buildYaml(lines: { string }, capture: Capture)
	local split = Yaml.splitLines(lines)
	capture.yaml = split
	capture.yamlLines = Yaml.redactSecretData(lines, split.docs)
	capture.diagnostics = split.diagnostics
	for _, doc in split.docs do
		if doc.kind == "Secret" then
			capture.sensitive = true
		end
	end
end

function M.build(run: Run, rawLines: { string }, status: number?, deps: Deps): Capture
	local inv = Argv.parse(run.program, run.args)
	local support = Argv.lensSupport(inv)
	local lines = withoutInterrupt(rawLines)
	local mode: Mode = modeFor(inv, support.supported)
	local capture: Capture = {
		invocation = inv,
		support = support,
		status = status,
		lineCount = #lines,
		lines = lines,
		mode = mode,
		snapshot = nil,
		objects = nil,
		yaml = nil,
		yamlLines = nil,
		describe = nil,
		mutation = nil,
		diagnostics = {},
		unparsed = 0,
		sensitive = false,
	}
	if mode == "table" then
		buildTable(inv, lines, status, capture)
	elseif mode == "name" then
		buildName(inv, lines, status, capture)
	elseif mode == "json" then
		buildJson(inv, lines, status, capture, deps)
	elseif mode == "yaml" then
		buildYaml(lines, capture)
	elseif mode == "describe" then
		local parsed = Describe.parse(lines)
		capture.describe = parsed
		capture.diagnostics = parsed.diagnostics
	elseif mode == "mutation" then
		local verb = if inv.verb == "rollout" then "rollout restart" else inv.verb :: string
		local parsed = Mutation.parse(verb, lines)
		capture.mutation = parsed
		capture.diagnostics = parsed.diagnostics
	end
	return capture
end

-- Rows of every table, in display order, for lookups by key.
function M.findRow(capture: Capture, key: string): (ResourceRow?, SnapshotTable?)
	local snapshot = capture.snapshot
	if snapshot == nil then
		return nil, nil
	end
	for _, tbl in snapshot.tables do
		for _, row in tbl.rows do
			if row.key == key then
				return row, tbl
			end
		end
	end
	return nil, nil
end

return M
