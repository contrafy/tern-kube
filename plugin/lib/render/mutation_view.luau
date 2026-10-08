--!strict
-- What an apply/delete/rollout restart/scale run did, read from its output.
-- The banner says plainly that this is a result, not a preview: by the time
-- a lens sees this output the change has already been made.

local Capture = require("../lens/capture")
local Cells = require("./cells")
local Grid = require("./grid")
local Kinds = require("../kubectl/kinds")
local Query = require("../lens/query")
local Types = require("../model/types")
local Viewstate = require("../lens/viewstate")
local ui = require("../ui")

type Capture = Capture.Capture
type Diagnostic = Types.Diagnostic
type MutationResult = Types.MutationResult
type Node = ui.Node
type SnapshotTable = Types.SnapshotTable
type ViewState = Viewstate.ViewState

local M = {}

M.BANNER = "Result of an executed command (not a preview)"

local HEADERS = { "KIND", "NAME", "NAMESPACE", "ACTION" }
local TYPES: { Types.ColumnType } = { "text", "text", "text", "text" }

local CATEGORIES = { "created", "configured", "unchanged", "deleted", "restarted", "scaled", "pruned", "other" }

local TONES: { [string]: string } = {
	created = "success",
	configured = "info",
	unchanged = "muted",
	deleted = "warning",
	restarted = "info",
	scaled = "info",
	pruned = "warning",
	other = "neutral",
}

local function category(action: string): string
	return if TONES[action] then action else "other"
end

-- First match wins: specific causes before the generic HTTP reason.
local HINTS: { { pattern: string, hint: string } } = {
	{
		pattern = "strict decoding error",
		hint = "The manifest has a field the API does not know. Fix its spelling or remove it, then re-run.",
	},
	{
		pattern = "unknown field",
		hint = "The manifest has a field the API does not know. Fix its spelling or remove it, then re-run.",
	},
	{
		pattern = "error converting YAML",
		hint = "The manifest is not valid YAML. Fix the syntax at the line kubectl names, then re-run.",
	},
	{
		pattern = "error parsing",
		hint = "The manifest could not be parsed. Fix the syntax at the line kubectl names, then re-run.",
	},
	{
		pattern = 'the path "[^"]*" does not exist',
		hint = "The -f path was not found. Paths are relative to the directory the command ran in.",
	},
	{
		pattern = 'context "[^"]*" does not exist',
		hint = "That --context is not in your kubeconfig. List contexts with `kubectl config get-contexts`.",
	},
	{
		pattern = "%(NotFound%)",
		hint = "Nothing by that name exists in the target. Check the name, -n/--namespace and --context.",
	},
	{
		pattern = "%(Forbidden%)",
		hint = "Your credentials may not do this. Check the user of --context (or --as) and its RBAC permissions.",
	},
	{
		pattern = "%(AlreadyExists%)",
		hint = "An object with that name already exists. Use `kubectl apply`, or choose another name.",
	},
	{
		pattern = "%(Conflict%)",
		hint = "The object changed after kubectl read it. Re-run the command against the current state.",
	},
	{ pattern = "is invalid", hint = "The API server rejected the object. The message names the invalid field." },
	{ pattern = "%(Invalid%)", hint = "The API server rejected the object. The message names the invalid field." },
	{
		pattern = "Unable to connect",
		hint = "The API server could not be reached. Check the context, network or VPN, and that the cluster is up.",
	},
	{
		pattern = "connection refused",
		hint = "The API server could not be reached. Check the context, network or VPN, and that the cluster is up.",
	},
}

function M.hint(text: string): string?
	for _, h in HINTS do
		if string.find(text, h.pattern) then
			return h.hint
		end
	end
	return nil
end

local function qualifiedKind(r: MutationResult): string
	return if r.group then r.kind .. "." .. r.group else r.kind
end

local function namespaceOf(r: MutationResult, inv: Types.Invocation): string
	if r.namespace then
		return r.namespace
	end
	local info = Kinds.normalize(qualifiedKind(r))
	if info.namespaced == true and inv.namespace then
		return inv.namespace
	end
	return ""
end

local function dryRunMode(capture: Capture, results: { MutationResult }): string?
	for _, r in results do
		if r.dryRun then
			return r.dryRun
		end
	end
	local flag = capture.invocation.dryRun
	if flag and flag ~= "none" and flag ~= "false" then
		return if flag == "server" then "server" else "client"
	end
	return nil
end

local function statusBadge(status: number?): Node
	if status == nil then
		return ui.badge("running", "muted")
	end
	return ui.badge("exit " .. tostring(status), if status == 0 then "success" else "error")
end

local function banner(capture: Capture, results: { MutationResult }): Node
	local children: { Node } = {
		ui.badge("Executed", "info"),
		ui.text({ ui.span(M.BANNER, "strong") }),
		statusBadge(capture.status),
	}
	local dry = dryRunMode(capture, results)
	if dry then
		table.insert(children, ui.badge("dry run (" .. dry .. ")", "warning"))
		table.insert(children, ui.muted("nothing was persisted"))
	end
	return ui.row(children, { role = "kube-lens.mutation-banner", wrap = true })
