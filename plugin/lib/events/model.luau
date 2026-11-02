--!strict
-- Normalised Kubernetes events from the two shapes kubectl prints: JSON
-- EventLists (core/v1 and events.k8s.io/v1) and table rows (`kubectl events`,
-- `kubectl get events`, `-o wide`, `-A`, `--output-watch-events`).
local Kinds = require("../kubectl/kinds")
local Resource = require("../model/resource")
local ModelTypes = require("../model/types")

type Ref = ModelTypes.ResourceRef
type Invocation = ModelTypes.Invocation

export type Event = {
	key: string,
	type: string,
	reason: string,
	message: string,
	object: Ref?,
	fieldPath: string?,
	related: Ref?,
	count: number,
	first: string?,
	last: string?,
	lastSeen: string?,
	over: string?,
	source: string?,
	namespace: string?,
	series: boolean,
}

export type Tone = "error" | "warning" | "success" | "neutral"
export type LastSeen = { age: string, count: number?, over: string? }

local M = {}

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function tbl(v: any): { [string]: any }?
	if type(v) == "table" then
		return v
	end
	return nil
end

local function positive(v: any): number?
	if type(v) == "number" and v >= 1 then
		return v
	end
	return nil
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

-- involvedObject (core/v1) and regarding/related (both APIs) are ObjectReferences.
local function refOf(v: any): Ref?
	local o = tbl(v)
	if not o then
		return nil
	end
	local kind, name = str(o.kind), str(o.name)
	if not kind or not name then
		return nil
	end
	local group, version = Resource.splitApiVersion(o.apiVersion)
	return {
		clusterContext = nil,
		namespace = str(o.namespace),
		group = group,
		version = version,
		kind = kind,
		name = name,
		uid = str(o.uid),
		source = "live",
	}
end

local function sourceOf(item: { [string]: any }): string?
	local src = tbl(item.source) or tbl(item.deprecatedSource)
	local component = if src then str(src.component) else nil
	if component then
		local host = if src then str(src.host) else nil
		return if host then component .. ", " .. host else component
	end
	return str(item.reportingComponent) or str(item.reportingController)
end

local function fromItem(item: { [string]: any }, index: number): Event
	local metadata: { [string]: any } = tbl(item.metadata) or {}
	local series = tbl(item.series)
	local namespace = str(metadata.namespace)
	local first = str(item.firstTimestamp)
		or str(item.deprecatedFirstTimestamp)
		or str(item.eventTime)
		or str(metadata.creationTimestamp)
	local last = (if series then str(series.lastObservedTime) else nil)
		or str(item.lastTimestamp)
		or str(item.deprecatedLastTimestamp)
		or str(item.eventTime)
		or first
	local involved = tbl(item.involvedObject) or tbl(item.regarding)
	local name = str(metadata.name)
	local key = str(metadata.uid)
		or (if name then (namespace or "") .. "/" .. name else nil)
		or ("#" .. tostring(index))
	return {
		key = key,
		type = str(item.type) or "",
		reason = str(item.reason) or "",
		message = str(item.message) or str(item.note) or "",
		object = refOf(involved),
		fieldPath = if involved then str(involved.fieldPath) else nil,
		related = refOf(item.related),
		count = (if series then positive(series.count) else nil) or positive(item.count) or positive(
			item.deprecatedCount
		) or 1,
		first = first,
		last = last,
		lastSeen = nil,
		over = nil,
		source = sourceOf(item),
		namespace = namespace,
		series = series ~= nil,
	}
end

-- Accepts an EventList (core/v1 `kubectl get events -o json` / `kubectl events
-- -o json`, or events.k8s.io/v1) or a bare `List`; a single Event object
-- yields one event; anything else yields none. Items that are not tables, or
-- are empty (a JSON null sentinel), are skipped; items without metadata get
-- the key `#<item index>`.
function M.fromList(obj: any): { Event }
	local out: { Event } = {}
	local root = tbl(obj)
	if not root then
		return out
	end
	if root.kind == "Event" then
		table.insert(out, fromItem(root, 1))
		return out
	end
	local items = root.items
	if type(items) ~= "table" then
		return out
	end
	for i, item in ipairs(items) do
		local t = tbl(item)
		if t and next(t) ~= nil then
			table.insert(out, fromItem(t, i))
		end
	end
	return out
end

