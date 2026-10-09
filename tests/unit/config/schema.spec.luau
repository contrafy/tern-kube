--!strict
-- schema/config.schema.json is what editors use to complete and check the
-- config file. If it disagreed with the loader, an editor would suggest a
-- default tern-kube does not use, accept a value tern-kube replaces, or
-- flag a value tern-kube takes. `make schema-check` keeps the file equal to
-- the generator's output; these specs check the committed file against the
-- loader itself.
local Config = require("../../../plugin/lib/config")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local schema = json.decode(fixtures.read("schema/config.schema.json"))
local defaults = Config.defaults() :: any

local function property(path: string): any
	local section, key = string.match(path, "^([%w_]+)%.([%w_]+)$")
	if section then
		return schema.properties[section].properties[key]
	end
	return schema.properties[path]
end

local function encode(section: string?, key: string, value: string): string
	if section then
		return string.format('{"%s": {"%s": %s}}', section, key, value)
	end
	return string.format('{"%s": %s}', key, value)
end

-- Every leaf key as {section?, key, spec}.
local function leaves(): { { section: string?, key: string, spec: Config.Spec } }
	local out: { { section: string?, key: string, spec: Config.Spec } } = {}
	for _, spec in Config.CATALOG do
		if spec.fields then
			for _, f in spec.fields do
				table.insert(out, { section = spec.key, key = f.key, spec = f })
			end
		else
			table.insert(out, { section = nil, key = spec.key, spec = spec })
		end
	end
	return out
end

local function pathOf(leaf: { section: string?, key: string }): string
	return if leaf.section then leaf.section .. "." .. leaf.key else leaf.key
end

describe("config JSON Schema", function()
	it("is draft 2020-12 and served at the URL the stub points to", function()
		expect(schema["$schema"]).toBe("https://json-schema.org/draft/2020-12/schema")
		expect(schema["$id"]).toBe(Config.SCHEMA_URL)
		expect(string.find(Config.SCHEMA_URL, "/master/schema/config%.schema%.json$") ~= nil).toBe(true)
		expect(json.decode(fixtures.read("examples/config.json"))["$schema"]).toBe(Config.SCHEMA_URL)
	end)

	it("states every default the loader uses", function()
		local missing: { string } = {}
		for key, value in defaults do
			if type(value) == "table" and next(value) ~= nil and type((next(value))) == "string" then
				for sub, v in value do
					local p = property(key .. "." .. sub)
					if p == nil then
						table.insert(missing, key .. "." .. sub)
					else
						expect(p.default).toEqual(v)
					end
				end
			else
				local p = property(key)
				if p == nil then
					table.insert(missing, key)
				else
					expect(p.default).toEqual(value)
				end
			end
		end
		expect(missing).toEqual({})
	end)

	it("states no default for the keys that are unset by default", function()
		expect(property("kubeconfig").default).toBeNil()
		expect(property("gitops.unmanaged_kinds").default).toBeNil()
	end)

	it("describes every key", function()
		for _, leaf in leaves() do
			local p = property(pathOf(leaf))
			expect(p ~= nil and type(p.description) == "string" and #p.description > 0).toBe(true)
		end
		for _, spec in Config.CATALOG do
			expect(type(schema.properties[spec.key].description)).toBe("string")
		end
	end)

	-- The loader warns about unknown keys at the top level and in every
	-- section; editors must flag the same keys, and only those.
	it("rejects unknown keys exactly where the loader warns about them", function()
		expect(schema.additionalProperties).toBe(false)
		local known = 0
		for _ in schema.properties do
			known += 1
		end
		expect(known).toBe(#Config.CATALOG)
		for _, spec in Config.CATALOG do
			if spec.fields then
				expect(schema.properties[spec.key].type).toBe("object")
				expect(schema.properties[spec.key].additionalProperties).toBe(false)
			end
			local _, diags = Config.parse(encode(nil, spec.key, if spec.fields then "{}" else '"x"'), json.decode)
			for _, d in diags do
				expect((string.find(d.message, "unknown key", 1, true))).toBeNil()
			end
		end
	end)

	it("states the integer ranges the loader enforces", function()
		for _, leaf in leaves() do
			local p = property(pathOf(leaf))
			if p.type ~= "integer" then
				continue
			end
			local function errors(n: number): number
				local _, diags = Config.parse(encode(leaf.section, leaf.key, tostring(n)), json.decode)
				local count = 0
				for _, d in diags do
					if d.level == "error" then
						count += 1
					end
				end
				return count
			end
			expect(errors(p.minimum)).toBe(0)
			expect(errors(p.maximum)).toBe(0)
			expect(errors(p.minimum - 1)).toBe(1)
			if leaf.key ~= "schema_version" then
				expect(errors(p.maximum + 1)).toBe(1)
			end
		end
	end)

	it("lists exactly the placements the loader accepts", function()
		local p = property("quick_actions.placement")
		for _, v in p.enum do
			local _, diags = Config.parse(encode("quick_actions", "placement", '"' .. v .. '"'), json.decode)
			expect(diags).toEqual({})
		end
		local _, diags = Config.parse(encode("quick_actions", "placement", '"left"'), json.decode)
		expect(#diags).toBe(1)
	end)

	it("flags auto_refresh true, which the loader replaces with false", function()
		expect(property("explore.auto_refresh").const).toBe(false)
		local cfg = Config.parse(encode("explore", "auto_refresh", "true"), json.decode)
		expect(cfg.explore.auto_refresh).toBe(false)
	end)

	it("types every boolean key the loader checks as true or false", function()
		for _, leaf in leaves() do
			local p = property(pathOf(leaf))
			if leaf.spec.kind == "bool" then
				expect(p.type).toBe("boolean")
				local _, diags = Config.parse(encode(leaf.section, leaf.key, '"yes"'), json.decode)
				expect(#diags).toBe(1)
			end
		end
	end)
end)

return nil
