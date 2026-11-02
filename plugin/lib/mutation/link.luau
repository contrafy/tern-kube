--!strict
-- `tern-kube://mutate?...` links (Explore keys, lens chips, palette) and the
-- single-use grants that let a confirmed quick-action mutation through the
-- window. A link names a target and structured inputs, never a command line:
-- every field is validated and the approve block rebuilds the argv from
-- them, so a crafted URL can at most ask for a preview of an ordinary
-- guarded verb.
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

export type Op =
	"delete"
	| "restart"
	| "scale"
	| "apply"
	| "undo"
	| "pause"
	| "resume"
	| "label"
	| "annotate"
	| "patch"
	| "cordon"
	| "uncordon"
	| "drain"
export type Source = "flag" | "chosen" | "inferred"
export type PatchType = "strategic" | "merge" | "json"

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
	-- label/annotate: kubectl's positional edits (`KEY=VALUE`, `KEY-`), values unquoted.
	edits: { string }?,
	overwrite: boolean,
	patch: string?,
	patchType: PatchType?,
	-- drain: `--flag` / `--flag=value` words from the allow-list, in canonical order.
	drainFlags: { string }?,
}

export type Prompt = { text: string, hint: string, prefill: string }

export type Grant = { url: string, expires: number }
export type Grants = { [string]: Grant }

local M = {}

M.SCHEME = "tern-kube://mutate?"
M.GRANTS_KEY = "quick_confirm_grants"
-- Seconds between the confirmation and the window opening the split.
M.GRANT_TTL = 60
M.MAX_REPLICAS = 100000
M.MAX_INPUT_BYTES = 65536
M.MAX_DRAIN_TIMEOUT_MS = 3600000
M.DRAIN_PREFILL = "--ignore-daemonsets --timeout=4m"

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
	"edits",
	"overwrite",
	"patchtype",
	"patch",
	"drain",
}

local OPS: { [string]: Op } = {
	delete = "delete",
	restart = "restart",
	scale = "scale",
	apply = "apply",
	undo = "undo",
	pause = "pause",
	resume = "resume",
	label = "label",
	annotate = "annotate",
	patch = "patch",
	cordon = "cordon",
	uncordon = "uncordon",
	drain = "drain",
}
local SOURCES: { [string]: Source } = { flag = "flag", chosen = "chosen", inferred = "inferred" }
local PATCH_TYPES: { [string]: PatchType } = { strategic = "strategic", merge = "merge", json = "json" }

local RESTARTABLE = { Deployment = true, StatefulSet = true, DaemonSet = true }
local SCALABLE = { Deployment = true, StatefulSet = true, ReplicaSet = true, ReplicationController = true }
local UNDOABLE = { Deployment = true, StatefulSet = true, DaemonSet = true }
local PAUSABLE = { Deployment = true }
local NODE_OPS = { cordon = true, uncordon = true, drain = true }
local INPUT_OPS = { scale = true, apply = true, label = true, annotate = true, patch = true, drain = true }

-- Per-op parameters beyond the target and connection fields.
local EXTRA: { [string]: { [string]: boolean } } = {
	scale = { replicas = true },
	label = { edits = true, overwrite = true },
	annotate = { edits = true, overwrite = true },
	patch = { patch = true, patchtype = true },
	drain = { drain = true },
}
local OP_PARAMS = { "replicas", "edits", "overwrite", "patch", "patchtype", "drain" }

local function noControl(s: string): boolean
	return string.find(s, "%c") == nil
end

local function dnsLabel(s: string): boolean
	return #s >= 1
		and #s <= 63
		and string.find(s, "^[a-z0-9][a-z0-9%-]*$") ~= nil
		and string.find(s, "[a-z0-9]$") ~= nil
end

local function dnsSubdomain(s: string): boolean
	if #s > 253 or string.find(s, "..", 1, true) or string.sub(s, -1) == "." then
		return false
	end
	for part in string.gmatch(s, "[^.]+") do
		if not dnsLabel(part) then
			return false
		end
	end
	return s ~= ""
