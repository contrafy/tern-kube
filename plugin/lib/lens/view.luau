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

-- Running policy (general.streaming_view): while an event watch runs, Raw
-- is live and a plugin view trails it (Tern hands lens lines over late), so
-- the lens stays raw until the watch stops unless the user opted in.
function M.rawWhileRunning(inv: Types.Invocation, streamingView: "raw" | "native"): boolean
	return inv.watch and Argv.isEventsListing(inv) and streamingView ~= "native"
end

return M
