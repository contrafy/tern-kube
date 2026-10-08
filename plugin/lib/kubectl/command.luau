--!strict
-- Copyable kubectl commands and Explore links for a snapshot row. Commands
-- carry the lensed command's own --context/--kubeconfig/-n so a copied
-- command targets the cluster the snapshot came from, not whatever context
-- is current when it is pasted.

local Resource = require("../model/resource")
local Types = require("../model/types")

type Invocation = Types.Invocation
type Ref = Types.ResourceRef

local M = {}

-- POSIX sh single quoting; words made only of these characters need none.
function M.quote(s: string): string
	if s ~= "" and string.find(s, "^[%w%-_%./:=@,+%%]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function M.format(argv: { string }): string
	local out: { string } = table.create(#argv)
	for i, w in argv do
		out[i] = M.quote(w)
	end
	return table.concat(out, " ")
end

function M.connectionArgs(inv: Invocation): { string }
	local out: { string } = {}
	if inv.kubeconfig then
		table.insert(out, "--kubeconfig")
		table.insert(out, inv.kubeconfig)
	end
	if inv.context then
		table.insert(out, "--context")
		table.insert(out, inv.context)
	end
	return out
end

-- `pod`, `deployment.apps`, `widgets.lens.example.com`: the form every
-- kubectl verb accepts.
function M.resourceType(ref: Ref): string
	local t = string.lower(ref.kind)
	if ref.group and ref.group ~= "" then
		t ..= "." .. ref.group
	end
	return t
end

local function program(inv: Invocation): string
	return if inv.program ~= "" then inv.program else "kubectl"
end

local function base(inv: Invocation, verb: string): { string }
	local argv = { program(inv) }
	for _, a in M.connectionArgs(inv) do
		table.insert(argv, a)
	end
	table.insert(argv, verb)
	return argv
end

local function addNamespace(argv: { string }, ref: Ref)
	if ref.namespace and ref.namespace ~= "" then
		table.insert(argv, "-n")
		table.insert(argv, ref.namespace)
	end
end

export type What = "name" | "id" | "describe" | "logs" | "get-yaml"

export type Options = { containers: number? }

-- Argv for a command about `ref`; nil when it does not apply (logs of a
-- non-pod).
function M.argv(what: What, inv: Invocation, ref: Ref, opts: Options?): { string }?
	if what == "describe" then
		local argv = base(inv, "describe")
		table.insert(argv, M.resourceType(ref))
		table.insert(argv, ref.name)
		addNamespace(argv, ref)
		return argv
	elseif what == "get-yaml" then
		local argv = base(inv, "get")
		table.insert(argv, M.resourceType(ref))
		table.insert(argv, ref.name)
		addNamespace(argv, ref)
		table.insert(argv, "-o")
		table.insert(argv, "yaml")
		return argv
	elseif what == "logs" then
		if ref.kind ~= "Pod" or (ref.group ~= nil and ref.group ~= "") then
			return nil
		end
		local argv = base(inv, "logs")
		table.insert(argv, ref.name)
		addNamespace(argv, ref)
		local containers = if opts then opts.containers else nil
		if containers and containers > 1 then
			table.insert(argv, "--all-containers")
		end
		return argv
	end
	return nil
end

-- The text a copy action puts on the clipboard.
function M.copyText(what: What, inv: Invocation, ref: Ref, opts: Options?): string?
	if what == "name" then
		return ref.name
	elseif what == "id" then
		return Resource.qualifiedId(ref)
	end
	local argv = M.argv(what, inv, ref, opts)
	return if argv then M.format(argv) else nil
end

function M.urlencode(s: string): string
	return (
		string.gsub(s, "[^%w%-_%.~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

function M.urldecode(s: string): string
	local spaced = string.gsub(s, "%+", " ")
	return (
		string.gsub(spaced, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

local EXPLORE_FIELDS = { "kind", "group", "name", "namespace", "context", "kubeconfig", "route", "cwd" }

-- `route` opens a GitOps view on top of the object (`manifest`, `diff`);
-- `cwd` is where the manifest index is built (the lensed shell's directory).
function M.exploreUrl(inv: Invocation, ref: Ref, extra: { route: string?, cwd: string? }?): string
	local values: { [string]: string? } = {
		kind = ref.kind,
		group = ref.group,
		name = ref.name,
		namespace = ref.namespace,
		context = inv.context,
		kubeconfig = inv.kubeconfig,
		route = extra and extra.route,
		cwd = extra and extra.cwd,
	}
	local parts: { string } = {}
	for _, k in EXPLORE_FIELDS do
		local v = values[k]
		if v and v ~= "" then
			table.insert(parts, k .. "=" .. M.urlencode(v))
		end
	end
	return "tern-kube://explore?" .. table.concat(parts, "&")
end

-- Query parameters of a tern-kube:// URL, in order of appearance.
function M.parseQuery(url: string): { { key: string, value: string } }
	local out: { { key: string, value: string } } = {}
	local query = string.match(url, "%?(.*)$")
	if query == nil then
		return out
	end
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=?(.*)$")
		if k and k ~= "" then
			table.insert(out, { key = M.urldecode(k), value = M.urldecode(v or "") })
		end
	end
	return out
end

return M
