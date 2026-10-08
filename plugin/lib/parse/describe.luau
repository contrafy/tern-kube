--!strict
-- Reads `kubectl describe` text: objects start at a column-0 `Name:` line,
-- nesting follows indentation, values continued on following lines are
-- aligned to the value column, and embedded tables (Events, Conditions, node
-- pod lists) are recognised by their header row, usually underlined.

local Types = require("../model/types")

type Column = Types.Column
type Diagnostic = Types.Diagnostic
type DescribeEvent = Types.DescribeEvent
type DescribeField = Types.DescribeField
type DescribeObject = Types.DescribeObject
type DescribeParse = Types.DescribeParse
type ParsedTable = Types.ParsedTable
type TableRow = Types.TableRow

type Frame = { indent: number, field: DescribeField }
type Continuation = { field: DescribeField, column: number }
type Draft = { line: number, fields: { DescribeField }, stack: { Frame } }

local M = {}

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function indentOf(line: string): number
	local spaces = string.match(line, "^ *") or ""
	return #spaces
end

local function isBlank(line: string?): boolean
	return line == nil or string.find(line, "%S") == nil
end

local function runeColumn(line: string, bytePos: number): number
	return (utf8.len(string.sub(line, 1, bytePos - 1)) or (bytePos - 1)) + 1
end

local function isUnderline(line: string?): boolean
	return line ~= nil and string.match(line, "^ *%-[%- ]*$") ~= nil
end

local function diagnosticSeverity(line: string): ("error" | "warning" | "info")?
	if string.match(line, "^[Ee]rror[%s:]") ~= nil or string.match(line, "^[Uu]nable to ") ~= nil then
		return "error"
	end
	if string.match(line, "^Warning:") ~= nil or string.match(line, "^W%d%d%d%d %d") ~= nil then
		return "warning"
	end
	if string.match(line, "^No resources found") ~= nil then
		return "info"
	end
	return nil
end

