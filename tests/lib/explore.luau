--!strict
-- A fake kubectl for Explore specs: answers the argv Explore builds from the
-- real JSON fixtures captured from the kind cluster (tests/fixtures/real/
-- json-world), and drives init/update until no process is left running.
-- Single-object `get` answers are fixture objects handed over by reference:
-- stdout carries a token that the injected decoder resolves.

local Config = require("../../plugin/lib/config")
local State = require("../../plugin/lib/explore/state")
local fixtures = require("./fixtures")
local json = require("./json")

type State = State.State
type Effect = State.Effect
type Msg = State.Msg
export type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Responder = (argv: { string }) -> (Result?, string?)

local M = {}

M.CTX = "kind-tern-kube-dev"
M.NS = "tern-test-apps"
M.AT = 1000

local tokens: { [string]: any } = {}

function M.decode(text: string): any
	local obj = tokens[text]
	if obj ~= nil then
		return obj
	end
	return json.decode(text)
end

function M.config(text: string?): Config.Config
	local cfg = Config.parse(text, json.decode)
	return cfg
end

-- The last Explore used the context default namespace of M.CTX, so a fresh
-- block starts there (a first-ever block starts in all namespaces).
function M.env(): State.Env
	return {
		kubeconfig = nil,
		home = "/home/u",
		kubectl = "kubectl",
		decode = M.decode,
		now = M.AT,
		lastScope = { context = M.CTX, namespace = nil, all = false },
	}
end

local function ok(stdout: string): Result
	return { status = 0, stdout = stdout, stderr = "", timed_out = false }
end

function M.fail(status: number, stderr: string): Result
	return { status = status, stdout = "", stderr = stderr, timed_out = false }
end

local DIRS: { [string]: string } = {
	["tern-test-apps"] = "ns-apps",
	["tern-test-batch"] = "ns-batch",
	["tern-test-edge"] = "ns-edge",
	["tern-test-crd"] = "ns-crd",
	["tern-test-empty"] = "ns-empty",
}

local function flag(argv: { string }, name: string): string?
	local i = table.find(argv, name)
	return if i then argv[i + 1] else nil
end

local function has(argv: { string }, word: string): boolean
	return table.find(argv, word) ~= nil
end

-- Words after the global flags: verb and its positionals.
local function command(argv: { string }): { string }
	local out: { string } = {}
	local i = 2
	while i <= #argv do
		local a = argv[i]
		if a == "--kubeconfig" or a == "--context" or a == "-n" or a == "-o" or a == "-l" or a == "-c" then
			i += 2
		elseif string.sub(a, 1, 1) == "-" then
			i += 1
		else
			table.insert(out, a)
			i += 1
		end
	end
	return out
end

local PLURAL: { [string]: string } = {
	pod = "pods",
	["deployment.apps"] = "deployments",
	["replicaset.apps"] = "replicasets",
	["statefulset.apps"] = "statefulsets",
	["daemonset.apps"] = "daemonsets",
	service = "services",
	["job.batch"] = "jobs",
	["cronjob.batch"] = "cronjobs",
	node = "nodes",
}

local function listFixture(resource: string, ns: string?): string?
	local plural = PLURAL[resource] or string.match(resource, "^([^.]+)") or resource
	local path: string
	if plural == "nodes" then
		path = "real/json-world/cluster/get_nodes_-o_json.txt"
	else
		local dir = DIRS[ns or M.NS]
		if dir == nil then
			return nil
		end
		path = "real/json-world/" .. dir .. "/get_" .. plural .. "_-o_json.txt"
	end
	if not fixtures.has(path) then
		if ns == "tern-test-empty" then
			return '{"apiVersion":"v1","items":[],"kind":"List","metadata":{"resourceVersion":""}}'
		end
		return nil
	end
	return fixtures.read(path)
end

function M.objectToken(resource: string, name: string, ns: string?): string?
	local text = listFixture(resource, ns)
	if text == nil then
		return nil
	end
	local doc = json.decode(text)
	for _, item in doc.items do
		if item.metadata.name == name then
			local token = "@obj:" .. resource .. "/" .. (ns or "") .. "/" .. name
			tokens[token] = item
			return token
		end
	end
	return nil
end

-- Hands `value` over as kubectl stdout: M.decode resolves the token.
function M.token(name: string, value: any): string
	tokens[name] = value
	return name
end

