--!strict
-- Decoded Secret values reach the screen only through this module, so the
-- decoder must fail closed (no lenient base64 that guesses), and anything
-- that could disguise or move text (terminal escapes, bidi overrides,
-- zero-width characters) must be shown escaped, never raw.
local SecretData = require("../../../plugin/lib/model/secretdata")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function b64(bytes: string): string
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local out: { string } = {}
	for i = 1, #bytes, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local function at(shift: number): string
			local idx = bit32.band(bit32.rshift(n, shift), 63) + 1
			return string.sub(alphabet, idx, idx)
		end
		table.insert(out, at(18) .. at(12) .. (if b then at(6) else "=") .. (if c then at(0) else "="))
	end
	return table.concat(out)
end

describe("SecretData.decodeBase64", function()
	-- RFC 4648 section 10 test vectors.
	it("decodes the RFC 4648 vectors", function()
		local vectors = {
			{ "", "" },
			{ "Zg==", "f" },
			{ "Zm8=", "fo" },
			{ "Zm9v", "foo" },
			{ "Zm9vYg==", "foob" },
			{ "Zm9vYmE=", "fooba" },
			{ "Zm9vYmFy", "foobar" },
		}
		for _, v in vectors do
			expect((SecretData.decodeBase64(v[1]))).toBe(v[2])
		end
	end)

	it("decodes every byte value", function()
		local all: { string } = {}
		for i = 0, 255 do
			table.insert(all, string.char(i))
		end
		local bytes = table.concat(all)
		expect((SecretData.decodeBase64(b64(bytes)))).toBe(bytes)
	end)

	-- kubectl prints canonical, padded standard base64; anything else is not
	-- what the API returned, so it is reported, never guessed at.
	it("rejects what kubectl never prints", function()
		local bad = {
			"Zg", -- missing padding
			"Zg=", -- short padding
			"Zg===", -- extra padding
			"Zm9v====",
			"Zm9vYg=a", -- data after padding
			"Z=g=",
			"Zm9v Yg==", -- whitespace
			"Zm9v\nYg==",
			"Zm9-YmFy", -- URL-safe alphabet
			"Zm9_YmFy",
			"Zm9vYmF*",
			"Zh==", -- non-zero pad bits (not canonical)
			"Zm9=",
			"=",
			"====",
		}
		for _, s in bad do
			local out, err = SecretData.decodeBase64(s)
			expect(out).toBeNil()
			expect(type(err)).toBe("string")
		end
	end)
end)

describe("SecretData.classify", function()
	it("plain UTF-8 is text", function()
		local v = SecretData.classify("hunter2-fake")
		expect(v.kind).toBe("text")
		expect(v.text).toBe("hunter2-fake")
		expect(v.size).toBe(12)
		expect(v.multiline).toBe(false)
		local cafe = "caf" .. utf8.char(0xe9) .. " " .. utf8.char(0x1f600)
		local u = SecretData.classify(cafe)
		expect(u.kind).toBe("text")
		expect(u.text).toBe(cafe)
	end)

	it("PEM-like values are multi-line text", function()
		local pem = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n"
		local v = SecretData.classify(pem)
		expect(v.kind).toBe("text")
		expect(v.multiline).toBe(true)
		expect(v.text).toBe(pem)
	end)

	it("an empty value is empty", function()
		local v = SecretData.classify("")
		expect(v.kind).toBe("empty")
		expect(v.size).toBe(0)
	end)

	-- CRLF is ordinary text, but the CR would be invisible: shown as \r.
	it("CRLF stays text with the CR made visible", function()
		local v = SecretData.classify("a\r\nb\r\n")
		expect(v.kind).toBe("text")
		expect(v.text).toBe("a\\r\nb\\r\n")
		expect(v.multiline).toBe(true)
	end)

	-- A value can rename the terminal title or recolour the screen; it is
	-- shown as escapes, never as raw control bytes.
	it("escapes terminal control sequences", function()
		local v = SecretData.classify("user=admin \27]0;pwned\7\27[31mred text here and more")
		expect(v.kind).toBe("escaped")
		local text = v.text :: string
		expect(text).toContain("\\x1b]0;pwned\\x07\\x1b[31m")
		expect((string.find(text, "\27", 1, true))).toBeNil()
		expect((string.find(text, "\7", 1, true))).toBeNil()
	end)

	-- Trojan Source: bidi overrides reorder what is shown; zero-width
	-- characters hide differences between two values.
	it("escapes bidi controls and zero-width characters", function()
		local pad = " and enough ordinary text to stay below the binary ratio"
		local cases = {
			{ "admin" .. utf8.char(0x202e) .. "txt.exe", "\\u{202e}" },
			{ "isolate" .. utf8.char(0x2066) .. "x" .. utf8.char(0x2069), "\\u{2066}x\\u{2069}" },
			{ "zero" .. utf8.char(0x200b) .. "width", "\\u{200b}" },
			{ "rlm" .. utf8.char(0x200f) .. "x", "\\u{200f}" },
			{ "joiner" .. utf8.char(0x2060) .. "x", "\\u{2060}" },
			{ "bom" .. utf8.char(0xfeff) .. "x", "\\u{feff}" },
			{ "c1" .. utf8.char(0x85) .. "x", "\\u{85}" },
			{ "del\127x", "\\x7f" },
			{ "lone\rcr", "\\r" },
		}
		for _, c in cases do
			local v = SecretData.classify(c[1] .. pad)
			expect(v.kind).toBe("escaped")
			expect(v.text :: string).toContain(c[2])
		end
	end)

	-- Once escapes are shown, a literal backslash must not read as one.
	it("doubles backslashes when escapes are shown", function()
		local v = SecretData.classify("C:\\x1b \27 padding padding padding")
		expect(v.text).toBe("C:\\\\x1b \\x1b padding padding padding")
		expect(SecretData.classify("C:\\path").text).toBe("C:\\path")
	end)

	it("keeps tabs and newlines as they are", function()
		local v = SecretData.classify("a\tb\nc")
		expect(v.kind).toBe("text")
		expect(v.text).toBe("a\tb\nc")
	end)

	it("NUL, invalid UTF-8 or mostly escaped bytes are binary", function()
		expect(SecretData.classify("abc\0def").kind).toBe("binary")
		expect(SecretData.classify("abc\255def").kind).toBe("binary")
		expect(SecretData.classify("\192\128 overlong").kind).toBe("binary")
		expect(SecretData.classify("\237\160\128 surrogate").kind).toBe("binary")
		expect(SecretData.classify("\137PNG\r\n\26\n").kind).toBe("binary")
		expect(SecretData.classify("\27\27abcdefgh").kind).toBe("binary")
		local png = SecretData.classify("\0\1\2\255\254\137PNG\r\n\26\n")
		expect(png.kind).toBe("binary")
		expect(png.size).toBe(13)
		expect(png.hex).toBe("0000  00 01 02 ff fe 89 50 4e  47 0d 0a 1a 0a  |......PNG....|")
		expect(png.more).toBe(0)
	end)
end)

