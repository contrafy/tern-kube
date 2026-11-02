--!strict
-- Filtering, paging and jumps over the kept records of a logs store.
local Parse = require("./parse")
local Store = require("./store")
local T = require("./types")

type Level = T.Level
type Record = T.Record
type Store = Store.Store

export type Filter = {
	levels: { [Level]: boolean }?,
	minLevel: Level?,
	sources: { [number]: boolean }?,
	text: string?,
	merge: boolean,
}
export type Window = { indices: { number }, matched: number, page: number, pages: number }

local M = {}

local function contains(hay: string?, needle: string): boolean
	return hay ~= nil and string.find(string.lower(hay), needle, 1, true) ~= nil
end

-- Plain, case-insensitive search over message, fields, continuation lines
-- and the source's pod/container (`srcHit`: sources matched once up front).
local function textMatches(srcHit: { [number]: boolean }, r: Record, needle: string): boolean
	if srcHit[r.source] or contains(r.message, needle) then
		return true
	end
	if r.fields then
		for _, f in r.fields do
			if contains(f.key, needle) or contains(f.value, needle) then
				return true
			end
		end
	end
	if r.extra then
		for _, l in r.extra do
			if contains(l, needle) then
				return true
			end
		end
	end
	return false
end

type Matcher = (Record) -> boolean

local function matcher(s: Store, f: Filter, floor: Level?): Matcher
	local levels = f.levels
	local sources = f.sources
	local minRank = math.max(Parse.rank(f.minLevel or "none"), Parse.rank(floor or "none"))
	local needle = if f.text and f.text ~= "" then string.lower(f.text) else nil
	local srcHit: { [number]: boolean } = {}
	if needle then
		for i, src in s.sources do
			srcHit[i] = contains(src.pod, needle) or contains(src.container, needle)
		end
	end
	return function(r: Record): boolean
		if levels and not levels[r.level] then
			return false
		end
		if minRank > 0 and Parse.rank(r.level) < minRank then
			return false
		end
		if sources and not sources[r.source] then
			return false
		end
		return needle == nil or textMatches(srcHit, r, needle)
	end
end

local DAYS_BEFORE_MONTH = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }

local function isLeap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function daysFromCivil(y: number, m: number, d: number): number
	local days = (y - 1970) * 365
	for yy = 1970, y - 1 do
		if isLeap(yy) then
			days += 1
		end
	end
	days += DAYS_BEFORE_MONTH[m] + d - 1
	if m > 2 and isLeap(y) then
		days += 1
	end
	return days
end

