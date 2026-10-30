--!strict
-- The edit preview sends a merge patch built from these values to the API
-- server. Anything lost on the way (`[]` turning into `{}`, `1.50` into
-- `1.5`, a dropped null) would preview a different change than the one
-- kubectl applies, so decode/encode must be lossless and the patch exact.
local Jsonv = require("../../../plugin/lib/parse/jsonv")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function decode(text: string): Jsonv.Value
	local v, err = Jsonv.decode(text)
	assert(v, err)
	return v
end

local function patch(a: string, b: string): string?
	local p = Jsonv.mergePatch(decode(a), decode(b))
	return if p then Jsonv.encode(p) else nil
end

describe("parse.jsonv decode/encode", function()
	it("round-trips member order, empty containers, nulls and number text", function()
		local text = '{"z":1.50,"a":[],"m":{},"n":null,"big":9007199254740993,"e":-1.0e+3,"b":[true,false]}'
		expect(Jsonv.encode(decode(text))).toBe(text)
	end)

	it("decodes escapes including surrogate pairs and re-escapes control characters", function()
		local v = decode('"a\\"b\\\\c\\n\\u00e9\\ud83d\\ude00\\u0001"')
		expect(v).toEqual({ t = "str", v = 'a"b\\c\n\195\169\240\159\152\128\1' })
		expect(Jsonv.encode(v)).toBe('"a\\"b\\\\c\\n\195\169\240\159\152\128\\u0001"')
	end)

	it("keeps the last value of a duplicate key at its first position", function()
		expect(Jsonv.encode(decode('{"a":1,"b":2,"a":3}'))).toBe('{"a":3,"b":2}')
	end)

	it("reports malformed input with a byte offset instead of raising", function()
		for _, bad in { "", "{", '{"a" 1}', "[1,]", "01", "1.", "-", '"\\x"', "{} x", "nul", '"a\nb"' } do
			local v, err = Jsonv.decode(bad)
			expect(v).toBeNil()
			expect(err).toContain("byte")
		end
	end)
end)

describe("parse.jsonv get/equal", function()
	it("walks object keys and zero-based array indexes", function()
		local v = decode('{"spec":{"containers":[{"name":"a"},{"name":"b"}]}}')
		expect(Jsonv.get(v, { "spec", "containers", "1", "name" })).toEqual({ t = "str", v = "b" })
		expect(Jsonv.get(v, { "spec", "containers", "2" })).toBeNil()
		expect(Jsonv.get(v, { "spec", "x", "y" })).toBeNil()
	end)

	it("ignores member order but not array order, types or number text", function()
		expect(Jsonv.equal(decode('{"a":1,"b":[1,2]}'), decode('{"b":[1,2],"a":1}'))).toBe(true)
		expect(Jsonv.equal(decode("[1,2]"), decode("[2,1]"))).toBe(false)
		expect(Jsonv.equal(decode("[]"), decode("{}"))).toBe(false)
		expect(Jsonv.equal(decode('"1"'), decode("1"))).toBe(false)
		expect(Jsonv.equal(decode('{"a":null}'), decode("{}"))).toBe(false)
	end)
end)

describe("parse.jsonv mergePatch (RFC 7386)", function()
	it("is nil when nothing changed", function()
		expect(patch('{"a":{"b":1}}', '{"a":{"b":1}}')).toBeNil()
	end)

	it("carries only changed members, recursing into objects", function()
		expect(
			patch(
				'{"metadata":{"name":"w","labels":{"a":"1"}},"spec":{"size":3,"color":"blue"}}',
				'{"metadata":{"name":"w","labels":{"a":"1","b":"2"}},"spec":{"size":4,"color":"blue"}}'
			)
		).toBe('{"metadata":{"labels":{"b":"2"}},"spec":{"size":4}}')
	end)

	-- A removed member must be sent as null, or the server keeps it.
	it("removes members with null, after the edited members", function()
		expect(patch('{"a":1,"b":2,"c":3}', '{"c":4}')).toBe('{"c":4,"a":null,"b":null}')
	end)

	-- Merge patches cannot address list items: the whole list is sent.
	it("replaces arrays whole and keeps [] distinct from {}", function()
		expect(patch('{"tags":["a"],"x":{}}', '{"tags":["a","b"],"x":[]}')).toBe('{"tags":["a","b"],"x":[]}')
	end)

	it("replaces a member whose type changed", function()
		expect(patch('{"a":{"b":1}}', '{"a":"s"}')).toBe('{"a":"s"}')
		expect(patch('{"a":"s"}', '{"a":{"b":1}}')).toBe('{"a":{"b":1}}')
	end)
end)

return nil
