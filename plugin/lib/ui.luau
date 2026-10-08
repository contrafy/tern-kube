--!strict
-- Plain-table equivalents of the `tern.ui` builders used by kube-lens. Tern
-- 0.6.2 accepts `{k, p, c}` tables as nodes (`tern.ui.node(k, p, c)` encodes
-- to the same JSON), and building them in Luau is ~50x cheaper than calling
-- the builders, which matters for 1000-row views.

export type Span = { t: string, s: string?, href: string? }
export type Node = { k: string, p: { [string]: any }?, c: { Node }? }
export type SpanLike = Span | string

local M = {}

function M.span(t: string, s: string?): Span
	if s == nil or s == "" then
		return { t = t }
	end
	return { t = t, s = s }
end

function M.spans(list: { SpanLike }): { Span }
	local out: { Span } = table.create(#list)
	for i, s in list do
		out[i] = if type(s) == "string" then { t = s } else s
	end
	return out
end

function M.text(list: { SpanLike }, props: { [string]: any }?): Node
	local p: { [string]: any } = { spans = M.spans(list) }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "text", p = p }
end

function M.el(tag: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = { tag = tag }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "el", p = p, c = children }
end

function M.badge(text: string, tone: string, props: { [string]: any }?): Node
	local p: { [string]: any } = { text = text, tone = tone }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "badge", p = p }
end

function M.col(children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { gap = "sm" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "col", p = p, c = children }
end

function M.row(children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { gap = "sm" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "row", p = p, c = children }
end

function M.kv(items: { { { SpanLike } } }): Node
	local out = table.create(#items)
	for i, pair in items do
		out[i] = { k = M.spans(pair[1]), v = M.spans(pair[2]) }
	end
	return { k = "kv", p = { items = out } }
end

return M
