--!strict
-- Display-only decoding of Secret `data` values. The decoder is strict
-- (canonical, padded RFC 4648 base64, as kubectl prints it) and fails
-- closed; decoded text is escaped wherever it could disguise or move what
-- the screen shows (terminal escapes, bidi controls, zero-width
-- characters). Nothing here keeps the decoded bytes beyond the call.

local Redact = require("./redact")

export type Kind = "text" | "escaped" | "binary" | "empty" | "invalid" | "toolarge"

export type Value = {
	kind: Kind,
	-- Decoded bytes; invalid: the length of the original string.
	size: number,
	-- text/escaped: what to show; invalid: the original (base64) string.
	text: string?,
	multiline: boolean,
	-- binary: the hex dump of the first HEX_BYTES bytes, and what it left out.
	hex: string?,
	more: number?,
	-- invalid: why the decoder refused.
	error: string?,
}

export type Pair = { key: string, value: any }
export type Entry = { key: string, value: Value }

local M = {}

M.MAX_VALUE = 64 * 1024
M.MAX_TOTAL = 1024 * 1024
M.HEX_BYTES = 256
-- More escaped bytes than this share of the value reads as binary.
M.BINARY_RATIO = 0.1

-- Why there is nothing to decode (Explore's masking notice says the same).
M.MASKED = "Secret values are masked; set security.show_secret_values to show them"

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PAD = string.byte("=")
local SIXBITS: { [number]: number } = {}
for i = 1, #ALPHABET do
	SIXBITS[string.byte(ALPHABET, i)] = i - 1
end

local function padding(s: string): number
	local n = #s
	if n >= 2 and string.byte(s, n) == PAD then
		return if string.byte(s, n - 1) == PAD then 2 else 1
	end
	return 0
end

-- Errors name positions only, never content.
function M.decodeBase64(s: string): (string?, string?)
	local n = #s
	if n == 0 then
		return "", nil
	end
	if n % 4 ~= 0 then
		return nil, "length is not a multiple of 4"
	end
	local out = buffer.create(n // 4 * 3 - padding(s))
	local o = 0
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local va, vb, vc, vd = SIXBITS[a], SIXBITS[b], SIXBITS[c], SIXBITS[d]
		local last = i + 3 == n
		if va == nil or vb == nil then
			return nil, string.format("unexpected character at offset %d", if va == nil then i - 1 else i)
		end
		if vc == nil then
			if not (last and c == PAD and d == PAD) then
				return nil, string.format("unexpected character at offset %d", i + 1)
			end
			if vb % 16 ~= 0 then
				return nil, "non-zero padding bits"
			end
			buffer.writeu8(out, o, va * 4 + vb // 16)
			o += 1
		elseif vd == nil then
			if not (last and d == PAD) then
				return nil, string.format("unexpected character at offset %d", i + 2)
			end
			if vc % 4 ~= 0 then
				return nil, "non-zero padding bits"
			end
			buffer.writeu8(out, o, va * 4 + vb // 16)
			buffer.writeu8(out, o + 1, (vb % 16) * 16 + vc // 4)
			o += 2
		else
			buffer.writeu8(out, o, va * 4 + vb // 16)
			buffer.writeu8(out, o + 1, (vb % 16) * 16 + vc // 4)
			buffer.writeu8(out, o + 2, (vc % 4) * 64 + vd)
			o += 3
		end
	end
	return buffer.tostring(out), nil
end

-- C0 controls (tab and newline aside), DEL, C1 controls, bidi embeddings,
-- overrides and isolates, zero-width characters and the BOM.
local function unsafe(cp: number): boolean
	return (cp < 32 and cp ~= 9 and cp ~= 10)
		or (cp >= 127 and cp <= 0x9F)
		or (cp >= 0x200B and cp <= 0x200F)
		or (cp >= 0x202A and cp <= 0x202E)
		or cp == 0x2060
		or (cp >= 0x2066 and cp <= 0x2069)
		or cp == 0xFEFF
end

local function escapeOf(cp: number): string
	if cp == 13 then
		return "\\r"
	end
	return if cp < 0x80 then string.format("\\x%02x", cp) else string.format("\\u{%x}", cp)
end

local function width(cp: number): number
	return if cp < 0x80 then 1 elseif cp < 0x800 then 2 elseif cp < 0x10000 then 3 else 4
end

function M.hexdump(bytes: string, max: number): string
	local n = math.min(#bytes, max)
	local lines: { string } = {}
	for off = 0, n - 1, 16 do
		local last = math.min(off + 16, n)
		local hex: { string } = {}
		local ascii: { string } = {}
		for i = off + 1, last do
			local b = string.byte(bytes, i)
			table.insert(hex, (if i - off == 9 then " " else "") .. string.format("%02x", b))
			table.insert(ascii, if b >= 32 and b < 127 then string.char(b) else ".")
		end
		table.insert(lines, string.format("%04x  %s  |%s|", off, table.concat(hex, " "), table.concat(ascii)))
	end
	return table.concat(lines, "\n")
end

local function binary(bytes: string): Value
	return {
		kind = "binary",
		size = #bytes,
		multiline = false,
		hex = M.hexdump(bytes, M.HEX_BYTES),
		more = math.max(0, #bytes - M.HEX_BYTES),
	}
end

function M.classify(bytes: string): Value
	local size = #bytes
	if size == 0 then
		return { kind = "empty", size = 0, multiline = false }
	end
	if string.find(bytes, "\0", 1, true) or utf8.len(bytes) == nil then
		return binary(bytes)
	end
	local parts: { string } = {}
	local backslashes: { number } = {}
	local escaped = 0
	local shown = false
	for pos, cp in utf8.codes(bytes) do
		if cp == 13 and string.byte(bytes, pos + 1) == 10 then
			table.insert(parts, "\\r")
			shown = true
		elseif unsafe(cp) then
			table.insert(parts, escapeOf(cp))
			escaped += width(cp)
		else
			table.insert(parts, string.sub(bytes, pos, pos + width(cp) - 1))
			if cp == 92 then
				table.insert(backslashes, #parts)
			end
		end
	end
	if escaped > size * M.BINARY_RATIO then
		return binary(bytes)
	end
	if escaped > 0 or shown then
		for _, i in backslashes do
			parts[i] = "\\\\"
		end
	end
	return {
		kind = if escaped > 0 then "escaped" else "text",
		size = size,
		text = table.concat(parts),
		multiline = string.find(bytes, "\n", 1, true) ~= nil,
	}
end

local function isPairs(source: any): boolean
	return type(source) == "table" and source[1] ~= nil
end

-- The `data` of a Secret object as pairs (nil when it is not a Secret).
function M.pairs(source: any): { Pair }?
	if isPairs(source) then
		return source :: { Pair }
	end
	if type(source) ~= "table" or source.kind ~= "Secret" then
		return nil
	end
	local out: { Pair } = {}
	if type(source.data) == "table" then
		for k, v in source.data do
			table.insert(out, { key = tostring(k), value = v })
		end
	end
	return out
end

-- At least one value that is not a mask: masked output has nothing to decode.
function M.hasValues(list: { Pair }): boolean
	for _, p in list do
		if type(p.value) == "string" and not Redact.isMask(p.value) then
			return true
		end
	end
	return false
end

function M.decodable(source: any): boolean
	local list = M.pairs(source)
	return list ~= nil and M.hasValues(list)
end

local function sorted(list: { Pair }): { Pair }
	local out = table.clone(list)
	table.sort(out, function(a: Pair, b: Pair): boolean
		return a.key < b.key
	end)
	return out
end

-- One entry per key, sorted. Values above MAX_VALUE, or past MAX_TOTAL
-- decoded bytes for the whole view, are not decoded at all.
function M.entries(source: any): { Entry }
	local list = M.pairs(source)
	if list == nil then
		return {}
	end
	local out: { Entry } = {}
	local total = 0
	for _, p in sorted(list) do
		local raw = p.value
		local value: Value
		if type(raw) ~= "string" then
			value = { kind = "invalid", size = 0, multiline = false, error = "not a string" }
		else
			local estimate = #raw // 4 * 3 - padding(raw)
			if estimate > M.MAX_VALUE or total + estimate > M.MAX_TOTAL then
				value = { kind = "toolarge", size = estimate, multiline = false }
			else
				local bytes, err = M.decodeBase64(raw)
				if bytes == nil then
					value = { kind = "invalid", size = #raw, text = raw, multiline = false, error = err }
				else
					total += #bytes
					value = M.classify(bytes)
				end
			end
		end
		table.insert(out, { key = p.key, value = value })
	end
	return out
end

return M
