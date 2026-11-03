--!strict
-- The contexts a compare can run against: one local `kubectl config view -o
-- json` (credentials are omitted by kubectl) gives every context of the
-- kubeconfig with its cluster's server, which also tells contexts that are
-- aliases of one cluster apart. The picker offers a single choice, never a
-- multi-select: one other context, all of them, or the configured preset,
-- with the budget enforced before any query runs.

export type ContextInfo = { name: string, cluster: string?, server: string?, namespace: string? }

-- id: "=<ctx>" one other context, "*" every context, "@" the configured preset.
export type Choice = {
	id: string,
	label: string,
	contexts: { string },
	note: string?,
	-- Shown next to the row but does not prevent choosing it.
	warning: string?,
	-- Why the row cannot be chosen.
	disabled: string?,
}

local M = {}

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local EMPTY: { [string]: any } = table.freeze({})

local function map(v: any): { [string]: any }?
	return if type(v) == "table" then v else nil
end

local function list(v: any): { any }
	return if type(v) == "table" then v else {}
end

function M.parse(text: string, decode: (string) -> any): ({ ContextInfo }?, string?)
	local ok, value = pcall(decode, text)
	if not ok then
		return nil, "kubectl config view printed invalid JSON: " .. tostring(value)
	end
	local config = map(value)
	if config == nil or (config.kind ~= nil and config.kind ~= "Config") then
		return nil, "kubectl config view did not print a kubeconfig"
	end
	local servers: { [string]: string } = {}
	for _, c in list(config.clusters) do
		local entry = map(c)
		local name = entry and str(entry.name)
		local server = entry and str((map(entry.cluster) or EMPTY).server)
		if name and server then
			servers[name] = server
		end
	end
	local out: { ContextInfo } = {}
	for _, c in list(config.contexts) do
		local entry = map(c)
		local name = entry and str(entry.name)
		if entry and name then
			local context = map(entry.context) or EMPTY
			local cluster = str(context.cluster)
			table.insert(out, {
				name = name,
				cluster = cluster,
				server = if cluster then servers[cluster] else nil,
				namespace = str(context.namespace),
			})
		end
	end
	return out, nil
end

local function budget(count: number, max: number): string?
	if count == 0 then
		return "no other context to compare with"
	elseif count > max then
		return string.format("%d other contexts, above compare.max_contexts (%d)", count, max)
	end
	return nil
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

function M.choices(all: { ContextInfo }, base: string, configured: { string }, max: number): { Choice }
	local baseServer: string? = nil
	local byName: { [string]: ContextInfo } = {}
	for _, info in all do
		byName[info.name] = info
		if info.name == base then
			baseServer = info.server
		end
	end
	local function sameServer(info: ContextInfo): boolean
		return baseServer ~= nil and info.server == baseServer
	end

	local out: { Choice } = {}
	local others: { string } = {}
	local shared = 0
	for _, info in all do
		if info.name ~= base then
			table.insert(others, info.name)
			local same = sameServer(info)
			if same then
				shared += 1
			end
			table.insert(out, {
				id = "=" .. info.name,
				label = info.name,
				contexts = { info.name },
				note = info.server,
				warning = if same then "same server as base" else nil,
			})
		end
	end

	table.insert(out, {
		id = "*",
		label = string.format("All contexts (%d)", #all),
		contexts = others,
		warning = if shared > 0 then plural(shared, "context") .. " with the same server as base" else nil,
		disabled = budget(#others, max),
	})

	if #configured > 0 then
		local known: { string } = {}
		local unknown: { string } = {}
		for _, name in configured do
			if byName[name] == nil then
				table.insert(unknown, name)
			elseif name ~= base then
				table.insert(known, name)
			end
		end
		table.insert(out, {
			id = "@",
			label = "Configured: " .. table.concat(configured, ", "),
			contexts = known,
			warning = if #unknown > 0 then "not in this kubeconfig: " .. table.concat(unknown, ", ") else nil,
			disabled = budget(#known, max),
		})
	end
	return out
end

local SEPARATOR = "[%-_%.:/@]"

-- Narrow columns: the longest common prefix of all names, cut back to its
-- last separator, is dropped (`kind-tern-kube-dev`, `kind-tern-kube-dev2`
-- -> `dev`, `dev2`). Labels stay unique or every name keeps its full form.
function M.short(names: { string }): { [string]: string }
	local out: { [string]: string } = {}
	if #names < 2 then
		for _, name in names do
			out[name] = name
		end
		return out
	end
	local prefix = names[1]
	for i = 2, #names do
		local name = names[i]
		local n = 0
		while n < #prefix and n < #name and string.byte(prefix, n + 1) == string.byte(name, n + 1) do
			n += 1
		end
		prefix = string.sub(prefix, 1, n)
	end
	local cut = 0
	for i = #prefix, 1, -1 do
		if string.find(string.sub(prefix, i, i), SEPARATOR) then
			cut = i
			break
		end
	end
	local seen: { [string]: boolean } = {}
	for _, name in names do
		local label = string.sub(name, cut + 1)
		if label == "" then
			label = name
		end
		if seen[label] then
			for _, n in names do
				out[n] = n
			end
			return out
		end
		seen[label] = true
		out[name] = label
	end
	return out
end

return M
