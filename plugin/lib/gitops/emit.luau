--!strict
-- Block-style YAML emitter for exported Kubernetes objects. Output must read
-- back identically under both YAML 1.2 and the YAML 1.1 resolver that
-- kubectl (sigs.k8s.io/yaml, go-yaml v2) uses, so any string that either
-- version could resolve to a non-string, or that the grammar would split, is
-- quoted. Plain style is chosen only for strings proven safe.

export type Options = {
	-- Consulted for empty tables only (non-empty sequences are detected by
	-- shape): true emits `[]`. JSON decoders lose `[]` vs `{}` otherwise; in
	-- Tern `tern.json.encode(t) == "[]"` answers it for decoded arrays.
	isList: ((t: { [any]: any }) -> boolean)?,
	-- Sentinel standing for JSON null (e.g. `tern.json.null`).
	null: any?,
	-- Comment lines (without `# `) emitted before the document.
	comments: { string }?,
}

local TOP_ORDER: { [string]: number } = { apiVersion = 1, kind = 2, metadata = 3, spec = 4, data = 5, stringData = 6 }
local METADATA_ORDER: { [string]: number } = { name = 1, namespace = 2, labels = 3, annotations = 4 }
local ITEM_ORDER: { [string]: number } = { name = 1 }

-- YAML 1.1 bools/nulls and the 1.2 core schema spellings, compared lowercased.
local RESERVED: { [string]: true } = {
	["~"] = true,
	null = true,
	["true"] = true,
	["false"] = true,
	yes = true,
	no = true,
	on = true,
	off = true,
	y = true,
	n = true,
	["<<"] = true,
	["="] = true,
}

local INFINITIES: { [string]: true } = {
	inf = true,
	infinity = true,
	nan = true,
	[".inf"] = true,
	[".nan"] = true,
	[".infinity"] = true,
}

local LEADING_INDICATORS = "-?:,[]{}#&*!|>'\"%@`"

-- Unicode characters YAML treats as line breaks or that parsers strip.
local NEL, LS, PS, BOM = "\194\133", "\226\128\168", "\226\128\169", "\239\187\191"
local SPECIAL_UNICODE: { string } = { NEL, LS, PS, BOM }

local function hasSpecialUnicode(s: string): boolean
	for _, seq in SPECIAL_UNICODE do
		if string.find(s, seq, 1, true) then
			return true
		end
	end
	-- C1 control characters U+0080..U+009F.
	return string.find(s, "\194[\128-\159]") ~= nil
end

local function hasControl(s: string): boolean
	return string.find(s, "[%z\1-\8\11-\31\127]") ~= nil or hasSpecialUnicode(s)
end

local function looksNumeric(s: string): boolean
	local lowered = string.lower(s)
	local unsigned = string.match(lowered, "^[-+]?(.*)$") :: string
	if INFINITIES[unsigned] then
		return true
	end
	local first = string.sub(s, 1, 1)
	if not string.find(first, "[%d%+%.%-]") then
		return false
	end
	-- Ints/floats in every base, exponents, underscores and YAML 1.1
	-- sexagesimal (`1:30`) all draw only from these characters.
	if string.find(unsigned, "%d") and string.find(unsigned, "^[%x_%.:xop%+%-]*$") then
		return true
	end
	-- Timestamps (`2001-12-14`, `2001-12-14t21:59:43.10-05:00`).
	return string.find(s, "^%d%d%d%d%-%d%d?%-%d%d?") ~= nil
end

local function isPlainSafe(s: string): boolean
	if s == "" or RESERVED[string.lower(s)] then
		return false
	end
	if string.find(s, "^%s") or string.find(s, "%s$") then
		return false
	end
	if string.find(LEADING_INDICATORS, string.sub(s, 1, 1), 1, true) then
		return false
	end
	if string.find(s, "[%c]") or hasSpecialUnicode(s) then
		return false
	end
	if string.find(s, ": ", 1, true) or string.find(s, " #", 1, true) or string.sub(s, -1) == ":" then
		return false
	end
	return not looksNumeric(s)
end

local DOUBLE_ESCAPES: { [string]: string } = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\0"] = "\\0",
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\t"] = "\\t",
	["\n"] = "\\n",
	["\v"] = "\\v",
	["\f"] = "\\f",
	["\r"] = "\\r",
	["\27"] = "\\e",
}

local UNICODE_ESCAPES: { [string]: string } = {
	[NEL] = "\\N",
	[LS] = "\\L",
	[PS] = "\\P",
	[BOM] = "\\uFEFF",
}

local function doubleQuoted(s: string): string
	local body = string.gsub(s, '[%z\1-\31\127\\"]', function(c: string): string
		return DOUBLE_ESCAPES[c] or string.format("\\x%02X", string.byte(c))
	end)
	for seq, esc in UNICODE_ESCAPES do
		body = string.gsub(body, seq, esc)
	end
	body = string.gsub(body, "\194([\128-\159])", function(c: string): string
		return string.format("\\x%02X", string.byte(c))
	end)
	return '"' .. body .. '"'
end

local function singleQuoted(s: string): string
	return "'" .. string.gsub(s, "'", "''") .. "'"
end

-- Inline form of a string scalar (for keys and single-line values).
local function quote(s: string): string
	if isPlainSafe(s) then
		return s
	end
	if hasControl(s) or string.find(s, "[\t\n]") then
		return doubleQuoted(s)
	end
	return singleQuoted(s)
end