end

-- Label value / qualified-name part: alphanumerics at both ends, `-_.` inside.
local function labelName(s: string): boolean
	return #s >= 1 and #s <= 63 and string.find(s, "^[%w][%w%-_%.]*$") ~= nil and string.find(s, "[%w]$") ~= nil
end

local function qualifiedKey(k: string): boolean
	local prefix, name = string.match(k, "^([^/]*)/(.*)$")
	if prefix == nil or name == nil then
		return labelName(k)
	end
	return dnsSubdomain(prefix) and labelName(name)
end

local function absPath(v: string, what: string): string?
	if #v > 4096 or not noControl(v) or string.sub(v, 1, 1) ~= "/" then
		return what .. " must be an absolute path"
	end
	return nil
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function lines(v: string): { string }
	local out: { string } = {}
	for part in string.gmatch(v, "[^\n]+") do
		table.insert(out, part)
	end
	return out
end

-- Go duration (`90s`, `4m`, `1h30m`, `500ms`) in milliseconds; nil when malformed.
function M.durationMs(text: string): number?
	if text == "" or #text > 32 then
		return nil
	end
	local units: { [string]: number } = { h = 3600000, m = 60000, s = 1000, ms = 1, us = 0.001, ns = 0.000001 }
	local total = 0
	local rest = text
	while rest ~= "" do
		local num, unit, after = string.match(rest, "^(%d+%.?%d*)([a-z]+)(.*)$")
		if num == nil or unit == nil or after == nil or units[unit] == nil then
			return nil
		end
		total += (tonumber(num) :: number) * units[unit]
		rest = after
	end
	return total
end

local DRAIN_ORDER: { string } = {
	"ignore-daemonsets",
	"delete-emptydir-data",
	"force",
	"disable-eviction",
	"grace-period",
	"timeout",
	"pod-selector",
	"skip-wait-for-delete-timeout",
}
local DRAIN_RANK: { [string]: number } = {}
for i, name in DRAIN_ORDER do
	DRAIN_RANK[name] = i
end
local DRAIN_BOOL =
	{ ["ignore-daemonsets"] = true, ["delete-emptydir-data"] = true, force = true, ["disable-eviction"] = true }

local DRAIN_VALUES: { [string]: (string) -> string? } = {
	["grace-period"] = function(v)
		local n = if string.find(v, "^%-?%d+$") and #v <= 7 then tonumber(v) else nil
		return if n and n >= -1 then nil else "--grace-period must be a whole number of seconds, -1 or more"
	end,
	timeout = function(v)
		local ms = M.durationMs(v)
		if ms == nil or ms <= 0 or ms > M.MAX_DRAIN_TIMEOUT_MS then
			return "--timeout must be a duration above zero and at most 1h, such as 4m or 90s"
		end
		return nil
	end,
	["pod-selector"] = function(v)
		return if #v <= 1024 and string.find(v, "^[%w%-_%./=!, ()]+$") ~= nil
			then nil
			else "--pod-selector must be a label selector"
	end,
	["skip-wait-for-delete-timeout"] = function(v)
		return if string.find(v, "^%d+$") and #v <= 7
			then nil
			else "--skip-wait-for-delete-timeout must be whole seconds"
	end,
}

local function drainFlagName(word: string): (string?, string?)
	local name, value = string.match(word, "^%-%-([a-z%-]+)=(.*)$")
	if name then
		return name, value
	end
	return string.match(word, "^%-%-([a-z%-]+)$"), nil
end

