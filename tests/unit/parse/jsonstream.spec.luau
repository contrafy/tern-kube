--!strict
-- label/annotate/patch over several objects print the objects back to back,
-- not as a List, so one JSON decode of stdout fails; the splitter is what
-- makes those after states readable at all.
local Jsonstream = require("../../../plugin/lib/parse/jsonstream")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("parse.jsonstream split", function()
	it("splits kubectl's concatenated label output into one text per object", function()
		local texts = Jsonstream.split(fixtures.read("kubectl/track1/label-cm-cm2-json.txt")) :: { string }
		expect(#texts).toBe(2)
		expect(json.decode(texts[1]).metadata.name).toBe("cm")
		expect(json.decode(texts[2]).metadata.name).toBe("cm2")
	end)

	it("keeps a single object (or a List) whole", function()
		local texts = Jsonstream.split(fixtures.read("kubectl/track1/get-cm-json.txt")) :: { string }
		expect(#texts).toBe(1)
		expect(json.decode(texts[1]).kind).toBe("List")
	end)

	-- `label -l` matching nothing prints nothing and exits 0.
	it("returns no texts for empty output", function()
		expect((Jsonstream.split(""))).toEqual({})
		expect((Jsonstream.split("  \n"))).toEqual({})
	end)

	it("ignores brackets and quotes inside strings", function()
		local texts = Jsonstream.split('{"a":"}{\\"]"}{"b":["{"]}') :: { string }
		expect(texts).toEqual({ '{"a":"}{\\"]"}', '{"b":["{"]}' })
	end)

	it("fails on stray text instead of guessing", function()
		local texts, err = Jsonstream.split('{"a":1}\nWarning: x')
		expect(texts).toBeNil()
		expect(err).toContain("byte 9")
	end)

	it("fails on a truncated object", function()
		local texts, err = Jsonstream.split('{"a":1}{"b":')
		expect(texts).toBeNil()
		expect(err).toContain("unterminated")
	end)
end)

return nil
