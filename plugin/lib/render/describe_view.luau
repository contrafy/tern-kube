--!strict
-- `kubectl describe` as one card per object: scalar fields as key/values,
-- nested blocks as disclosure sections, embedded tables as tables and the
-- Events table as a timeline whose Warning rows stand out. Nothing here is
-- clickable beyond Tern's own disclosure toggles, which need no view state.

local Capture = require("../lens/capture")
local Cells = require("./cells")
local Types = require("../model/types")
local Values = require("../model/values")
local Viewstate = require("../lens/viewstate")
local ui = require("../ui")

type Capture = Capture.Capture
type DescribeField = Types.DescribeField
type DescribeObject = Types.DescribeObject
type Diagnostic = Types.Diagnostic
type Node = ui.Node
type ParsedTable = Types.ParsedTable
type Span = ui.Span
type ViewState = Viewstate.ViewState

local M = {}

M.MAX_TABLE_ROWS = 500
-- More objects than this and only the first card starts expanded.
M.EXPANDED_OBJECTS = 3

-- Nested blocks a user opens describe for; shown expanded at any depth.
local ALWAYS_OPEN: { [string]: boolean } = {
	Containers = true,
	["Init Containers"] = true,
	["Ephemeral Containers"] = true,
	Conditions = true,
}

local STATUS_KEYS: { [string]: boolean } = {
	Status = true,
	State = true,
	["Last State"] = true,
	Reason = true,
	Ready = true,
	Phase = true,
}

local TONE_STYLE: { [string]: string } = { success = "success", warning = "warning", error = "error", muted = "muted" }

-- Conditions whose True means trouble (node pressure, failed rollouts).
local function negativeCondition(conditionType: string): boolean
	return string.find(conditionType, "Pressure$") ~= nil
		or conditionType == "NetworkUnavailable"
		or conditionType == "ReplicaFailure"
		or conditionType == "Failed"
		or conditionType == "FailureTarget"
end

local function conditionStyle(conditionType: string, status: string): string?
	if status ~= "True" and status ~= "False" then
		return if Values.isPlaceholder(status) or status == "Unknown" then "warning" else nil
	end
	local good = (status == "True") ~= negativeCondition(conditionType)
	return if good then "success strong" else "error strong"
end

local function valueSpans(key: string, value: string): { Span }
	if Values.isPlaceholder(value) then
		return { { t = if value == "" then "<empty>" else value, s = "muted" } }
	end
	if key == "Restart Count" then
		local n = tonumber(value)
		return { { t = value, s = if n and n > 0 then "warning mono" else "mono" } }
	end
	if STATUS_KEYS[key] then
		local style = TONE_STYLE[Values.statusTone(key, value)]
		if style then
			return { { t = value, s = style .. " strong" } }
		end
	end
	return { { t = value } }
end

local function fieldValue(field: DescribeField): string
	return if #field.values > 1 then table.concat(field.values, "\n") else field.value
end

