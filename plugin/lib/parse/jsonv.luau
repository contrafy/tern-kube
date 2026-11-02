--!strict
-- Lossless JSON values. `tern.json` decodes to plain tables, which loses what
-- an edit preview must keep: `[]` vs `{}`, the exact number text (`1.50`,
-- 64-bit integers), explicit nulls and member order. Values here keep all of
-- them so a merge patch computed from two kubectl conversions re-encodes
-- exactly what the user wrote.

export type Value =
	{ t: "obj", keys: { string }, map: { [string]: Value } }
	| { t: "arr", items: { Value } }
	| { t: "str", v: string }
	| { t: "num", raw: string }
	| { t: "bool", v: boolean }
	| { t: "null" }

local M = {}

local MAX_DEPTH = 512

type Cursor = { text: string, pos: number, depth: number }

local function fail(c: Cursor, what: string): never
	error({ message = string.format("%s at byte %d", what, c.pos) }, 0)
end

local function skip(c: Cursor)
	c.pos = string.find(c.text, "[^ \t\r\n]", c.pos) or #c.text + 1
end

local ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

local function hex4(c: Cursor, at: number): number
	local digits = string.sub(c.text, at, at + 3)
	if not string.match(digits, "^%x%x%x%x$") then
		c.pos = at
		fail(c, "invalid \\u escape")
	end
	return tonumber(digits, 16) :: number
end

local function parseString(c: Cursor): string
	local text = c.text
	local i = c.pos + 1
	local parts: { string } = {}
	while true do
		local stop = string.find(text, '["\\%c]', i)
		if stop == nil then
			c.pos = #text + 1
			fail(c, "unterminated string")
		end
		local s = stop :: number
		table.insert(parts, string.sub(text, i, s - 1))
		local ch = string.sub(text, s, s)
		if ch == '"' then
			c.pos = s + 1
			return table.concat(parts)
		elseif ch == "\\" then
			local e = string.sub(text, s + 1, s + 1)
			if e == "u" then
				local code = hex4(c, s + 2)
				i = s + 6
				if code >= 0xD800 and code <= 0xDBFF and string.sub(text, i, i + 1) == "\\u" then
					local low = hex4(c, i + 2)
					if low >= 0xDC00 and low <= 0xDFFF then
						code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
						i += 6
					end
				end
				table.insert(parts, utf8.char(code))
			elseif ESCAPES[e] then
				table.insert(parts, ESCAPES[e])
				i = s + 2
			else
				c.pos = s
				fail(c, "invalid escape")
			end
		else
			c.pos = s
			fail(c, "control character in string")
		end
	end
end

local parseValue: (Cursor) -> Value

