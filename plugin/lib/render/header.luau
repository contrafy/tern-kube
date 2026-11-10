--!strict
-- The snapshot header: what ran, against which target, what the view shows,
-- and everything the user should distrust (exit status, unparsed lines,
-- kubectl errors, Secret data in Raw, values the native view masks).

local Capture = require("../lens/capture")
local Kinds = require("../kubectl/kinds")
local Redact = require("../model/redact")
local Types = require("../model/types")
local Viewstate = require("../lens/viewstate")
local ui = require("../ui")

type Capture = Capture.Capture
type Node = ui.Node
type ViewState = Viewstate.ViewState

export type Counts = { shown: number, matched: number, total: number }

local M = {}

M.SENSITIVE = "Raw output contains Secret data; native view masks it"

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local function lastFlag(inv: Types.Invocation, name: string): string?
	local list = inv.flags[name]
	return if list then list[#list] else nil
end

local function flagOn(inv: Types.Invocation, name: string): boolean
	local v = lastFlag(inv, name)
	return v ~= nil and v ~= "false"
end

-- The command as typed minus connection flags, keeping every flag that
-- changes which rows or lines are shown.
function M.commandSummary(inv: Types.Invocation): string
	local parts: { string } = { basename(inv.program) }
	if inv.verb then
		table.insert(parts, inv.verb)
	end
	if inv.subverb then
		table.insert(parts, inv.subverb)
	end
	for _, p in inv.positionals do
		table.insert(parts, p)
	end
	if inv.output ~= "table" then
		table.insert(parts, "-o " .. (if inv.outputSpec then inv.output .. "=" .. inv.outputSpec else inv.output))
	end
	if inv.selector then
		table.insert(parts, "-l " .. inv.selector)
	end
	if inv.fieldSelector then
		table.insert(parts, "--field-selector " .. inv.fieldSelector)
	end
	if inv.verb == "logs" then
		local all = flagOn(inv, "all-containers")
		local container = lastFlag(inv, "container")
		if all then
			table.insert(parts, "--all-containers")
		elseif container then
			table.insert(parts, "-c " .. container)
		end
		if flagOn(inv, "previous") then
			table.insert(parts, "--previous")
		end
		if flagOn(inv, "follow") then
			table.insert(parts, "-f")
		end
	end
	if inv.watch then
		table.insert(parts, "-w")
	end
	return table.concat(parts, " ")
end

-- Every named resource type is cluster-scoped (nodes, namespaces, CRDs), so
-- a namespace means nothing for this command.
local function clusterScoped(inv: Types.Invocation): boolean
	if inv.verb == "top" then
		return inv.subverb == "node" or inv.subverb == "nodes"
	end
	if #inv.resources == 0 then
		return false
	end
	for _, r in inv.resources do
		if Kinds.normalize(r.kind).namespaced ~= false then
			return false
		end
	end
	return true
end

function M.target(inv: Types.Invocation): { ui.Span }
	local ctx = inv.context or "current context at run time"
	local out = {
		ui.span("context: ", "muted"),
		ui.span(ctx, if inv.context then "mono" else "muted"),
	}
	if clusterScoped(inv) then
		return out
	end
	local ns = if inv.allNamespaces then "all" else inv.namespace or "default for context"
	table.insert(out, ui.span("   ns: ", "muted"))
	table.insert(out, ui.span(ns, if inv.namespace or inv.allNamespaces then "mono" else "muted"))
	return out
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

function M.countsText(c: Counts): string
	if c.matched == c.total and c.shown == c.total then
		return plural(c.total, "row")
	elseif c.shown == c.matched then
		return string.format("%d of %d rows", c.matched, c.total)
	end
	return string.format("%d shown, %d matched of %d rows", c.shown, c.matched, c.total)
end

local SEVERITY_TONE: { [string]: string } = { error = "error", warning = "warning", info = "muted" }

-- klog's `E1110 11:06:29.652110   60233 ` head differs on every repeat.
local KLOG_HEAD = "^[EWIF]%d%d%d%d %d%d:%d%d:%d%d%.%d+%s+%d+ "

type Entry = { text: string, severity: string, count: number, klog: boolean }

-- Identical messages once each with a ×N count; kubectl's own sentences
-- before klog lines, which repeat the cause in Go terms.
local function collapsed(diagnostics: { Types.Diagnostic }): { Entry }
	local out: { Entry } = {}
	local byText: { [string]: Entry } = {}
	for _, d in diagnostics do
		local stripped, n = string.gsub(d.text, KLOG_HEAD, "")
		local key = d.severity .. "\0" .. stripped
		local entry = byText[key]
		if entry then
			entry.count += 1
		else
			local created: Entry = { text = stripped, severity = d.severity, count = 1, klog = n > 0 }
			byText[key] = created
			table.insert(out, created)
		end
	end
	local order: { [Entry]: number } = {}
	for i, e in out do
		order[e] = i
	end
	table.sort(out, function(a: Entry, b: Entry): boolean
		if a.klog ~= b.klog then
			return not a.klog
		end
		return order[a] < order[b]
	end)
	return out
end

local function diagnosticsNode(diagnostics: { Types.Diagnostic }): Node?
	local errors, warnings = 0, 0
	local lines: { Node } = {}
	local infos: { Node } = {}
	for _, e in collapsed(diagnostics) do
		local spans: { ui.SpanLike } = { ui.span(e.text, SEVERITY_TONE[e.severity] or "muted") }
		if e.count > 1 then
			table.insert(spans, ui.span("  ×" .. e.count, "muted"))
		end
		local node = ui.text(spans)
		if e.severity == "error" then
			errors += 1
			table.insert(lines, node)
		elseif e.severity == "warning" then
			warnings += 1
			table.insert(lines, node)
		else
			table.insert(infos, node)
		end
	end
	local out: { Node } = {}
	if errors + warnings > 0 then
		local head: { string } = {}
		if errors > 0 then
			table.insert(head, plural(errors, "error"))
		end
		if warnings > 0 then
			table.insert(head, plural(warnings, "warning"))
		end
		table.insert(
			out,
			ui.section({ ui.span(table.concat(head, ", "), if errors > 0 then "error" else "warning") }, lines, {
				key = "diag",
				collapsible = true,
				collapsed = errors == 0,
				role = "tern-kube.diagnostics",
			})
		)
	end
	if #infos > 0 then
		table.insert(out, ui.lines(infos, { key = "info" }))
	end
	if #out == 0 then
		return nil
	end
	return ui.col(out, { key = "diags" })
end

local HELP: { { string } } = {
	{ "Click a column header", "Sort by it; click again to reverse" },
	{ "Click a row", "Open the inline inspector; click again to close" },
	{ "Inspect", "All columns, source lines and the object (JSON) for one row; Back returns" },
	{ "Filter chips", "Keep rows with that value; chips in one group widen, groups narrow" },
	{ "Problems", "Only rows kubectl reports as unhealthy, short of ready, or restarting" },
	{ "Copy chips", "Name, qualified id, describe/logs/get -o yaml commands for this target" },
	{ "Explore", "Opens the live Explore block for the row (it may run kubectl)" },
	{ "Raw", "The block's Raw toggle shows the exact output" },
	{ "Keyboard", "Lenses take no keys; keyboard navigation lives in the Explore block" },
}

local function helpNode(): Node
	local items: { { { ui.SpanLike } } } = table.create(#HELP)
	for i, pair in HELP do
		items[i] = { { ui.span(pair[1], "strong") }, { pair[2] } }
	end
	return ui.card({ "Tern Kube" }, { ui.kv(items) }, { key = "help", role = "tern-kube.help" })
end

-- `notes`: muted lines under the bar (a live view that trails the stream).
function M.render(capture: Capture, vs: ViewState, counts: Counts?, notes: { string }?): Node
	local inv = capture.invocation
	local top: { Node } = {
		ui.badge("Snapshot", "muted", { title = "Captured output of this command; not live" }),
		ui.text({ ui.span(M.commandSummary(inv), "mono strong") }),
		ui.text(M.target(inv)),
	}
	if counts then
		table.insert(top, ui.text({ ui.span(M.countsText(counts), "muted") }, { role = "tern-kube.counts" }))
	end
	if vs.sort and capture.snapshot then
		table.insert(top, ui.text({ ui.span("sorted by " .. vs.sort .. (if vs.desc then " (desc)" else ""), "muted") }))
	end
	-- mutation_view shows the exit status and kubectl errors in its result.
	local bodyReports = capture.mode == "mutation"
	if capture.interrupted and capture.status ~= nil and capture.status ~= 0 then
		table.insert(top, ui.badge("stopped (Ctrl-C)", "neutral", { role = "tern-kube.stopped" }))
	elseif capture.status ~= nil and capture.status ~= 0 and not bodyReports then
		table.insert(top, ui.badge("exit " .. capture.status, "error", { role = "tern-kube.exit" }))
	end
	if capture.unparsed > 0 then
		table.insert(
			top,
			ui.badge("partial: " .. plural(capture.unparsed, "unparsed line"), "warning", {
				title = "Some output was not understood; Raw shows everything",
				role = "tern-kube.partial",
			})
		)
	end
	table.insert(
		top,
		ui.badge(if vs.help then "? hide help" else "?", if vs.help then "accent" else "neutral", {
			key = "help-chip",
			title = "What you can do here",
			actions = { click = Viewstate.action(Viewstate.toggledHelp(vs)) },
		})
	)
	local children: { Node } = { ui.row(top, { key = "bar", wrap = true, role = "tern-kube.bar" }) }
	if notes then
		for i, note in notes do
			table.insert(children, ui.text({ ui.span(note, "muted") }, { key = "note" .. i, role = "tern-kube.note" }))
		end
	end
	-- yaml_view shows its own banner next to the masked YAML.
	if capture.mode ~= "yaml" then
		for i, notice in Redact.notices(capture.policy, capture.sensitive, capture.masked, M.SENSITIVE) do
			table.insert(
				children,
				ui.text(
					{ ui.span(notice, "warning") },
					{ key = if i == 1 then "sensitive" else "sensitive" .. i, role = "tern-kube.sensitive" }
				)
			)
		end
	end
	local diags = if bodyReports then nil else diagnosticsNode(capture.diagnostics)
	if diags then
		table.insert(children, diags)
	end
	if vs.help then
		table.insert(children, helpNode())
	end
	return ui.col(children, { key = "header", role = "tern-kube.header" })
end

return M
