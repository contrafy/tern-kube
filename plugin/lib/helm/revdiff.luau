--!strict
-- Per-object diff of two recorded release manifests (`helm status -o json`
-- `.manifest`, hooks excluded). Each object is diffed as text under kubectl
-- diff's file name (`[group.]version.Kind.namespace.name`) and read back
-- through Diffseg, so the approve block and the Helm views render revision
-- diffs exactly like `kubectl diff` output. Texts are masked before diffing;
-- raw texts decide whether anything changed, so a change that masking hides
-- is still reported (`masked`) instead of vanishing.

local Diffseg = require("../mutation/diffseg")
local HelmTypes = require("./types")
local Kinds = require("../kubectl/kinds")
local LineDiff = require("../model/linediff")
local Redact = require("../model/redact")
local Types = require("../model/types")
local Yaml = require("../parse/yaml")

export type Doc = { key: string, ref: Types.ResourceRef?, text: string }
export type Options = { namespace: string, policy: Redact.Policy, secrets: { string } }
export type Hooks = { added: { string }, removed: { string }, changed: { string } }
export type Result = {
	summary: Diffseg.Summary,
	-- Segment keys whose change is wholly or partly hidden by masking.
	masked: { [string]: boolean },
	maskedChanges: number,
	hooks: Hooks,
}
export type Sets = { create: { Doc }, delete: { Doc }, modify: { Doc } }

local M = {}

M.MASKED_NOTE = "values changed (masked)"

type Entry = { key: string, ref: Types.ResourceRef?, text: string, masked: string }
type Parsed = { order: { Entry }, byKey: { [string]: Entry } }

local function clusterScoped(ref: Types.ResourceRef): boolean
	local info = Kinds.normalize(if ref.group then ref.kind .. "." .. ref.group else ref.kind)
	return info.known and info.namespaced == false
end

-- helm applies namespace-less namespaced objects to the release namespace.
local function placed(ref: Types.ResourceRef?, namespace: string): Types.ResourceRef?
	if ref == nil or ref.namespace ~= nil or clusterScoped(ref) then
		return ref
	end
	local copy = table.clone(ref)
	copy.namespace = namespace
	return copy
end

local function keyOf(ref: Types.ResourceRef): string
	return table.concat({
		(if ref.group then ref.group .. "." else "") .. (ref.version or ""),
		ref.kind,
		ref.namespace or "",
		ref.name,
	}, ".")
end

local function slice(lines: { string }, first: number, last: number): string
	return table.concat(lines, "\n", first, last) .. "\n"
end

-- `opts == nil` skips masking (`masked` is the raw text).
local function parse(text: string, namespace: string, opts: Options?): Parsed
	local source = Yaml.lines(text)
	local docs = Yaml.splitLines(source).docs
	local shown = if opts then Yaml.redact(source, docs, opts.policy) else source
	local echoes = opts ~= nil and not opts.policy.showSecrets and #opts.secrets > 0
	local parsed: Parsed = { order = {}, byKey = {} }
	for i, doc in docs do
		local ref = placed(doc.ref, namespace)
		local key = if ref then keyOf(ref) else string.format("unidentified.%d", i)
		local raw = slice(source, doc.startLine, doc.endLine)
		local masked = if opts then slice(shown, doc.startLine, doc.endLine) else raw
		if echoes then
			masked = Redact.maskEchoes(masked, (opts :: Options).secrets)
		end
		local seen = parsed.byKey[key]
		if seen then
			-- helm refuses duplicate objects; never drop a document silently.
			seen.text ..= "---\n" .. raw
			seen.masked ..= "---\n" .. masked
		else
			local entry: Entry = { key = key, ref = ref, text = raw, masked = masked }
			parsed.byKey[key] = entry
			table.insert(parsed.order, entry)
		end
	end
	return parsed
end

function M.docs(manifest: string, namespace: string): { [string]: Doc }
	local out: { [string]: Doc } = {}
	for key, entry in parse(manifest, namespace, nil).byKey do
		out[key] = { key = key, ref = entry.ref, text = entry.text }
	end
	return out
end

-- Raw lines that masking replaced, in order. Masking keeps the line count
-- unless an echoed secret spans lines; then the whole raw text stands in.
local function hidden(entry: Entry?): string
	if entry == nil or entry.text == entry.masked then
		return ""
	end
	local raw, masked = LineDiff.lines(entry.text), LineDiff.lines(entry.masked)
	if #raw ~= #masked then
		return entry.text
	end
	local out: { string } = {}
	for i, line in raw do
		if line ~= masked[i] then
			table.insert(out, line)
		end
	end
	return table.concat(out, "\n")
