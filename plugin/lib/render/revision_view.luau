--!strict
-- `rollout history TYPE/NAME --revision=N`: what the revision is (object,
-- number, change-cause, images) and its chips above the pod template, which
-- renders like describe (and is masked like describe).

local Capture = require("../lens/capture")
local DescribeView = require("./describe_view")
local LensChips = require("./lens_chips")
local Viewstate = require("../lens/viewstate")
local ui = require("../ui")

type Capture = Capture.Capture
type Node = ui.Node
type ViewState = Viewstate.ViewState

local M = {}

function M.render(capture: Capture, vs: ViewState, opts: LensChips.Options?): Node
	local info = if capture.k9s then capture.k9s.revision else nil
	local children: { Node } = {}
	if info then
		local spans: { ui.SpanLike } = {
			ui.span(info.type .. "/" .. info.ref.name, "mono strong"),
			ui.span("  revision ", "muted"),
			ui.span(tostring(info.revision), "strong"),
		}
		if info.cause then
			table.insert(spans, ui.span("  " .. info.cause))
		end
		local items: { Node } = { ui.text(spans, { key = "what" }) }
		if #info.images > 0 then
			table.insert(
				items,
				ui.text({
					ui.span("image" .. (if #info.images > 1 then "s " else " "), "muted"),
					ui.span(table.concat(info.images, ", "), "mono"),
				}, { key = "images" })
			)
		end
		table.insert(children, ui.col(items, { key = "summary", role = "tern-kube.revision" }))
		local chips = LensChips.nodes(LensChips.revisionChips(capture, opts))
		if #chips > 0 then
			table.insert(children, ui.row(chips, { key = "chips", wrap = true, role = "tern-kube.chips" }))
		end
	end
	table.insert(children, DescribeView.render(capture, vs, Viewstate))
	return ui.col(children, { key = "revision" })
end

return M
