--!strict
-- Which Helm release an object belongs to, from what the object itself says
-- (no queries, so lens views can use it on rehydrated output). Helm 3.2+
-- annotates every object it creates; the managed-by/instance labels are a
-- convention most charts follow and only a guess. Hooks and release
-- records carry neither annotation and have their own readers.
local HelmTypes = require("./types")

export type Owner = HelmTypes.Owner

local M = {}

local RELEASE_NAME = "meta.helm.sh/release-name"
local RELEASE_NAMESPACE = "meta.helm.sh/release-namespace"
local HOOK = "helm.sh/hook"
local MANAGED_BY = "app.kubernetes.io/managed-by"
local INSTANCE = "app.kubernetes.io/instance"
local RECORD_TYPE = "helm.sh/release.v1"

local function nonEmpty(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function mapOf(v: any): { [string]: any }
	return if type(v) == "table" then v else {}
end

local function ownerOf(namespace: string?, annotations: { [string]: any }, labels: { [string]: any }): Owner?
	local release = nonEmpty(annotations[RELEASE_NAME])
	if release then
		local ns = nonEmpty(annotations[RELEASE_NAMESPACE]) or namespace
		return if ns then { release = release, namespace = ns, via = "annotation" } else nil
	end
	if annotations[HOOK] ~= nil or labels[MANAGED_BY] ~= "Helm" then
		return nil
	end
	local instance = nonEmpty(labels[INSTANCE])
	if instance and namespace then
		return { release = instance, namespace = namespace, via = "instance-label" }
	end
	return nil
end

function M.fromObject(obj: any): Owner?
	if type(obj) ~= "table" or type(obj.metadata) ~= "table" then
		return nil
	end
	local m = obj.metadata
	return ownerOf(nonEmpty(m.namespace), mapOf(m.annotations), mapOf(m.labels))
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- `annotations` is the describe Annotations field value (lines joined by
-- "\n"); `namespace` the describe Namespace field.
function M.fromDescribe(annotations: string, namespace: string?): Owner?
	local ann: { [string]: string } = {}
	for _, line in string.split(annotations, "\n") do
		local k, v = string.match(trim(line), "^([^%s:]+):%s*(.*)$")
		if k and v then
			ann[k] = v
		end
	end
	return ownerOf(nonEmpty(namespace), ann, {})
end

type YamlLine = { col: number, key: string, value: string }

local function unquote(s: string): string
	local q = string.sub(s, 1, 1)
	if #s >= 2 and (q == '"' or q == "'") and string.sub(s, -1) == q then
		local inner = string.sub(s, 2, -2)
		if q == "'" then
			return (string.gsub(inner, "''", "'"))
		end
		return (string.gsub(inner, '\\(["\\])', "%1"))
	end
	return s
end

-- One `key: value` mapping line; `col` is the key's column after any
-- `- ` sequence markers. Lines that are not mapping entries return nil.
local function yamlLine(line: string): YamlLine?
	local lead, rest = string.match(line, "^([ %-]*)(.*)$")
	if lead == nil or rest == nil or rest == "" or string.sub(rest, 1, 1) == "#" then
		return nil
	end
	local key: string?, value: string? = nil, nil
	local q = string.sub(rest, 1, 1)
	if q == '"' or q == "'" then
		local quoted, after = string.match(rest, "^(" .. q .. "[^" .. q .. "]*" .. q .. "):(.*)$")
		if quoted then
			key, value = unquote(quoted), after
		end
	else
		key, value = string.match(rest, "^([^:]-):%s(.*)$")
		if key == nil then
			key = string.match(rest, "^([^:]-):$")
			value = ""
		end
	end
	if key == nil or value == nil or key == "" then
		return nil
	end
	return { col = #lead, key = key, value = unquote(trim(value)) }
end

local function indentOf(line: string): number
	return #(string.match(line, "^ *") or "")
end

local function blank(line: string): boolean
	return string.find(line, "^%s*$") ~= nil or string.find(line, "^%s*#") ~= nil
end

-- Entries of the block mapping under the line `header` (key column
-- `col`): key -> (value, line index), direct children only.
local function children(
	lines: { string },
	header: number,
	last: number,
	col: number
): { [string]: { value: string, at: number } }
	local out: { [string]: { value: string, at: number } } = {}
	local childCol: number? = nil
	for i = header + 1, last do
		local line = lines[i]
		if not blank(line) then
			local indent = indentOf(line)
			if indent <= col then
				break
			end
			childCol = childCol or indent
			if indent == childCol then
				local entry = yamlLine(line)
				if entry and entry.col == indent then
					out[entry.key] = { value = entry.value, at = i }
				end
			end
		end
	end
	return out
end

-- Inclusive line range of one YAML document (or one List item).
function M.fromYamlLines(lines: { string }, first: number, last: number): Owner?
	last = math.min(last, #lines)
	local base: number? = nil
	local metaAt: number? = nil
	for i = math.max(first, 1), last do
		local line = lines[i]
		if not blank(line) and line ~= "---" then
			local entry = yamlLine(line)
			if entry then
				base = base or entry.col
				if entry.col == base and entry.key == "metadata" and entry.value == "" then
					metaAt = i
					break
				end
			end
		end
	end
	if base == nil or metaAt == nil then
		return nil
	end
	local metadata = children(lines, metaAt, last, base)
	local function nested(key: string): { [string]: string }
		local out: { [string]: string } = {}
		local e = metadata[key]
		if e and e.value == "" then
			for k, v in children(lines, e.at, last, indentOf(lines[e.at])) do
				out[k] = v.value
			end
		end
		return out
	end
	local ns = metadata.namespace
	return ownerOf(if ns then nonEmpty(ns.value) else nil, nested("annotations"), nested("labels"))
end

function M.hook(obj: any): { events: { string } }?
	if type(obj) ~= "table" or type(obj.metadata) ~= "table" then
		return nil
	end
	local spec = nonEmpty(mapOf(obj.metadata.annotations)[HOOK])
	if spec == nil then
		return nil
	end
	local events: { string } = {}
	for _, e in string.split(spec, ",") do
		local name = trim(e)
		if name ~= "" then
			table.insert(events, name)
		end
	end
	return { events = events }
end

-- Release records: Secrets of type helm.sh/release.v1 (or ConfigMaps under
-- HELM_DRIVER=configmap) named sh.helm.release.v1.<release>.v<revision>,
-- labelled owner=helm,name,version. Names may contain dots, so the labels
-- win over the object name.
function M.record(obj: any): { release: string, revision: number }?
	if type(obj) ~= "table" or type(obj.metadata) ~= "table" then
		return nil
	end
	local labels = mapOf(obj.metadata.labels)
	local helmLabels = labels.owner == "helm"
	if obj.kind == "Secret" then
		if obj.type ~= RECORD_TYPE then
			return nil
		end
	elseif obj.kind ~= "ConfigMap" or not helmLabels then
		return nil
	end
	local release: string?, version: string?
	if helmLabels and nonEmpty(labels.name) and nonEmpty(labels.version) then
		release, version = labels.name, labels.version
	elseif type(obj.metadata.name) == "string" then
		release, version = string.match(obj.metadata.name, "^sh%.helm%.release%.v1%.(.+)%.v(%d+)$")
	end
	local revision = if version then tonumber(version) else nil
	if release == nil or revision == nil or revision < 1 or revision % 1 ~= 0 then
		return nil
	end
	return { release = release, revision = revision }
end

return M
