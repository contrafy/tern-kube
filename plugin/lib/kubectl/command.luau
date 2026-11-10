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

local EXPLORE_FIELDS = {
	"kind",
	"group",
	"name",
	"namespace",
	"context",
	"kubeconfig",
	"route",
	"release",
	"revision",
	"cwd",
	"container",
	"previous",
	"selector",
	"since",
	"tail",
	"q",
	"types",
	"search",
}

export type ExploreExtra = {
	route: string?,
	-- The listed type when there is no object (`Filter in Explore`).
	kind: string?,
	group: string?,
	-- helm-release / helm-history: the release, its revision and namespace
	-- (the namespace replaces the object's or invocation's).
	release: string?,
	revision: number?,
	namespace: string?,
	cwd: string?,
	container: string?,
	previous: boolean?,
	selector: string?,
	since: string?,
	tail: string?,
	q: string?,
	types: string?,
	-- Land on the logs route with its `/` filter focused.
	search: boolean?,
}

-- `route` opens a view on top of the object (`manifest`, `diff`, `logs`,
-- `events`) or a Helm view (`helm-releases`, `helm-release`, `helm-history`
-- with `release`); `cwd` is where the manifest index is built (the lensed
-- shell's directory). Without `ref` the route is scoped to the invocation's
-- namespace (`*` for -A): a namespace events timeline or `logs -l`.
function M.exploreUrl(inv: Invocation, ref: Ref?, extra: ExploreExtra?): string
	local e: ExploreExtra = extra or {}
	local namespace = if e.namespace
		then e.namespace
		elseif ref then ref.namespace
		elseif inv.allNamespaces then "*"
		else inv.namespace
	local values: { [string]: string? } = {
		kind = if ref then ref.kind else e.kind,
		group = if ref then ref.group else e.group,
		name = ref and ref.name,
		namespace = namespace,
		context = inv.context,
		kubeconfig = inv.kubeconfig,
		route = e.route,
		release = e.release,
		revision = if e.revision then string.format("%d", e.revision) else nil,
		cwd = e.cwd,
		container = e.container,
		previous = if e.previous then "1" else nil,
		selector = e.selector,
		since = e.since,
		tail = e.tail,
		q = e.q,
		types = e.types,
		search = if e.search then "1" else nil,
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

-- The lens "Filter in Explore" chip: one listed resource type of `get`
-- (no names) reopened in Explore with the same namespace scope, selector and
-- pinned target, its text filter focused. nil when Explore cannot list the
-- same thing.
function M.exploreFilterUrl(inv: Invocation, cwd: string?): string?
	local first = inv.resources[1]
	if inv.verb ~= "get" or #inv.resources ~= 1 or first == nil or first.name ~= nil then
		return nil
	end
	if string.lower(first.kind) == "all" then
		return nil
	end
	return M.exploreUrl(inv, nil, {
		kind = first.kind,
		group = first.group,
		selector = inv.selector,
		search = true,
		cwd = cwd,
	})
end

export type LogsSource = {
	ref: Ref?,
	selector: string?,
	container: string?,
	previous: boolean,
	since: string?,
	tail: string?,
	prefix: boolean,
	timestamps: boolean,
	allContainers: boolean,
}

local function lastFlag(inv: Invocation, name: string): string?
	local list = inv.flags[name]
	return if list then list[#list] else nil
end

local function flagOn(inv: Invocation, name: string): boolean
	local v = lastFlag(inv, name)
	return v ~= nil and v ~= "false"
end

-- What a `kubectl logs` invocation reads from: the pod or TYPE/NAME (nil
-- with -l) and the flags a rerun (Explore, a split) must keep.
function M.logsSource(inv: Invocation): LogsSource
	local first = inv.resources[1]
	local ref: Ref? = nil
	if inv.selector == nil and first and first.name and first.name ~= "" then
		ref = {
			clusterContext = inv.context,
			namespace = inv.namespace,
			group = first.group,
			version = nil,
			kind = first.kind,
			name = first.name,
			uid = nil,
			source = "snapshot",
		}
	end
	local allContainers = flagOn(inv, "all-containers")
	return {
		ref = ref,
		selector = inv.selector,
		container = if allContainers then nil else lastFlag(inv, "container"),
		previous = flagOn(inv, "previous"),
		since = lastFlag(inv, "since"),
		tail = lastFlag(inv, "tail"),
		prefix = flagOn(inv, "prefix"),
		timestamps = flagOn(inv, "timestamps"),
		allContainers = allContainers,
	}
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
