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

M.CTX = "kind-kube-lens-dev"
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

function M.env(): State.Env
	return { kubeconfig = nil, home = "/home/u", kubectl = "kubectl", decode = M.decode, now = M.AT }
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
		return ok("pods\ndeployments.apps\nservices\n")
	elseif verb == "get" and cmd[2] == "namespaces" then
		return ok("namespace/default\nnamespace/tern-test-apps\nnamespace/tern-test-empty\n")
	elseif verb == "describe" then
		return ok(
			"Name:         " .. (cmd[3] or "?") .. "\nNamespace:    " .. (ns or "") .. "\nStatus:       Running\n"
		)
	elseif verb == "logs" then
		return ok("log line 1\nlog line 2\n")
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
	return "kube-lens://explore?" .. table.concat(parts, "&")
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

return M
