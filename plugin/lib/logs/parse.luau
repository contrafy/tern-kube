--!strict
-- Line grammar of `kubectl logs` output (plan 4.2): kubectl diagnostics,
-- `--prefix` attribution, `--timestamps` kubelet time, continuation lines,
-- then the payload's format and level. Pure; JSON decoding is injected.
--
-- Every function runs once per delivered line, so dispatch is on the first
-- byte and plain `find`s; whole lines are never lowercased.
local ModelTypes = require("../model/types")
local T = require("./types")

type Level = T.Level
type Format = T.Format
type Field = T.Field
type Notice = T.Notice

export type Classified = {
	level: Level,
	format: Format,
	message: string,
	fields: { Field }?,
	appTime: string?,
	location: string?,
}

local M = {}

M.MAX_FIELDS = 32
M.MAX_EXTRA = 200
-- Field values re-encoded from JSON objects/arrays are cut here.
M.MAX_VALUE = 1024
M.LEVEL_WINDOW = 48

local RANK: { [Level]: number } = { fatal = 6, error = 5, warn = 4, info = 3, debug = 2, trace = 1, none = 0 }

function M.rank(level: Level): number
	return RANK[level] or 0
end

-- Plain-text level tokens (plan 4.2), keyed lowercase.
local WORDS: { [string]: Level } = {
	trace = "trace",
	debug = "debug",
	info = "info",
	notice = "info",
	warn = "warn",
	warning = "warn",
	error = "error",
	err = "error",
	fatal = "fatal",
	critical = "fatal",
	crit = "fatal",
	panic = "fatal",
}

-- Structured level values also seen in the wild (zap, syslog, .NET, Python).
local VALUES: { [string]: Level } = table.clone(WORDS)
VALUES.dbg = "debug"
VALUES.verbose = "debug"
VALUES.information = "info"
VALUES.informational = "info"
VALUES.alert = "fatal"
VALUES.emerg = "fatal"
VALUES.emergency = "fatal"
VALUES.dpanic = "fatal"

local function levelOfNumber(n: number): Level
	if n >= 60 then
		return "fatal"
	elseif n >= 50 then
		return "error"
	elseif n >= 40 then
		return "warn"
	elseif n >= 30 then
		return "info"
	elseif n >= 20 then
		return "debug"
	elseif n >= 10 then
		return "trace"
	end
	return "none"
end

-- String or pino/bunyan number (10 trace .. 60 fatal).
function M.levelOf(value: any): Level
	if type(value) == "number" then
		return levelOfNumber(value)
	elseif type(value) ~= "string" or #value > 16 then
		return "none"
	end
	local named: Level? = VALUES[string.lower(value)]
	if named then
		return named
	end
	local n = tonumber(value)
	return if n then levelOfNumber(n) else "none"
end

