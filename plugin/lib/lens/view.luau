--!strict
-- Lens view dispatch: header bar plus the body for the capture's mode. nil
-- means "show raw": unsupported commands, empty output, nothing understood.

local Argv = require("../kubectl/argv")
local Capture = require("./capture")
local DescribeView = require("../render/describe_view")
local Header = require("../render/header")
local MutationView = require("../render/mutation_view")
local Quick = require("../actions/quick")
local TableView = require("../render/table_view")
local Viewstate = require("./viewstate")
local Types = require("../model/types")
local YamlView = require("../render/yaml_view")
local ui = require("../ui")

type Capture = Capture.Capture
type Node = ui.Node
type ViewState = Viewstate.ViewState
-- notes: muted header lines (a native view of a still-running watch).
-- quick: this host's quick_actions settings for the inspector's chips.
export type Options = { pageSize: number?, mutations: boolean?, notes: { string }?, quick: Quick.Settings? }

local M = {}

local function wrap(capture: Capture, header: Node, body: Node?): Node
	local children: { Node } = { header }
	if body then
		table.insert(children, body)
	end
	return ui.col(children, { key = "lens", role = "tern-kube." .. capture.mode })
end

function M.render(capture: Capture, vs: ViewState, opts: Options?): Node?
	local mode = capture.mode
	if mode == "raw" or capture.lineCount == 0 then
		return nil
	end
	local notes = if opts then opts.notes else nil
	if mode == "table" or mode == "name" or mode == "json" then
		local tableOpts: TableView.Options? = if opts
			then { pageSize = opts.pageSize, mutations = opts.mutations, quick = opts.quick }
			else nil
		local body, counts = TableView.render(capture, vs, tableOpts)
		if body == nil and #capture.diagnostics == 0 then
			return nil
		end
		return wrap(capture, Header.render(capture, vs, if body then counts else nil, notes), body)
	end
	local body: Node
	if mode == "describe" then
		body = DescribeView.render(capture, vs, Viewstate)
	elseif mode == "mutation" then
		body = MutationView.render(capture, vs, Viewstate)
	else
		body = YamlView.render(capture, vs, Viewstate)
	end
	return wrap(capture, Header.render(capture, vs, nil, notes), body)
end

-- Output past general.max_rows / max_capture_bytes is not parsed (it would
-- stall the pane). `preview`: the first lines the host kept.
export type Overflow = { lines: number, bytes: number, maxLines: number, maxBytes: number, preview: { string } }

local function size(bytes: number): string
	if bytes >= 1048576 then
		return string.format("%.1f MiB", bytes / 1048576)
	elseif bytes >= 1024 then
		return string.format("%d KiB", bytes // 1024)
	end
	return bytes .. " bytes"
end

function M.renderOverflow(inv: Types.Invocation, o: Overflow): Node
	local why = if o.lines > o.maxLines
		then string.format("%d lines (general.max_rows is %d)", o.lines, o.maxLines)
		else string.format("%s (general.max_capture_bytes is %s)", size(o.bytes), size(o.maxBytes))
	local bar = ui.row({
		ui.badge("Too large", "warning", { title = "Not parsed: the native view would stall the pane" }),
		ui.text({ ui.span(Header.commandSummary(inv), "mono strong") }),
		ui.text(Header.target(inv)),
	}, { key = "bar", wrap = true, role = "tern-kube.bar" })
	local note = ui.text({
		ui.span("Too large for the native view: " .. why .. ". ", "warning"),
		ui.span(
			if #o.preview > 0
				then string.format("The first %d lines are below; the block's Raw toggle shows everything.", #o.preview)
				else "The block's Raw toggle shows everything.",
			"muted"
		),
	}, { key = "why", role = "tern-kube.overflow" })
	local children: { Node } = { ui.col({ bar, note }, { key = "header", role = "tern-kube.header" }) }
	if #o.preview > 0 then
		table.insert(children, ui.code(table.concat(o.preview, "\n"), nil, 1, { key = "preview" }))
		if o.lines > #o.preview then
			table.insert(children, ui.overflow(o.lines - #o.preview))
		end
	end
	return ui.col(children, { key = "lens", role = "tern-kube.too-large" })
end

-- Running policy (general.streaming_view): while an event watch runs, Raw
-- is live and a plugin view trails it (Tern hands lens lines over late), so
-- the lens stays raw until the watch stops unless the user opted in.
function M.rawWhileRunning(inv: Types.Invocation, streamingView: "raw" | "native"): boolean
	return inv.watch and Argv.isEventsListing(inv) and streamingView ~= "native"
end

return M
