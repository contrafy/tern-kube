--!strict
-- One collapsible card per diff segment (kubectl diff file, Objdiff pair):
-- the hunks of the segment in a unified diff view, capped at MAX_LINES.
-- Shared by the GitOps, Helm and compare views. Pure: plain `{k,p,c}` tables.

local Diffseg = require("../mutation/diffseg")
local ui = require("../ui")

type Node = ui.Node

local M = {}

M.MAX_LINES = 4000

local ACTION_TONE: { [string]: string } = {
	create = "success",
	modify = "info",
	delete = "error",
	unknown = "neutral",
}

local function hunks(seg: Diffseg.Segment): (string, number)
	local out: { string } = {}
	local started = false
	local hidden = 0
	for _, l in seg.lines do
		if string.sub(l, 1, 2) == "@@" then
			started = true
		end
		if started then
			if #out < M.MAX_LINES then
				table.insert(out, l)
			else
				hidden += 1
			end
		end
	end
	return table.concat(out, "\n"), hidden
end

local function segName(seg: Diffseg.Segment): string
	return (seg.kind or "?") .. " " .. (if seg.namespace then seg.namespace .. "/" else "") .. (seg.name or seg.key)
end

function M.card(seg: Diffseg.Segment, key: string, collapsed: boolean): Node
	local text, hidden = hunks(seg)
	local body: { Node } = {}
	if seg.binary then
		table.insert(body, ui.muted("Binary or unreadable difference", { key = "bin" }))
	else
		table.insert(body, { k = "diff", p = { key = "diff", text = text, path = "object.yaml", mode = "unified" } })
	end
	if hidden > 0 then
		table.insert(body, ui.muted(string.format("… %d more lines", hidden), { key = "more" }))
	end
	return ui.card(
		{
			ui.span(string.upper(seg.action) .. "  ", "strong"),
			ui.span(segName(seg), "strong"),
			ui.span(string.format("   +%d −%d", seg.added, seg.removed), "muted"),
		},
		body,
		{
			key = key,
			collapsible = true,
			collapsed = collapsed,
			inset = true,
			tone = ACTION_TONE[seg.action],
			role = "tern-kube.gitops-diff",
		}
	)
end

return M
