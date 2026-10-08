--!strict
local data = require("./kinds_data")

export type KindInfo = {
	kind: string,
	group: string?,
	plural: string,
	singular: string,
	short: { string },
	namespaced: boolean?,
	known: boolean,
}

local byName: { [string]: data.Row } = {}
local byGroupName: { [string]: data.Row } = {}

local function names(row: data.Row): { string }
	local list = { row.plural, string.lower(row.kind) }
	for _, s in row.short do
		table.insert(list, s)
	end
	return list
end

for _, row in data do
	for _, n in names(row) do
		if byName[n] == nil then
			byName[n] = row
		end
		local key = n .. "." .. row.group
		if byGroupName[key] == nil then
			byGroupName[key] = row
		end
	end
end

local function fromRow(row: data.Row): KindInfo
	return {
		kind = row.kind,
		group = if row.group == "" then nil else row.group,
		plural = row.plural,
		singular = string.lower(row.kind),
		short = table.clone(row.short),
		namespaced = row.namespaced,
		known = true,
	}
end

local function unknown(resource: string, group: string?): KindInfo
	return {
		kind = resource,
		group = group,
		plural = resource,
		singular = resource,
		short = {},
		namespaced = nil,
		known = false,
	}
end

local M = {}

-- Accepts the forms kubectl resolves: `resource`, `resource.group` and
-- `resource.version.group`, where resource is a plural, singular, short name or Kind.
function M.normalize(token: string): KindInfo
	local lowered = string.lower(token)
	local direct = byName[lowered]
	if direct then
		return fromRow(direct)
	end
	local resource, rest = string.match(lowered, "^([^.]+)%.(.+)$")
	if resource == nil or rest == nil then
		return unknown(token, nil)
	end
	local grouped = byGroupName[resource .. "." .. rest]
	if grouped then
		return fromRow(grouped)
	end
	local version, group = string.match(rest, "^([^.]+)%.(.+)$")
	if version and group and string.match(version, "^v%d") then
		local versioned = byGroupName[resource .. "." .. group]
		if versioned then
			return fromRow(versioned)
		end
	end
	-- Core resources may be addressed as `pods.v1`.
	if string.match(rest, "^v%d[%w]*$") then
		local core = byGroupName[resource .. "."]
		if core then
			return fromRow(core)
		end
	end
	local original = string.sub(token, 1, #resource)
	return unknown(original, string.sub(token, #resource + 2))
end

-- Resolves the TYPE part of NAME cells printed by `get all` / `-o name`,
-- e.g. `deployment.apps` or `deployment.apps/web`.
function M.fromPrefix(prefix: string): KindInfo
	local slash = string.find(prefix, "/", 1, true)
	return M.normalize(if slash then string.sub(prefix, 1, slash - 1) else prefix)
end

return M
