--!strict
-- Before/after object diffs for the verbs `kubectl diff` cannot preview
-- (patch, label, annotate, rollout undo/pause/resume, cordon, drain, edit).
-- Both sides are rendered as YAML and diffed per object into the same
-- unified text kubectl diff prints, so the apply path's diff cards, counts
-- and Secret handling apply unchanged. Keys follow kubectl diff's file names
-- (`[group.]version.Kind.namespace.name`), which Diffseg.identity reads back.

local Diffseg = require("./diffseg")
local Emit = require("../gitops/emit")
local Jsonstream = require("../parse/jsonstream")
local Linediff = require("../model/linediff")

export type Pair = { key: string, before: any?, after: any? }
export type Result = { summary: Diffseg.Summary, unchanged: { string }, pairs: { Pair } }
export type Options = {
	showSecretValues: boolean,
	-- Passed to the YAML emitter: JSON null sentinel and `[]` detection.
	null: any?,
	isList: ((t: { [any]: any }) -> boolean)?,
	-- Header prefixes {before, after}: `--- <before>/<key>`, `+++ <after>/<key>`.
	paths: { string }?,
}

local M = {}

M.REDACTED = "<redacted>"
M.REDACTED_CHANGED = "<redacted, changed>"

local LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration"

local function map(v: any): { [string]: any }?
	return if type(v) == "table" then v else nil
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Empty tables are shared, not copied: `tern.json` keeps the `[]` vs `{}`
-- tag on the table identity.
local function deepCopy(v: any): any
	if type(v) ~= "table" or next(v) == nil then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

function M.identity(obj: any): string?
	local o = map(obj)
	local metadata = o and map(o.metadata)
	if o == nil or metadata == nil then
		return nil
	end
	local apiVersion, kind, name = str(o.apiVersion), str(o.kind), str(metadata.name)
	if apiVersion == nil or kind == nil or name == nil then
		return nil
	end
	local namespace = str(metadata.namespace) or ""
	return table.concat({ (string.gsub(apiVersion, "/", ".")), kind, namespace, name }, ".")
end

-- Fields that change on every write without being part of the change.
function M.clean(obj: any): any
	local copy = deepCopy(obj)
	local metadata = map(map(copy) and copy.metadata)
	if metadata and next(metadata) ~= nil then
		metadata.generation = nil
		metadata.resourceVersion = nil
		metadata.managedFields = nil
	end
	return copy
end

-- replace --force deletes and re-creates: identity, age and status of the
-- live object do not carry over, so neither side shows them.
function M.recreated(objects: { any }): { any }
	local out: { any } = {}
	for _, obj in objects do
		local copy = M.clean(obj)
		local o = map(copy)
		local metadata = if o then map(o.metadata) else nil
		if metadata and next(metadata) ~= nil then
			metadata.uid = nil
			metadata.creationTimestamp = nil
			metadata.selfLink = nil
		end
		if o then
			o.status = nil
		end
		table.insert(out, copy)
	end
	return out
end

-- Objects as YAML documents for the text heuristics (risk manifestReasons).
function M.manifests(
	objects: { any },
	opts: { null: any?, isList: ((t: { [any]: any }) -> boolean)? }
): { { path: string, text: string } }
	local out: { { path: string, text: string } } = {}
	for i, obj in objects do
		table.insert(out, {
			path = M.identity(obj) or ("object " .. i),
			text = Emit.yaml(obj, { null = opts.null, isList = opts.isList }),
		})
	end
	return out
end

local function isList(obj: any): boolean
	local o = map(obj)
	return o ~= nil and type(o.kind) == "string" and string.sub(o.kind, -4) == "List" and type(o.items) == "table"
end