local function parseObject(c: Cursor): Value
	local keys: { string } = {}
	local map: { [string]: Value } = {}
	c.pos += 1
	skip(c)
	if string.sub(c.text, c.pos, c.pos) == "}" then
		c.pos += 1
		return { t = "obj", keys = keys, map = map }
	end
	while true do
		if string.sub(c.text, c.pos, c.pos) ~= '"' then
			fail(c, "expected object key")
		end
		local key = parseString(c)
		skip(c)
		if string.sub(c.text, c.pos, c.pos) ~= ":" then
			fail(c, "expected ':'")
		end
		c.pos += 1
		skip(c)
		local value = parseValue(c)
		-- Duplicate keys: the last value wins (Go's encoding/json), first position kept.
		if map[key] == nil then
			table.insert(keys, key)
		end
		map[key] = value
		skip(c)
		local ch = string.sub(c.text, c.pos, c.pos)
		c.pos += 1
		if ch == "}" then
			return { t = "obj", keys = keys, map = map }
		elseif ch ~= "," then
			c.pos -= 1
			fail(c, "expected ',' or '}'")
		end
		skip(c)
	end
end

local function parseArray(c: Cursor): Value
	local items: { Value } = {}
	c.pos += 1
	skip(c)
	if string.sub(c.text, c.pos, c.pos) == "]" then
		c.pos += 1
		return { t = "arr", items = items }
	end
	while true do
		table.insert(items, parseValue(c))
		skip(c)
		local ch = string.sub(c.text, c.pos, c.pos)
		c.pos += 1
		if ch == "]" then
			return { t = "arr", items = items }
		elseif ch ~= "," then
			c.pos -= 1
			fail(c, "expected ',' or ']'")
		end
		skip(c)
	end
end

local LITERALS: { [string]: Value } = {
	["true"] = { t = "bool", v = true },
	["false"] = { t = "bool", v = false },
	["null"] = { t = "null" },
}

-- JSON number grammar: no leading zeros, digits after '.', digits in the exponent.
local function scanNumber(text: string, pos: number): string?
	local i = if string.sub(text, pos, pos) == "-" then pos + 1 else pos
	local int = string.match(text, "^0", i) or string.match(text, "^[1-9]%d*", i)
	if int == nil then
		return nil
	end
	i += #int
	local frac = string.match(text, "^%.%d+", i)
	if frac then
		i += #frac
	end
	local exp = string.match(text, "^[eE][%-+]?%d+", i)
	if exp then
		i += #exp
	end
	return string.sub(text, pos, i - 1)
end

function parseValue(c: Cursor): Value
	local ch = string.sub(c.text, c.pos, c.pos)
	if ch == "{" or ch == "[" then
		c.depth += 1
		if c.depth > MAX_DEPTH then
			fail(c, "nesting too deep")
		end
		local v = if ch == "{" then parseObject(c) else parseArray(c)
		c.depth -= 1
		return v
	elseif ch == '"' then
		return { t = "str", v = parseString(c) }
	end
	local raw = scanNumber(c.text, c.pos)
	if raw then
		c.pos += #raw
		return { t = "num", raw = raw }
	end
	for word, value in LITERALS do
		if string.sub(c.text, c.pos, c.pos + #word - 1) == word then
			c.pos += #word
			return table.clone(value)
		end
	end
	return fail(c, "unexpected token")
end

function M.decode(text: string): (Value?, string?)
	local c: Cursor = { text = text, pos = 1, depth = 0 }
	local ok, result = pcall(function(): Value
		skip(c)
		local v = parseValue(c)
		skip(c)
		if c.pos <= #text then
			fail(c, "trailing data")
		end
		return v
	end)
	if ok then
		return result, nil
	end
	local err: any = result
	if type(err) == "table" and type(err.message) == "string" then
		return nil, err.message
	end
	error(err, 0)
end

local function encodeString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(ch: string): string
			if ch == '"' then
				return '\\"'
			elseif ch == "\\" then
				return "\\\\"
			elseif ch == "\n" then
				return "\\n"
			elseif ch == "\r" then
				return "\\r"
			elseif ch == "\t" then
				return "\\t"
			end
			return string.format("\\u%04x", string.byte(ch))
		end)
		.. '"'
end

local function encodeInto(v: Value, out: { string })
	if v.t == "obj" then
		table.insert(out, "{")
		for i, k in v.keys do
			if i > 1 then
				table.insert(out, ",")
			end
			table.insert(out, encodeString(k))
			table.insert(out, ":")
			encodeInto(v.map[k], out)
		end
		table.insert(out, "}")
	elseif v.t == "arr" then
		table.insert(out, "[")
		for i, item in v.items do
			if i > 1 then
				table.insert(out, ",")
			end
			encodeInto(item, out)
		end
		table.insert(out, "]")
	elseif v.t == "str" then
		table.insert(out, encodeString(v.v))
	elseif v.t == "num" then
		table.insert(out, v.raw)
	elseif v.t == "bool" then
		table.insert(out, if v.v then "true" else "false")
	else
		table.insert(out, "null")
	end
end

-- Compact JSON, members in their original order.
function M.encode(v: Value): string
	local out: { string } = {}
	encodeInto(v, out)
	return table.concat(out)
end

-- Object members by key; array items by zero-based index ("0", "1", ...).
function M.get(v: Value, path: { string }): Value?
	local cur: Value? = v
	for _, seg in path do
		local node = cur
		if node == nil then
			return nil
		elseif node.t == "obj" then
			cur = node.map[seg]
		elseif node.t == "arr" then
			local index = if string.match(seg, "^%d+$") then tonumber(seg) else nil
			cur = if index then node.items[(index :: number) + 1] else nil
		else
			return nil
		end
	end
	return cur
end

-- Member order does not matter; numbers compare by their text, which is what
-- kubectl's own serialization makes canonical for both sides.
function M.equal(a: Value, b: Value): boolean
	if a.t == "obj" and b.t == "obj" then
		if #a.keys ~= #b.keys then
			return false
		end
		for _, k in a.keys do
			local other = b.map[k]
			if other == nil or not M.equal(a.map[k], other) then
				return false
			end
		end
		return true
	elseif a.t == "arr" and b.t == "arr" then
		if #a.items ~= #b.items then
			return false
		end
		for i, item in a.items do
			if not M.equal(item, b.items[i]) then
				return false
			end
		end
		return true
	elseif a.t == "str" and b.t == "str" then
		return a.v == b.v
	elseif a.t == "num" and b.t == "num" then
		return a.raw == b.raw
	elseif a.t == "bool" and b.t == "bool" then
		return a.v == b.v
	end
	return a.t == "null" and b.t == "null"
end

-- RFC 7386 JSON merge patch turning `original` into `edited`: members
-- removed become null, objects recurse, anything else (arrays included) is
-- replaced whole. Members follow the edited order, removals last.
function M.mergePatch(original: Value, edited: Value): Value?
	if M.equal(original, edited) then
		return nil
	end
	if original.t ~= "obj" or edited.t ~= "obj" then
		return edited
	end
	local keys: { string } = {}
	local map: { [string]: Value } = {}
	for _, k in edited.keys do
		local before = original.map[k]
		local after = edited.map[k]
		local change: Value? = if before == nil then after else M.mergePatch(before, after)
		if change ~= nil then
			table.insert(keys, k)
			map[k] = change
		end
	end
	for _, k in original.keys do
		if edited.map[k] == nil then
			table.insert(keys, k)
			map[k] = { t = "null" }
		end
	end
	return { t = "obj", keys = keys, map = map }
end

return M
