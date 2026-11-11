--!strict
-- `kubectl auth can-i VERB RESOURCE`: one card with the answer (a `no` is an
-- answer, not a failure, though kubectl exits 1), the question in words,
-- the target, kubectl's warnings and the chips.

local Capture = require("../lens/capture")
local Cani = require("../parse/cani")
local K9s = require("../lens/k9s")
local LensChips = require("./lens_chips")
local ui = require("../ui")

type Capture = Capture.Capture
type Node = ui.Node

local M = {}

M.WILDCARD_NOTE = "kubectl still answers for unknown types and verbs: wildcard (*) rules match them"

local function who(q: Cani.Question): string
	local subject = if q.as
		then q.as
		elseif q.user then "user " .. q.user
		elseif q.token then "the --token user"
		else "the context's user"
	if #q.asGroups > 0 then
		subject ..= " (groups " .. table.concat(q.asGroups, ", ") .. ")"
	end
	if q.asUid then
		subject ..= " (uid " .. q.asUid .. ")"
	end
	return subject
end

-- "Can system:serviceaccount:ns:viewer get pods/log in namespace ns?"
function M.sentence(q: Cani.Question): string
	local what = q.url or q.typed or "?"
	if q.subresource then
		what ..= " (subresource " .. q.subresource .. ")"
	end
	local where = if q.url
		then ""
		elseif q.allNamespaces then " in all namespaces"
		elseif q.namespace then " in namespace " .. q.namespace
		else " in the context's default namespace"
	return string.format("Can %s %s %s%s?", who(q), q.verb or "?", what, where)
end

function M.render(capture: Capture, opts: LensChips.Options?): Node
	local info = if capture.k9s then capture.k9s.cani else nil
	if info == nil then
		return ui.col({}, { key = "cani" })
	end
	local a = info.answer
	local q = info.question
	local badge = if a.answer == "yes"
		then ui.badge("YES", "success", { role = "tern-kube.cani-yes" })
		elseif a.answer == "no" then ui.badge("NO", "error", { role = "tern-kube.cani-no" })
		else ui.badge("no answer", "warning", { role = "tern-kube.cani-none" })
	local children: { Node } = {
		ui.row({ badge, ui.text({ ui.span(M.sentence(q), "strong") }) }, { key = "answer", wrap = true }),
		ui.text({
			ui.span("context: ", "muted"),
			ui.span(q.context or "current context at run time", if q.context then "mono" else "muted"),
		}, { key = "context" }),
	}
	if a.reason then
		table.insert(children, ui.text({ ui.span("reason: ", "muted"), ui.span(a.reason) }, { key = "reason" }))
	end
	if a.line == nil and a.answer then
		table.insert(children, ui.muted("Answered by the exit status (-q)", { key = "quiet" }))
	end
	local warned = false
	for i, d in a.diagnostics do
		if d.severity == "warning" then
			warned = true
			table.insert(children, ui.text({ ui.span(d.text, "warning") }, { key = "warn" .. i }))
		elseif d.severity == "error" then
			table.insert(children, ui.text({ ui.span(d.text, "error") }, { key = "err" .. i }))
		end
	end
	if warned and a.answer == "yes" then
		table.insert(children, ui.muted(M.WILDCARD_NOTE, { key = "wildcard" }))
	end
	if q.impersonated then
		table.insert(children, ui.muted(K9s.IMPERSONATED_NOTE, { key = "impersonated" }))
	end
	local chips = LensChips.nodes(LensChips.answerChips(capture, opts))
	if #chips > 0 then
		table.insert(children, ui.row(chips, { key = "chips", wrap = true, role = "tern-kube.chips" }))
	end
	return ui.card({ "auth can-i" }, children, { key = "cani", role = "tern-kube.cani" })
end

return M
