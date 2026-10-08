--!strict
-- `kube-lens://mutate?...` links (Explore keys, lens chips, palette) and the
-- single-use grants that let a confirmed quick-action mutation through the
-- window. A link names a target, never a command line: the approve block
-- rebuilds the argv from validated fields, so a crafted URL can at most ask
-- for a preview of an ordinary delete/restart/scale/apply.
--
-- Grants: after the user confirms a mutating quick action (debug-pod,
-- debug-node, cronjob-run) the approve block stores `{url, expires}` under a
-- random token in tern.kv and opens the action link with `confirm=<token>`;
-- window.luau consumes the token (one use, expiry, exact link match) before
-- it opens the split.
local Command = require("../kubectl/command")
local Kinds = require("../kubectl/kinds")
local Quick = require("../actions/quick")
local Types = require("../model/types")

export type Op = "delete" | "restart" | "scale" | "apply"
export type Source = "flag" | "chosen" | "inferred"

export type Request = {
	op: Op,
	kind: string?,
	name: string?,
	namespace: string?,
	replicas: number?,
	file: string?,
	recursive: boolean,
	kustomize: string?,
	cwd: string?,
	context: string?,
	source: Source?,
	kubeconfig: string?,
}

export type Grant = { url: string, expires: number }
export type Grants = { [string]: Grant }

local M = {}

M.SCHEME = "kube-lens://mutate?"
M.GRANTS_KEY = "quick_confirm_grants"
-- Seconds between the confirmation and the window opening the split.
M.GRANT_TTL = 60
M.MAX_REPLICAS = 100000

local FIELDS = {
	"op",
	"kind",
	"name",
	"namespace",
	"replicas",
	"file",
	"recursive",
	"kustomize",
	"cwd",
	"context",
	"source",
	"kubeconfig",
}

local OPS: { [string]: Op } = { delete = "delete", restart = "restart", scale = "scale", apply = "apply" }
local SOURCES: { [string]: Source } = { flag = "flag", chosen = "chosen", inferred = "inferred" }

local RESTARTABLE = { Deployment = true, StatefulSet = true, DaemonSet = true }
local SCALABLE = { Deployment = true, StatefulSet = true, ReplicaSet = true, ReplicationController = true }

local function noControl(s: string): boolean
	return string.find(s, "%c") == nil
end

local function dnsLabel(s: string): boolean
	return #s >= 1
		and #s <= 63
		and string.find(s, "^[a-z0-9][a-z0-9%-]*$") ~= nil
		and string.find(s, "[a-z0-9]$") ~= nil
end

local function absPath(v: string, what: string): string?
	if #v > 4096 or not noControl(v) or string.sub(v, 1, 1) ~= "/" then
		return what .. " must be an absolute path"
	end
	return nil
end

local CHECKS: { [string]: (string) -> string? } = {
	kind = function(v)
		if
			#v <= 253
			and string.find(v, "^[a-z][a-z0-9%-]*[%.a-z0-9%-]*$") ~= nil
			and string.find(v, "..", 1, true) == nil
			and string.sub(v, -1) ~= "."
		then
			return nil
		end
		return "kind must be a resource type such as deployment or widgets.example.com"
	end,
	name = function(v)
		if #v <= 253 and string.find(v, "^[%w][%w%-%._:@]*$") ~= nil then
			return nil
		end
		return "name must be an object name"
	end,
	namespace = function(v)
		return if dnsLabel(v) then nil else "namespace must be a DNS-1123 label"
	end,
	replicas = function(v)
		if string.find(v, "^%d+$") and #v <= 6 and (tonumber(v) :: number) <= M.MAX_REPLICAS then
			return nil
		end
		return "replicas must be a whole number up to " .. M.MAX_REPLICAS
	end,
	file = function(v)
		return absPath(v, "file")
	end,
	kustomize = function(v)
		return absPath(v, "kustomize")
	end,
	cwd = function(v)
		return absPath(v, "cwd")
	end,
	recursive = function(v)
		return if v == "1" or v == "true" then nil else "recursive must be 1"
	end,
	context = function(v)
		if #v <= 253 and noControl(v) and v ~= "" and string.sub(v, 1, 1) ~= "-" then
			return nil
		end
		return "context must be printable, at most 253 bytes, not starting with -"
	end,
	source = function(v)
		return if SOURCES[v] then nil else "source must be flag, chosen or inferred"
	end,
	kubeconfig = function(v)
		if #v > 4096 or not noControl(v) or v == "" then
			return "kubeconfig must be a printable path"
		end
		local first = string.sub(v, 1, 1)
		if first == "-" or first == "~" then
			return "kubeconfig must be an absolute or relative path (no ~ or leading -)"
		end
		return nil
	end,
}

