--!strict
-- Parsers for helm's JSON output (list, history, status, get values) and for
-- the Query.EXTRAS_TEMPLATE output, plus the small readings the views share:
-- chart name/version split, times, status tones, stuck releases, error kinds.
-- `decode` is the host's JSON decoder and may raise; every parser returns
-- (value, nil) or (nil, message) and never raises.
local HelmTypes = require("./types")
local Query = require("./query")
local Values = require("../model/values")

type Status = HelmTypes.Status
type Decode = (string) -> any

local M = {}

M.STUCK_AFTER_S = 900

local STATUSES: { [string]: Status } = {
	deployed = "deployed",
	failed = "failed",
	["pending-install"] = "pending-install",
	["pending-upgrade"] = "pending-upgrade",
	["pending-rollback"] = "pending-rollback",
	superseded = "superseded",
	uninstalling = "uninstalling",
	uninstalled = "uninstalled",
	unknown = "unknown",
}

function M.statusOf(s: string?): Status
	return if s then STATUSES[s] or "unknown" else "unknown"
end

export type Tone = "ok" | "warn" | "error" | "muted"

local TONES: { [Status]: Tone } = {
	deployed = "ok",
	failed = "error",
	["pending-install"] = "warn",
	["pending-upgrade"] = "warn",
	["pending-rollback"] = "warn",
	uninstalling = "warn",
	superseded = "muted",
	uninstalled = "muted",
	unknown = "muted",
}

function M.tone(status: Status): Tone
	return TONES[status] or "muted"
end

function M.stuck(row: { status: Status, updatedAt: number? }, now: number?): boolean
	if now == nil or row.updatedAt == nil or string.sub(row.status, 1, 8) ~= "pending-" then
		return false
	end
	return now - row.updatedAt > M.STUCK_AFTER_S
end

-- RFC 3339 (helm history/status, list with --time-format); Go's
-- time.String() form is not parsed: callers show the raw text.
function M.time(text: string): number?
	return Values.timestamp(text)
end