end

local function maskedOnly(key: string): Diffseg.Segment
	local id = Diffseg.identity(key)
	return {
		key = key,
		group = if id then id.group else nil,
		version = if id then id.version else nil,
		kind = if id then id.kind else nil,
		namespace = if id then id.namespace else nil,
		name = if id then id.name else nil,
		action = "modify",
		added = 0,
		removed = 0,
		binary = false,
		lines = { "--- " .. key, "+++ " .. key },
	}
end

-- Keys in the new revision's order, then those only the old one has.
local function union(old: Parsed, new: Parsed): { string }
	local keys: { string } = {}
	for _, entry in new.order do
		table.insert(keys, entry.key)
	end
	for _, entry in old.order do
		if new.byKey[entry.key] == nil then
			table.insert(keys, entry.key)
		end
	end
	return keys
end

local function hookKey(h: HelmTypes.Hook): string
	return h.kind .. "/" .. h.name
end

local function hookDiff(old: { HelmTypes.Hook }, new: { HelmTypes.Hook }): Hooks
	local before: { [string]: HelmTypes.Hook } = {}
	for _, h in old do
		before[hookKey(h)] = h
	end
	local after: { [string]: boolean } = {}
	local out: Hooks = { added = {}, removed = {}, changed = {} }
	for _, h in new do
		local key = hookKey(h)
		after[key] = true
		local prior = before[key]
		if prior == nil then
			table.insert(out.added, key)
		elseif prior.manifest ~= h.manifest then
			table.insert(out.changed, key)
		end
	end
	for _, h in old do
		if not after[hookKey(h)] then
			table.insert(out.removed, hookKey(h))
		end
	end
	return out
end

function M.diff(
	old: string,
	new: string,
	opts: Options,
	oldHooks: { HelmTypes.Hook }?,
	newHooks: { HelmTypes.Hook }?
): Result
	local a, b = parse(old, opts.namespace, opts), parse(new, opts.namespace, opts)
	local summary: Diffseg.Summary = {
		segments = {},
		create = 0,
		modify = 0,
		delete = 0,
		unknown = 0,
		added = 0,
		removed = 0,
		notes = {},
	}
	local masked: { [string]: boolean } = {}
	local maskedChanges = 0
	for _, key in union(a, b) do
		local before, after = a.byKey[key], b.byKey[key]
		local rawOld, rawNew = before and before.text, after and after.text
		if rawOld == rawNew then
			continue
		end
		local text = LineDiff.unified(before and before.masked, after and after.masked, key)
		local seg: Diffseg.Segment
		if text then
			local parsed = Diffseg.parse(text)
			seg = parsed.segments[1]
			table.move(parsed.notes, 1, #parsed.notes, #summary.notes + 1, summary.notes)
		else
			seg = maskedOnly(key)
		end
		if text == nil or hidden(before) ~= hidden(after) then
			masked[key] = true
			maskedChanges += 1
		end
		if seg.action == "create" then
			summary.create += 1
		elseif seg.action == "modify" then
			summary.modify += 1
		elseif seg.action == "delete" then
			summary.delete += 1
		else
			summary.unknown += 1
		end
		summary.added += seg.added
		summary.removed += seg.removed
		table.insert(summary.segments, seg)
	end
	return {
		summary = summary,
		masked = masked,
		maskedChanges = maskedChanges,
		hooks = hookDiff(oldHooks or {}, newHooks or {}),
	}
end

-- Raw (unmasked) documents: modify carries the new revision's text.
function M.changedSets(old: string, new: string, namespace: string): Sets
	local a, b = parse(old, namespace, nil), parse(new, namespace, nil)
	local sets: Sets = { create = {}, delete = {}, modify = {} }
	local function doc(entry: Entry): Doc
		return { key = entry.key, ref = entry.ref, text = entry.text }
	end
	for _, key in union(a, b) do
		local before, after = a.byKey[key], b.byKey[key]
		if before == nil then
			table.insert(sets.create, doc(after))
		elseif after == nil then
			table.insert(sets.delete, doc(before))
		elseif before.text ~= after.text then
			table.insert(sets.modify, doc(after))
		end
	end
	return sets
end

return M
