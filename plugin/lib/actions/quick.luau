--!strict
-- Quick actions: one key in Explore / two clicks in the lens open a new
-- split running a visible kubectl command (shell, follow logs,
-- port-forward, and the mutating debug/cronjob ones that M3 gates).
--
-- They travel as `kube-lens://act/<action>?<params>` links to the window's
-- route.link. The window never runs text taken from a URL: decode()
-- validates every field against a strict per-action schema and command()
-- rebuilds the command line from those fields with POSIX quoting.
--
-- Tern runs a Launch command as `$SHELL -l -c <line>` (login rc files only,
-- not .zshrc/.bashrc), so the line is a single `sh -c '<script>'`: it
-- behaves the same under zsh, bash and fish, sets the pane title to the
-- target, echoes the effective context when it is not pinned, and execs
-- kubectl so its exit status is the pane's.

local Command = require("../kubectl/command")
local Types = require("../model/types")

type Ref = Types.ResourceRef

export type ActionId = "shell" | "logs-follow" | "port-forward" | "debug-pod" | "debug-node" | "cronjob-run"

export type Action = {
	id: ActionId,
	label: string,
	-- Explore key (k9s-compatible); nil when the action has none.
	key: string?,
	mutates: boolean,
}

-- Extra fields (Explore's contextSource, namespace, ...) are ignored. A
-- present context is pinned with --context; `program` never travels in a URL.
export type Target = { kubeconfig: string?, context: string?, program: string? }

export type Info = {
	source: ("lens" | "explore")?,
	-- A ready pod of the workload, resolved by Explore (enables shell).
	pod: string?,
	-- The workload's label selector (logs from every pod).
	selector: string?,
	-- Declared ports; the first one is forwarded.
	ports: { number }?,
	-- The M3 confirm tier exists; until then mutating actions are not offered.
	allowMutations: boolean?,
}

export type Opts = {
	container: string?,
	pod: string?,
	selector: string?,
	port: number?,
	localPort: number?,
	image: string?,
	suffix: string?,
	confirm: string?,
}

-- Local quick_actions config; nil or invalid fields keep the defaults.
export type Settings = { shellCommand: { string }?, logsTail: number?, debugImage: string? }

export type Request = { action: ActionId, target: Target, ref: Ref, opts: Opts }

export type Launch = {
	-- The kubectl invocation the line ends in (for display and copying).
	-- Port-forward without a known port resolves it at run time: its last
	-- word is then the shell expression `$l:$p`.
	argv: { string },
	-- What the split runs.
	line: string,
	title: string,
}

export type Placement = { how: "split", dir: "right" | "down" } | { how: "tab" }

local M = {}

M.SCHEME = "kube-lens://act/"
M.DEFAULT_IMAGE = "busybox:1.36"
M.TAIL = "200"
M.MAX_LOG_REQUESTS = "10"

local KINDS: { [string]: { token: string, group: string, namespaced: boolean } } = {
	Pod = { token = "pod", group = "", namespaced = true },
	Deployment = { token = "deployment", group = "apps", namespaced = true },
	StatefulSet = { token = "statefulset", group = "apps", namespaced = true },
	DaemonSet = { token = "daemonset", group = "apps", namespaced = true },
	ReplicaSet = { token = "replicaset", group = "apps", namespaced = true },
	Job = { token = "job", group = "batch", namespaced = true },
	CronJob = { token = "cronjob", group = "batch", namespaced = true },
	Service = { token = "service", group = "", namespaced = true },
	Node = { token = "node", group = "", namespaced = false },
}

local function set(list: { string }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, v in list do
		out[v] = true
	end
	return out
end

type Spec = {
	label: string,
	key: string?,
	mutates: boolean,
	kinds: { [string]: boolean },
	-- Parameters beyond kind/name/namespace/context/kubeconfig.
	params: { [string]: boolean },
}

local SPECS: { [string]: Spec } = {
	shell = {
		label = "Shell",
		key = "s",
		mutates = false,
		kinds = set({ "Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job" }),
		params = set({ "container", "pod" }),
	},
	["logs-follow"] = {
		label = "Logs",
		key = "l",
		mutates = false,
		kinds = set({ "Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job" }),
		params = set({ "container", "selector" }),
	},
	["port-forward"] = {
		label = "Port-forward",
		key = "shift+f",
		mutates = false,
		kinds = set({ "Pod", "Service", "Deployment" }),
		params = set({ "port", "local" }),
	},
	["debug-pod"] = {
		label = "Debug",
		key = nil,
		mutates = true,
		kinds = set({ "Pod" }),
		params = set({ "container", "image", "confirm" }),
	},
	["debug-node"] = {
		label = "Debug node",
		key = nil,
		mutates = true,
		kinds = set({ "Node" }),
		params = set({ "image", "confirm" }),
	},
	["cronjob-run"] = {
		label = "Run now",
		key = nil,
		mutates = true,
		kinds = set({ "CronJob" }),
		params = set({ "suffix", "confirm" }),
	},
}

local ORDER: { ActionId } = { "shell", "logs-follow", "port-forward", "debug-pod", "debug-node", "cronjob-run" }
M.ORDER = ORDER

-- URL parameter order; also the full set any action may carry.
local FIELDS = {
	"kind",
	"name",
	"namespace",
	"container",
	"pod",
	"selector",
	"port",
	"local",
	"image",
	"suffix",
	"context",
	"kubeconfig",
	"confirm",
}
local COMMON = set({ "kind", "name", "namespace", "context", "kubeconfig" })

-- Validation ------------------------------------------------------------------

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
	if #s > 253 or string.find(s, "^[a-z0-9][a-z0-9%-%.]*$") == nil or string.find(s, "[a-z0-9]$") == nil then
		return false
	end
	if string.find(s, "..", 1, true) then
		return false
	end
	for part in string.gmatch(s, "[^.]+") do
		if not dnsLabel(part) then
			return false
		end
	end
	return true
end

local function portNumber(s: string): number?
	if string.find(s, "^[1-9]%d?%d?%d?%d?$") == nil then
		return nil
	end
	local n = tonumber(s) :: number
	return if n <= 65535 then n else nil
end

-- Validators return an error message or nil.
local CHECKS: { [string]: (string) -> string? } = {
	name = function(v)
		return if dnsSubdomain(v) then nil else "name must be a DNS-1123 subdomain"
	end,
	namespace = function(v)
		return if #v <= 63 and dnsLabel(v) then nil else "namespace must be a DNS-1123 label"
	end,
	container = function(v)
		return if #v <= 63 and dnsLabel(v) then nil else "container must be a DNS-1123 label"
	end,
	pod = function(v)
		return if dnsSubdomain(v) then nil else "pod must be a DNS-1123 subdomain"
	end,
	selector = function(v)
		return if #v <= 1024 and string.find(v, "^[%w%-_%./=!, ()]+$") ~= nil
			then nil
			else "selector has characters outside a label selector"
	end,
	port = function(v)
		return if portNumber(v) then nil else "port must be 1-65535"
	end,
	["local"] = function(v)
		return if portNumber(v) then nil else "local port must be 1-65535"
	end,
	image = function(v)
		return if #v <= 255 and string.find(v, "^[%w][%w%._/:@%-]*$") ~= nil
			then nil
			else "image is not an image reference"
	end,
	suffix = function(v)
		return if #v <= 12 and string.find(v, "^[a-z0-9]+$") ~= nil then nil else "suffix must be 1-12 of [a-z0-9]"
	end,
	context = function(v)
		return if #v <= 253
				and noControl(v)
				and string.sub(v, 1, 1) ~= "-"
			then nil
			else "context must be printable, at most 253 bytes, not starting with -"
	end,
	kubeconfig = function(v)
		if #v > 4096 or not noControl(v) then
			return "kubeconfig must be a printable path"
		end
		local first = string.sub(v, 1, 1)
		if first == "-" or first == "~" then
			return "kubeconfig must be an absolute or relative path (no ~ or leading -)"
		end
		return nil
	end,
	confirm = function(v)
		return if #v <= 128 and string.find(v, "^[%w%-_]+$") ~= nil then nil else "confirm token is malformed"
	end,
}

local function fieldsOf(target: Target, ref: Ref, opts: Opts): { [string]: string }
	local f: { [string]: string } = {}
	local function put(k: string, v: any)
		if v ~= nil and v ~= "" then
			f[k] = if type(v) == "number"
					and v == math.floor(v)
					and math.abs(v) < 1e9
				then string.format("%d", v)
				else tostring(v)
		end
	end
	put("kind", ref.kind)
	put("name", ref.name)
	put("namespace", ref.namespace)
	put("container", opts.container)
	put("pod", opts.pod)
	put("selector", opts.selector)
	put("port", opts.port)
	put("local", opts.localPort)
	put("image", opts.image)
	put("suffix", opts.suffix)
	put("context", target.context)
	put("kubeconfig", target.kubeconfig)
	put("confirm", opts.confirm)
	return f
end

-- Checks a field set for `action`; returns the validated request or an error.
local function validate(action: string, f: { [string]: string }, group: string?): (Request?, string?)
	local spec = SPECS[action :: ActionId]
	if spec == nil then
		return nil, "unknown action " .. string.format("%q", action)
	end
	for k, v in f do
		if not COMMON[k] and not spec.params[k] then
			return nil, string.format("%s does not take %s", action, k)
		end
		if not noControl(v) then
			return nil, k .. " contains control characters"
		end
		local check = CHECKS[k]
		if check then
			local err = check(v)
			if err then
				return nil, err
			end
		end
	end
	local kind = f.kind
	if kind == nil or f.name == nil then
		return nil, action .. " needs kind and name"
	end
	local info = KINDS[kind]
	if info == nil or not spec.kinds[kind] then
		return nil, string.format("%s does not apply to %s", action, kind)
	end
	if group ~= nil and group ~= "" and group ~= info.group then
		return nil, string.format("%s does not apply to %s.%s", action, kind, group)
	end
	if not info.namespaced and f.namespace then
		return nil, kind .. " is not namespaced"
	end
	if action == "shell" then
		if kind == "Pod" and f.pod then
			return nil, "shell on a Pod takes no pod parameter"
		elseif kind ~= "Pod" and f.pod == nil then
			return nil, "shell on a " .. kind .. " needs a ready pod"
		end
	elseif action == "logs-follow" and kind == "Pod" and f.selector then
		return nil, "logs of a Pod take no selector"
	elseif action == "port-forward" and f["local"] and f.port == nil then
		return nil, "a local port needs a port"
	elseif action == "cronjob-run" then
		if f.suffix == nil then
			return nil, "cronjob-run needs a suffix"
		elseif #f.name + #"-manual-" + #f.suffix > 63 then
			return nil, "job name would exceed 63 characters"
		end
	end
	return {
		action = action :: ActionId,
		target = { context = f.context, kubeconfig = f.kubeconfig },
		ref = {
			kind = kind,
			group = if info.group == "" then nil else info.group,
			name = f.name,
			namespace = f.namespace,
			source = "live",
		},
		opts = {
			container = f.container,
			pod = f.pod,
			selector = f.selector,
			port = if f.port then portNumber(f.port) else nil,
			localPort = if f["local"] then portNumber(f["local"]) else nil,
			image = f.image,
			suffix = f.suffix,
			confirm = f.confirm,
		},
	},
		nil
end

-- Public API ------------------------------------------------------------------

function M.spec(action: string): Action?
	local spec = SPECS[action :: ActionId]
	if spec == nil then
		return nil
	end
	return { id = action :: ActionId, label = spec.label, key = spec.key, mutates = spec.mutates }
end

function M.mutates(action: string): boolean
	local spec = SPECS[action :: ActionId]
	return spec ~= nil and spec.mutates
end

-- Local port for a remote one: the same when unprivileged, else 8000+port.
function M.localPort(port: number): number
	return if port > 1024 then port else 8000 + port
end

-- Actions offered for a resource. Mutating ones need info.allowMutations
-- (the M3 confirm tier); workload shells need a resolved ready pod.
function M.available(kind: string, ref: Ref?, info: Info?): { Action }
	local i: Info = info or {}
	local k = KINDS[kind]
	if k == nil then
		return {}
	end
	if ref and ref.group and ref.group ~= "" and ref.group ~= k.group then
		return {}
	end
	local out: { Action } = {}
	for _, id in ORDER do
		local spec = SPECS[id]
		local ok: boolean = spec.kinds[kind] == true and (not spec.mutates or i.allowMutations == true)
		if ok and id == "shell" and kind ~= "Pod" then
			ok = i.pod ~= nil and i.pod ~= ""
		end
		if ok then
			table.insert(out, M.spec(id) :: Action)
		end
	end
	return out
end

function M.encode(action: string, target: Target, ref: Ref, opts: Opts?): (string?, string?)
	local f = fieldsOf(target, ref, opts or {})
	local _, err = validate(action, f, ref.group)
	if err then
		return nil, err
	end
	local parts: { string } = {}
	for _, k in FIELDS do
		local v = f[k]
		if v then
			table.insert(parts, k .. "=" .. Command.urlencode(v))
		end
	end
	return M.SCHEME .. action .. "?" .. table.concat(parts, "&"), nil
end

function M.decode(url: string): (Request?, string?)
	if string.sub(url, 1, #M.SCHEME) ~= M.SCHEME then
		return nil, "not a kube-lens://act/ link"
	end
	local action, query = string.match(string.sub(url, #M.SCHEME + 1), "^([a-z%-]+)%?(.+)$")
	if action == nil or query == nil then
		return nil, "malformed quick action link"
	end
	if string.find(query, "[^%w%-_%.~%%=&]") then
		return nil, "link has unencoded characters"
	end
	if string.find((string.gsub(query, "%%%x%x", "")), "%%") then
		return nil, "link has a malformed escape"
	end
	local f: { [string]: string } = {}
	for pair in string.gmatch(query, "[^&]*") do
		if pair ~= "" then
			local k, v = string.match(pair, "^([a-z]+)=(.+)$")
			if k == nil or v == nil then
				return nil, "malformed parameter " .. string.format("%q", pair)
			end
			if f[k] then
				return nil, "duplicate parameter " .. k
			end
			f[k] = Command.urldecode(v)
		end
	end
	return validate(action, f, nil)
end

local function connection(target: Target): { string }
	local out: { string } = {}
	if target.kubeconfig and target.kubeconfig ~= "" then
		table.insert(out, "--kubeconfig")
		table.insert(out, target.kubeconfig)
	end
	if target.context and target.context ~= "" then
		table.insert(out, "--context")
		table.insert(out, target.context)
	end
	return out
end

local function append(argv: { string }, words: { string })
	for _, w in words do
		table.insert(argv, w)
	end
end

local DEFAULT_SHELL: { string } = { "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh" }

local function shellWords(words: { string }?): { string }
	if words == nil or #words == 0 then
		return DEFAULT_SHELL
	end
	for _, w in words do
		if type(w) ~= "string" or not noControl(w) then
			return DEFAULT_SHELL
		end
	end
	return words
end

local function tailOf(n: number?): string
	if type(n) == "number" and n >= 1 and n == math.floor(n) and n < 1e9 then
		return string.format("%d", n)
	end
	return M.TAIL
end

local function imageOf(opts: Opts, settings: Settings): string
	if opts.image then
		return opts.image
	end
	local img = settings.debugImage
	if type(img) == "string" and CHECKS.image(img) == nil then
		return img
	end
	return M.DEFAULT_IMAGE
end

local PORT_PATHS: { [string]: string } = {
	Pod = "{.spec.containers[*].ports[*].containerPort}",
	Deployment = "{.spec.template.spec.containers[*].ports[*].containerPort}",
	Service = "{.spec.ports[*].port}",
}

-- The command a validated request runs. Validation is repeated so a caller
-- cannot skip decode().
function M.command(action: string, target: Target, ref: Ref, opts: Opts?, settings: Settings?): (Launch?, string?)
	local o: Opts = opts or {}
	local s: Settings = settings or {}
	local req, err = validate(action, fieldsOf(target, ref, o), ref.group)
	if req == nil then
		return nil, err
	end
	local r = req.ref
	o = req.opts
	local program = if target.program and target.program ~= "" then target.program else "kubectl"
	local conn = connection(req.target)
	local ns: { string } = if r.namespace then { "-n", r.namespace } else {}
	local typed = KINDS[r.kind].token .. "/" .. r.name
	local where = (if r.namespace then r.namespace .. "/" else "") .. r.name
	local argv: { string } = { program }
	local pre: { string } = {}
	local post: { string } = {}
	local title: string

	if action == "shell" then
		append(argv, { "exec", "-it" })
		append(argv, conn)
		append(argv, ns)
		local pod = o.pod or r.name
		table.insert(argv, pod)
		if o.container then
			append(argv, { "-c", o.container })
		end
		table.insert(argv, "--")
		append(argv, shellWords(s.shellCommand))
		where = (if r.namespace then r.namespace .. "/" else "")
			.. pod
			.. (if o.container then ":" .. o.container else "")
		title = "shell " .. where
	elseif action == "logs-follow" then
		append(argv, { "logs", "-f", "--tail=" .. tailOf(s.logsTail) })
		append(argv, conn)
		append(argv, ns)
		if r.kind == "Pod" then
			table.insert(argv, r.name)
			if o.container then
				append(argv, { "-c", o.container })
			else
				append(argv, { "--all-containers", "--prefix" })
			end
		elseif o.selector then
			append(argv, { "-l", o.selector, "--prefix", "--max-log-requests=" .. M.MAX_LOG_REQUESTS })
			if o.container then
				append(argv, { "-c", o.container })
			else
				table.insert(argv, "--all-containers")
			end
		else
			table.insert(argv, typed)
			if o.container then
				append(argv, { "-c", o.container })
			end
		end
		title = "logs " .. KINDS[r.kind].token .. " " .. where
	elseif action == "port-forward" then
		append(argv, { "port-forward" })
		append(argv, conn)
		append(argv, ns)
		table.insert(argv, typed)
		if o.port then
			table.insert(argv, string.format("%d:%d", o.localPort or M.localPort(o.port), o.port))
			title = string.format("port-forward %s %d", where, o.port)
		else
			local get = { program, "get" }
			append(get, conn)
			append(get, ns)
			append(get, { typed, "-o", "jsonpath=" .. PORT_PATHS[r.kind] })
			table.insert(pre, "set -- $(" .. Command.format(get) .. ")")
			table.insert(
				pre,
				"p=${1:-}; case $p in ''|*[!0-9]*) printf 'kube-lens: %s declares no port\\n' "
					.. Command.quote(typed)
					.. " >&2; exit 1;; esac"
			)
			table.insert(pre, 'if [ "$p" -gt 1024 ]; then l=$p; else l=$((8000 + p)); fi')
			table.insert(pre, 'printf \'kube-lens: forwarding localhost:%s -> %s\\n\' "$l" "$p"')
			table.insert(argv, "$l:$p")
			title = "port-forward " .. where
		end
	elseif action == "debug-pod" then
		append(argv, { "debug", "-it" })
		append(argv, conn)
		append(argv, ns)
		append(argv, { r.name, "--image=" .. imageOf(o, s) })
		if o.container then
			table.insert(argv, "--target=" .. o.container)
		end
		title = "debug " .. where
	elseif action == "debug-node" then
		append(argv, { "debug", "-it" })
		append(argv, conn)
		append(argv, { typed, "--image=" .. imageOf(o, s) })
		title = "debug node/" .. r.name
	else
		append(argv, { "create", "job" })
		append(argv, conn)
		append(argv, ns)
		append(argv, { r.name .. "-manual-" .. (o.suffix :: string), "--from=" .. typed })
		title = "run cronjob " .. where
		table.insert(post, "s=$?")
		table.insert(post, "printf '\\nkube-lens: exit %s; press Enter to close\\n' \"$s\"")
		table.insert(post, "read -r _")
		table.insert(post, 'exit "$s"')
	end

	local ctx = req.target.context
	title = "kube-lens " .. title .. " @ " .. (ctx or "current context")

	local script: { string } = { "printf '\\033]0;%s\\007' " .. Command.quote(title) }
	if ctx == nil then
		local current = { program }
		append(current, connection({ kubeconfig = req.target.kubeconfig }))
		append(current, { "config", "current-context" })
		table.insert(script, "printf 'kube-lens: context %s\\n' \"$(" .. Command.format(current) .. ')"')
	end
	append(script, pre)
	local run = Command.format(argv)
	if action == "port-forward" and o.port == nil then
		run = string.gsub(run, "'%$l:%$p'$", '"$l:$p"')
	end
	if #post > 0 then
		table.insert(script, run)
		append(script, post)
	else
		table.insert(script, "exec " .. run)
	end
	return { argv = argv, line = "sh -c " .. Command.quote(table.concat(script, "; ")), title = title }, nil
end

-- Placement from config `quick_actions.placement`; anything else is the
-- default split to the right.
function M.placement(value: any): Placement
	if value == "down" then
		return { how = "split", dir = "down" }
	elseif value == "tab" then
		return { how = "tab" }
	end
	return { how = "split", dir = "right" }
end

export type Chip = { label: string, url: string, title: string }

-- Pointer chips for a resource: one per available action whose link
-- validates. Mutating actions follow available() (hidden until M3).
function M.chipsFor(kind: string, ref: Ref, target: Target, info: Info?, settings: Settings?): { Chip }
	local i: Info = info or {}
	local opts: Opts = {
		pod = i.pod,
		selector = i.selector,
		port = if i.ports then i.ports[1] else nil,
	}
	local out: { Chip } = {}
	for _, a in M.available(kind, ref, i) do
		local o: Opts = {}
		if a.id == "shell" and kind ~= "Pod" then
			o.pod = opts.pod
		elseif a.id == "logs-follow" and kind ~= "Pod" then
			o.selector = opts.selector
		elseif a.id == "port-forward" then
			o.port = opts.port
		end
		local url = M.encode(a.id, target, ref, o)
		local launch = if url then M.command(a.id, target, ref, o, settings) else nil
		if url and launch then
			table.insert(out, {
				label = a.label,
				url = url,
				title = "Opens a new split running: " .. Command.format(launch.argv),
			})
		end
	end
	return out
end

return M
