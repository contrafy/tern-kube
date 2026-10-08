--!strict
-- examples/config.json is what users copy as a starting point: it must
-- list every key, load without a single diagnostic and change nothing,
-- so copying it can never weaken a default.
local Config = require("../../../plugin/lib/config")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local EXAMPLE = "examples/config.json"

describe("examples/config.json", function()
	it("loads cleanly and equals the defaults", function()
		local cfg, diags = Config.parse(fixtures.read(EXAMPLE), json.decode)
		expect(diags).toEqual({})
		expect(cfg).toEqual(Config.defaults())
	end)

	it("spells out every key", function()
		local raw = json.decode(fixtures.read(EXAMPLE))
		local missing: { string } = {}
		for key, value in Config.defaults() :: any do
			if raw[key] == nil and key ~= "kubeconfig" then
				table.insert(missing, key)
			elseif type(value) == "table" and next(value) ~= nil and type((next(value))) == "string" then
				for sub in value do
					if raw[key][sub] == nil then
						table.insert(missing, key .. "." .. sub)
					end
				end
			end
		end
		-- kubeconfig is null in the file; the decoder drops null members.
		expect(string.find(fixtures.read(EXAMPLE), '"kubeconfig": null', 1, true) ~= nil).toBe(true)
		table.sort(missing)
		expect(missing).toEqual({})
	end)
end)

return nil