-- The default world: two contexts, current-context = M.CTX.
function M.responder(argv: { string }): (Result?, string?)
	local cmd = command(argv)
	local verb = cmd[1]
	local ns = flag(argv, "-n")
	if verb == "config" and cmd[2] == "get-contexts" then
		return ok(M.CTX .. "\nother\n")
	elseif verb == "config" and cmd[2] == "current-context" then
		return ok(M.CTX .. "\n")
	elseif verb == "api-resources" then
		-- Explore's discovery argv as captured (`--verbs=list -o wide`).
		return ok(fixtures.read("kubectl/discovery/verbs-list-wide.out"))
	elseif verb == "get" and cmd[2] == "namespaces" then
		return ok("namespace/default\nnamespace/tern-test-apps\nnamespace/tern-test-empty\n")
	elseif verb == "describe" then
		return ok(
			"Name:         " .. (cmd[3] or "?") .. "\nNamespace:    " .. (ns or "") .. "\nStatus:       Running\n"
		)
	elseif verb == "logs" then
		return M.logs(argv)
	elseif verb == "get" and cmd[2] == "events" then
		if ns == M.NS or has(argv, "-A") then
			return ok(fixtures.read("real/ns-apps/get_events_-o_json.txt"))
		end
		return ok('{"apiVersion":"v1","items":[],"kind":"List","metadata":{"resourceVersion":""}}')
	elseif verb == "get" and cmd[2] and cmd[3] and flag(argv, "-o") == "json" then
		local token = M.objectToken(cmd[2], cmd[3], ns)
		if token then
			return ok(token)
		end
		if has(argv, "--ignore-not-found") then
			return ok("")
		end
		return M.fail(1, "Error from server (NotFound): " .. cmd[2] .. ' "' .. cmd[3] .. '" not found')
	elseif verb == "get" and cmd[2] and flag(argv, "-o") == "json" then
		local text = listFixture(cmd[2], if has(argv, "-A") then M.NS else ns)
		if text == nil then
			return ok('{"apiVersion":"v1","items":[],"kind":"List","metadata":{"resourceVersion":""}}')
		end
		local selector = flag(argv, "-l")
		if selector == nil then
			return ok(text)
		end
		-- Equality selectors only (all the fixtures' workloads use).
		local items: { any } = {}
		for _, item in json.decode(text).items do
			local labels = item.metadata.labels or {}
			local match = true
			for k, v in string.gmatch(selector, "([^,=]+)=([^,]+)") do
				if labels[k] ~= v then
					match = false
				end
			end
			if match then
				table.insert(items, item)
			end
		end
		local token = "@list:" .. table.concat(argv, " ")
		tokens[token] = { apiVersion = "v1", kind = "List", items = items }
		return ok(token)
	elseif verb == "get" and flag(argv, "-o") == "name" then
		return ok("")
	end
	return M.fail(1, "fake kubectl: unhandled " .. table.concat(argv, " "))
end

M.LOGS_POD = "real/ns-logs/logs_tk-logmix-6856789c59-kh4x5_--all-containers_--prefix_--timestamps.txt"
M.LOGS_SELECTOR = "real/ns-logs/logs_-l_app=tk-logmix_--all-containers_--prefix_--timestamps.txt"
M.LOGS_CRASHY = "real/ns-logs/logs_tk-logmix-6856789c59-kh4x5_-p_-c_crashy.txt"

-- `kubectl logs ... --timestamps --prefix` from the tk-logmix captures
-- (app, side and crashy containers), whatever pod Explore names: `-c`
-- keeps one container; `--previous` exists only for crashy.
function M.logs(argv: { string }): (Result?, string?)
	local container = flag(argv, "-c")
	if has(argv, "--previous") then
		if container ~= "crashy" then
			return M.fail(
				1,
				'Error from server (BadRequest): previous terminated container "'
					.. (container or "app")
					.. '" in pod "tk-logmix-6856789c59-kh4x5" not found'
			)
		end
		local out: { string } = {}
		for i, line in fixtures.lines(M.LOGS_CRASHY) do
			table.insert(
				out,
				string.format("[pod/tk-logmix-6856789c59-kh4x5/crashy] 2026-11-02T16:40:%02d.000000000Z %s", i, line)
			)
		end
		return ok(table.concat(out, "\n") .. "\n")
	end
	local text = fixtures.read(if flag(argv, "-l") then M.LOGS_SELECTOR else M.LOGS_POD)
	if container == nil then
		return ok(text)
	end
	local out: { string } = {}
	for _, line in fixtures.toLines(text) do
		if string.find(line, "/" .. container .. "] ", 1, true) then
			table.insert(out, line)
		end
	end
	return ok(table.concat(out, "\n") .. "\n")
end

export type Trace = { runs: { Effect }, effects: { Effect } }

-- Feeds every run effect's answer back until nothing runs. Results come back
-- in effect order (the real order is arbitrary; generations make it safe).
function M.settle(s: State, effects: { Effect }, responder: Responder?, trace: Trace?): (State, Trace)
	local tr: Trace = trace or { runs = {}, effects = {} }
	local respond: Responder = responder or M.responder
	local queue = table.clone(effects)
	local guard = 0
	while #queue > 0 do
		guard += 1
		assert(guard < 500, "settle: too many effects")
		local e = table.remove(queue, 1) :: Effect
		table.insert(tr.effects, e)
		if e.t == "run" then
			table.insert(tr.runs, e)
			local result, spawnError = respond(e.argv :: { string })
			local msg: Msg = {
				t = "result",
				tag = e.tag,
				gen = e.gen,
				result = result or { status = -1, stdout = "", stderr = "", timed_out = false },
				spawnError = spawnError,
				at = M.AT,
			}
			local nextEffects
			s, nextEffects = State.update(s, msg)
			for _, n in nextEffects do
				table.insert(queue, n)
			end
		end
	end
	return s, tr
end

function M.link(params: { [string]: string }?): string
	local parts: { string } = {}
	local p: { [string]: string } = params or {}
	local keys: { string } = {}
	for k in p do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		table.insert(parts, k .. "=" .. p[k])
	end
	return "tern-kube://explore?" .. table.concat(parts, "&")
end

-- A settled block opened from a lens row (`--context` given).
function M.open(params: { [string]: string }?, cfg: Config.Config?, saved: any?): (State, Trace)
	local p = params or { context = M.CTX, namespace = M.NS, kind = "Pod" }
	local s, effects = State.init({ M.link(p) }, saved, cfg or M.config(nil), M.env())
	return M.settle(s, effects)
end

function M.key(name: string, extra: { [string]: any }?): Msg
	local k: { [string]: any } = { name = name, ctrl = false, alt = false, shift = false, meta = false }
	if #name == 1 then
		k.text = name
	end
	if extra then
		for a, b in extra do
			k[a] = b
		end
	end
	return { t = "key", key = k :: any }
end

-- Applies keys in order and settles every run they start.
function M.keys(s: State, names: { string }, trace: Trace?): (State, Trace)
	local tr: Trace = trace or { runs = {}, effects = {} }
	for _, name in names do
		local effects
		s, effects = State.update(s, M.key(name))
		s, tr = M.settle(s, effects, nil, tr)
	end
	return s, tr
end

function M.action(s: State, act: string, value: string?, trace: Trace?): (State, Trace)
	local s2, effects = State.update(s, { t = "action", act = act, value = value })
	return M.settle(s2, effects, nil, trace)
end

-- Helm ----------------------------------------------------------------------
-- A fake helm (and the kubectl reads of the helm-resources view) over the
-- releases captured from the kind cluster (tests/fixtures/helm/captured,
-- namespace tern-test-helm): list, history, status, get all --template
-- (extras), get values --all. Anything else fails like helm would.

M.HELM_NS = "tern-test-helm"
M.HELM_DIR = "helm/captured/"

local HELM_VALUE_FLAGS: { [string]: boolean } = {
	["--kube-context"] = true,
	["--kubeconfig"] = true,
	["-n"] = true,
	["-o"] = true,
	["--time-format"] = true,
	["--max"] = true,
	["--revision"] = true,
	["--template"] = true,
	["--filter"] = true,
	["--version"] = true,
	["--timeout"] = true,
	["-f"] = true,
}

local function helmWords(argv: { string }): { string }
	local out: { string } = {}
	local i = 2
	while i <= #argv do
		local a = argv[i]
		if HELM_VALUE_FLAGS[a] then
			i += 2
		elseif string.sub(a, 1, 1) == "-" then
			i += 1
		else
			table.insert(out, a)
			i += 1
		end
	end
	return out
end

local function listRows(): { any }
	return json.decode(fixtures.read(M.HELM_DIR .. "list.json"))
end

local function latestRevision(name: string): number?
	for _, row in listRows() do
		if row.name == name then
			return tonumber(row.revision)
		end
	end
	return nil
end

local function tokenOf(label: string, value: any): string
	local token = "@helm:" .. label
	tokens[token] = value
	return token
end

local function helmFile(path: string): (Result?, string?)
	if fixtures.has(M.HELM_DIR .. path) then
		return ok(fixtures.read(M.HELM_DIR .. path))
	end
	return M.fail(1, "Error: release: not found")
end

function M.helm(argv: { string }): (Result?, string?)
	if flag(argv, "--kube-context") ~= M.CTX then
		return M.fail(
			1,
			'Error: Kubernetes cluster unreachable: context "'
				.. tostring(flag(argv, "--kube-context"))
				.. '" does not exist'
		)
	end
	local words = helmWords(argv)
	local verb = words[1]
	local ns = flag(argv, "-n")
	if verb == "list" then
		local filter = flag(argv, "--filter")
		local only = if filter then string.gsub(string.match(filter, "^%^(.*)%$$") or filter, "\\", "") else nil
		local rows: { any } = {}
		for _, row in listRows() do
			if (has(argv, "-A") or ns == nil or row.namespace == ns) and (only == nil or row.name == only) then
				table.insert(rows, row)
			end
		end
		return ok(tokenOf(table.concat(argv, " "), rows))
	end
	if ns ~= M.HELM_NS then
		return M.fail(1, "Error: release: not found")
	end
	local name = if verb == "get" then words[3] else words[2]
	local revision = tonumber(flag(argv, "--revision")) or latestRevision(name or "")
	if name == nil or revision == nil then
		return M.fail(1, "Error: release: not found")
	end
	if verb == "history" then
		if flag(argv, "--max") == "1" and fixtures.has(M.HELM_DIR .. "history-" .. name .. "-max1.json") then
			return helmFile("history-" .. name .. "-max1.json")
		end
		return helmFile("history-" .. name .. ".json")
	elseif verb == "status" then
		return helmFile(string.format("status-%s-r%d.json", name, revision))
	elseif verb == "get" and words[2] == "all" and flag(argv, "--template") then
		return helmFile(string.format("extras-%s-r%d.txt", name, revision))
	elseif verb == "get" and words[2] == "values" and has(argv, "--all") then
		return helmFile(string.format("values-all-%s-r%d.json", name, revision))
	end
	return M.fail(1, "fake helm: unhandled " .. table.concat(argv, " "))
end

local function helmObjects(argv: { string }): { any }
	local resource = command(argv)[2] or ""
	local kind = string.match(resource, "^([^.]+)") or resource
	local out: { any } = {}
	for _, item in json.decode(fixtures.read(M.HELM_DIR .. "objects.json")).items do
		if string.lower(item.kind) == kind then
			table.insert(out, item)
		end
	end
	return out
end

-- helm, the helm-resources kubectl reads of tern-test-helm, else M.responder.
function M.helmResponder(argv: { string }): (Result?, string?)
	if argv[1] == "helm" then
		return M.helm(argv)
	end
	if argv[1] == "kubectl" and flag(argv, "-n") == M.HELM_NS and command(argv)[1] == "get" then
		local items = helmObjects(argv)
		local single = command(argv)[3]
		if single and flag(argv, "-o") == "json" then
			for _, item in items do
				if item.metadata.name == single then
					return ok(tokenOf(table.concat(argv, " "), item))
				end
			end
			if has(argv, "--ignore-not-found") then
				return ok("")
			end
			return M.fail(1, "Error from server (NotFound): " .. command(argv)[2] .. ' "' .. single .. '" not found')
		end
		if flag(argv, "-o") == "name" then
			local want: { [string]: boolean } = {}
			for i = 3, #command(argv) do
				want[command(argv)[i]] = true
			end
			local names: { string } = {}
			for _, item in items do
				if want[item.metadata.name] then
					table.insert(names, command(argv)[2] .. "/" .. item.metadata.name)
				end
			end
			return ok(table.concat(names, "\n") .. (if #names > 0 then "\n" else ""))
		end
		local selector = flag(argv, "-l")
		local kept: { any } = {}
		for _, item in items do
			local labels = item.metadata.labels or {}
			if selector == nil or labels["app.kubernetes.io/managed-by"] == "Helm" then
				table.insert(kept, item)
			end
		end
		return ok(tokenOf(table.concat(argv, " "), { apiVersion = "v1", kind = "List", items = kept }))
	end
	return M.responder(argv)
end

function M.helmEnv(): State.Env
	local env = M.env()
	env.helm = "helm"
	return env
end

-- A settled block on the Helm releases (all namespaces) with helm found.
function M.openHelm(params: { [string]: string }?, cfg: Config.Config?): (State, Trace)
	local p = params or { context = M.CTX, namespace = "*", route = "helm-releases" }
	local s, effects = State.init({ M.link(p) }, nil, cfg or M.config(nil), M.helmEnv())
	return M.settle(s, effects, M.helmResponder)
end

function M.helmKeys(s: State, names: { string }, trace: Trace?): (State, Trace)
	local tr: Trace = trace or { runs = {}, effects = {} }
	for _, name in names do
		local effects
		s, effects = State.update(s, M.key(name))
		s, tr = M.settle(s, effects, M.helmResponder, tr)
	end
	return s, tr
end

function M.helmAction(s: State, act: string, value: string?, trace: Trace?): (State, Trace)
	local s2, effects = State.update(s, { t = "action", act = act, value = value })
	return M.settle(s2, effects, M.helmResponder, trace)
end

return M
