--!strict
-- Queries over plain `{k, p, c}` view nodes so render specs assert on what a
-- user would see (text, tones, clickable actions) instead of golden trees.

export type Node = { k: string, p: { [string]: any }?, c: { Node }? }
export type Predicate = (Node) -> boolean

local M = {}

local function spansText(spans: any): string
	if type(spans) == "string" then
		return spans
	end
	if type(spans) ~= "table" then
		return ""
	end
	if type(spans.t) == "string" then
		return spans.t
	end
	local parts = table.create(#spans)
	for i, s in spans do
		parts[i] = if type(s) == "string" then s elseif type(s) == "table" then s.t or "" else ""
	end
	return table.concat(parts)
end
M.spansText = spansText

local function treeText(nodes: any, out: { string })
	if type(nodes) ~= "table" then
		return
	end
	for _, n in nodes do
		table.insert(out, spansText(n.label))
		treeText(n.children, out)
	end
end

-- Text the node itself contributes, without its children.
function M.ownText(node: Node): string
	local p = node.p
	if p == nil then
		return ""
	end
	local out: { string } = {}
	if p.head ~= nil then
		table.insert(out, spansText(p.head))
	end
	if p.spans ~= nil then
		table.insert(out, spansText(p.spans))
	end
	if type(p.text) == "string" then
		table.insert(out, p.text)
	end
	if type(p.label) == "string" or type(p.label) == "table" then
		table.insert(out, spansText(p.label))
	end
	if node.k == "kv" and type(p.items) == "table" then
		for _, item in p.items do
			table.insert(out, spansText(item.k))
			table.insert(out, spansText(item.v))
		end
	end
	if node.k == "tree" then
		treeText(p.nodes, out)
	end
	return table.concat(out, " ")
end

function M.walk(node: Node, fn: (Node) -> ())
	fn(node)
	local children = node.c
	if children then
		for _, child in children do
			M.walk(child, fn)
		end
	end
end

function M.findAll(node: Node, predicate: Predicate): { Node }
	local out: { Node } = {}
	M.walk(node, function(n)
		if predicate(n) then
			table.insert(out, n)
		end
	end)
	return out
end

function M.find(node: Node, predicate: Predicate): Node?
	return M.findAll(node, predicate)[1]
end

-- All visible text of the subtree, nodes separated by single spaces.
function M.text(node: Node): string
	local out: { string } = {}
	M.walk(node, function(n)
		local own = M.ownText(n)
		if own ~= "" then
			table.insert(out, own)
		end
	end)
	return table.concat(out, " ")
end

function M.kind(k: string): Predicate
	return function(n)
		return n.k == k
	end
end

function M.class(name: string): Predicate
	return function(n)
		local cls = n.p and n.p.class
		if type(cls) ~= "string" then
			return false
		end
		for word in string.gmatch(cls, "%S+") do
			if word == name then
				return true
			end
		end
		return false
	end
end

function M.role(r: string): Predicate
	return function(n)
		return n.p ~= nil and n.p.role == r
	end
end

function M.key(k: string): Predicate
	return function(n)
		return n.p ~= nil and n.p.key == k
	end
end

-- Nodes whose own text contains `needle` (plain substring).
function M.hasText(needle: string): Predicate
	return function(n)
		return string.find(M.ownText(n), needle, 1, true) ~= nil
	end
end

function M.all(...: Predicate): Predicate
	local preds = { ... }
	return function(n)
		for _, p in preds do
			if not p(n) then
				return false
			end
		end
		return true
	end
end

-- Click action of a node, or nil when it is not clickable.
function M.action(node: Node): string?
	local actions = node.p and node.p.actions
	return if type(actions) == "table" and type(actions.click) == "string" then actions.click else nil
end

-- Click actions of every clickable node in the subtree, in document order.
function M.actions(node: Node): { string }
	local out: { string } = {}
	M.walk(node, function(n)
		local a = M.action(n)
		if a then
			table.insert(out, a)
		end
	end)
	return out
end

-- Tone of a node: `p.tone`, or the style tokens of its spans.
function M.tones(node: Node): { string }
	local out: { string } = {}
	local p = node.p
	if p == nil then
		return out
	end
	if type(p.tone) == "string" then
		table.insert(out, p.tone)
	end
	if type(p.spans) == "table" then
		for _, s in p.spans do
			if type(s) == "table" and type(s.s) == "string" then
				for word in string.gmatch(s.s, "%S+") do
					table.insert(out, word)
				end
			end
		end
	end
	return out
end

function M.count(node: Node): number
	local n = 0
	M.walk(node, function()
		n += 1
	end)
	return n
end

return M
