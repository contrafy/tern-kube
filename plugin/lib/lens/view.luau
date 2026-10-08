--!strict
-- Lens view dispatch: header bar plus the body for the capture's mode. nil
-- means "show raw": unsupported commands, empty output, nothing understood.

local Capture = require("./capture")
local DescribeView = require("../render/describe_view")
local Header = require("../render/header")
local MutationView = require("../render/mutation_view")
local TableView = require("../render/table_view")
local Viewstate = require("./viewstate")
local YamlView = require("../render/yaml_view")
local ui = require("../ui")

type Capture = Capture.Capture
type Node = ui.Node
type ViewState = Viewstate.ViewState
export type Options = TableView.Options

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
	if mode == "table" or mode == "name" or mode == "json" then
		local body, counts = TableView.render(capture, vs, opts)
		if body == nil and #capture.diagnostics == 0 then
			return nil
		end
		return wrap(capture, Header.render(capture, vs, if body then counts else nil), body)
	end
	local body: Node
	if mode == "describe" then
		body = DescribeView.render(capture, vs, Viewstate)
	elseif mode == "mutation" then
		body = MutationView.render(capture, vs, Viewstate)
	else
		body = YamlView.render(capture, vs, Viewstate)
	end
	return wrap(capture, Header.render(capture, vs, nil), body)
end

return M
