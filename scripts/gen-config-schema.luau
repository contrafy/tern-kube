--!strict
-- Prints schema/config.schema.json, the JSON Schema (draft 2020-12) of the
-- config file, from Config.CATALOG and Config.defaults(): `make schema`
-- regenerates it, `make schema-check` fails when it is stale.
--
--   .tools/bin/luau scripts/gen-config-schema.luau > schema/config.schema.json
--
-- The loader warns about unknown keys and falls back to the default for a
-- bad value; `additionalProperties: false` and the value constraints make
-- editors flag the same things.

local Config = require("../plugin/lib/config")

local DOCS = "https://github.com/contrafy/tern-kube/blob/master/docs/configuration.md"

-- Objects whose members are written in this order (property maps); other
-- objects are schema keywords, written in KEYWORDS order.
local ORDERED: { [any]: { string } } = {}

local KEYWORDS = {
	"$schema",
	"$id",
	"title",
	"description",
	"type",
	"const",
	"enum",
	"minimum",
	"maximum",
	"minLength",
	"maxLength",
	"pattern",
	"minItems",
	"maxItems",
	"items",
	"required",
	"properties",
	"additionalProperties",
	"default",
}
local RANK: { [string]: number } = {}
for i, k in KEYWORDS do
	RANK[k] = i
end

local function keysOf(t: { [string]: any }): { string }
	local order = ORDERED[t]
	if order then
		return order
	end
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: string, b: string): boolean
		local ra, rb = RANK[a] or #KEYWORDS + 1, RANK[b] or #KEYWORDS + 1
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	return keys
end

local function quote(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		local named = ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t" })[c]
		return named or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function isArray(v: { [any]: any }): boolean
	return ORDERED[v] == nil and (next(v) == nil or v[1] ~= nil)
end

local function encode(v: any, indent: string): string
	local tv = type(v)
	if tv == "string" then
		return quote(v)
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv == "number" then
		assert(v == math.floor(v), "the schema holds integers only")
		return string.format("%d", v)
	end
	assert(tv == "table", "unexpected " .. tv)
	local inner = indent .. "  "
	if isArray(v) then
		local flat = true
		local parts: { string } = {}
		for i, item in v do
			flat = flat and type(item) ~= "table"
			parts[i] = encode(item, inner)
		end
		if flat then
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		return "[\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "]"
	end
	local parts: { string } = {}
	for _, k in keysOf(v) do
		table.insert(parts, inner .. quote(k) .. ": " .. encode(v[k], inner))
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function node(spec: Config.Spec, default: any): { [string]: any }
	local out: { [string]: any } = table.clone(spec.schema)
	out.description = spec.doc
	if spec.fields then
		local properties: { [string]: any } = {}
		local order: { string } = {}
		for _, f in spec.fields do
			properties[f.key] = node(f, default[f.key])
			table.insert(order, f.key)
		end
		ORDERED[properties] = order
		out.properties = properties
		out.additionalProperties = false
	elseif default ~= nil then
		out.default = default
	end
	return out
end

local defaults = Config.defaults() :: any
local properties: { [string]: any } = {}
local order: { string } = {}
for _, spec in Config.CATALOG do
	properties[spec.key] = node(spec, defaults[spec.key])
	table.insert(order, spec.key)
end
ORDERED[properties] = order

print(encode({
	["$schema"] = "https://json-schema.org/draft/2020-12/schema",
	["$id"] = Config.SCHEMA_URL,
	title = "tern-kube config",
	description = "Settings of tern-kube, the Kubernetes plugin for Tern: $XDG_CONFIG_HOME/"
		.. Config.RELATIVE_PATH
		.. " (default ~/.config/"
		.. Config.RELATIVE_PATH
		.. "). Every key is optional; a bad value falls back to its default with a diagnostic. "
		.. DOCS,
	type = "object",
	properties = properties,
	additionalProperties = false,
}, ""))

return nil
