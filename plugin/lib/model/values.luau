--!strict
-- Typed readings of kubectl table cells: column type inference, value parsers,
-- status tones and sort keys. Pure; no clock.

local Types = require("../model/types")

type ColumnType = Types.ColumnType
export type Tone = "success" | "warning" | "error" | "muted" | "neutral"
export type SortKey = number | string

local M = {}

local function isPlaceholder(value: string): boolean
	return value == "" or string.find(value, "^<[^>]*>$") ~= nil
end

M.isPlaceholder = isPlaceholder

local DURATION_UNITS: { [string]: number } = {
	y = 365 * 86400,
	d = 86400,
	h = 3600,
	m = 60,
	s = 1,
}
local DURATION_ORDER = "ydhms"

-- kubectl HumanDuration ("90s", "5m30s", "3d4h", "2y3d"); units must descend.
function M.duration(value: string): number?
	if value == "" then
		return nil
	end
	local total = 0
	local lastRank = 0
	local pos = 1
	while pos <= #value do
		local digits, unit, stop = string.match(value, "^(%d+)([ydhms])()", pos)
		if digits == nil or unit == nil or stop == nil then
			return nil
		end
		local rank = string.find(DURATION_ORDER, unit, 1, true) :: number
		if rank <= lastRank then
			return nil
		end
		lastRank = rank
		total += (tonumber(digits) :: number) * DURATION_UNITS[unit]
		pos = stop
	end
	return total
end

function M.ratio(value: string): (number?, number?)
	local num, den = string.match(value, "^(%d+)/(%d+)$")
	if num == nil or den == nil then
		return nil, nil
	end
	return tonumber(num), tonumber(den)
end

-- RESTARTS: "3" or "3 (5m ago)".
function M.count(value: string): number?
	local digits = string.match(value, "^(%d+)$") or string.match(value, "^(%d+) %(.*%)$")
	return if digits then tonumber(digits) else nil
end

function M.percent(value: string): number?
	local digits = string.match(value, "^(%-?%d+%.?%d*)%%$")
	return if digits then tonumber(digits) else nil
end

-- Fractional suffixes divide so "500n" is exactly 5e-7 rather than 500 * 1e-9.
local QUANTITY_DIVISOR: { [string]: number } = { n = 1e9, u = 1e6, m = 1e3 }

local QUANTITY_SUFFIX: { [string]: number } = {
	[""] = 1,
	k = 1e3,
	M = 1e6,
	G = 1e9,
	T = 1e12,
	P = 1e15,
	E = 1e18,
	Ki = 1024,
	Mi = 1024 ^ 2,
	Gi = 1024 ^ 3,
	Ti = 1024 ^ 4,
	Pi = 1024 ^ 5,
	Ei = 1024 ^ 6,
}

-- Kubernetes resource.Quantity in base units (cores, bytes).
function M.quantity(value: string): number?
	local mantissa, suffix = string.match(value, "^([%+%-]?%d*%.?%d+)(%a*)$")
	if mantissa == nil or suffix == nil then
		local base, exponent = string.match(value, "^([%+%-]?%d*%.?%d+)[eE]([%+%-]?%d+)$")
		if base and exponent then
			return (tonumber(base) :: number) * 10 ^ (tonumber(exponent) :: number)
		end
		return nil
	end
	local number = tonumber(mantissa)
	if number == nil then
		return nil
	end
	local divisor = QUANTITY_DIVISOR[suffix]
	if divisor then
		return number / divisor
	end
	local scale = QUANTITY_SUFFIX[suffix]
	return if scale then number * scale else nil
end