local function checkDrain(flags: { string }): string?
	local seen: { [string]: boolean } = {}
	for _, word in flags do
		local name, value = drainFlagName(word)
		if name == nil or DRAIN_RANK[name] == nil then
			return string.format(
				"%s is not a drain option here; use %s",
				word,
				"--" .. table.concat(DRAIN_ORDER, ", --")
			)
		end
		if seen[name] then
			return "--" .. name .. " appears twice"
		end
		seen[name] = true
		if DRAIN_BOOL[name] then
			if value ~= nil then
				return "--" .. name .. " takes no value"
			end
		else
			if value == nil then
				return "--" .. name .. " needs =VALUE"
			end
			local e = DRAIN_VALUES[name](value :: string)
			if e then
				return e
			end
		end
	end
	if not seen.timeout then
		return "drain needs --timeout (at most 1h): a drain blocked by a PodDisruptionBudget otherwise retries forever"
	end
	return nil
end

local function checkEdits(op: string, edits: { string }): string?
	if #edits == 0 then
		return op .. " needs at least one KEY=VALUE or KEY-"
	end
	local seen: { [string]: boolean } = {}
	local bytes = 0
	for _, token in edits do
		bytes += #token
		local key, value = string.match(token, "^([^=]*)=(.*)$")
		if key == nil then
			key = string.match(token, "^(.+)%-$")
		end
		if key == nil or not qualifiedKey(key) then
			return string.format("%q: keys are [prefix/]name, set with KEY=VALUE or removed with KEY-", token)
		end
		if seen[key] then
			return "key " .. key .. " appears twice"
		end
		seen[key] = true
		if value ~= nil then
			if op == "label" and value ~= "" and not labelName(value) then
				return string.format(
					"%q: label values are at most 63 characters of letters, digits, - _ . and start and end alphanumeric",
					token
				)
			end
			if not noControl(value) then
				return string.format("%q: values must be printable text", key)
			end
		end
	end
	if bytes > M.MAX_INPUT_BYTES then
		return op .. " input is larger than 64 KiB"
	end
	return nil
end

local function checkPatch(v: string): string?
	if #v > M.MAX_INPUT_BYTES or not noControl(v) then
		return "patch must be printable JSON of at most 64 KiB"
	end
	local first = string.sub(trim(v), 1, 1)
	if first ~= "{" and first ~= "[" then
		return "patch must be a JSON object (or a JSON array for --type=json)"
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
	-- edits and drain are newline-joined lists, checked per op in validate.
	edits = function(v)
		return if #v <= M.MAX_INPUT_BYTES then nil else "edits are larger than 64 KiB"
	end,
	drain = function(v)
		return if #v <= 4096 and noControl((string.gsub(v, "\n", " "))) then nil else "drain options are malformed"
	end,
	overwrite = function(v)
		return if v == "1" or v == "true" then nil else "overwrite must be 1"
	end,
	patchtype = function(v)
		return if PATCH_TYPES[v] then nil else "patch type must be strategic, merge or json"
	end,
	patch = checkPatch,
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
	if r.edits and #r.edits > 0 then
		f.edits = table.concat(r.edits, "\n")
	end
	if r.overwrite then
		f.overwrite = "1"
	end
	put("patchtype", r.patchType)
	put("patch", r.patch)
	if r.drainFlags and #r.drainFlags > 0 then
		f.drain = table.concat(r.drainFlags, "\n")
	end
	return f
end