describe("SecretData.hexdump", function()
	it("prints 16 bytes per line with an ASCII column", function()
		local bytes = "0123456789abcdefXY"
		expect(SecretData.hexdump(bytes, 256)).toBe(
			"0000  30 31 32 33 34 35 36 37  38 39 61 62 63 64 65 66  |0123456789abcdef|\n" .. "0010  58 59  |XY|"
		)
	end)

	it("stops at the cap", function()
		local bytes = string.rep("\0", 300)
		local dump = SecretData.hexdump(bytes, 256)
		local lines = string.split(dump, "\n")
		expect(#lines).toBe(16)
		expect(lines[16]).toContain("00f0")
		local v = SecretData.classify(bytes)
		expect(v.more).toBe(44)
	end)
end)

describe("SecretData.entries", function()
	it("decodes a Secret object's data, sorted by key", function()
		local obj = {
			kind = "Secret",
			data = {
				password = b64("hunter2-fake"),
				["blob.bin"] = b64("\0\1\2"),
				empty = "",
				broken = "not*base64",
			},
		}
		local list = SecretData.entries(obj)
		local keys: { string } = {}
		for _, e in list do
			table.insert(keys, e.key)
		end
		expect(keys).toEqual({ "blob.bin", "broken", "empty", "password" })
		expect(list[1].value.kind).toBe("binary")
		expect(list[2].value.kind).toBe("invalid")
		expect(list[2].value.text).toBe("not*base64")
		expect(list[3].value.kind).toBe("empty")
		expect(list[4].value.text).toBe("hunter2-fake")
	end)

	it("takes key/value pairs read from YAML", function()
		local list = SecretData.entries({ { key = "a", value = b64("x") }, { key = "b", value = "" } })
		expect(#list).toBe(2)
		expect(list[1].value.text).toBe("x")
		expect(list[2].value.kind).toBe("empty")
	end)

	it("non-string values are invalid, not decoded", function()
		local list = SecretData.entries({ kind = "Secret", data = { n = 5 } })
		expect(list[1].value.kind).toBe("invalid")
	end)

	it("caps text per value and decoded bytes per view", function()
		local big = b64(string.rep("a", SecretData.MAX_VALUE + 1))
		local one = SecretData.entries({ { key = "big", value = big } })
		expect(one[1].value.kind).toBe("toolarge")
		expect(one[1].value.size).toBe(SecretData.MAX_VALUE + 1)
		local chunk = b64(string.rep("a", SecretData.MAX_VALUE))
		local many: { SecretData.Pair } = {}
		local n = math.floor(SecretData.MAX_TOTAL / SecretData.MAX_VALUE) + 1
		for i = 1, n do
			table.insert(many, { key = string.format("k%03d", i), value = chunk })
		end
		local list = SecretData.entries(many)
		expect(list[n - 1].value.kind).toBe("text")
		expect(list[n].value.kind).toBe("toolarge")
	end)
end)

describe("SecretData.decodable", function()
	it("needs a Secret holding unmasked string data", function()
		expect(SecretData.decodable({ kind = "Secret", data = { a = "eA==" } })).toBe(true)
		expect(SecretData.decodable({ kind = "Secret", data = { a = "<redacted: 4 bytes base64>" } })).toBe(false)
		expect(SecretData.decodable({ kind = "Secret", data = {} })).toBe(false)
		expect(SecretData.decodable({ kind = "Secret" })).toBe(false)
		expect(SecretData.decodable({ kind = "ConfigMap", data = { a = "eA==" } })).toBe(false)
		expect(SecretData.decodable(nil)).toBe(false)
	end)
end)

return nil