local function fieldsOf(r: Request): { [string]: string }
	local f: { [string]: string } = { op = r.op }
	local function put(k: string, v: string?)
		if v ~= nil and v ~= "" then
			f[k] = v
		end
	end
	put("kind", r.kind)
	put("name", r.name)
	put("namespace", r.namespace)
	if r.replicas then
		f.replicas = string.format("%d", r.replicas)
	end
	put("file", r.file)
	if r.recursive then
		f.recursive = "1"
	end
	put("kustomize", r.kustomize)
	put("cwd", r.cwd)
	put("context", r.context)
	put("source", r.source)
	put("kubeconfig", r.kubeconfig)
	return f
end

local function validate(f: { [string]: string }): (Request?, string?)
	local op = OPS[f.op or ""]
	if op == nil then
		return nil, "op must be delete, restart, scale or apply"
	end
	for k, v in f do
		if k ~= "op" then
			local check = CHECKS[k]
			if check == nil then
				return nil, "unknown parameter " .. k
			end
			local e = check(v)
			if e then
				return nil, e
			end
		end
	end
	local r: Request = {
		op = op :: Op,
		kind = f.kind,
		name = f.name,
		namespace = f.namespace,
		replicas = if f.replicas then tonumber(f.replicas) else nil,
		file = f.file,
		recursive = f.recursive ~= nil,
		kustomize = f.kustomize,
		cwd = f.cwd,
		context = f.context,
		source = if f.source then SOURCES[f.source] else nil,
		kubeconfig = f.kubeconfig,
	}
	if op == "apply" then
		if r.file and r.kustomize then
			return nil, "apply needs exactly one of file or kustomize"
		end
		if r.file == nil and r.kustomize == nil and r.cwd == nil then
			return nil, "apply needs a file, a kustomize directory, or a cwd to prompt for one"
		end
		if r.kind or r.name or r.replicas then
			return nil, "apply takes no kind, name or replicas"
		end
		if r.recursive and r.file == nil then
			return nil, "recursive applies to file only"
		end
		return r, nil
	end
	if r.kind == nil or r.name == nil then
		return nil, op .. " needs kind and name"
	end
	if r.file or r.kustomize or r.recursive then
		return nil, op .. " takes no file or kustomize"
	end
	local info = Kinds.normalize(r.kind :: string)
	if op == "restart" and not RESTARTABLE[info.kind] then
		return nil, "rollout restart applies to deployments, statefulsets and daemonsets"
	end
	if op == "scale" and not SCALABLE[info.kind] then
		return nil, "scale applies to deployments, statefulsets, replicasets and replicationcontrollers"
	end
	if op ~= "scale" and r.replicas then
		return nil, op .. " takes no replicas"
	end
	if info.known and info.namespaced == false and r.namespace then
		return nil, info.kind .. " is not namespaced"
	end
	return r, nil
end

function M.encode(r: Request): (string?, string?)
	local f = fieldsOf(r)
	local _, e = validate(f)
	if e then
		return nil, e
	end
	local parts: { string } = {}
	for _, k in FIELDS do
		local v = f[k]
		if v then
			table.insert(parts, k .. "=" .. Command.urlencode(v))
		end
	end
	return M.SCHEME .. table.concat(parts, "&"), nil
end

