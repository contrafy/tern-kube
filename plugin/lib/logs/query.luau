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

-- Lowered message, fields and continuation lines of a record, NUL-separated
-- so a needle never matches across two of them; cached in the store until
-- the record changes or leaves. `buf`: scratch space reused across records.
local function searchText(s: Store, r: Record, buf: { string }): string
	local cached = s.search[r.index]
	if cached then
		return cached
	end
	local text: string
	if r.fields == nil and r.extra == nil then
		text = string.lower(r.message)
	else
		table.clear(buf)
		buf[1] = r.message
		local n = 1
		if r.fields then
			for _, f in r.fields do
				buf[n + 1], buf[n + 2] = f.key, f.value
				n += 2
			end
		end
		if r.extra then
			for _, l in r.extra do
				n += 1
				buf[n] = l
			end
		end
		text = string.lower(table.concat(buf, "\0"))
	end
	s.search[r.index] = text
	return text
end

-- A filter in the form matching needs.
type Spec = {
	levels: { [Level]: boolean }?,
	minRank: number,
	sources: { [number]: boolean }?,
	needle: string?,
}

local function spec(f: Filter, floor: Level?): Spec
	return {
		levels = f.levels,
		minRank = math.max(Parse.rank(f.minLevel or "none"), Parse.rank(floor or "none")),
		sources = f.sources,
		needle = if f.text and f.text ~= "" then string.lower(f.text) else nil,
	}
end

local function matchesAll(p: Spec): boolean
	return p.levels == nil and p.minRank == 0 and p.sources == nil and p.needle == nil
end

local function setKey(set: { [any]: boolean }?): string
	if set == nil then
		return "*"
	end
	local on: { string } = {}
	for k, v in set do
		if v then
			table.insert(on, tostring(k))
		end
	end
	table.sort(on)
	return table.concat(on, ",")
end

-- Identifies the hits of `p` over one order, for the store's result cache.
local function resultKey(p: Spec, merge: boolean): string
	return table.concat({
		if merge then "merged" else "arrival",
		setKey(p.levels),
		tostring(p.minRank),
		setKey(p.sources),
		p.needle or "",
	}, "\0")
end

type Matcher = (Record) -> boolean

-- Plain, case-insensitive search over message, fields, continuation lines
-- and the source's pod/container (sources matched once up front).
local function matcher(s: Store, p: Spec): Matcher
	local levels, minRank, sources, needle = p.levels, p.minRank, p.sources, p.needle
	local srcHit: { [number]: boolean } = {}
	local buf: { string } = {}
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
		return needle == nil or srcHit[r.source] == true or string.find(searchText(s, r, buf), needle, 1, true) ~= nil
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

-- Record indices sorted by (key, index), keys alongside.
type Run = { indices: { number }, keys: { string } }