end

local function summaryBadges(results: { MutationResult }): Node?
	local counts: { [string]: number } = {}
	for _, r in results do
		local c = category(r.action)
		counts[c] = (counts[c] or 0) + 1
	end
	local badges: { Node } = {}
	for _, c in CATEGORIES do
		local n = counts[c]
		if n then
			table.insert(badges, ui.badge(string.format("%d %s", n, c), TONES[c]))
		end
	end
	return if #badges > 0 then ui.row(badges, { role = "kube-lens.mutation-summary", wrap = true }) else nil
end

local function diagnosticNodes(diagnostics: { Diagnostic }): { Node }
	local out: { Node } = {}
	local other: { Node } = {}
	for i, d in diagnostics do
		if d.severity == "error" then
			local body: { Node } = { ui.text({ d.text }) }
			local hint = M.hint(d.text)
			if hint then
				table.insert(body, ui.text({ ui.span("What to do: ", "strong"), hint }))
			end
			table.insert(
				out,
				ui.card({ ui.span("kubectl error", "error strong") }, body, {
					key = "diag" .. i,
					tone = "error",
					role = "kube-lens.error",
				})
			)
		elseif d.severity == "warning" then
			table.insert(out, ui.text({ ui.span(d.text, "warning") }, { key = "diag" .. i, tone = "warning" }))
		else
			table.insert(other, ui.text({ ui.span(d.text, "mono") }))
		end
	end
	if #other > 0 then
		local head = { ui.span("Other output", "strong"), ui.span(string.format("  %d lines", #other), "muted") }
		table.insert(out, ui.section(head, other, { key = "other", collapsible = true, collapsed = #other > 5 }))
	end
	return out
end

local function resultsTable(capture: Capture, results: { MutationResult }): SnapshotTable
	local rows: { Types.ResourceRow } = table.create(#results)
	for i, r in results do
		rows[i] = {
			key = "m" .. i,
			cells = { qualifiedKind(r), r.name, namespaceOf(r, capture.invocation), r.action },
			rawLines = { r.line },
			warnings = {},
		}
	end
	return { kind = nil, group = nil, headers = HEADERS, types = TYPES, rows = rows }
end

local function actionCell(col: string, columnType: Types.ColumnType, value: string): Node
	if col == "ACTION" then
		local tone = TONES[category(value)]
		local style = if tone == "info" then "accent strong" elseif tone == "neutral" then nil else tone .. " strong"
		return ui.text({ if style then ui.span(value, style) else ui.span(value) })
	end
	return Cells.cell(col, columnType, value)
end

local function inspector(capture: Capture, results: { MutationResult }, rowKey: string): Node?
	local index = tonumber(string.match(rowKey, "^m(%d+)$"))
	local r = if index then results[index] else nil
	if r == nil then
		return nil
	end
	local function item(key: string, value: string, style: string?): { { ui.SpanLike } }
		return { { ui.span(key, "muted") }, { ui.span(value, style) } }
	end
	local items: { { { ui.SpanLike } } } = {
		item("Resource", qualifiedKind(r) .. "/" .. r.name),
		item("Action", r.action),
	}
	local ns = namespaceOf(r, capture.invocation)
	if ns ~= "" then
		table.insert(items, item("Namespace", ns))
	end
	local dryRun = r.dryRun
	if dryRun then
		table.insert(items, item("Dry run", dryRun))
	end
	local line = capture.lines[r.line]
	if line then
		table.insert(items, item("Output line " .. r.line, line, "mono"))
	end
	return ui.kv(items)
end

function M.render(capture: Capture, vs: ViewState, vsm: typeof(Viewstate)): Node
	local parsed = capture.mutation
	local results = if parsed then parsed.results else {}
	local children: { Node } = { banner(capture, results) }
	local summary = summaryBadges(results)
	if summary then
		table.insert(children, summary)
	end
	for _, n in diagnosticNodes(if parsed then parsed.diagnostics else {}) do
		table.insert(children, n)
	end
	if #results > 0 then
		local tbl = resultsTable(capture, results)
		local shown = Query.apply(tbl, vs)
		local rows: { Grid.GridRow } = table.create(#shown.rows)
		for i, row in shown.rows do
			rows[i] = {
				key = row.key,
				cells = row.cells,
				action = vsm.action(vsm.opened(vs, row.key)),
				open = vs.open == row.key,
			}
		end
		table.insert(
			children,
			Grid.grid({
				key = "mutation",
				headers = HEADERS,
				types = TYPES,
				rows = rows,
				sortCol = vs.sort,
				desc = vs.desc,
				sortAction = function(col: string): string
					return vsm.action(vsm.sortedBy(vs, col))
				end,
				inspector = function(rowKey: string): Node?
					return inspector(capture, results, rowKey)
				end,
				cell = actionCell,
			})
		)
	elseif #children == 1 then
		table.insert(children, ui.muted("kubectl reported no objects"))
	end
	return ui.col(children, { role = "kube-lens.mutation" })
end

return M
