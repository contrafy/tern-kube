--!strict
-- Logs lens view state carried in action values (plan 4.5), like
-- lens/viewstate.luau: "lv=lvl:error,warn;src:1,3;wrap:1;page:4". A reload
-- rebuilds the store from the same lines, so record indices stay valid.
-- Default parts are omitted (the default state encodes to ""); unknown parts
-- and malformed numbers are ignored so other plugin versions still decode.
local Query = require("./query")
local T = require("./types")

type Level = T.Level

export type LogsView = {
	-- Shown levels; empty = all.
	levels: { Level },
	-- Shown source indices; empty = all.
	sources: { number },
	wrap: boolean,
	-- Time column; nil = automatic (shown when any time is known).
	time: boolean?,
	merge: boolean,
	-- 1-based page; nil = newest.
	page: number?,
	-- Record whose inspector is open.
	open: number?,
	-- Record a context view centres on.
	ctx: number?,
	help: boolean,
}

local M = {}

local LEVEL_ORDER: { Level } = { "fatal", "error", "warn", "info", "debug", "trace", "none" }

function M.default(): LogsView
	return {
		levels = {},
		sources = {},
		wrap = false,
		time = nil,
		merge = false,
		page = nil,
		open = nil,
		ctx = nil,
		help = false,
	}
end

-- Same escaping as lens/viewstate.luau.
local function escape(s: string): string
	return (
		string.gsub(s, "[%%;:=,~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function unescape(s: string): string
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

local function levelsOf(list: { Level }): { Level }
	local set: { [string]: boolean } = {}
	for _, l in list do
		set[l] = true
	end
	local out: { Level } = {}
	for _, l in LEVEL_ORDER do
		if set[l] then
			table.insert(out, l)
		end
	end
	return out
end

local function sourcesOf(list: { number }): { number }
	local set: { [number]: boolean } = {}
	local out: { number } = {}
	for _, n in list do
		if not set[n] then
			set[n] = true
			table.insert(out, n)
		end
	end
	table.sort(out)
	return out
end

local function wholeAtLeast(s: string, min: number): number?
	local n = tonumber(s)
	if n == nil or n ~= math.floor(n) or n < min or n ~= n or n == math.huge then
		return nil
	end
	return n
end

function M.encode(v: LogsView): string
	local parts: { string } = {}
	local levels = levelsOf(v.levels)
	if #levels > 0 then
		local esc: { string } = table.create(#levels)
		for i, l in levels do
			esc[i] = escape(l)
		end
		table.insert(parts, "lvl:" .. table.concat(esc, ","))
	end
	local sources = sourcesOf(v.sources)
	if #sources > 0 then
		local nums: { string } = table.create(#sources)
		for i, n in sources do
			nums[i] = string.format("%d", n)
		end
		table.insert(parts, "src:" .. table.concat(nums, ","))
	end
	if v.wrap then
		table.insert(parts, "wrap:1")
	end
	if v.time ~= nil then
		table.insert(parts, if v.time then "time:1" else "time:0")
	end
	if v.merge then
		table.insert(parts, "merge:1")
	end
	if v.page then
		table.insert(parts, string.format("page:%d", v.page))
	end
	if v.open then
		table.insert(parts, string.format("open:%d", v.open))
	end
	if v.ctx then
		table.insert(parts, string.format("ctx:%d", v.ctx))
	end
	if v.help then
		table.insert(parts, "help:1")
	end
	return table.concat(parts, ";")
end

local KNOWN_LEVEL: { [string]: Level } = {
	fatal = "fatal",
	error = "error",
	warn = "warn",
	info = "info",
	debug = "debug",
	trace = "trace",
	none = "none",
}

function M.decode(s: string): LogsView
	local v = M.default()
	for part in string.gmatch(s, "[^;]+") do
		local k, val = string.match(part, "^([^:]+):(.*)$")
		if k == nil or val == nil then
			continue
		end
		if k == "lvl" then
			local list: { Level } = {}
			for item in string.gmatch(val, "[^,]+") do
				local l = KNOWN_LEVEL[unescape(item)]
				if l then
					table.insert(list, l)
				end
			end
			v.levels = levelsOf(list)
		elseif k == "src" then
			local list: { number } = {}
			for item in string.gmatch(val, "[^,]+") do
				local n = wholeAtLeast(item, 0)
				if n then
					table.insert(list, n)
				end
			end
			v.sources = sourcesOf(list)
		elseif k == "wrap" then
			v.wrap = val == "1"
		elseif k == "time" then
			v.time = if val == "1" then true elseif val == "0" then false else nil
		elseif k == "merge" then
			v.merge = val == "1"
		elseif k == "page" then
			v.page = wholeAtLeast(val, 1) or v.page
		elseif k == "open" then
			v.open = wholeAtLeast(val, 1) or v.open
		elseif k == "ctx" then
			v.ctx = wholeAtLeast(val, 1) or v.ctx
		elseif k == "help" then
			v.help = val == "1"
		end
	end
	return v
end

function M.action(v: LogsView): string
	return "lv=" .. M.encode(v)
end

function M.filterOf(v: LogsView): Query.Filter
	local levels: { [Level]: boolean }? = nil
	if #v.levels > 0 then
		local set: { [Level]: boolean } = {}
		for _, l in v.levels do
			set[l :: Level] = true
		end
		levels = set
	end
	local sources: { [number]: boolean }? = nil
	if #v.sources > 0 then
		local set: { [number]: boolean } = {}
		for _, n in v.sources do
			set[n] = true
		end
		sources = set
	end
	return { levels = levels, minLevel = nil, sources = sources, text = nil, merge = v.merge }
end

return M
