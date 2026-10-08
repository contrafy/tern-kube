--!strict
local fixtures = require("../lib/fixtures")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("fixtures", function()
	-- Parsers are tested against byte-exact captures; embedding must not add or
	-- drop the first/last newline.
	it("embeds fixture files byte-exactly", function()
		local text = fixtures.read("kubectl/get_pods.txt")
		expect(string.sub(text, 1, 5)).toBe("NAME ")
		expect(string.sub(text, -1)).toBe("\n")
	end)

	it("splits text like Tern delivers lens lines", function()
		expect(fixtures.toLines("a\r\n  b\n\n\n  \n")).toEqual({ "a", "  b" })
		expect(fixtures.toLines("a\n\nb")).toEqual({ "a", "", "b" })
		expect(fixtures.toLines("")).toEqual({})
	end)

	it("fails loudly for fixtures that were never embedded", function()
		expect(function()
			fixtures.read("real/does-not-exist.txt")
		end).toThrow("make fixtures")
	end)

	it("lists fixtures by prefix in sorted order", function()
		local list = fixtures.list("kubectl/get_pods")
		expect(list[1]).toBe("kubectl/get_pods.txt")
		expect(#list > 1).toBe(true)
	end)
end)

return nil