local function truthy(list: { string }?): boolean
	local v = if list then list[#list] else nil
	return v ~= nil and v ~= "false"
end

function M.optionsFor(inv: ModelTypes.Invocation, decode: (string) -> any): T.Options
	local flags = inv.flags
	local allContainers = truthy(flags["all-containers"])
	local containers = flags.container
	local first = inv.resources[1]
	local pod = if first and first.kind == "Pod" and inv.selector == nil then first.name else nil
	return {
		prefix = truthy(flags.prefix),
		timestamps = truthy(flags.timestamps),
		follow = truthy(flags.follow),
		decode = decode,
		pod = pod,
		container = if containers and not allContainers then containers[#containers] else nil,
		multiPod = inv.selector ~= nil or truthy(flags["all-pods"]),
		allContainers = allContainers,
	}
end

local function startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

local UNABLE = "unable to retrieve container logs for "

local function splitList(s: string): { string }
	local out: { string } = {}
	for item in string.gmatch(s, "[^,%s]+") do
		table.insert(out, item)
	end
	return out
end

-- kubectl's own lines. "start" forms are recognised at any position: with
-- `-l`, kubectl repeats `Defaulted container` per pod and the terminal shows
-- it between pod blocks, and `logs -p` prints `unable to retrieve ...` on
-- stdout with exit 0. "end" adds the forms that are only kubectl's when they
-- trail the output of a failed command (a log line may start with "error: ").
function M.diagnostic(line: string, phase: "start" | "end"): Notice?
	local b = string.byte(line, 1)
	if b == 70 then -- F
		local pod = string.match(line, "^Found %d+ pods, using pod/(%S+)$")
		if pod then
			return { kind = "found-pods", text = line, pod = pod }
		end
	elseif b == 68 then -- D
		local c, list = string.match(line, '^Defaulted container "([^"]+)" out of: (.+)$')
		if c and list then
			return { kind = "defaulted-container", text = line, container = c, containers = splitList(list) }
		end
	elseif b == 117 then -- u
		if startsWith(line, UNABLE) then
			return { kind = "error", text = line }
		end
	end
	if phase == "start" then
		return nil
	end
	if b == 101 then -- e
		if startsWith(line, "error: ") then
			return { kind = "error", text = line }
		end
	elseif b == 69 then -- E
		if startsWith(line, "Error from server") then
			return { kind = "error", text = line }
		end
	elseif b == 87 then -- W
		if startsWith(line, "Warning: ") then
			return { kind = "warning", text = line }
		end
	elseif b == 94 then -- ^
		if string.byte(line, 2) == 67 then -- C
			return { kind = "interrupted", text = "stopped (Ctrl-C)" }
		end
	end
	return nil
end

-- The shell's mark for output that did not end in a newline (zsh `%`/`#`,
-- fish `⏎`), which Tern delivers as a final line of its own.
function M.isPromptMark(line: string): boolean
	local s = string.match(line, "^%s*(.-)%s*$") or line
	return s == "%" or s == "#" or s == "⏎"
end

function M.splitPrefix(line: string): (string?, string?, string)
	if string.byte(line, 1) ~= 91 then -- [
		return nil, nil, line
	end
	local pod, container, at = string.match(line, "^%[pod/([^/%]]+)/([^%]]+)%] ()")
	if pod == nil or container == nil then
		return nil, nil, line
	end
	return pod, container, string.sub(line, at :: number)
end

function M.splitTimestamp(rest: string): (string?, string)
	local b = string.byte(rest, 1)
	if b == nil or b < 48 or b > 57 then
		return nil, rest
	end
	local ts, at = string.match(rest, "^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*[Z%+%-][%d:]*) ()")
	if ts == nil then
		return nil, rest
	end
	return ts, string.sub(rest, at :: number)
end

-- Strong continuation forms only (stack frames, `Caused by:`, Python
-- `File "..."`); the store adds the weaker "indented right after a line of the
-- same source" rule, which needs context.
function M.isContinuation(payload: string): boolean
	local b = string.byte(payload, 1)
	if b == 9 then
		return true
	elseif b == 32 then
		return string.find(payload, "^%s+at ") ~= nil
			or string.find(payload, '^%s+File "') ~= nil
			or string.find(payload, "^%s+%.%.%. %d+ more") ~= nil
	elseif b == 67 then -- C
		return startsWith(payload, "Caused by: ")
	end
	return false
end

-- Indented by two or more spaces: a continuation only when it directly
-- follows a line of the same source.
function M.isIndented(payload: string): boolean
	return string.byte(payload, 1) == 32 and string.find(payload, "^%s%s+%S") ~= nil
end

local function stripAnsi(s: string): string
	if string.find(s, "\27", 1, true) == nil then
		return s
	end
	return (string.gsub(s, "\27%[[0-?]*[ -/]*[@-~]", ""))
end

local function formatNumber(n: number): string
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return tostring(n)
end

local function quoteJson(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			if c == '"' or c == "\\" then
				return "\\" .. c
			end
			return string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function encodeInto(v: any, out: { string }, depth: number)
	local t = type(v)
	if t == "string" then
		table.insert(out, quoteJson(v))
	elseif t == "number" then
		table.insert(out, formatNumber(v))
	elseif t == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif t == "table" then
		if depth > 8 then
			table.insert(out, "…")
		elseif #v > 0 then
			table.insert(out, "[")
			for i, item in ipairs(v) do
				if i > 1 then
					table.insert(out, ",")
				end
				encodeInto(item, out, depth + 1)
			end
			table.insert(out, "]")
		else
			local keys: { string } = {}
			for k in v do
				if type(k) == "string" then
					table.insert(keys, k)
				end
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, quoteJson(k))
				table.insert(out, ":")
				encodeInto(v[k], out, depth + 1)
			end
			table.insert(out, "}")
		end
	else
		table.insert(out, "null")
	end
end

-- Field values: strings verbatim, numbers without a trailing ".0", nested
-- objects/arrays re-encoded as compact JSON with sorted keys (decoded
-- objects have no order) and cut at MAX_VALUE bytes.
function M.valueString(v: any): string
	local t = type(v)
	if t == "string" then
		return v
	elseif t == "number" then
		return formatNumber(v)
	elseif t == "boolean" then
		return if v then "true" else "false"
	end
	local out: { string } = {}
	encodeInto(v, out, 1)
	local s = table.concat(out)
	if #s > M.MAX_VALUE then
		return string.sub(s, 1, M.MAX_VALUE) .. "…"
	end
	return s
end

local LEVEL_KEYS = { "level", "lvl", "severity", "log.level", "levelname", "@l" }
local MESSAGE_KEYS = { "msg", "message", "log", "text", "@m", "@mt" }
local TIME_KEYS = { "ts", "time", "timestamp", "@timestamp", "t", "@t" }

local function isScalar(v: any): boolean
	local t = type(v)
	return t == "string" or t == "number" or t == "boolean"
end

-- Byte offset of `"key"` used as a member name in the source line, or huge.
local function keyOffset(src: string, key: string): number
	local needle = '"' .. key .. '"'
	local init = 1
	while true do
		local s, e = string.find(src, needle, init, true)
		if s == nil or e == nil then
			return math.huge
		end
		if string.find(src, "^%s*:", e + 1) then
			return s
		end
		init = e + 1
	end
end

type Keyed = { key: string, at: number }

-- Decoded objects are unordered, so fields follow the byte position of their
-- key in the line (the order the program wrote them); keys that cannot be
-- located (escaped names) follow, sorted by name.
local function orderedFields(src: string, obj: { [any]: any }, used: { [string]: boolean }): { Field }?
	local keys: { Keyed } = {}
	for k in obj do
		if type(k) == "string" and not used[k] then
			table.insert(keys, { key = k, at = 0 })
		end
	end
	if #keys == 0 then
		return nil
	end
	if #keys > 1 then
		for _, e in keys do
			e.at = keyOffset(src, e.key)
		end
		table.sort(keys, function(a: Keyed, b: Keyed): boolean
			if a.at ~= b.at then
				return a.at < b.at
			end
			return a.key < b.key
		end)
	end
	local fields: { Field } = table.create(math.min(#keys, M.MAX_FIELDS))
	for i = 1, math.min(#keys, M.MAX_FIELDS) do
		local k = keys[i].key
		fields[i] = { key = k, value = M.valueString(obj[k]) }
	end
	return fields
end

local function classifyJson(p: string, decode: (string) -> any): Classified?
	local ok, obj = pcall(decode, p)
	if not ok or type(obj) ~= "table" then
		return nil
	end
	local used: { [string]: boolean } = {}
	local level: Level = "none"
	for _, k in LEVEL_KEYS do
		local v = obj[k]
		if v ~= nil and isScalar(v) then
			level = M.levelOf(v)
			used[k] = true
			break
		end
	end
	if not next(used) and type(obj.log) == "table" and isScalar(obj.log.level) then
		level = M.levelOf(obj.log.level)
	end
	local message = ""
	for _, k in MESSAGE_KEYS do
		local v = obj[k]
		if v ~= nil and isScalar(v) then
			message = M.valueString(v)
			used[k] = true
			break
		end
	end
	local appTime: string? = nil
	for _, k in TIME_KEYS do
		local v = obj[k]
		if v ~= nil and isScalar(v) then
			appTime = M.valueString(v)
			used[k] = true
			break
		end
	end
	return {
		level = level,
		format = "json",
		message = message,
		fields = orderedFields(p, obj, used),
		appTime = appTime,
		location = nil,
	}
end

local UNESCAPE: { [string]: string } = { n = "\n", t = "\t", r = "\r" }

-- Double-quoted string starting at `i` (the quote) with backslash escapes.
-- Returns the value and the index after the closing quote.
local function unquote(s: string, i: number): (string?, number)
	local q = string.find(s, '["\\]', i + 1)
	if q and string.byte(s, q) == 34 then
		return string.sub(s, i + 1, q - 1), q + 1
	end
	local parts: { string } = {}
	local pos = i + 1
	while q do
		table.insert(parts, string.sub(s, pos, q - 1))
		if string.byte(s, q) == 34 then
			return table.concat(parts), q + 1
		end
		local e = string.sub(s, q + 1, q + 1)
		if e == "" then
			break
		end
		table.insert(parts, UNESCAPE[e] or e)
		pos = q + 2
		q = string.find(s, '["\\]', pos)
	end
	return nil, i
end

-- `k=v k2="quoted \" v"` from `i` to the end; nil when any token is not a pair.
local function parsePairs(s: string, i: number): { Field }?
	local fields: { Field } = {}
	local n = #s
	while true do
		local _, sp = string.find(s, "^%s*", i)
		i = (sp :: number) + 1
		if i > n then
			return fields
		end
		local ks, ke = string.find(s, "^[%w_%.%-@/]+=", i)
		if ks == nil or ke == nil then
			return nil
		end
		local key = string.sub(s, ks, ke - 1)
		i = ke + 1
		local value: string?
		if string.byte(s, i) == 34 then
			value, i = unquote(s, i)
			if value == nil then
				return nil
			end
		else
			local _, ve = string.find(s, "^%S*", i)
			value = string.sub(s, i, ve)
			i = (ve :: number) + 1
		end
		table.insert(fields, { key = key, value = value :: string })
	end
end

local function take(fields: { Field }, keys: { string }): string?
	for _, k in keys do
		for i, f in fields do
			if f.key == k then
				table.remove(fields, i)
				return f.value
			end
		end
	end
	return nil
end

local function capped(fields: { Field }): { Field }?
	if #fields == 0 then
		return nil
	end
	while #fields > M.MAX_FIELDS do
		table.remove(fields)
	end
	return fields
end

local LOGFMT_MARKERS = { level = true, lvl = true, severity = true, msg = true }

local function classifyLogfmt(p: string): Classified?
	if string.find(p, "^[%w_%.%-@/]+=") == nil then
		return nil
	end
	local pairs_ = parsePairs(p, 1)
	if pairs_ == nil or #pairs_ < 2 then
		return nil
	end
	local marked = false
	for _, f in pairs_ do
		if LOGFMT_MARKERS[f.key] then
			marked = true
			break
		end
	end
	if not marked then
		return nil
	end
	local lv = take(pairs_, LEVEL_KEYS)
	local message = take(pairs_, MESSAGE_KEYS)
	local appTime = take(pairs_, TIME_KEYS)
	return {
		level = if lv then M.levelOf(lv) else "none",
		format = "logfmt",
		message = message or "",
		fields = capped(pairs_),
		appTime = appTime,
		location = nil,
	}
end

local KLOG_LEVELS: { [string]: Level } = { I = "info", W = "warn", E = "error", F = "fatal" }

local function classifyKlog(p: string): Classified?
	local sev, date, clock, loc, tail =
		string.match(p, "^([IWEF])(%d%d%d%d) (%d%d:%d%d:%d%d%.%d+)%s+%d+ ([^%]]+)%] ?(.*)$")
	if sev == nil or date == nil or clock == nil or loc == nil or tail == nil then
		return nil
	end
	local message = tail
	local fields: { Field }? = nil
	if string.byte(tail, 1) == 34 then
		local msg, after = unquote(tail, 1)
		if msg then
			local rest = parsePairs(tail, after)
			if rest then
				message = msg
				fields = capped(rest)
			end
		end
	end
	return {
		level = KLOG_LEVELS[sev],
		format = "klog",
		message = message,
		fields = fields,
		appTime = date .. " " .. clock,
		location = loc,
	}
end

-- First bytes of level words, either case.
local WORD_FIRST: { [number]: boolean } = {}
for _, c in { "t", "d", "i", "n", "w", "e", "f", "c", "p" } do
	WORD_FIRST[string.byte(c)] = true
	WORD_FIRST[string.byte(string.upper(c))] = true
end
-- Before a token: start, space, tab, "[". After: end, space, tab, ":", "]".
local BEFORE: { [number]: boolean } = { [32] = true, [9] = true, [91] = true }
local AFTER: { [number]: boolean } = { [32] = true, [9] = true, [58] = true, [93] = true }

local function leadingTime(p: string): (string?, number)
	local b = string.byte(p, 1)
	if b == nil or b < 48 or b > 57 then
		return nil, 1
	end
	local t, at = string.match(p, "^(%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d[%.,]?%d*Z?)()")
	if t == nil then
		t, at = string.match(p, "^(%d%d:%d%d:%d%d[%.,]?%d*)()")
	end
	if t == nil or at == nil then
		return nil, 1
	end
	local zone, after = string.match(p, "^([%+%-]%d%d:?%d%d)()", at)
	if zone and after then
		t = t .. zone
		at = after
	end
	local _, sp = string.find(p, "^%s*", at)
	return t, (sp :: number) + 1
end

local function errorForm(p: string, i: number): boolean
	local b = string.byte(p, i)
	if b == 112 and string.find(p, "^panic: ", i) then
		return true
	elseif b == 84 and string.find(p, "^Traceback ", i) then
		return true
	elseif b == 102 and string.find(p, "^fatal error: ", i) then
		return true
	end
	if string.find(p, "Exception", i, true) then
		if string.find(p, "^[%w%.%$]+Exception[:%s]", i) or string.find(p, "^[%w%.%$]+Exception$", i) then
			return true
		end
	end
	return string.find(p, "Error: ", i, true) ~= nil and string.find(p, "^[%w%.]+Error: ", i) ~= nil
end

local function tokenLevel(p: string, i: number): Level
	local limit = i + M.LEVEL_WINDOW - 1
	local pos = i
	while pos <= limit do
		local a, b = string.find(p, "%a+", pos)
		if a == nil or b == nil or a > limit then
			break
		end
		local len = b - a + 1
		if len >= 3 and len <= 8 and WORD_FIRST[string.byte(p, a)] then
			local before = if a > 1 then string.byte(p, a - 1) else nil
			local after = string.byte(p, b + 1)
			if (before == nil or BEFORE[before]) and (after == nil or AFTER[after]) then
				local lv: Level? = WORDS[string.lower(string.sub(p, a, b))]
				if lv then
					return lv
				end
			end
		end
		pos = b + 1
	end
	return "none"
end

local function classifyPlain(p: string): Classified
	local appTime, i = leadingTime(p)
	local level: Level = if errorForm(p, i) then "error" else tokenLevel(p, i)
	return { level = level, format = "plain", message = p, fields = nil, appTime = appTime, location = nil }
end

-- Format and level of a payload (prefix and kubelet time already split off).
-- ANSI CSI sequences are stripped first: Tern strips them before a lens sees
-- a line, fixture files keep them.
function M.classify(payload: string, decode: (string) -> any): Classified
	local p = stripAnsi(payload)
	local b = string.byte(p, 1)
	if b == 123 or (b == 32 and string.find(p, "^%s+{")) then
		local c = classifyJson(p, decode)
		if c then
			return c
		end
	elseif b and KLOG_LEVELS[string.char(b)] then
		local d = string.byte(p, 2)
		if d and d >= 48 and d <= 57 then
			local c = classifyKlog(p)
			if c then
				return c
			end
		end
	end
	local c = classifyLogfmt(p)
	if c then
		return c
	end
	return classifyPlain(p)
end

return M