local function tableNode(tbl: ParsedTable, id: string, parentKey: string): Node
	local cols = table.create(#tbl.columns)
	local types: { Types.ColumnType } = table.create(#tbl.columns)
	local typeIndex: number? = nil
	local statusIndex: number? = nil
	for i, column in tbl.columns do
		cols[i] = { id = "c" .. i, head = column.name }
		local samples = table.create(#tbl.rows)
		for r, row in tbl.rows do
			samples[r] = row.cells[i] or ""
		end
		types[i] = Values.columnType(string.upper(column.name), samples)
		if column.name == "Type" then
			typeIndex = typeIndex or i
		elseif column.name == "Status" then
			statusIndex = statusIndex or i
		end
	end
	local conditions = parentKey == "Conditions" and typeIndex ~= nil and statusIndex ~= nil
	local shown = math.min(#tbl.rows, M.MAX_TABLE_ROWS)
	local rows = table.create(shown)
	for r = 1, shown do
		local row = tbl.rows[r]
		local cells: { [string]: { Span } } = {}
		for i, column in tbl.columns do
			local value = row.cells[i] or ""
			local style: string?
			if conditions and i == statusIndex then
				style = conditionStyle(row.cells[typeIndex :: number] or "", value)
			else
				style = Cells.style(string.upper(column.name), types[i], value)
			end
			cells["c" .. i] = { if style then { t = value, s = style } else { t = value } }
		end
		rows[r] = { id = "r" .. r, cells = cells }
	end
	local out: { Node } = { { k = "table", p = { key = id, cols = cols, rows = rows } } }
	if #tbl.rows > shown then
		table.insert(out, ui.overflow(#tbl.rows - shown))
	end
	for _, raw in tbl.unparsed do
		table.insert(out, ui.text({ ui.span(raw.text, "mono muted") }))
	end
	return if #out == 1 then out[1] else ui.col(out)
end

local fieldNodes: (fields: { DescribeField }, depth: number, parentKey: string, id: string) -> { Node }

local function sectionNode(field: DescribeField, depth: number, parentKey: string, id: string): Node
	local head: { ui.SpanLike } = { ui.span(field.key, "strong") }
	if field.value ~= "" then
		table.insert(head, ui.span(":  ", "muted"))
		for _, s in valueSpans(field.key, field.value) do
			table.insert(head, s)
		end
	end
	local body = fieldNodes(field.children, depth + 1, field.key, id)
	local tbl = field.table
	if tbl then
		local node = tableNode(tbl, id .. "/t", field.key)
		local at = #body + 1
		for i, child in field.children do
			if child.line > (tbl.headerLine or 0) then
				at = i
				break
			end
		end
		table.insert(body, math.min(at, #body + 1), node)
	end
	local open = depth == 1 or ALWAYS_OPEN[field.key] == true or ALWAYS_OPEN[parentKey] == true
	return ui.section(head, body, { key = id, collapsible = true, collapsed = not open })
end

function fieldNodes(fields: { DescribeField }, depth: number, parentKey: string, id: string): { Node }
	local out: { Node } = {}
	local items: { { { ui.SpanLike } } } = {}
	local function flush()
		if #items > 0 then
			table.insert(out, ui.kv(items))
			items = {}
		end
	end
	for i, field in fields do
		local childId = id .. "/" .. i
		local nested = #field.children > 0 or field.table ~= nil
		if field.key == "" then
			flush()
			local tbl = field.table
			if tbl then
				table.insert(out, tableNode(tbl, childId, parentKey))
			end
			if field.value ~= "" then
				table.insert(out, ui.text({ ui.span(fieldValue(field), "mono") }))
			end
			if #field.children > 0 then
				for _, n in fieldNodes(field.children, depth + 1, parentKey, childId) do
					table.insert(out, n)
				end
			end
		elseif nested then
			flush()
			table.insert(out, sectionNode(field, depth, parentKey, childId))
		else
			table.insert(items, { { ui.span(field.key, "muted") }, valueSpans(field.key, fieldValue(field)) })
		end
	end
	flush()
	return out
end

local function warningCount(obj: DescribeObject): number
	local events = obj.events
	if events == nil then
		return 0
	end
	local n = 0
	for _, e in events do
		if e.type == "Warning" then
			n += 1
		end
	end
	return n
end

local function eventsNode(obj: DescribeObject, id: string): Node?
	local events = obj.events
	if events == nil then
		return nil
	end
	if #events == 0 then
		return ui.text({ ui.span("Events:", "strong"), ui.span("  <none>", "muted") }, { key = id })
	end
	local warnings = warningCount(obj)
	local cols = {
		{ id = "type", head = "Type" },
		{ id = "reason", head = "Reason" },
		{ id = "age", head = "Age" },
		{ id = "from", head = "From" },
		{ id = "message", head = "Message", grow = 1 },
	}
	local rows = table.create(#events)
	for i, e in events do
		local warn = e.type == "Warning"
		local style = if warn then "warning" else nil
		local function cell(text: string, s: string?): { Span }
			return { if s then { t = text, s = s } else { t = text } }
		end
		rows[i] = {
			id = "e" .. i,
			cells = {
				type = cell(e.type, if warn then "warning strong" else "muted"),
				reason = cell(e.reason, style),
				age = cell(e.age, "mono"),
				from = cell(e.from, "muted"),
				message = cell(e.message, style),
			},
		}
	end
	local head: { ui.SpanLike } = { ui.span("Events", "strong"), ui.span(string.format("  %d", #events), "muted") }
	if warnings > 0 then
		table.insert(head, ui.span(string.format("  %d Warning", warnings), "warning"))
	end
	return ui.section(head, { { k = "table", p = { key = id .. "/t", cols = cols, rows = rows } } }, {
		key = id,
		collapsible = true,
		collapsed = false,
	})
end

local function topField(obj: DescribeObject, key: string): DescribeField?
	for _, f in obj.fields do
		if f.key == key then
			return f
		end
	end
	return nil
end

local HIDDEN_TOP: { [string]: boolean } = { Name = true, Namespace = true, Events = true }

local function objectCard(obj: DescribeObject, index: number, collapsed: boolean): Node
	local id = "obj" .. index
	local head: { ui.SpanLike } = {
		ui.span(obj.kind or "Object", "muted"),
		" ",
		ui.span(if obj.name ~= "" then obj.name else "<unnamed>", "strong"),
	}
	if obj.namespace then
		table.insert(head, ui.span("  ns " .. obj.namespace, "muted"))
	end
	local body: { Node } = {}
	local badges: { Node } = {}
	local status = topField(obj, "Status")
	if status and status.value ~= "" and #status.children == 0 then
		local tone = Values.statusTone("STATUS", status.value)
		table.insert(badges, ui.badge(status.value, tone))
	end
	local warnings = warningCount(obj)
	if warnings > 0 then
		table.insert(
			badges,
			ui.badge(string.format("%d Warning event%s", warnings, if warnings == 1 then "" else "s"), "warning")
		)
	end
	if #badges > 0 then
		table.insert(body, ui.row(badges))
	end
	local fields: { DescribeField } = {}
	for _, f in obj.fields do
		if not HIDDEN_TOP[f.key] then
			table.insert(fields, f)
		end
	end
	for _, n in fieldNodes(fields, 1, "", id) do
		table.insert(body, n)
	end
	local events = eventsNode(obj, id .. "/events")
	if events then
		table.insert(body, events)
	end
	return ui.card(head, body, { key = id, collapsible = true, collapsed = collapsed })
end

local function diagnosticNodes(diagnostics: { Diagnostic }): { Node }
	local out: { Node } = {}
	for i, d in diagnostics do
		if d.severity == "error" then
			table.insert(
				out,
				ui.card({ ui.span("kubectl error", "error strong") }, { ui.text({ d.text }) }, {
					key = "diag" .. i,
					tone = "error",
					role = "tern-kube.error",
				})
			)
		elseif d.severity == "warning" then
			table.insert(out, ui.text({ ui.span(d.text, "warning") }, { key = "diag" .. i, tone = "warning" }))
		else
			table.insert(out, ui.muted(d.text, { key = "diag" .. i }))
		end
	end
	return out
end

function M.render(capture: Capture, _vs: ViewState, _vsm: typeof(Viewstate)): Node
	local parsed = capture.describe
	local children: { Node } = {}
	if parsed then
		for _, n in diagnosticNodes(parsed.diagnostics) do
			table.insert(children, n)
		end
		local many = #parsed.objects > M.EXPANDED_OBJECTS
		for i, obj in parsed.objects do
			table.insert(children, objectCard(obj, i, many and i > 1))
		end
	end
	if #children == 0 then
		table.insert(children, ui.muted("kubectl printed no objects"))
	end
	return ui.col(children, { role = "tern-kube.describe" })
end

return M
