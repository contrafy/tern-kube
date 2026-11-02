--!strict
-- Ordering, filtering and bucketing of normalised events, plus the
-- ownerReferences closure that widens an object scope to what it owns.
local Model = require("./model")
local Resource = require("../model/resource")
local ModelTypes = require("../model/types")

type Event = Model.Event
type Ref = ModelTypes.ResourceRef

export type Group = { label: string, events: { Event }, warnings: number }
export type Filter = { warnings: boolean, text: string?, scope: { Ref }? }

local M = {}

-- Howard Hinnant's days_from_civil: proleptic Gregorian date -> days since
-- 1970-01-01, independent of the host time zone (os.time is local time).
local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function isLeap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function zoneOffset(zone: string): number?
	if zone == "Z" or zone == "z" then
		return 0
	end
	local sign, hh, mm = string.match(zone, "^([+-])(%d%d):(%d%d)$")
	if not sign then
		return nil
	end
	local h, m = tonumber(hh) :: number, tonumber(mm) :: number
	if h > 23 or m > 59 then
		return nil
	end
	local offset = h * 3600 + m * 60
	return if sign == "-" then -offset else offset
end

-- RFC 3339 date-time -> epoch seconds (fractional seconds kept); nil when malformed.
function M.parseTime(rfc3339: string): number?
	local ys, mos, ds, hs, mis, ss, frac, zone =
		string.match(rfc3339, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
	if not ys then
		return nil
	end
	local offset = zoneOffset(zone :: string)
	if offset == nil or frac == "." then
		return nil
	end
	local y, mo, d = tonumber(ys) :: number, tonumber(mos) :: number, tonumber(ds) :: number
	local h, mi, s = tonumber(hs) :: number, tonumber(mis) :: number, tonumber(ss) :: number
	if mo < 1 or mo > 12 or h > 23 or mi > 59 or s > 60 then
		return nil
	end
	local maxDay = if mo == 2 and isLeap(y) then 29 else MONTH_DAYS[mo]
	if d < 1 or d > maxDay then
		return nil
	end
	local fraction = if frac ~= "" then tonumber("0" .. (frac :: string)) :: number else 0
	return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s + fraction - offset
end

local function timeOf(e: Event): number?
	return (if e.last then M.parseTime(e.last) else nil) or (if e.first then M.parseTime(e.first) else nil)
end

-- Newest first by `last` (falling back to `first`); ties by key, then input
-- order; events without a parseable time keep their input order at the end.
function M.sort(events: { Event }): { Event }
	type Entry = { event: Event, time: number?, index: number }
	local entries: { Entry } = {}
	for i, e in events do
		table.insert(entries, { event = e, time = timeOf(e), index = i })
	end
	table.sort(entries, function(a: Entry, b: Entry): boolean
		local ta, tb = a.time, b.time
		if ta and tb then
			if ta ~= tb then
				return ta > tb
			end
			if a.event.key ~= b.event.key then
				return a.event.key < b.event.key
			end
		elseif ta or tb then
			return ta ~= nil
		end
		return a.index < b.index
	end)
	local out: { Event } = {}
	for _, entry in entries do
		table.insert(out, entry.event)
	end
	return out
end

-- Uid decides when both sides carry one (a recreated object reuses its name);
-- otherwise kind (case-insensitive: tables print `pod`), name and namespace.
local function sameObject(a: Ref, b: Ref): boolean
	if a.uid and b.uid then
		return a.uid == b.uid
	end
	return string.lower(a.kind) == string.lower(b.kind)
		and a.name == b.name
		and (a.namespace or "") == (b.namespace or "")
end

local function inScope(e: Event, scope: { Ref }): boolean
	local object = e.object
	if not object then
		return false
	end
	for _, ref in scope do
		if sameObject(object, ref) then
			return true
		end
	end
	return false
end

local function matchesText(e: Event, needle: string): boolean
	local object = e.object
	local haystack = {
		e.reason,
		if object then object.kind .. "/" .. object.name else "",
		e.message,
	}
	for _, s in haystack do
		if string.find(string.lower(s), needle, 1, true) then
			return true
		end
	end
	return false
end

-- `scope` nil means unscoped; an empty scope matches nothing. Text is a
-- case-insensitive plain substring over reason, `Kind/name` and message.
function M.filter(events: { Event }, f: Filter): { Event }
	local needle = if f.text and f.text ~= "" then string.lower(f.text) else nil
	local out: { Event } = {}
	for _, e in events do
		if f.warnings and e.type ~= "Warning" then
			continue
		end
		if needle and not matchesText(e, needle) then
			continue
		end
		if f.scope and not inScope(e, f.scope) then
			continue
		end
		table.insert(out, e)
	end
	return out
end

local BUCKETS: { { label: string, within: number } } = {
	{ label = "last 5 minutes", within = 5 * 60 },
	{ label = "last hour", within = 60 * 60 },
	-- Rolling 24 hours, not the calendar day: pure modules do not know the
	-- user's time zone, and a UTC day would split a local evening in two.
	{ label = "today", within = 24 * 60 * 60 },
}

local EARLIER = "earlier"

local function bucketOf(e: Event, now: number): string
	local t = timeOf(e)
	if t == nil then
		return EARLIER
	end
	-- Clock skew can stamp events slightly in the future: treat them as newest.
	local age = now - t
	for _, b in BUCKETS do
		if age < b.within then
			return b.label
		end
	end
	return EARLIER
end

-- Buckets keep input order (call sort first) and empty buckets are omitted.
function M.groups(events: { Event }, now: number): { Group }
	local byLabel: { [string]: Group } = {}
	local order = { BUCKETS[1].label, BUCKETS[2].label, BUCKETS[3].label, EARLIER }
	for _, label in order do
		byLabel[label] = { label = label, events = {}, warnings = 0 }
	end
	for _, e in events do
		local g = byLabel[bucketOf(e, now)]
		table.insert(g.events, e)
		if e.type == "Warning" then
			g.warnings += 1
		end
	end
	local out: { Group } = {}
	for _, label in order do
		local g = byLabel[label]
		if #g.events > 0 then
			table.insert(out, g)
		end
	end
	return out
end

local function ownedBy(obj: { [string]: any }, owner: Ref): boolean
	local metadata = obj.metadata
	if type(metadata) ~= "table" or type(metadata.ownerReferences) ~= "table" then
		return false
	end
	-- Owners live in the same namespace as what they own, or are cluster-scoped.
	if owner.namespace and metadata.namespace ~= owner.namespace then
		return false
	end
	for _, ownerRef in metadata.ownerReferences do
		if type(ownerRef) ~= "table" then
			continue
		end
		if owner.uid and type(ownerRef.uid) == "string" then
			if ownerRef.uid == owner.uid then
				return true
			end
		elseif ownerRef.kind == owner.kind and ownerRef.name == owner.name then
			return true
		end
	end
	return false
end

-- Scope first, then everything reachable through ownerReferences (Deployment
-- -> ReplicaSets -> Pods, CronJob -> Jobs -> Pods), breadth first in
-- `objects` order. Owners match by uid when the owner's uid is known, else by
-- kind+name within the namespace. Objects are seen once, so cycles terminate.
function M.owned(scope: Ref, objects: { any }): { Ref }
	local out: { Ref } = { scope }
	local seen: { [string]: boolean } = { [Resource.key(scope)] = true }
	if scope.uid then
		seen[scope.uid] = true
	end
	local head = 1
	while head <= #out do
		local owner = out[head]
		head += 1
		for _, obj in objects do
			if type(obj) ~= "table" or not ownedBy(obj, owner) then
				continue
			end
			local ref = Resource.fromObject(obj, "live")
			if not ref or seen[Resource.key(ref)] or (ref.uid and seen[ref.uid]) then
				continue
			end
			seen[Resource.key(ref)] = true
			if ref.uid then
				seen[ref.uid] = true
			end
			table.insert(out, ref)
		end
	end
	return out
end

return M