-- Sortable form of a kubelet RFC3339(Nano) time: UTC, fraction padded to 9
-- digits ("2026-11-02T16:22:48.983930000Z"). Go trims trailing zeros of the
-- fraction, so raw strings do not compare lexically.
function M.sortKey(ts: string): string
	if #ts == 30 and string.byte(ts, 30) == 90 and string.byte(ts, 20) == 46 then
		return ts
	end
	local y, mo, d, h, mi, sec, frac, zone =
		string.match(ts, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)(.*)$")
	if y == nil or mo == nil or d == nil or h == nil or mi == nil or sec == nil or frac == nil or zone == nil then
		return ts
	end
	local frac9 = string.sub(frac .. "000000000", 1, 9)
	if zone == "Z" or zone == "" then
		return string.format("%s-%s-%sT%s:%s:%s.%sZ", y, mo, d, h, mi, sec, frac9)
	end
	local sign, oh, om = string.match(zone, "^([%+%-])(%d%d):?(%d%d)$")
	if sign == nil or oh == nil or om == nil then
		return ts
	end
	local offset = ((tonumber(oh) :: number) * 60 + (tonumber(om) :: number)) * 60
	local days = daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	local epoch = days * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ tonumber(sec) :: number
	epoch -= if sign == "+" then offset else -offset
	local day = epoch // 86400
	local rem = epoch % 86400
	-- civil from days (Howard Hinnant's algorithm)
	local z = day + 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local dd = doy - (153 * mp + 2) // 5 + 1
	local mm = if mp < 10 then mp + 3 else mp - 9
	local yy = yoe + era * 400 + (if mm <= 2 then 1 else 0)
	return string.format(
		"%04d-%02d-%02dT%02d:%02d:%02d.%sZ",
		yy,
		mm,
		dd,
		rem // 3600,
		(rem % 3600) // 60,
		rem % 60,
		frac9
	)
end

type Lane = { indices: { number }, keys: { string }, at: number }

-- Stable merge by kubelet time: each source keeps its own order (sorted
-- first if its times go backwards); lanes interleave by (time, arrival).
-- Records without a time take the previous time of their source.
local function merged(s: Store, indices: { number }): { number }
	local lanes: { [number]: Lane } = {}
	local order: { number } = {}
	for _, i in indices do
		local r = s.records[i]
		local lane = lanes[r.source]
		if lane == nil then
			lane = { indices = {}, keys = {}, at = 1 }
			lanes[r.source] = lane
			table.insert(order, r.source)
		end
		local n = #lane.indices + 1
		lane.indices[n] = i
		lane.keys[n] = if r.ts then M.sortKey(r.ts) else (lane.keys[n - 1] or "")
	end
	local list: { Lane } = {}
	for _, src in order do
		local lane = lanes[src]
		local sorted = true
		for k = 2, #lane.keys do
			if lane.keys[k] < lane.keys[k - 1] then
				sorted = false
				break
			end
		end
		if not sorted then
			local pos: { number } = table.create(#lane.keys)
			for k = 1, #lane.keys do
				pos[k] = k
			end
			local keys = lane.keys
			table.sort(pos, function(a: number, b: number): boolean
				if keys[a] ~= keys[b] then
					return keys[a] < keys[b]
				end
				return a < b
			end)
			local ni: { number } = table.create(#pos)
			local nk: { string } = table.create(#pos)
			for k, p in pos do
				ni[k] = lane.indices[p]
				nk[k] = keys[p]
			end
			lane.indices, lane.keys = ni, nk
		end
		table.insert(list, lane)
	end
	if #list == 1 then
		return list[1].indices
	end
	local out: { number } = table.create(#indices)
	for n = 1, #indices do
		local best: Lane? = nil
		local bestKey, bestIndex = "", 0
		for _, lane in list do
			local k = lane.keys[lane.at]
			if k ~= nil then
				local idx = lane.indices[lane.at]
				if best == nil or k < bestKey or (k == bestKey and idx < bestIndex) then
					best, bestKey, bestIndex = lane, k, idx
				end
			end
		end
		local chosen = best :: Lane
		out[n] = bestIndex
		chosen.at += 1
	end
	return out
end

-- Kept records matching `f`, in arrival order (or merged by kubelet time
-- when `f.merge` and the run has --timestamps), cut into pages of
-- `pageSize`. Pages are 1-based; nil asks for the newest (last) page.
function M.apply(s: Store, f: Filter, page: number?, pageSize: number): Window
	local match = matcher(s, f, nil)
	local hits: { number } = {}
	local n = 0
	for i = s.first, s.last do
		if match(s.records[i]) then
			n += 1
			hits[n] = i
		end
	end
	if f.merge and s.opts.timestamps and n > 1 then
		hits = merged(s, hits)
	end
	local size = math.max(1, math.floor(pageSize))
	local pages = math.max(1, math.ceil(n / size))
	local p = if page == nil then pages else math.clamp(math.floor(page), 1, pages)
	local from = (p - 1) * size + 1
	local to = math.min(n, p * size)
	local indices: { number } = table.create(math.max(0, to - from + 1))
	if to >= from then
		table.move(hits, from, to, 1, indices)
	end
	return { indices = indices, matched = n, page = p, pages = pages }
end

-- Unfiltered records [index - radius, index + radius], clipped to the kept
-- range.
function M.context(s: Store, index: number, radius: number): Window
	local lo = math.max(s.first, index - radius)
	local hi = math.min(s.last, index + radius)
	local indices: { number } = {}
	for i = lo, hi do
		table.insert(indices, i)
	end
	return { indices = indices, matched = #indices, page = 1, pages = 1 }
end

-- Nearest kept record after (dir > 0) or before (dir < 0) `from`, in arrival
-- order, that matches `f` and is at `minLevel` or above; nil past either end.
function M.next(s: Store, f: Filter, from: number, dir: number, minLevel: Level): number?
	local step = if dir < 0 then -1 else 1
	local match = matcher(s, f, minLevel)
	local i = from + step
	if step > 0 then
		i = math.max(i, s.first)
	else
		i = math.min(i, s.last)
	end
	while i >= s.first and i <= s.last do
		if match(s.records[i]) then
			return i
		end
		i += step
	end
	return nil
end

return M
