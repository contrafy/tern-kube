--!strict
local Types = require("./types")

type Ref = Types.ResourceRef
type Source = "snapshot" | "live"

local function nonEmpty(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

-- "apps/v1" -> ("apps", "v1"); "v1" -> (nil, "v1"): the core group has no name.
local function splitApiVersion(apiVersion: any): (string?, string?)
	local text = nonEmpty(apiVersion)
	if not text then
		return nil, nil
	end
	local group, version = string.match(text, "^([^/]+)/(.+)$")
	if group then
		return group, version
	end
	return nil, text
end

-- Context is deliberately excluded: every ref in one snapshot shares the
-- snapshot's target, and the context name may only be resolved later (or be
-- an alias of the same cluster), so including it would give one object two
-- keys. Version and uid are excluded because the same object is served under
-- several versions and table output carries no uid. Kubernetes names, kinds,
-- groups and namespaces cannot contain "/", so the joined form is unique.
local function key(ref: Ref): string
	return table.concat({ ref.group or "", ref.kind, ref.namespace or "", ref.name }, "/")
end

-- Same spelling as `kubectl get -o name` (`deployment.apps/web`), which every
-- kubectl verb accepts as a resource argument.
local function qualifiedId(ref: Ref): string
	local resource = string.lower(ref.kind)
	local group = nonEmpty(ref.group)
	if group then
		resource ..= "." .. group
	end
	local id = resource .. "/" .. ref.name
	local namespace = nonEmpty(ref.namespace)
	if namespace then
		id ..= " -n " .. namespace
	end
	return id
end

local function fromObject(obj: { [string]: any }, source: Source): Ref?
	local kind = nonEmpty(obj.kind)
	local metadata = obj.metadata
	if not kind or type(metadata) ~= "table" then
		return nil
	end
	local name = nonEmpty(metadata.name)
	if not name then
		return nil
	end
	local group, version = splitApiVersion(obj.apiVersion)
	return {
		clusterContext = nil,
		namespace = nonEmpty(metadata.namespace),
		group = group,
		version = version,
		kind = kind,
		name = name,
		uid = nonEmpty(metadata.uid),
		source = source,
	}
end

return {
	key = key,
	qualifiedId = qualifiedId,
	fromObject = fromObject,
	splitApiVersion = splitApiVersion,
}