-- Each source keeps its own order, sorted first if its times go backwards.
local function sortRun(run: Run)
	local keys = run.keys
	local sorted = true
	for k = 2, #keys do
		if keys[k] < keys[k - 1] then
			sorted = false
			break
		end
	end
	if sorted then
		return
	end
	local pos: { number } = table.create(#keys)
	for k = 1, #keys do
		pos[k] = k
	end
	table.sort(pos, function(a: number, b: number): boolean
		if keys[a] ~= keys[b] then
			return keys[a] < keys[b]
		end
		return a < b
	end)
	local ni: { number } = table.create(#pos)
	local nk: { string } = table.create(#pos)
	for k, p in pos do
		ni[k] = run.indices[p]
		nk[k] = keys[p]
	end
	run.indices, run.keys = ni, nk
end

-- Writes the merge of runs `a` and `b` into `out` from position `at`.
local function mergeInto(a: Run, b: Run, out: Run, at: number)
	local ai, ak, bi, bk = a.indices, a.keys, b.indices, b.keys
	local oi, ok = out.indices, out.keys
	local x, y, w = 1, 1, at
	local nx, ny = #ai, #bi
	while x <= nx and y <= ny do
		local kx, ky = ak[x], bk[y]
		if kx < ky or (kx == ky and ai[x] < bi[y]) then
			oi[w], ok[w] = ai[x], kx
			x += 1
		else
			oi[w], ok[w] = bi[y], ky
			y += 1
		end
		w += 1
	end
	if x <= nx then
		table.move(ai, x, nx, w, oi)
		table.move(ak, x, nx, w, ok)
	elseif y <= ny then
		table.move(bi, y, ny, w, oi)
		table.move(bk, y, ny, w, ok)
	end
end

-- Merges sorted runs pairwise until one is left.
local function mergeAll(runs: { Run }): Run
	while #runs > 1 do
		local paired: { Run } = {}
		for k = 1, #runs, 2 do
			local a, b = runs[k], runs[k + 1]
			if b == nil then
				table.insert(paired, a)
			else
				local n = #a.indices + #b.indices
				local out: Run = { indices = table.create(n), keys = table.create(n) }
				mergeInto(a, b, out, 1)
				table.insert(paired, out)
			end
		end
		runs = paired
	end
	return runs[1]
end

-- Every kept record merged by kubelet time, stable on equal times. Records
-- without a time take the previous time of their source. Kept in the store
-- across calls: evicted indices leave, records pushed since are merged in.
local function mergedOrder(s: Store): { number }
	local m: Store.Merged = s.merged or { order = {}, keys = {}, upto = s.first - 1, low = s.first, lastKey = {} }
	s.merged = m
	local order, keys = m.order, m.keys
	if m.low < s.first then
		local n = 0
		for k = 1, #order do
			local i = order[k]
			if i >= s.first then
				n += 1
				order[n], keys[n] = i, keys[k]
			end
		end
		for k = #order, n + 1, -1 do
			order[k], keys[k] = nil, nil
		end
		m.low = s.first
	end
	local from = math.max(m.upto + 1, s.first)
	if from > s.last then
		return order
	end
	local bySource: { [number]: Run } = {}
	local runs: { Run } = {}
	for i = from, s.last do
		local r = s.records[i]
		local key = if r.ts then M.sortKey(r.ts) else (m.lastKey[r.source] or "")
		m.lastKey[r.source] = key
		local run = bySource[r.source]
		if run == nil then
			run = { indices = {}, keys = {} }
			bySource[r.source] = run
			table.insert(runs, run)
		end
		table.insert(run.indices, i)
		table.insert(run.keys, key)
	end
	m.upto = s.last
	for _, run in runs do
		sortRun(run)
	end
	local new = mergeAll(runs)
	-- New records have the highest indices, so they sort after every merged
	-- record with a key <= the smallest new key: only the tail past that
	-- point is re-merged (a stream mostly appends).
	local n = #order
	local lo, hi = 1, n + 1
	local smallest = new.keys[1]
	while lo < hi do
		local mid = (lo + hi) // 2
		if keys[mid] <= smallest then
			lo = mid + 1
		else
			hi = mid
		end
	end
	local tail: Run = { indices = table.create(n - lo + 1), keys = table.create(n - lo + 1) }
	table.move(order, lo, n, 1, tail.indices)
	table.move(keys, lo, n, 1, tail.keys)
	mergeInto(tail, new, { indices = order, keys = keys }, lo)
	return order
end

-- Kept records matching `p` in arrival or merged order; the last result is
-- kept in the store so paging and re-renders do not rescan.
local function hitsOf(s: Store, p: Spec, merge: boolean): { number }
	local key = resultKey(p, merge)
	local cached = s.result
	if cached and cached.gen == s.gen and cached.key == key then
		return cached.hits
	end
	local match = matcher(s, p)
	local records = s.records
	local hits: { number } = {}
	local n = 0
	if merge then
		for _, i in mergedOrder(s) do
			if match(records[i]) then
				n += 1
				hits[n] = i
			end
		end
	else
		for i = s.first, s.last do
			if match(records[i]) then
				n += 1
				hits[n] = i
			end
		end
	end
	s.result = { gen = s.gen, key = key, hits = hits }
	return hits
end

-- Kept records matching `f`, in arrival order (or merged by kubelet time
-- when `f.merge` and the run has --timestamps), cut into pages of
-- `pageSize`. Pages are 1-based; nil asks for the newest (last) page.
function M.apply(s: Store, f: Filter, page: number?, pageSize: number): Window
	local merge = f.merge and s.opts.timestamps
	local p = spec(f, nil)
	-- nil: every kept record in arrival order, records[first..last].
	local hits: { number }? = nil
	if not matchesAll(p) then
		hits = hitsOf(s, p, merge)
	elseif merge then
		hits = mergedOrder(s)
	end
	local n = if hits then #hits else s.last - s.first + 1
	local size = math.max(1, math.floor(pageSize))
	local pages = math.max(1, math.ceil(n / size))
	local pg = if page == nil then pages else math.clamp(math.floor(page), 1, pages)
	local from = (pg - 1) * size + 1
	local to = math.min(n, pg * size)
	local indices: { number } = table.create(math.max(0, to - from + 1))
	if hits and to >= from then
		table.move(hits, from, to, 1, indices)
	elseif to >= from then
		for k = from, to do
			indices[k - from + 1] = s.first + k - 1
		end
	end
	return { indices = indices, matched = n, page = pg, pages = pages }
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
	local match = matcher(s, spec(f, minLevel))
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