function M.decode(url: string): (Request?, string?)
	if string.sub(url, 1, #M.SCHEME) ~= M.SCHEME then
		return nil, "not a kube-lens://mutate link"
	end
	local query = string.sub(url, #M.SCHEME + 1)
	if string.find(query, "[^%w%-_%.~%%=&]") then
		return nil, "link has unencoded characters"
	end
	if string.find((string.gsub(query, "%%%x%x", "")), "%%") then
		return nil, "link has a malformed escape"
	end
	local f: { [string]: string } = {}
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([a-z]+)=(.+)$")
		if k == nil or v == nil then
			return nil, "malformed parameter " .. string.format("%q", pair)
		end
		if f[k] then
			return nil, "duplicate parameter " .. k
		end
		f[k] = Command.urldecode(v)
	end
	return validate(f)
end

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$") or "/"
	return if d == "" then "/" else d
end

-- The typed command a request stands for (connection flags are pinned later
-- by the plan from the context/kubeconfig fields). nil while a scale has no
-- replica count or an apply no path yet: the block asks for it.
function M.argv(r: Request, program: string): { string }?
	local argv: { string } = { program }
	local function add(...: string)
		for _, w in { ... } do
			table.insert(argv, w)
		end
	end
	if r.op == "apply" then
		if r.kustomize then
			add("apply", "-k", r.kustomize :: string)
		elseif r.file then
			add("apply", "-f", r.file :: string)
			if r.recursive then
				add("-R")
			end
		else
			return nil
		end
		return argv
	end
	local target = (r.kind :: string) .. "/" .. (r.name :: string)
	if r.op == "delete" then
		add("delete", target)
	elseif r.op == "restart" then
		add("rollout", "restart", target)
	else
		if r.replicas == nil then
			return nil
		end
		add("scale", target, string.format("--replicas=%d", r.replicas :: number))
	end
	if r.namespace then
		add("-n", r.namespace :: string)
	end
	return argv
end

-- Working directory for the plan: explicit, else the input's directory.
function M.cwd(r: Request, home: string?): string
	if r.cwd then
		return r.cwd :: string
	elseif r.file then
		return dirname(r.file :: string)
	elseif r.kustomize then
		return dirname(r.kustomize :: string)
	end
	return home or "/"
end

local function normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- The apply prompt's input: a path relative to the request's cwd (or
-- absolute, or `~/`), optionally `-k DIR` for a kustomization and `-R` (before
-- or after the path) to recurse into a directory. Paths may contain spaces.
function M.withPath(r: Request, input: string, home: string?): (Request?, string?)
	local rest = string.match(input, "^%s*(.-)%s*$") or ""
	local kustomize, recursive = false, false
	while true do
		local flag, after = string.match(rest, "^(%-[kR])%s+(.*)$")
		if flag == nil then
			break
		end
		if flag == "-k" then
			kustomize = true
		else
			recursive = true
		end
		rest = after :: string
	end
	local tail = string.match(rest, "^(.-)%s+%-R$")
	if tail then
		recursive = true
		rest = tail
	end
	if rest == "" or string.sub(rest, 1, 1) == "-" then
		return nil, "Enter a file or directory (-k DIR for a kustomization, -R to recurse)"
	end
	if kustomize and recursive then
		return nil, "-R applies to files and directories, not to -k"
	end
	local path: string
	if string.sub(rest, 1, 1) == "/" then
		path = rest
	elseif rest == "~" or string.sub(rest, 1, 2) == "~/" then
		if home == nil then
			return nil, "Cannot expand ~ here; enter an absolute path"
		end
		path = (home :: string) .. string.sub(rest, 2)
	else
		path = (r.cwd or home or "/") .. "/" .. rest
	end
	local out = table.clone(r)
	out.file = if kustomize then nil else normalize(path)
	out.kustomize = if kustomize then normalize(path) else nil
	out.recursive = recursive
	local _, e = M.encode(out)
	if e then
		return nil, e
	end
	return out, nil
end

-- Shortcuts (Explore keys, lens chips) -----------------------------------------

-- Where a shortcut's object was seen: the context it came from and how that
-- context was decided, plus the kubeconfig.
export type Origin = { context: string?, source: Source?, kubeconfig: string? }

export type Chip = { op: Op, label: string, key: string, url: string, title: string }

local SHORTCUTS: { { op: Op, label: string, key: string } } = {
	{ op = "delete", label = "Delete", key = "ctrl+d" },
	{ op = "restart", label = "Restart", key = "ctrl+r" },
	{ op = "scale", label = "Scale", key = "shift+s" },
}

-- A link for `op` on one object; nil (with the reason) when the op does not
-- apply to its kind. A scale carries no replica count: the block asks.
function M.forRef(op: Op, ref: Types.ResourceRef, origin: Origin): (string?, string?)
	return M.encode({
		op = op,
		kind = Command.resourceType(ref),
		name = ref.name,
		namespace = if ref.namespace ~= "" then ref.namespace else nil,
		recursive = false,
		context = origin.context,
		source = if origin.context then origin.source else nil,
		kubeconfig = origin.kubeconfig,
	})
end

-- Delete for every named object, Restart and Scale for the kinds that
-- support them; each opens the approve block, which previews first.
function M.chips(ref: Types.ResourceRef, origin: Origin): { Chip }
	local out: { Chip } = {}
	for _, s in SHORTCUTS do
		local url = M.forRef(s.op, ref, origin)
		local req = if url then M.decode(url) else nil
		if url and req then
			local argv = M.argv(req, "kubectl")
			local title = if argv
				then "Preview, then confirm: " .. Command.format(argv)
				else "Asks for the replica count, then previews"
			table.insert(out, { op = s.op, label = s.label, key = s.key, url = url, title = title })
		end
	end
	return out
end

-- Explore's target source as a link source: a confirmed inferred context
-- counts as chosen.
function M.sourceOf(source: string?, confirmed: boolean?): Source?
	if source == "flag" or source == "chosen" then
		return source :: Source
	elseif source == "inferred" then
		return if confirmed then "chosen" else "inferred"
	end
	return nil
end

-- Grants ---------------------------------------------------------------------

-- The quick-action link a grant is bound to: the request without `confirm`.
function M.quickBase(req: Quick.Request): string?
	local opts = table.clone(req.opts)
	opts.confirm = nil
	return (Quick.encode(req.action, req.target, req.ref, opts))
end

local function isToken(s: any): boolean
	return type(s) == "string" and #s == 32 and string.find(s, "^[0-9a-f]+$") ~= nil
end

local function live(grants: any, now: number): Grants
	local out: Grants = {}
	if type(grants) ~= "table" then
		return out
	end
	for token, g in grants do
		if
			isToken(token)
			and type(g) == "table"
			and type(g.url) == "string"
			and type(g.expires) == "number"
			and g.expires >= now
		then
			out[token] = { url = g.url, expires = g.expires }
		end
	end
	return out
end

-- Stored grants plus a new one; expired and malformed entries are dropped.
function M.addGrant(grants: any, token: string, url: string, now: number, ttl: number?): (Grants?, string?)
	if not isToken(token) then
		return nil, "grant token must be 32 lowercase hex characters"
	end
	local out = live(grants, now)
	out[token] = { url = url, expires = now + (ttl or M.GRANT_TTL) }
	return out, nil
end

-- One use: the token is removed whether or not it matches, so a guessed or
-- replayed token never succeeds twice. Returns the remaining grants.
function M.consumeGrant(grants: any, token: string?, url: string, now: number): (boolean, Grants, string?)
	local rest = live(grants, now)
	if not isToken(token) then
		return false, rest, "the confirmation token is malformed"
	end
	local g = rest[token :: string]
	rest[token :: string] = nil
	if g == nil then
		return false, rest, "the confirmation expired or was already used; confirm again"
	end
	if g.url ~= url then
		return false, rest, "the confirmation was given for a different action"
	end
	return true, rest, nil
end

return M
