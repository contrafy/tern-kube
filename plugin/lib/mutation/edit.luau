--!strict
-- Plans the server dry run of a `kubectl edit` from kubectl's own JSON
-- conversion of the file before and after the editor ran (`patch --local
-- -f FILE -o json`, so YAML quirks resolve exactly as `kubectl edit` does).
-- kubectl sends a patch computed original -> edited; the preview sends the
-- RFC 7386 merge patch of the same pair to `patch --dry-run=server`. Values
-- stay lossless (parse/jsonv) so `[]`, `{}`, nulls and number text in the
-- patch are what the user saved. kubectl refuses any change of apiVersion,
-- kind or name, so identities only on one side are reported, not patched.

local Jsonstream = require("../parse/jsonstream")
local Jsonv = require("../parse/jsonv")

type Value = Jsonv.Value

export type Change = {
	key: string,
	-- `Kind.version.group` as `kubectl get` resolves it (core: `ConfigMap.v1.`).
	typeRef: string,
	name: string,
	namespace: string?,
	patch: string,
	liveVersion: string?,
}
export type EditSet = { changes: { Change }, unchanged: { string }, renamed: { string } }

local M = {}

type Doc = { key: string, typeRef: string, name: string, namespace: string?, version: string?, value: Value }

local function str(v: Value?): string?
	if v ~= nil and v.t == "str" and v.v ~= "" then
		return v.v
	end
	return nil
end

local function isList(v: Value): boolean
	local kind = str(Jsonv.get(v, { "kind" }))
	local items = Jsonv.get(v, { "items" })
	return kind ~= nil and string.sub(kind, -4) == "List" and items ~= nil and items.t == "arr"
end

local function docOf(v: Value, label: string, index: number): (Doc?, string?)
	local apiVersion = str(Jsonv.get(v, { "apiVersion" }))
	local kind = str(Jsonv.get(v, { "kind" }))
	local name = str(Jsonv.get(v, { "metadata", "name" }))
	if apiVersion == nil or kind == nil or name == nil then
		return nil, string.format("%s object %d has no apiVersion, kind or metadata.name", label, index)
	end
	local namespace = str(Jsonv.get(v, { "metadata", "namespace" }))
	local group, version = string.match(apiVersion, "^(.+)/([^/]+)$")
	return {
		key = table.concat({ (string.gsub(apiVersion, "/", ".")), kind, namespace or "", name }, "."),
		typeRef = string.format("%s.%s.%s", kind, version or apiVersion, group or ""),
		name = name,
		namespace = namespace,
		version = str(Jsonv.get(v, { "metadata", "resourceVersion" })),
		value = v,
	},
		nil
end

local function decodeAll(text: string, label: string): ({ Doc }?, string?)
	local texts, splitErr = Jsonstream.split(text)
	if texts == nil then
		return nil, string.format("%s: %s", label, splitErr or "invalid JSON")
	end
	local values: { Value } = {}
	for i, piece in texts do
		local v, err = Jsonv.decode(piece)
		if v == nil then
			return nil, string.format("%s object %d: %s", label, i, err or "invalid JSON")
		end
		local value = v :: Value
		if isList(value) then
			local items = Jsonv.get(value, { "items" })
			if items and items.t == "arr" then
				table.move(items.items, 1, #items.items, #values + 1, values)
			end
		else
			table.insert(values, value)
		end
	end
	local docs: { Doc } = {}
	local seen: { [string]: boolean } = {}
	for i, v in values do
		local doc, err = docOf(v, label, i)
		if doc == nil then
			return nil, err
		end
		local d = doc :: Doc
		if seen[d.key] then
			return nil, string.format("%s lists %s twice", label, d.key)
		end
		seen[d.key] = true
		table.insert(docs, d)
	end
	return docs, nil
end

function M.plan(originalJson: string, editedJson: string): (EditSet?, string?)
	local original, oerr = decodeAll(originalJson, "original")
	if original == nil then
		return nil, oerr
	end
	local edited, eerr = decodeAll(editedJson, "edited")
	if edited == nil then
		return nil, eerr
	end
	local editedByKey: { [string]: Doc } = {}
	for _, d in edited do
		editedByKey[d.key] = d
	end
	local set: EditSet = { changes = {}, unchanged = {}, renamed = {} }
	local originalKeys: { [string]: boolean } = {}
	for _, o in original do
		originalKeys[o.key] = true
		local e = editedByKey[o.key]
		if e == nil then
			table.insert(set.renamed, o.key)
			continue
		end
		local patch = Jsonv.mergePatch(o.value, e.value)
		if patch == nil then
			table.insert(set.unchanged, o.key)
		else
			table.insert(set.changes, {
				key = o.key,
				typeRef = o.typeRef,
				name = o.name,
				namespace = o.namespace,
				patch = Jsonv.encode(patch),
				liveVersion = o.version,
			})
		end
	end
	for _, e in edited do
		if not originalKeys[e.key] then
			table.insert(set.renamed, e.key)
		end
	end
	return set, nil
end

return M