local function validate(f: { [string]: string }): (Request?, string?)
	local op = OPS[f.op or ""]
	if op == nil then
		return nil,
			"op must be one of delete, restart, scale, apply, undo, pause, resume, label, annotate, patch, cordon, uncordon, drain"
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
		edits = if f.edits then lines(f.edits) else nil,
		overwrite = f.overwrite ~= nil,
		patch = f.patch,
		patchType = if f.patchtype then PATCH_TYPES[f.patchtype] else nil,
		drainFlags = if f.drain then lines(f.drain) else nil,
	}
	local extra = EXTRA[op] or {}
	for _, k in OP_PARAMS do
		if f[k] and not extra[k] then
			return nil, op .. " takes no " .. k
		end
	end
	if op == "apply" then
		if r.file and r.kustomize then
			return nil, "apply needs exactly one of file or kustomize"
		end
		if r.file == nil and r.kustomize == nil and r.cwd == nil then
			return nil, "apply needs a file, a kustomize directory, or a cwd to prompt for one"
		end
		if r.kind or r.name then
			return nil, "apply takes no kind or name"
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
	elseif op == "scale" and not SCALABLE[info.kind] then
		return nil, "scale applies to deployments, statefulsets, replicasets and replicationcontrollers"
	elseif op == "undo" and not UNDOABLE[info.kind] then
		return nil, "rollout undo applies to deployments, daemonsets and statefulsets"
	elseif (op == "pause" or op == "resume") and not PAUSABLE[info.kind] then
		return nil, "rollout pause/resume supports deployments only"
	elseif NODE_OPS[op] and info.kind ~= "Node" then
		return nil, op .. " applies to nodes only"
	end
	if info.known and info.namespaced == false and r.namespace then
		return nil, info.kind .. " is not namespaced"
	end
	if r.edits then
		local e = checkEdits(op, r.edits :: { string })
		if e then
			return nil, e
		end
	end
	if r.drainFlags then
		local e = checkDrain(r.drainFlags :: { string })
		if e then
			return nil, e
		end
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
		return nil, "not a tern-kube://mutate link"
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

local function target(r: Request): string
	return (r.kind or "") .. "/" .. (r.name or "")
end

-- kubectl's default strategic merge patch fails on custom resources, so
-- kinds the plugin does not know default to a JSON merge patch.
function M.defaultPatchType(r: Request): PatchType
	return if r.kind and Kinds.normalize(r.kind :: string).known then "strategic" else "merge"
end

function M.takesInput(op: Op): boolean
	return INPUT_OPS[op] == true
end

-- The block asks for input before it can preview.
function M.needsInput(r: Request): boolean
	if r.op == "scale" then
		return r.replicas == nil
	elseif r.op == "apply" then
		return r.file == nil and r.kustomize == nil
	elseif r.op == "label" or r.op == "annotate" then
		return r.edits == nil or #(r.edits :: { string }) == 0
	elseif r.op == "patch" then
		return r.patch == nil
	elseif r.op == "drain" then
		return r.drainFlags == nil or #(r.drainFlags :: { string }) == 0
	end
	return false
end

-- The typed command a request stands for (connection flags are pinned later
-- by the plan from the context/kubeconfig fields); nil while it needs input.
function M.argv(r: Request, program: string): { string }?
	if M.needsInput(r) then
		return nil
	end
	local argv: { string } = { program }
	local function add(...: string)
		for _, w in { ... } do
			table.insert(argv, w)
		end
	end
	local function addAll(words: { string }?)
		for _, w in (words or {}) :: { string } do
			table.insert(argv, w)
		end
	end
	local op = r.op
	if op == "apply" then
		if r.kustomize then
			add("apply", "-k", r.kustomize :: string)
		else
			add("apply", "-f", r.file :: string)
			if r.recursive then
				add("-R")
			end
		end
		return argv
	elseif op == "cordon" or op == "uncordon" then
		add(op, r.name :: string)
		return argv
	elseif op == "drain" then
		add("drain", r.name :: string)
		addAll(r.drainFlags)
		return argv
	end
	local t = target(r)
	if op == "delete" then
		add("delete", t)
	elseif op == "restart" then
		add("rollout", "restart", t)
	elseif op == "undo" or op == "pause" or op == "resume" then
		add("rollout", op, t)
	elseif op == "scale" then
		add("scale", t, string.format("--replicas=%d", r.replicas :: number))
	elseif op == "label" or op == "annotate" then
		add(op, t)
		addAll(r.edits)
		if r.overwrite then
			add("--overwrite")
		end
	else
		add("patch", t, "--type=" .. (r.patchType or M.defaultPatchType(r)), "-p", trim(r.patch :: string))
	end
	if r.namespace then
		add("-n", r.namespace :: string)
	end
	return argv