-- `kubectl events` prints `<last> (x<count> over <first>)`, where both ages
-- are relative to now; `over` is therefore the age of the first occurrence.
function M.lastSeenCell(text: string): LastSeen
	local s = trim(text)
	local age, count, over = string.match(s, "^(%S+)%s+%(x(%d+)%s+over%s+([^%)]+)%)$")
	if age and count and over then
		return { age = age, count = tonumber(count), over = trim(over) }
	end
	return { age = s, count = nil, over = nil }
end

-- OBJECT cells: `Pod/x` (kubectl events), `pod/x` (get events),
-- `deployment.apps/x`. Kinds unknown to the kinds table keep their spelling
-- and namespace; known cluster-scoped kinds drop the namespace.
function M.objectRef(text: string, namespace: string?): Ref?
	local resource, name = string.match(trim(text), "^([^/%s]+)/([^/%s]+)$")
	if not resource or not name then
		return nil
	end
	local info = Kinds.normalize(resource)
	return {
		clusterContext = nil,
		namespace = if info.namespaced == false then nil else namespace,
		group = info.group,
		version = nil,
		kind = info.kind,
		name = name,
		uid = nil,
		source = "snapshot",
	}
end

local function columnIndex(headers: { string }): { [string]: number }
	local map: { [string]: number } = {}
	for i, h in headers do
		local name = string.upper(trim(h))
		if map[name] == nil then
			map[name] = i
		end
	end
	return map
end

local KEY_MESSAGE_CHARS = 64

-- Rows carry no uid. `-o wide` prints the Event NAME, which is unique per
-- namespace; otherwise the key joins namespace, OBJECT, TYPE, REASON, the raw
-- LAST SEEN cell and the first 64 message bytes, so the two rows kubectl
-- prints for one object with the same reason at different times stay
-- distinct. Byte-identical rows share a key; callers that need uniqueness
-- per row add the row position.
function M.fromRow(headers: { string }, cells: { string }, inv: Invocation): Event
	local cols = columnIndex(headers)
	local function cell(name: string): string?
		local i = cols[name]
		local v = if i then cells[i] else nil
		return if v then str(trim(v)) else nil
	end
	local namespace = cell("NAMESPACE") or inv.namespace
	local objectText = cell("OBJECT") or ""
	local seenText = cell("LAST SEEN") or ""
	local seen = M.lastSeenCell(seenText)
	local typ = cell("TYPE") or ""
	local reason = cell("REASON") or ""
	local message = cell("MESSAGE") or ""
	local eventName = cell("NAME")
	local key = if eventName
		then (namespace or "") .. "/" .. eventName
		else table.concat({
			namespace or "",
			objectText,
			typ,
			reason,
			seenText,
			string.sub(message, 1, KEY_MESSAGE_CHARS),
		}, "|")
	local countText = cell("COUNT")
	return {
		key = key,
		type = typ,
		reason = reason,
		message = message,
		object = M.objectRef(objectText, namespace),
		fieldPath = cell("SUBOBJECT"),
		related = nil,
		count = (countText and positive(tonumber(countText))) or seen.count or 1,
		first = nil,
		last = nil,
		lastSeen = if seen.age ~= "" and seen.age ~= "<unknown>" then seen.age else nil,
		over = seen.over or cell("FIRST SEEN"),
		source = cell("SOURCE"),
		namespace = namespace,
		series = false,
	}
end

local ERROR_REASONS: { [string]: boolean } = {
	BackOff = true,
	Unhealthy = true,
	FailedScheduling = true,
	Evicted = true,
	OOMKilling = true,
	FailedMount = true,
	NodeNotReady = true,
}

local WARNING_REASONS: { [string]: boolean } = {
	Killing = true,
	Preempting = true,
	Rebooted = true,
	ProbeWarning = true,
}

local SUCCESS_REASONS: { [string]: boolean } = {
	Scheduled = true,
	Pulled = true,
	Created = true,
	Started = true,
	SuccessfulCreate = true,
	ScalingReplicaSet = true,
	Completed = true,
}

-- Known reasons win over TYPE (kubelet reports image `BackOff` as Normal);
-- an unknown reason on a Warning event is still a warning.
function M.reasonTone(reason: string, typ: string): Tone
	if ERROR_REASONS[reason] or string.sub(reason, 1, 6) == "Failed" then
		return "error"
	end
	if WARNING_REASONS[reason] then
		return "warning"
	end
	if SUCCESS_REASONS[reason] then
		return "success"
	end
	if typ == "Warning" then
		return "warning"
	end
	return "neutral"
end

return M