local function daysFromCivil(y: number, m: number, d: number): number
	local year = if m <= 2 then y - 1 else y
	local era = (if year >= 0 then year else year - 399) // 400
	local yoe = year - era * 400
	local doy = (153 * (if m > 2 then m - 3 else m + 9) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- RFC3339 as seconds since the Unix epoch (fraction kept), computed from the
-- calendar fields so it needs no os.time.
function M.timestamp(value: string): number?
	local y, mo, d, h, mi, s, frac, zone =
		string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
	if y == nil or zone == nil then
		return nil
	end
	local offset = 0
	if zone ~= "Z" and zone ~= "z" then
		local sign, oh, om = string.match(zone, "^([%+%-])(%d%d):(%d%d)$")
		if sign == nil then
			return nil
		end
		offset = (tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60
		if sign == "-" then
			offset = -offset
		end
	end
	if frac == "." then
		return nil
	end
	local days = daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	local seconds = days * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ (tonumber(s) :: number)
		- offset
	if frac ~= "" then
		seconds += tonumber("0" .. (frac :: string)) :: number
	end
	return seconds
end

local HEADER_TYPES: { [string]: ColumnType } = {
	AGE = "duration",
	["LAST SEEN"] = "duration",
	["FIRST SEEN"] = "duration",
	DURATION = "duration",
	RESTARTS = "count",
	STATUS = "status",
	PHASE = "status",
	["CPU(cores)"] = "quantity",
	["MEMORY(bytes)"] = "quantity",
	CPU = "quantity",
	MEMORY = "quantity",
	CAPACITY = "quantity",
	["CPU%"] = "percent",
	["MEMORY%"] = "percent",
	["CPU(%)"] = "percent",
	["MEMORY(%)"] = "percent",
	DESIRED = "number",
	CURRENT = "number",
	["UP-TO-DATE"] = "number",
	AVAILABLE = "number",
	DATA = "number",
	REVISION = "number",
	COUNT = "number",
}

local CONDITION_VALUES: { [string]: boolean } = { True = true, False = true, Unknown = true }
local EVENT_TYPES: { [string]: boolean } = { Normal = true, Warning = true }

local function all(samples: { string }, predicate: (string) -> boolean): boolean
	local seen = false
	for _, sample in samples do
		if not isPlaceholder(sample) then
			if not predicate(sample) then
				return false
			end
			seen = true
		end
	end
	return seen
end

local function isRatio(v: string): boolean
	return (M.ratio(v)) ~= nil
end

local function isCondition(v: string): boolean
	return CONDITION_VALUES[v] == true
end

local function isEventType(v: string): boolean
	return EVENT_TYPES[v] == true
end

local function isInteger(v: string): boolean
	return string.find(v, "^%-?%d+$") ~= nil
end

local function isPercent(v: string): boolean
	return M.percent(v) ~= nil
end

local function isTimestamp(v: string): boolean
	return M.timestamp(v) ~= nil
end

local function isDuration(v: string): boolean
	return M.duration(v) ~= nil
end

function M.columnType(header: string, samples: { string }): ColumnType
	if all(samples, isCondition) or (header == "TYPE" and all(samples, isEventType)) then
		return "status"
	end
	if (header == "READY" or header == "COMPLETIONS") and all(samples, isRatio) then
		return "ratio"
	end
	local known = HEADER_TYPES[header]
	if known then
		return known :: ColumnType
	end
	if all(samples, isInteger) then
		return "number"
	end
	if all(samples, isPercent) then
		return "percent"
	end
	if all(samples, isRatio) then
		return "ratio"
	end
	if all(samples, isTimestamp) then
		return "timestamp"
	end
	if all(samples, isDuration) then
		return "duration"
	end
	return "text"
end

local TONES: { [string]: Tone } = {
	Running = "success",
	Ready = "success",
	Complete = "success",
	Active = "success",
	Bound = "success",
	Available = "success",
	True = "success",

	Completed = "muted",
	Succeeded = "muted",

	Normal = "neutral",

	Pending = "warning",
	ContainerCreating = "warning",
	PodInitializing = "warning",
	Terminating = "warning",
	Unknown = "warning",
	SchedulingDisabled = "warning",
	Suspended = "warning",
	Warning = "warning",
	Released = "warning",
	NotReady = "error",

	CrashLoopBackOff = "error",
	Error = "error",
	ImagePullBackOff = "error",
	ErrImagePull = "error",
	ErrImageNeverPull = "error",
	InvalidImageName = "error",
	OOMKilled = "error",
	Evicted = "error",
	CreateContainerConfigError = "error",
	CreateContainerError = "error",
	RunContainerError = "error",
	ContainerStatusUnknown = "error",
	DeadlineExceeded = "error",
	BackOff = "error",
	Failed = "error",
	Lost = "error",
	False = "error",
}

local RANK: { [string]: number } = { muted = 1, neutral = 2, success = 3, warning = 4, error = 5 }

local function singleTone(value: string): Tone
	local known = TONES[value]
	if known then
		return known :: Tone
	end
	local initReason = string.match(value, "^Init:(.+)$")
	if initReason then
		if string.find(initReason, "^%d+/%d+$") then
			return "warning"
		end
		return if TONES[initReason] == "error" then "error" else "warning"
	end
	if string.find(value, "^Signal:%d+$") or string.find(value, "^ExitCode:%d+$") then
		return "error"
	end
	return "neutral"
end

function M.statusTone(header: string, value: string): Tone
	if isPlaceholder(value) then
		return "muted"
	end
	if header == "SUSPEND" then
		return if value == "True" then "warning" else "neutral"
	end
	local num, den = M.ratio(value)
	if num and den then
		if den == 0 then
			return "muted"
		end
		return if num < den then "warning" else "success"
	end
	local worst: Tone = "neutral"
	local first = true
	for part in string.gmatch(value, "[^,]+") do
		local tone = singleTone(part)
		if first or RANK[tone] > RANK[worst] then
			worst = tone :: Tone
		end
		first = false
	end
	return worst
end

local function naturalKey(value: string): string
	return (
		string.gsub(string.lower(value), "%d+", function(digits: string): string
			local trimmed = string.gsub(digits, "^0+", "")
			return string.format("%012s", if trimmed == "" then "0" else trimmed)
		end)
	)
end

-- Comparable key for a cell, or nil when the cell holds no value of that type
-- (placeholders, blanks, unparseable text).
function M.sortKey(columnType: ColumnType, value: string): SortKey?
	if isPlaceholder(value) then
		return nil
	end
	if columnType == "duration" then
		return M.duration(value)
	elseif columnType == "count" then
		return M.count(value)
	elseif columnType == "quantity" then
		return M.quantity(value)
	elseif columnType == "percent" then
		return M.percent(value)
	elseif columnType == "number" then
		return tonumber(value)
	elseif columnType == "timestamp" then
		return M.timestamp(value)
	elseif columnType == "ratio" then
		local num, den = M.ratio(value)
		if num == nil or den == nil then
			return nil
		end
		return if den == 0 then 0 else num / den
	end
	return naturalKey(value)
end

-- Strict "a sorts before b". Valueless cells sort last in both directions;
-- equal keys return false so the caller's tie-break decides.
function M.compare(columnType: ColumnType, a: string, b: string, descending: boolean?): boolean
	local ka = M.sortKey(columnType, a)
	local kb = M.sortKey(columnType, b)
	if ka == nil or kb == nil then
		return ka ~= nil and kb == nil
	end
	if descending then
		return (kb :: any) < (ka :: any)
	end
	return (ka :: any) < (kb :: any)
end

return M