local function isSemver(s: string): boolean
	local rest = string.match(s, "^v?%d+%.%d+%.%d+(.*)$")
	if rest == nil then
		return false
	end
	local lead = string.sub(rest, 1, 1)
	return rest == "" or ((lead == "-" or lead == "+") and #rest > 1)
end

-- helm joins chart name and version with "-"; names may contain hyphens
-- and digits, so the version starts at the first hyphen followed by semver.
function M.splitChart(chart: string): (string, string?)
	local from = 1
	while true do
		local dash = string.find(chart, "-", from, true)
		if dash == nil then
			return chart, nil
		end
		if dash > 1 and isSemver(string.sub(chart, dash + 1)) then
			return string.sub(chart, 1, dash - 1), string.sub(chart, dash + 1)
		end
		from = dash + 1
	end
end

local function hex4(code: number): string
	return string.format("\\u%04x", code)
end

-- Go's %+q quoting -> JSON. Inside strings: \a, \v, \xHH, \UHHHHHHHH have no
-- JSON form; every other escape is shared. A backslash always consumes the
-- next character, which keeps "\\a" (escaped backslash, then `a`) intact.
function M.goJson(text: string): string
	local out: { string } = {}
	local copied = 1
	local i = 1
	local inString = false
	while true do
		local pos = string.find(text, if inString then '["\\]' else '"', i)
		if pos == nil then
			break
		end
		if string.byte(text, pos) == 34 then
			inString = not inString
			i = pos + 1
		else
			local e = string.sub(text, pos + 1, pos + 1)
			local len = 2
			local rep: string? = nil
			if e == "a" then
				rep = "\\u0007"
			elseif e == "v" then
				rep = "\\u000b"
			elseif e == "x" then
				local hex = string.match(text, "^%x%x", pos + 2)
				if hex then
					len = 4
					local byte = tonumber(hex, 16) :: number
					-- %+q writes \xHH only for bytes that are not valid UTF-8.
					rep = if byte < 0x80 then hex4(byte) else "\\ufffd"
				end
			elseif e == "U" then
				local hex = string.match(text, "^%x%x%x%x%x%x%x%x", pos + 2)
				if hex then
					len = 10
					local code = tonumber(hex, 16) :: number
					if code > 0x10FFFF then
						rep = "\\ufffd"
					elseif code >= 0x10000 then
						local v = code - 0x10000
						rep = hex4(0xD800 + v // 0x400) .. hex4(0xDC00 + v % 0x400)
					else
						rep = hex4(code)
					end
				end
			end
			if rep then
				table.insert(out, string.sub(text, copied, pos - 1))
				table.insert(out, rep)
				copied = pos + len
			end
			i = pos + len
		end
	end
	table.insert(out, string.sub(text, copied))
	return table.concat(out)
end

local function decodeWith(decode: Decode, text: string): (boolean, any)
	local ok, value = pcall(decode, text)
	if not ok then
		return false, (string.gsub(tostring(value), "^.-tern%.json%.decode: ", ""))
	end
	return true, value
end

local function isArray(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local n = 0
	for _ in t do
		n += 1
	end
	return n == #t
end

local function isObject(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	for k in t do
		if type(k) ~= "string" then
			return false
		end
	end
	return true
end

local function str(v: any): string
	return if type(v) == "string" then v else ""
end

local function optStr(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function revisionOf(v: any): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	if n == nil or n < 1 or n % 1 ~= 0 then
		return nil
	end
	return n
end

local function strings(v: any): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, s in v do
			if type(s) == "string" then
				table.insert(out, s)
			end
		end
	end
	return out
end

type Common = {
	revision: number,
	updated: string,
	updatedAt: number?,
	status: Status,
	chart: string,
	chartName: string,
	chartVersion: string?,
	appVersion: string,
}

local function common(row: any): (Common?, string?)
	if type(row) ~= "table" then
		return nil, "not an object"
	end
	local revision = revisionOf(row.revision)
	if revision == nil then
		return nil, "missing or invalid revision"
	end
	if type(row.chart) ~= "string" then
		return nil, "missing chart"
	end
	local name, version = M.splitChart(row.chart)
	local updated = str(row.updated)
	return {
		revision = revision,
		updated = updated,
		updatedAt = M.time(updated),
		status = M.statusOf(row.status),
		chart = row.chart,
		chartName = name,
		chartVersion = version,
		appVersion = str(row.app_version),
	},
		nil
end

local function rows(what: string, text: string, decode: Decode): ({ any }?, string?)
	local ok, value = decodeWith(decode, text)
	if not ok then
		return nil, string.format("%s: not JSON: %s", what, tostring(value))
	end
	if not isArray(value) then
		return nil, what .. ": expected a JSON list"
	end
	return value, nil
end

function M.list(text: string, decode: Decode): ({ HelmTypes.ReleaseRow }?, string?)
	local list, err = rows("helm list", text, decode)
	if list == nil then
		return nil, err
	end
	local out: { HelmTypes.ReleaseRow } = {}
	for i, row in list do
		local c, cerr = common(row)
		if c == nil then
			return nil, string.format("helm list: row %d: %s", i, tostring(cerr))
		end
		if type(row.name) ~= "string" or row.name == "" or type(row.namespace) ~= "string" then
			return nil, string.format("helm list: row %d: missing name or namespace", i)
		end
		table.insert(out, {
			name = row.name,
			namespace = row.namespace,
			revision = c.revision,
			updated = c.updated,
			updatedAt = c.updatedAt,
			status = c.status,
			chart = c.chart,
			chartName = c.chartName,
			chartVersion = c.chartVersion,
			appVersion = c.appVersion,
		})
	end
	return out, nil
end

function M.history(text: string, decode: Decode): ({ HelmTypes.Revision }?, string?)
	local list, err = rows("helm history", text, decode)
	if list == nil then
		return nil, err
	end
	local out: { HelmTypes.Revision } = {}
	for i, row in list do
		local c, cerr = common(row)
		if c == nil then
			return nil, string.format("helm history: row %d: %s", i, tostring(cerr))
		end
		table.insert(out, {
			revision = c.revision,
			updated = c.updated,
			updatedAt = c.updatedAt,
			status = c.status,
			chart = c.chart,
			chartName = c.chartName,
			chartVersion = c.chartVersion,
			appVersion = c.appVersion,
			description = str(row.description),
		})
	end
	return out, nil
end

function M.status(text: string, decode: Decode): (HelmTypes.ReleaseStatus?, string?)
	local ok, v = decodeWith(decode, text)
	if not ok then
		return nil, "helm status: not JSON: " .. tostring(v)
	end
	if not isObject(v) or type(v.name) ~= "string" or type(v.info) ~= "table" then
		return nil, "helm status: not a release"
	end
	local revision = revisionOf(v.version)
	if revision == nil then
		return nil, "helm status: missing or invalid version"
	end
	local info = v.info
	return {
		name = v.name,
		namespace = str(v.namespace),
		revision = revision,
		info = {
			status = M.statusOf(info.status),
			description = str(info.description),
			firstDeployed = optStr(info.first_deployed),
			lastDeployed = optStr(info.last_deployed),
			notes = str(info.notes),
		},
		user = if isObject(v.config) then v.config else {},
		manifest = str(v.manifest),
	},
		nil
end

-- `get values -o json` prints `null` when the release has no user values.
function M.values(text: string, decode: Decode): ({ [string]: any }?, string?)
	if string.match(text, "^%s*null%s*$") then
		return {}, nil
	end
	local ok, v = decodeWith(decode, text)
	if not ok then
		return nil, "helm values: not JSON: " .. tostring(v)
	end
	if not isObject(v) then
		return nil, "helm values: expected a JSON object"
	end
	return v, nil
end

local function chartOf(c: any): HelmTypes.Chart
	local deps: { HelmTypes.Dependency } = {}
	if type(c.dependencies) == "table" then
		for _, d in c.dependencies do
			if type(d) == "table" then
				table.insert(deps, {
					name = str(d.name),
					version = str(d.version),
					repository = str(d.repository),
					alias = str(d.alias),
				})
			end
		end
	end
	return {
		name = str(c.name),
		version = str(c.version),
		appVersion = str(c.app_version),
		type = str(c.type),
		description = str(c.description),
		home = str(c.home),
		sources = strings(c.sources),
		dependencies = deps,
	}
end

local function hookOf(h: any): HelmTypes.Hook
	local run = if type(h.last_run) == "table" then h.last_run else {}
	return {
		name = str(h.name),
		kind = str(h.kind),
		path = str(h.path),
		weight = if type(h.weight) == "number" then h.weight else 0,
		events = strings(h.events),
		deletePolicies = strings(h.delete_policies),
		phase = str(run.phase),
		startedAt = optStr(run.started_at),
		completedAt = optStr(run.completed_at),
		manifest = str(h.manifest),
	}
end

function M.extras(text: string, decode: Decode): (HelmTypes.Extras?, string?)
	local ok, v = decodeWith(decode, M.goJson(text))
	if not ok then
		return nil, "helm extras: not JSON: " .. tostring(v)
	end
	if not isObject(v) then
		return nil, "helm extras: expected a JSON object"
	end
	if v.format ~= Query.EXTRAS_FORMAT then
		return nil, string.format("helm extras: format %q, expected %q", tostring(v.format), Query.EXTRAS_FORMAT)
	end
	local revision = revisionOf(v.revision)
	if revision == nil or type(v.name) ~= "string" or type(v.chart) ~= "table" then
		return nil, "helm extras: missing name, revision or chart"
	end
	local hooks: { HelmTypes.Hook } = {}
	if type(v.hooks) == "table" then
		for _, h in v.hooks do
			if type(h) == "table" then
				table.insert(hooks, hookOf(h))
			end
		end
	end
	return {
		name = v.name,
		namespace = str(v.namespace),
		revision = revision,
		chart = chartOf(v.chart),
		defaults = if isObject(v.defaults) then v.defaults else {},
		hooks = hooks,
	},
		nil
end

export type ErrorKind = "unreachable" | "forbidden" | "not-found" | "other"

local UNREACHABLE = {
	"cluster unreachable",
	"does not exist",
	"connection refused",
	"no such host",
	"i/o timeout",
	"tls handshake timeout",
	"no route to host",
}

function M.errorKind(stderr: string): ErrorKind
	local s = string.lower(stderr)
	for _, needle in UNREACHABLE do
		if string.find(s, needle, 1, true) then
			return "unreachable"
		end
	end
	if string.find(s, "forbidden", 1, true) or string.find(s, "unauthorized", 1, true) then
		return "forbidden"
	end
	if string.find(s, "not found", 1, true) or string.find(s, "release has no %d+ version") then
		return "not-found"
	end
	return "other"
end

return M