end

-- A drain request's --timeout in milliseconds (the block refuses a native
-- drain that could outlive its execute timeout).
function M.drainTimeoutMs(r: Request): number?
	for _, w in (r.drainFlags or {}) :: { string } do
		local v = string.match(w, "^%-%-timeout=(.*)$")
		if v then
			return M.durationMs(v)
		end
	end
	return nil
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

-- Input ------------------------------------------------------------------------

local DRAIN_HINT = "--ignore-daemonsets --delete-emptydir-data --force --disable-eviction "
	.. "--grace-period=N --timeout=DURATION --pod-selector=SELECTOR --skip-wait-for-delete-timeout=N"

function M.prompt(r: Request): Prompt
	local t = target(r)
	local op = r.op
	if op == "apply" then
		return {
			text = "Apply a file or directory relative to " .. (r.cwd or "/"),
			hint = "path; -k DIR for a kustomization, -R to recurse",
			prefill = "",
		}
	elseif op == "scale" then
		return { text = "Scale " .. t .. " to how many replicas?", hint = "digits", prefill = "" }
	elseif op == "label" then
		return {
			text = "Labels for " .. t .. ": KEY=VALUE sets, KEY- removes; add --overwrite to change values",
			hint = "KEY=VALUE KEY- --overwrite",
			prefill = "",
		}
	elseif op == "annotate" then
		return {
			text = "Annotations for " .. t .. ": KEY=VALUE sets, KEY- removes; add --overwrite to change values",
			hint = "KEY=VALUE (quote values with spaces) KEY- --overwrite",
			prefill = "",
		}
	elseif op == "patch" then
		return {
			text = "Patch for " .. t .. ": [--type=strategic|merge|json] JSON",
			hint = "--type=strategic|merge|json, then the JSON patch",
			prefill = "--type=" .. M.defaultPatchType(r) .. " ",
		}
	elseif op == "drain" then
		return { text = "Drain node " .. (r.name or "") .. " with:", hint = DRAIN_HINT, prefill = M.DRAIN_PREFILL }
	end
	return { text = "", hint = "", prefill = "" }
end

