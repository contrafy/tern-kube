--!strict
-- The first plugin load writes Config.STUB_TEXT when there is no config
-- file, so users find a file to edit and their editor finds the schema. The
-- stub must not set any setting: a later default change has to reach users
-- who never edited the file, and loading it must stay silent.
local Config = require("../../../plugin/lib/config")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("config stub", function()
	it("holds only $schema and schema_version", function()
		expect(json.decode(Config.STUB_TEXT)).toEqual({
			["$schema"] = Config.SCHEMA_URL,
			schema_version = Config.SCHEMA_VERSION,
		})
	end)

	it("loads without a diagnostic and changes no default", function()
		local cfg, diags = Config.parse(Config.STUB_TEXT, json.decode)
		expect(diags).toEqual({})
		expect(cfg).toEqual(Config.defaults())
	end)

	it("is pretty-printed with $schema first and ends with a newline", function()
		expect(Config.STUB_TEXT).toBe(
			'{\n  "$schema": "' .. Config.SCHEMA_URL .. '",\n  "schema_version": ' .. Config.SCHEMA_VERSION .. "\n}\n"
		)
	end)
end)

return nil