-- Column starts come from the dash runs of the underline; without one, from
-- header words separated by at least two spaces (describe pads with two).
local function columnsFrom(header: string, underline: string?): { Column }
	local starts: { number } = {}
	if underline then
		for pos in string.gmatch(underline, "()%-+") do
			table.insert(starts, pos :: number)
		end
	else
		local pos = 1
		while true do
			local from = string.find(header, "%S", pos)
			if from == nil then
				break
			end
			table.insert(starts, from)
			local gap = string.find(header, "%s%s", from)
			if gap == nil then
				break
			end
			pos = gap
		end
	end
	local columns: { Column } = {}
	for i, start in starts do
		local nextStart = starts[i + 1]
		local stop = if nextStart then nextStart - 1 else nil
		local name = trim(string.sub(header, start, stop or #header))
		table.insert(columns, {
			name = name,
			start = runeColumn(header, start),
			stop = if nextStart then runeColumn(header, nextStart) - 1 else nil,
		})
	end
	return columns
end

-- Returns nil when a column boundary cuts through text: such rows were not
-- aligned to the header (the ingress rules printer does this).
local function cellsOf(line: string, columns: { Column }): { string }?
	local ascii = string.find(line, "[\128-\255]") == nil
	local function byteAt(column: number): number
		if ascii then
			return column
		end
		return utf8.offset(line, column) or (#line + 1)
	end
	local cells: { string } = table.create(#columns)
	for i, column in columns do
		local from = byteAt(column.start)
		if i > 1 and from > 1 and from <= #line then
			if string.find(line, "^%S%S", from - 1) then
				return nil
			end
		end
		local stop = column.stop
		local to = if stop then byteAt(stop + 1) - 1 else #line
		cells[i] = trim(string.sub(line, from, to))
	end
	return cells
end

local EVENT_KEYS: { [string]: string } = {
	type = "type",
	reason = "reason",
	age = "age",
	["last seen"] = "age",
	lastseen = "age",
	from = "from",
	message = "message",
}

local function eventsOf(tbl: ParsedTable): { DescribeEvent }
	local slots: { [string]: number } = {}
	for i, column in tbl.columns do
		local key = EVENT_KEYS[string.lower(column.name)]
		if key and slots[key] == nil then
			slots[key] = i
		end
	end
	local function pick(row: TableRow, key: string): string
		local slot = slots[key]
		return if slot then row.cells[slot] or "" else ""
	end
	local events: { DescribeEvent } = {}
	for _, row in tbl.rows do
		table.insert(events, {
			type = pick(row, "type"),
			reason = pick(row, "reason"),
			age = pick(row, "age"),
			from = pick(row, "from"),
			message = pick(row, "message"),
			line = row.line,
		})
	end
	return events
end

local function topLevel(fields: { DescribeField }): ({ [string]: DescribeField }, { [string]: boolean })
	local byKey: { [string]: DescribeField } = {}
	local plain: { [string]: boolean } = {}
	for _, field in fields do
		if field.key == "" then
			plain[field.value] = true
		elseif byKey[field.key] == nil then
			byKey[field.key] = field
		end
	end
	return byKey, plain
end

type KindRule = { kind: string, test: ({ [string]: DescribeField }, { [string]: boolean }) -> boolean }

local function has(...: string): ({ [string]: DescribeField }, { [string]: boolean }) -> boolean
	local keys = { ... }
	return function(byKey)
		for _, key in keys do
			if byKey[key] == nil then
				return false
			end
		end
		return true
	end
end

local KIND_RULES: { KindRule } = {
	{ kind = "Pod", test = has("QoS Class") },
	{ kind = "Deployment", test = has("NewReplicaSet") },
	{ kind = "StatefulSet", test = has("Update Strategy", "Volume Claims") },
	{ kind = "DaemonSet", test = has("Desired Number of Nodes Scheduled") },
	{
		kind = "ReplicaSet",
		test = function(byKey)
			local owner = byKey["Controlled By"]
			return byKey["Pods Status"] ~= nil
				and owner ~= nil
				and string.sub(owner.value, 1, #"Deployment/") == "Deployment/"
		end,
	},
	{ kind = "Job", test = has("Completions", "Pods Statuses") },
	{ kind = "CronJob", test = has("Concurrency Policy") },
	{ kind = "Node", test = has("System Info", "Taints") },
	{ kind = "Service", test = has("Session Affinity") },
	{
		kind = "Namespace",
		test = function(byKey, plain)
			return byKey["Resource Quotas"] ~= nil or plain["No resource quota."] == true
		end,
	},
	{
		kind = "ConfigMap",
		test = function(_, plain)
			return plain["BinaryData"] == true
		end,
	},
	{
		kind = "Secret",
		test = function(byKey, plain)
			return byKey["Type"] ~= nil and plain["Data"] == true and plain["BinaryData"] == nil
		end,
	},
	{ kind = "ServiceAccount", test = has("Mountable secrets") },
	{ kind = "PersistentVolumeClaim", test = has("StorageClass", "Used By") },
	{ kind = "PersistentVolume", test = has("Reclaim Policy", "Claim") },
	{ kind = "Ingress", test = has("Ingress Class") },
	{ kind = "HorizontalPodAutoscaler", test = has("Reference", "Min replicas") },
	{ kind = "Endpoints", test = has("Subsets") },
}

local function inferKind(fields: { DescribeField }): string?
	local byKey, plain = topLevel(fields)
	local explicit = byKey["Kind"]
	if explicit and explicit.value ~= "" then
		return explicit.value
	end
	local found: string? = nil
	for _, rule in KIND_RULES do
		if rule.test(byKey, plain) then
			if found then
				return nil
			end
			found = rule.kind
		end
	end
	return found
end

local function finish(draft: Draft): DescribeObject
	local byKey = topLevel(draft.fields)
	local namespace = byKey["Namespace"]
	local nsValue = if namespace then namespace.value else ""
	local eventsField = byKey["Events"]
	local events: { DescribeEvent }? = nil
	if eventsField then
		local tbl = eventsField.table
		events = if tbl then eventsOf(tbl) else {}
	end
	local nameField = byKey["Name"]
	return {
		name = if nameField then nameField.value else "",
		namespace = if nsValue ~= "" and nsValue ~= "<none>" then nsValue else nil,
		kind = inferKind(draft.fields),
		line = draft.line,
		fields = draft.fields,
		events = events,
	}
end

local function newField(key: string, value: string, lineNo: number): DescribeField
	return {
		key = key,
		value = value,
		values = if value ~= "" then { value } else {},
		line = lineNo,
		children = {},
	}
end

local function attach(draft: Draft, parent: DescribeField?, field: DescribeField)
	table.insert(if parent then parent.children else draft.fields, field)
end

function M.parse(lines: { string }): DescribeParse
	local objects: { DescribeObject } = {}
	local diagnostics: { Diagnostic } = {}
	local draft: Draft? = nil
	local continuation: Continuation? = nil
	local count = #lines
	local i = 1
	while i <= count do
		local line = lines[i]
		if isBlank(line) then
			continuation = nil
			i += 1
			continue
		end
		local indent = indentOf(line)
		if indent == 0 then
			local severity = diagnosticSeverity(line)
			if severity then
				local diagnostic: Diagnostic =
					{ line = i, severity = severity :: "error" | "warning" | "info", text = trim(line) }
				table.insert(diagnostics, diagnostic)
				continuation = nil
				i += 1
				continue
			end
			if string.match(line, "^Name:") then
				if draft then
					table.insert(objects, finish(draft))
				end
				draft = { line = i, fields = {}, stack = {} }
				continuation = nil
			end
		end
		local current = draft
		if current == nil then
			table.insert(diagnostics, { line = i, severity = "info", text = trim(line) })
			i += 1
			continue
		end
		if continuation and indent >= continuation.column - 1 then
			local nested = string.rep(" ", indent - (continuation.column - 1))
			table.insert(continuation.field.values, nested .. trim(line))
			i += 1
			continue
		end
		continuation = nil

		local stack = current.stack
		while #stack > 0 and stack[#stack].indent >= indent do
			table.remove(stack)
		end
		local parentFrame = stack[#stack]
		local parent = if parentFrame then parentFrame.field else nil

		local nextLine = lines[i + 1]
		local underlined = isUnderline(nextLine) and indentOf(nextLine) == indent
		local conditionsHeader = parent ~= nil
			and parent.key == "Conditions"
			and #parent.children == 0
			and parent.table == nil
			and string.match(line, "^%s*Type%s%s+Status") ~= nil
		if underlined or conditionsHeader then
			local columns = columnsFrom(line, if underlined then nextLine else nil)
			local rows: { TableRow } = {}
			local unparsed: { Types.RawLine } = {}
			local j = if underlined then i + 2 else i + 1
			while j <= count do
				local rowLine = lines[j]
				if isBlank(rowLine) or indentOf(rowLine) < indent or indentOf(rowLine) == 0 then
					break
				end
				local cells = cellsOf(rowLine, columns)
				if cells then
					table.insert(rows, { cells = cells, line = j })
				else
					table.insert(unparsed, { line = j, text = trim(rowLine) })
				end
				j += 1
			end
			local tbl: ParsedTable = { columns = columns, rows = rows, headerLine = i, unparsed = unparsed }
			if parent and parent.table == nil then
				parent.table = tbl
			else
				local holder = newField("", "", i)
				holder.table = tbl
				attach(current, parent, holder)
			end
			i = j
			continue
		end

		local content = string.sub(line, indent + 1)
		local key, rest = string.match(content, "^([^%s:][^:]-):%s+(.*)$")
		if key == nil then
			key = string.match(content, "^([^%s:][^:]-):$")
			rest = ""
		end
		local field: DescribeField
		local commandArgs = parent ~= nil and (parent.key == "Command" or parent.key == "Args")
		if
			key
			and rest
			and not commandArgs
			and string.find(key, "^[%w%s%-%._/()]+$")
			and not string.find(key, "  ", 1, true)
		then
			local value = trim(rest)
			field = newField(key, value, i)
			if value ~= "" then
				local valueByte = indent + #content - #rest + 1
				local leading = string.match(rest, "^%s*") or ""
				valueByte += #leading
				continuation = { field = field, column = runeColumn(line, valueByte) }
			end
		else
			field = newField("", trim(content), i)
		end
		attach(current, parent, field)
		table.insert(stack, { indent = indent, field = field })
		i += 1
	end
	if draft then
		table.insert(objects, finish(draft))
	end
	return { objects = objects, diagnostics = diagnostics }
end

return M