-- Shell-like words: whitespace separates, '...' and "..." quote (inside
-- double quotes, \" and \\ escape). No expansion of any kind.
function M.words(text: string): ({ string }?, string?)
	local out: { string } = {}
	local i, n = 1, #text
	while true do
		while i <= n and string.find(string.sub(text, i, i), "^%s") do
			i += 1
		end
		if i > n then
			break
		end
		local buf: { string } = {}
		while i <= n do
			local c = string.sub(text, i, i)
			if string.find(c, "^%s") then
				break
			elseif c == "'" then
				local close = string.find(text, "'", i + 1, true)
				if close == nil then
					return nil, "unterminated ' quote"
				end
				table.insert(buf, string.sub(text, i + 1, close - 1))
				i = close + 1
			elseif c == '"' then
				local j = i + 1
				while true do
					if j > n then
						return nil, 'unterminated " quote'
					end
					local d = string.sub(text, j, j)
					local e = string.sub(text, j + 1, j + 1)
					if d == "\\" and (e == '"' or e == "\\") then
						table.insert(buf, e)
						j += 2
					elseif d == '"' then
						break
					else
						table.insert(buf, d)
						j += 1
					end
				end
				i = j + 1
			else
				table.insert(buf, c)
				i += 1
			end
		end
		table.insert(out, table.concat(buf))
	end
	return out, nil
end

-- The inverse of words() for one word.
local function quoteWord(w: string): string
	if w ~= "" and not string.find(w, "[%s'\"\\]") then
		return w
	elseif not string.find(w, "'", 1, true) then
		return "'" .. w .. "'"
	end
	return '"' .. (string.gsub(w, '[\\"]', "\\%0")) .. '"'
end

local function joinWords(words: { string }): string
	local out: { string } = table.create(#words)
	for i, w in words do
		out[i] = quoteWord(w)
	end
	return table.concat(out, " ")
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
local function withPath(r: Request, input: string, home: string?): (Request?, string?)
	local rest = trim(input)
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
	return out, nil
end

local function withEdits(r: Request, input: string): (Request?, string?)
	local words, e = M.words(input)
	if words == nil then
		return nil, e
	end
	local edits: { string } = {}
	local overwrite = false
	for _, w in words do
		if w == "--overwrite" then
			overwrite = true
		elseif string.sub(w, 1, 1) == "-" then
			return nil, w .. " is not accepted here; only --overwrite"
		else
			table.insert(edits, w)
		end
	end
	local out = table.clone(r)
	out.edits = edits
	out.overwrite = overwrite
	return out, checkEdits(r.op, edits)
end

local function withPatch(r: Request, input: string): (Request?, string?)
	local rest = trim(input)
	local patchType: PatchType? = nil
	local typed, after = string.match(rest, "^%-%-type=(%S*)%s*(.*)$")
	if typed then
		patchType = PATCH_TYPES[typed :: string]
		if patchType == nil then
			return nil, "--type must be strategic, merge or json"
		end
		rest = after :: string
	end
	if rest == "" then
		return nil, 'Enter the patch as JSON, e.g. {"metadata":{"labels":{"a":"b"}}}'
	end
	local e = checkPatch(rest)
	if e then
		return nil, e
	end
	local pt: PatchType = patchType or M.defaultPatchType(r)
	if pt == "json" and string.sub(rest, 1, 1) ~= "[" then
		return nil, "--type=json takes a JSON array of operations"
	end
	local out = table.clone(r)
	out.patch = rest
	out.patchType = pt
	return out, nil
end

local function withDrain(r: Request, input: string): (Request?, string?)
	local words, e = M.words(input)
	if words == nil then
		return nil, e
	end
	local de = checkDrain(words)
	if de then
		return nil, de
	end
	table.sort(words, function(a: string, b: string): boolean
		return DRAIN_RANK[(drainFlagName(a)) :: string] < DRAIN_RANK[(drainFlagName(b)) :: string]
	end)
	local out = table.clone(r)
	out.drainFlags = words
	return out, nil
end

-- Validates what the user typed at the block's prompt into structured
-- fields; the result encodes (so argv() can rebuild the command from it).
function M.withInput(r: Request, text: string, home: string?): (Request?, string?)
	local out: Request?, e: string?
	if r.op == "apply" then
		out, e = withPath(r, text, home)
	elseif r.op == "scale" then
		local digits = string.match(text, "^%s*(%d+)%s*$")
		local n = if digits and #digits <= 6 then tonumber(digits) else nil
		if n == nil or n > M.MAX_REPLICAS then
			return nil, "Enter a whole number of replicas"
		end
		local scaled = table.clone(r)
		scaled.replicas = n
		out = scaled
	elseif r.op == "label" or r.op == "annotate" then
		out, e = withEdits(r, text)
	elseif r.op == "patch" then
		out, e = withPatch(r, text)
	elseif r.op == "drain" then
		out, e = withDrain(r, text)
	else
		return nil, r.op .. " takes no input"
	end
	if out == nil or e then
		return nil, e
	end
	local _, ve = M.encode(out)
	if ve then
		return nil, ve
	end
	return out, nil
end

-- The accepted input as the user would type it (back to the prompt keeps
-- it); the prompt's prefill while there is none.
function M.inputText(r: Request): string
	if M.needsInput(r) then
		return M.prompt(r).prefill
	end
	local op = r.op
	if op == "scale" then
		return string.format("%d", r.replicas :: number)
	elseif op == "apply" then
		if r.kustomize then
			return "-k " .. (r.kustomize :: string)
		end
		return (r.file :: string) .. (if r.recursive then " -R" else "")
	elseif op == "label" or op == "annotate" then
		local words = table.clone(r.edits :: { string })
		if r.overwrite then
			table.insert(words, "--overwrite")
		end
		return joinWords(words)
	elseif op == "patch" then
		return "--type=" .. (r.patchType or M.defaultPatchType(r)) .. " " .. (r.patch :: string)
	elseif op == "drain" then
		return joinWords(r.drainFlags :: { string })
	end
	return ""
end

-- Shortcuts (Explore keys, lens chips) -----------------------------------------

-- Where a shortcut's object was seen: the context it came from and how that
-- context was decided, plus the kubeconfig.
export type Origin = { context: string?, source: Source?, kubeconfig: string? }

-- What the row or object says about the target; nil fields are unknown.
export type ObjState = { paused: boolean?, unschedulable: boolean? }

export type Chip = { op: Op, label: string, key: string, url: string, title: string }

local SHORTCUTS: { { op: Op, label: string, key: string } } = {
	{ op = "delete", label = "Delete", key = "ctrl+d" },
	{ op = "restart", label = "Restart", key = "ctrl+r" },
	{ op = "scale", label = "Scale", key = "shift+s" },
	{ op = "undo", label = "Undo", key = "U" },
	{ op = "pause", label = "Pause", key = "p" },
	{ op = "resume", label = "Resume", key = "P" },
	{ op = "cordon", label = "Cordon", key = "C" },
	{ op = "uncordon", label = "Uncordon", key = "u" },
	{ op = "drain", label = "Drain", key = "D" },
	{ op = "label", label = "Label", key = "t" },
	{ op = "annotate", label = "Annotate", key = "T" },
	{ op = "patch", label = "Patch", key = "X" },
}

local ASKS: { [string]: string } = {
	scale = "Asks for the replica count, then previews",
	label = "Asks for the labels, then previews",
	annotate = "Asks for the annotations, then previews",
	patch = "Asks for the patch, then previews",
	drain = "Asks for the drain options, then previews the evictions",
}

-- Events are records, not objects anyone labels or patches.
local NO_METADATA_OPS: { [string]: boolean } = { Event = true }

local function offered(op: Op, ref: Types.ResourceRef, state: ObjState?): boolean
	local st: ObjState = state or {}
	if op == "pause" then
		return st.paused ~= true
	elseif op == "resume" then
		return st.paused ~= false
	elseif op == "cordon" then
		return st.unschedulable ~= true
	elseif op == "uncordon" then
		return st.unschedulable ~= false
	elseif op == "label" or op == "annotate" or op == "patch" then
		return not NO_METADATA_OPS[ref.kind]
	end
	return true
end

-- A link for `op` on one object; nil (with the reason) when the op does not
-- apply to its kind. Input ops carry no input: the block asks.
function M.forRef(op: Op, ref: Types.ResourceRef, origin: Origin): (string?, string?)
	local node = op == "cordon" or op == "uncordon" or op == "drain"
	return M.encode({
		op = op,
		kind = Command.resourceType(ref),
		name = ref.name,
		namespace = if ref.namespace ~= "" and not node then ref.namespace else nil,
		recursive = false,
		overwrite = false,
		context = origin.context,
		source = if origin.context then origin.source else nil,
		kubeconfig = origin.kubeconfig,
	})
end

-- One chip per op that applies to the object's kind (and, when known, its
-- state: Pause or Resume, Cordon or Uncordon); each opens the approve
-- block, which previews first.
function M.chips(ref: Types.ResourceRef, origin: Origin, state: ObjState?): { Chip }
	local out: { Chip } = {}
	for _, s in SHORTCUTS do
		if not offered(s.op, ref, state) then
			continue
		end
		local url = M.forRef(s.op, ref, origin)
		local req = if url then M.decode(url) else nil
		if url and req then
			local argv = M.argv(req, "kubectl")
			local title = if argv
				then "Preview, then confirm: " .. Command.format(argv)
				else ASKS[s.op] or "Asks for input, then previews"
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