-- Literal block style keeps multiline text readable. Rejected when content
-- cannot round-trip through it: CR/control chars, tab-led lines (tabs are not
-- indentation), trailing spaces, or text with no visible content.
local function literalEligible(s: string): boolean
	if not string.find(s, "\n", 1, true) or string.find(s, "\r", 1, true) then
		return false
	end
	if string.find(s, "[%z\1-\8\11-\31\127]") or hasSpecialUnicode(s) then
		return false
	end
	if string.find(s, "^\t") or string.find(s, "\n\t") then
		return false
	end
	if string.find(s, " \n") or string.find(s, " $") then
		return false
	end
	return string.find(s, "%S") ~= nil
end

-- Header and content lines of a literal block scalar whose content sits at
-- `indent` columns, `step` columns deeper than its parent.
local function literal(s: string, indent: number, step: number): (string, { string })
	local trailing = #(string.match(s, "\n*$") :: string)
	local chomp = if trailing == 0 then "-" elseif trailing == 1 then "" else "+"
	local indicator = if string.find(s, "^[ \n]") then tostring(step) else ""
	local body = if trailing > 0 then string.sub(s, 1, #s - trailing) else s
	local pad = string.rep(" ", indent)
	local out: { string } = {}
	for _, line in string.split(body, "\n") do
		table.insert(out, if line == "" then "" else pad .. line)
	end
	for _ = 2, trailing do
		table.insert(out, "")
	end
	return "|" .. indicator .. chomp, out
end

local function number(n: number): string
	if n ~= n then
		return ".nan"
	elseif n == math.huge then
		return ".inf"
	elseif n == -math.huge then
		return "-.inf"
	end
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	for digits = 15, 17 do
		local text = string.format("%." .. digits .. "g", n)
		if tonumber(text) == n then
			return text
		end
	end
	return string.format("%.17g", n)
end

type Ctx = { opts: Options }

local function isEmpty(t: { [any]: any }): boolean
	return next(t) == nil
end

local function isSequence(t: { [any]: any }): boolean
	local n = 0
	for k in t do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #t
end

local function sortedKeys(map: { [any]: any }, order: { [string]: number }?): { string }
	local keys: { string } = {}
	for k in map do
		table.insert(keys, tostring(k))
	end
	table.sort(keys, function(a: string, b: string): boolean
		local ra = if order then order[a] or math.huge else math.huge
		local rb = if order then order[b] or math.huge else math.huge
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	return keys
end

local function lookup(map: { [any]: any }, key: string): any
	local v = map[key]
	if v == nil then
		v = map[tonumber(key) :: any]
	end
	return v
end

local writeMap: (
	ctx: Ctx,
	map: { [any]: any },
	indent: number,
	out: { string },
	first: string?,
	order: { [string]: number }?
) -> ()
local writeList: (ctx: Ctx, list: { any }, indent: number, out: { string }, first: string?) -> ()

-- Scalar or empty-collection text for `v`, or nil when `v` needs a block.
local function inline(ctx: Ctx, v: any): string?
	local t = type(v)
	if t == "string" then
		return if literalEligible(v) then nil else quote(v)
	elseif t == "number" then
		return number(v)
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif v == nil or (ctx.opts.null ~= nil and v == ctx.opts.null) then
		return "null"
	elseif t == "table" then
		if isEmpty(v) then
			local isList = ctx.opts.isList
			return if isList and isList(v) then "[]" else "{}"
		end
		return nil
	end
	error(string.format("emit: unsupported value of type %s", t), 0)
end

-- Writes `v` after `head` (`key:` or `-`); nested content at `indent`.
local function writeValue(ctx: Ctx, v: any, head: string, indent: number, out: { string }, order: { [string]: number }?)
	local text = inline(ctx, v)
	if text then
		table.insert(out, head .. " " .. text)
	elseif type(v) == "string" then
		local header, lines = literal(v, indent, 2)
		table.insert(out, head .. " " .. header)
		table.move(lines, 1, #lines, #out + 1, out)
	elseif isSequence(v) then
		if string.sub(head, -1) == "-" then
			writeList(ctx, v, indent, out, head .. " ")
		else
			table.insert(out, head)
			writeList(ctx, v, indent, out, nil)
		end
	elseif string.sub(head, -1) == "-" then
		writeMap(ctx, v, indent, out, head .. " ", order or ITEM_ORDER)
	else
		table.insert(out, head)
		writeMap(ctx, v, indent, out, nil, order)
	end
end

writeMap = function(ctx, map, indent, out, first, order)
	local pad = string.rep(" ", indent)
	for i, key in sortedKeys(map, order) do
		local prefix = if i == 1 and first then first else pad
		local head = prefix .. quote(key) .. ":"
		local childOrder = if key == "metadata" then METADATA_ORDER else nil
		writeValue(ctx, lookup(map, key), head, indent + 2, out, childOrder)
	end
end

writeList = function(ctx, list, indent, out, first)
	local pad = string.rep(" ", indent)
	for i, item in list do
		local prefix = if i == 1 and first then first else pad
		writeValue(ctx, item, prefix .. "-", indent + 2, out, nil)
	end
end

-- One YAML document for `value`, newline-terminated, without `---`.
local function yaml(value: any, opts: Options?): string
	local ctx: Ctx = { opts = opts or {} }
	local out: { string } = {}
	local comments: { string } = ctx.opts.comments or {}
	for _, comment in comments do
		table.insert(out, if comment == "" then "#" else "# " .. comment)
	end
	local text = if type(value) == "string" then quote(value) else inline(ctx, value)
	if text then
		table.insert(out, text)
	elseif isSequence(value) then
		writeList(ctx, value, 0, out, nil)
	else
		writeMap(ctx, value, 0, out, nil, TOP_ORDER)
	end
	return table.concat(out, "\n") .. "\n"
end

return {
	yaml = yaml,
	quote = quote,
	isPlainSafe = isPlainSafe,
}