-- kubectl prints several objects back to back (not as a List) and `get`
-- of several names prints a List: both become one flat object list.
function M.decodeStream(text: string, decode: (string) -> any): ({ any }?, string?)
	local texts, err = Jsonstream.split(text)
	if texts == nil then
		return nil, err
	end
	local out: { any } = {}
	for i, piece in texts do
		local ok, value = pcall(decode, piece)
		if not ok then
			return nil, string.format("object %d: %s", i, tostring(value))
		end
		if isList(value) then
			for _, item in value.items do
				table.insert(out, item)
			end
		else
			table.insert(out, value)
		end
	end
	return out, nil
end

-- Pairs in `before` order, then objects only `after` has. Objects without
-- an identity are kept under a positional key so nothing is dropped silently.
function M.pair(before: { any }, after: { any }): { Pair }
	local pairs: { Pair } = {}
	local byKey: { [string]: Pair } = {}
	local function add(obj: any, side: "before" | "after", index: number)
		local key = M.identity(obj) or string.format("unidentified.%s.%d", side, index)
		local p = byKey[key]
		if p == nil then
			p = { key = key }
			byKey[key] = p
			table.insert(pairs, p)
		end
		local entry = p :: Pair
		if side == "before" then
			entry.before = obj
		else
			entry.after = obj
		end
	end
	for i, obj in before do
		add(obj, "before", i)
	end
	for i, obj in after do
		add(obj, "after", i)
	end
	return pairs
end

local function isSecret(obj: any): boolean
	local o = map(obj)
	return o ~= nil and o.kind == "Secret" and o.apiVersion == "v1"
end

-- After-side values are classified against the unmasked before side, then
-- the before side is masked.
local function redactMap(before: { [string]: any }?, after: { [string]: any }?)
	if after then
		for k, v in after do
			local old = if before then before[k] else nil
			after[k] = if old ~= nil and old == v then M.REDACTED else M.REDACTED_CHANGED
		end
	end
	if before then
		for k in before do
			before[k] = M.REDACTED
		end
	end
end

local function annotations(obj: any): { [string]: any }?
	local o = map(obj)
	local metadata = if o then map(o.metadata) else nil
	return if metadata then map(metadata.annotations) else nil
end

-- The last-applied annotation of a Secret holds its applied data in clear
-- text, so it is masked like the values.
local function redactSecretPair(before: any?, after: any?)
	local b, a = map(before), map(after)
	for _, field in { "data", "stringData" } do
		redactMap(if b then map(b[field]) else nil, if a then map(a[field]) else nil)
	end
	local ba, aa = annotations(b), annotations(a)
	local bl = if ba then ba[LAST_APPLIED] else nil
	local al = if aa then aa[LAST_APPLIED] else nil
	if aa and al ~= nil then
		aa[LAST_APPLIED] = if bl ~= nil and bl == al then M.REDACTED else M.REDACTED_CHANGED
	end
	if ba and bl ~= nil then
		ba[LAST_APPLIED] = M.REDACTED
	end
end

local function render(obj: any, opts: Options): string
	return Emit.yaml(obj, { null = opts.null, isList = opts.isList })
end

function M.compute(pairs: { Pair }, opts: Options): Result
	local texts: { string } = {}
	local unchanged: { string } = {}
	local beforePath = if opts.paths then opts.paths[1] else "/live"
	local afterPath = if opts.paths then opts.paths[2] else "/merged"
	for _, p in pairs do
		local before = if p.before ~= nil then M.clean(p.before) else nil
		local after = if p.after ~= nil then M.clean(p.after) else nil
		if not opts.showSecretValues and (isSecret(before) or isSecret(after)) then
			redactSecretPair(before, after)
		end
		local old = if before ~= nil then render(before, opts) else nil
		local new = if after ~= nil then render(after, opts) else ""
		local diff = Linediff.unified(old, new, afterPath .. "/" .. p.key, beforePath .. "/" .. p.key)
		if diff == nil then
			table.insert(unchanged, p.key)
		else
			table.insert(texts, diff)
		end
	end
	return { summary = Diffseg.parse(table.concat(texts)), unchanged = unchanged, pairs = pairs }
end

return M
