--!strict
-- The Decoded values card: a separate, display-only view of a Secret's
-- `data`. The YAML/tree beside it keeps kubectl's base64, so nothing on
-- screen can be applied back decoded. The card has no actions: decoded
-- text never reaches an action string, a toast or the clipboard.

local SecretData = require("../model/secretdata")
local ui = require("../ui")

type Node = ui.Node
type Entry = SecretData.Entry
type Value = SecretData.Value

export type Opts = {
	key: string?,
	-- How the user hides the card ("z / Hide decoded", "Hide decoded").
	hint: string,
}

local M = {}

M.ROLE = "tern-kube.secret-decoded"

local KIND_LABEL: { [SecretData.Kind]: string } = {
	text = "text",
	escaped = "text (escaped)",
	binary = "binary",
	empty = "empty",
	invalid = "invalid base64",
	toolarge = "too large",
}

function M.label(decoded: boolean, key: string?): string
	local text = if decoded then "Hide decoded" else "Decode values"
	return if key then text .. " (" .. key .. ")" else text
end

function M.banner(hint: string): string
	return "Decoded Secret values on screen (display only: not copied, saved or logged). " .. hint .. " hides them."
end

local function bytes(n: number): string
	return if n == 1 then "1 byte" else string.format("%d bytes", n)
end

local function valueNodes(v: Value, key: string): { Node }
	local kind = v.kind
	if kind == "empty" then
		return { ui.muted("(empty)", { key = key }) }
	elseif kind == "toolarge" then
		return { ui.muted(bytes(v.size) .. ", too large to decode here (Raw shows base64)", { key = key }) }
	elseif kind == "binary" then
		local out: { Node } = { ui.code(v.hex or "", nil, nil, { key = key }) }
		if v.more and v.more > 0 then
			table.insert(out, ui.muted("… " .. bytes(v.more) .. " more", { key = key .. "-more" }))
		end
		return out
	elseif kind == "invalid" then
		-- The string as kubectl printed it, still escaped: JSON output can
		-- carry control characters in a string that is not base64.
		local shown = if v.text then SecretData.classify(v.text).text else nil
		local spans: { ui.SpanLike } = {
			ui.span("not decoded: " .. (v.error or "invalid") .. "; shown as printed", "warning"),
		}
		if shown then
			table.insert(spans, "  ")
			table.insert(spans, ui.span(shown, "mono"))
		end
		return { ui.text(spans, { key = key, tone = "warning" }) }
	end
	local text = v.text or ""
	if v.multiline then
		return { ui.code(text, nil, nil, { key = key }) }
	end
	return { ui.text({ ui.span(text, "mono") }, { key = key }) }
end

local function entryNode(e: Entry): Node
	local v = e.value
	local children: { Node } = {
		ui.text({
			ui.span(e.key, "strong mono"),
			ui.span("  " .. bytes(v.size) .. " · " .. KIND_LABEL[v.kind], "muted"),
		}, { key = "head" }),
	}
	for _, n in valueNodes(v, "value") do
		table.insert(children, n)
	end
	return ui.col(children, { key = "e-" .. e.key })
end

function M.card(entries: { Entry }, opts: Opts): Node
	local rows: { Node } = {}
	for _, e in entries do
		table.insert(rows, entryNode(e))
	end
	if #rows == 0 then
		table.insert(rows, ui.muted("No data keys", { key = "none" }))
	end
	return ui.col({
		ui.text({ ui.span(M.banner(opts.hint), "warning") }, {
			key = "banner",
			tone = "warning",
			role = M.ROLE .. "-banner",
		}),
		ui.card({ "Decoded values" }, rows, { key = "card", role = M.ROLE }),
	}, { key = opts.key or "decoded" })
end

return M
