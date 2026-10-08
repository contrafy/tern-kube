--!strict
-- Disclosure tree for a decoded Kubernetes object. Only the first levels
-- start open; every map/array shows at most `maxChildren` entries followed by
-- an overflow line, so a huge object never becomes a huge view. Secret values
-- are masked before anything is rendered. Node ids are field paths, so Tern
-- keeps a node's open/closed state across re-renders of the same object.

local Json = require("../parse/json")
local ui = require("../ui")

type Node = ui.Node
type Span = ui.Span
export type TreeNode = ui.TreeNode

export type Options = { id: string?, openDepth: number?, maxChildren: number?, maxText: number? }

local M = {}

local DEFAULT_OPEN_DEPTH = 2
local DEFAULT_MAX_CHILDREN = 200
local DEFAULT_MAX_TEXT = 240

local KEY_ORDER: { [string]: number } = {
	apiVersion = 1,
	kind = 2,
	metadata = 3,
	name = 4,
	namespace = 5,
	type = 6,
	spec = 7,
	data = 8,
	stringData = 9,
	status = 10,
}

type Config = { openDepth: number, maxChildren: number, maxText: number }

local function isArray(t: { [any]: any }): boolean
	return #t > 0
end

local function sortedKeys(t: { [any]: any }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, tostring(k))
	end
	table.sort(keys, function(a: string, b: string): boolean
		local ra, rb = KEY_ORDER[a] or 100, KEY_ORDER[b] or 100
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	return keys
end

local function scalarSpans(value: any, cfg: Config): { Span }
	local kind = type(value)
	if kind == "string" then
		local text = string.gsub(value, "\n", " ")
		if #text > cfg.maxText then
			return {
				{ t = string.sub(text, 1, cfg.maxText) },
				{ t = string.format(" … (%d bytes)", #value), s = "muted" },
			}
		end
		return { { t = text } }
	elseif kind == "number" then
		local text = if value == math.floor(value) and math.abs(value) < 2 ^ 53
			then string.format("%d", value)
			else tostring(value)
		return { { t = text, s = "num" } }
	elseif kind == "boolean" then
		return { { t = tostring(value), s = "accent" } }
	end
	return { { t = "null", s = "muted" } }
end

local function overflowNode(id: string, hidden: number): TreeNode
	return {
		id = id .. "/…",
		label = { { t = string.format("… %d more (Raw shows everything)", hidden), s = "muted" } },
	}
end

local build: (value: any, id: string, label: { Span }, depth: number, cfg: Config) -> TreeNode

local function children(value: { [any]: any }, id: string, depth: number, cfg: Config): { TreeNode }
	local out: { TreeNode } = {}
	if isArray(value) then
		local n = #value
		for i = 1, math.min(n, cfg.maxChildren) do
			local item = value[i]
			local label: { Span } = { { t = string.format("[%d]", i - 1), s = "muted" } }
			if type(item) == "table" and type(item.name) == "string" then
				table.insert(label, { t = " " .. item.name })
			end
			table.insert(out, build(item, id .. "/" .. (i - 1), label, depth, cfg))
		end
		if n > cfg.maxChildren then
			table.insert(out, overflowNode(id, n - cfg.maxChildren))
		end
		return out
	end
	local keys = sortedKeys(value)
	for i = 1, math.min(#keys, cfg.maxChildren) do
		local key = keys[i]
		table.insert(out, build(value[key], id .. "/" .. key, { { t = key, s = "strong" } }, depth, cfg))
	end
	if #keys > cfg.maxChildren then
		table.insert(out, overflowNode(id, #keys - cfg.maxChildren))
	end
	return out
end

function build(value: any, id: string, label: { Span }, depth: number, cfg: Config): TreeNode
	local spans = table.clone(label)
	if type(value) ~= "table" or next(value) == nil then
		table.insert(spans, { t = ": ", s = "muted" })
		if type(value) == "table" then
			table.insert(spans, { t = "{}", s = "muted" })
		else
			for _, s in scalarSpans(value, cfg) do
				table.insert(spans, s)
			end
		end
		return { id = id, label = spans }
	end
	if isArray(value) then
		table.insert(spans, { t = string.format("  [%d]", #value), s = "muted" })
	else
		local count = 0
		for _ in value do
			count += 1
		end
		table.insert(spans, { t = string.format("  {%d}", count), s = "muted" })
	end
	return {
		id = id,
		label = spans,
		open = depth <= cfg.openDepth,
		children = children(value, id, depth + 1, cfg),
	}
end

local function redact(obj: any): any
	if type(obj) ~= "table" then
		return obj
	end
	local masked = Json.redactObject(obj)
	local items = masked.items
	if type(items) == "table" and isArray(items) then
		local copy = table.clone(masked)
		local maskedItems = table.create(#items)
		for i, item in items do
			maskedItems[i] = if type(item) == "table" then Json.redactObject(item) else item
		end
		copy.items = maskedItems
		return copy
	end
	return masked
end

-- Tree nodes for `obj`; its top-level fields are depth 1.
function M.nodes(obj: any, opts: Options?): { TreeNode }
	local cfg: Config = {
		openDepth = opts and opts.openDepth or DEFAULT_OPEN_DEPTH,
		maxChildren = opts and opts.maxChildren or DEFAULT_MAX_CHILDREN,
		maxText = opts and opts.maxText or DEFAULT_MAX_TEXT,
	}
	local id = opts and opts.id or "obj"
	local value = redact(obj)
	if type(value) ~= "table" then
		return { { id = id, label = scalarSpans(value, cfg) } }
	end
	return children(value, id, 1, cfg)
end

function M.tree(obj: any, opts: Options?): Node
	return ui.tree(M.nodes(obj, opts))
end

return M
