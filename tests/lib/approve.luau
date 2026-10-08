--!strict
-- Fake host for lib/mutation/session.luau specs: answers run effects from a
-- scripted responder, records every other effect, and offers a fake cluster
-- whose answers follow the argv the session built (context, names).
local Fingerprint = require("../../plugin/lib/mutation/fingerprint")
local Session = require("../../plugin/lib/mutation/session")
local json = require("./json")

type Effect = Session.Effect
type State = Session.State
type Result = Session.ProcessResult

local M = {}

M.SERVER = "https://127.0.0.1:6443"
M.HOME = "/home/me"
M.SPOOL = "/data/spool"
M.NONCE = "0123456789abcdef0123456789abcdef"
M.TOKEN = "fedcba9876543210fedcba9876543210"

function M.ok(stdout: string?): Result
	return { status = 0, stdout = stdout or "", stderr = "", timed_out = false }
end

function M.failed(code: number, stderr: string): Result
	return { status = code, stdout = "", stderr = stderr, timed_out = false }
end

function M.timeout(): Result
	return { status = -1, stdout = "", stderr = "", timed_out = true }
end

-- Deterministic stand-in for sha256 (64 hex), sensitive to every byte.
function M.sha(text: string): string
	local parts: { string } = {}
	for seed = 1, 4 do
		local h = seed * 2654435761 % 4294967296
		for i = 1, #text do
			h = (h * 31 + string.byte(text, i) + seed) % 4294967296
		end
		table.insert(parts, string.format("%08x%08x", h, (h * 2246822519 + #text) % 4294967296))
	end
	return table.concat(parts)
end

-- `over` patches the mutations section; `showSecretValues` the top level.
function M.config(over: { [string]: any }?): Session.Config
	local m = {
		enabled = true,
		require_target_confirmation = true,
		allow_failed_preview_override = false,
	}
	local show = false
	local overrides: { [string]: any } = over or {}
	for k, v in overrides do
		if k == "showSecretValues" then
			show = v == true
		else
			(m :: any)[k] = v
		end
	end
	return { mutations = m, previewTimeoutMs = 30000, execTimeoutMs = 300000, showSecretValues = show, quick = {} }
end

export type Opts = {
	now: number?,
	config: Session.Config?,
	kubeconfig: string?,
	request: string?,
	panes: { string }?,
	decode: ((string) -> any)?,
}

function M.init(arg: string, opts: Opts?): (State, { Effect })
	local o: Opts = opts or {}
	return Session.init({
		args = { arg },
		now = o.now or 1000,
		config = o.config or M.config(),
		kubectl = "kubectl",
		kubeconfig = o.kubeconfig or "/k/config",
		home = M.HOME,
		spool = M.SPOOL,
		request = if o.request then { text = o.request } else nil,
		panes = o.panes or { "7" },
		decode = o.decode or json.decode,
	})
end

local function after(argv: { string }, flag: string): string?
	for i, a in argv do
		if a == flag then
			return argv[i + 1]
		end
	end
	return nil
end

-- A healthy cluster; `world` overrides per tag (a Result or a function).
export type World = {
	context: string?,
	current: string?,
	server: string?,
	namespace: string?,
	files: { { path: string, size: number, sha256: string } }?,
	replicas: number?,
	diff: string?,
	diffExit: number?,
	[string]: any,
}

function M.cluster(world: World?): (Effect) -> Result?
	local w: World = world or {}
	return function(e: Effect): Result?
		local tag = e.tag :: string
		local over = w[tag]
		if type(over) == "function" then
			return over(e)
		elseif over ~= nil then
			return over
		end
		local argv = e.argv or {}
		if tag == "spool" then
			return M.ok(M.SPOOL .. "\n")
		elseif tag == "current" or tag == "v-current" then
			return M.ok((w.current or "kind-dev") .. "\n")
		elseif tag == "target" or tag == "v-target" then
			local ctx = after(argv, "--context") :: string
			if w.context and ctx ~= w.context and ctx ~= w.current then
				return M.failed(1, string.format('error: context "%s" does not exist', ctx))
			end
			local ns = if w.namespace then string.format(',"namespace":"%s"', w.namespace) else ""
			return M.ok(
				string.format(
					'{"contexts":[{"name":"%s","context":{"cluster":"%s","user":"u"%s}}],'
						.. '"clusters":[{"name":"%s","cluster":{"server":"%s"}}]}',
					ctx,
					ctx,
					ns,
					ctx,
					w.server or M.SERVER
				)
			)
		elseif tag == "digest" or tag == "v-digest" then
			local out: { string } = {}
			local files: { { path: string, size: number, sha256: string } } = w.files or {}
			for _, f in files do
				table.insert(out, string.format("%d %s %s", f.size, f.sha256, f.path))
			end
			return M.ok(table.concat(out, "\n") .. (if #out > 0 then "\n" else ""))
		elseif tag == "fp" or tag == "v-fp" then
			return M.ok(M.sha(e.stdin or "") .. "  -\n")
		elseif tag == "step:targets" or tag == "rq:targets" then
			local target = argv[#argv - 2] or "deployment/web"
			local name = string.match(target, "([^/]+)$") or target
			return M.ok(
				string.format(
					'{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"%s","namespace":"apps"},'
						.. '"spec":{"replicas":%d},"status":{"readyReplicas":%d}}',
					name,
					w.replicas or 3,
					w.replicas or 3
				)
			)
		elseif tag == "step:dry-run" then
			return M.ok("deployment.apps/web configured (server dry run)\n")
		elseif tag == "step:diff" or tag == "rq:diff" then
			return { status = w.diffExit or 1, stdout = w.diff or "", stderr = "", timed_out = false }
		elseif tag == "exec" then
			return M.ok('deployment.apps "web" deleted\n')
		elseif tag == "nonce" then
			return M.ok(M.TOKEN)
		elseif tag == "respond" then
			return M.ok()
		end
		return nil
	end
end

export type Drive = { effects: { Effect }, runs: { Effect } }

-- Answers run/write effects until none is answerable; returns everything
-- emitted (runs included) in order.
function M.drive(s: State, effects: { Effect }, respond: (Effect) -> Result?, now: number?): Drive
	local all: Drive = { effects = {}, runs = {} }
	local queue = table.clone(effects)
	while #queue > 0 do
		local e = table.remove(queue, 1) :: Effect
		table.insert(all.effects, e)
		if e.t == "run" or e.t == "write" then
			table.insert(all.runs, e)
			local r = respond(e)
			if r then
				local _, more = Session.update(s, { t = "result", tag = e.tag, gen = e.gen, result = r, now = now })
				for _, m in more do
					table.insert(queue, m)
				end
			end
		elseif e.t == "read" then
			local files: { Session.ReadFile } = {}
			local paths: { string } = e.paths or {}
			for _, p in paths do
				table.insert(files, { path = p, text = "kind: ConfigMap\nmetadata:\n  name: x\n" })
			end
			local _, more = Session.update(s, { t = "read", tag = e.tag, gen = e.gen, files = files, now = now })
			for _, m in more do
				table.insert(queue, m)
			end
		end
	end
	return all
end

function M.send(s: State, msg: Session.Msg, respond: (Effect) -> Result?): Drive
	local _, effects = Session.update(s, msg)
	return M.drive(s, effects, respond, msg.now)
end

function M.key(name: string, text: string?): Session.Msg
	return { t = "key", key = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false } }
end

function M.typeText(s: State, text: string, respond: (Effect) -> Result?)
	for i = 1, #text do
		local ch = string.sub(text, i, i)
		M.send(s, M.key(if ch == " " then "space" else ch, ch), respond)
	end
end

function M.find(effects: { Effect }, t: string, tag: string?): Effect?
	for _, e in effects do
		if e.t == t and (tag == nil or e.tag == tag) then
			return e
		end
	end
	return nil
end

function M.count(effects: { Effect }, t: string, tag: string?): number
	local n = 0
	for _, e in effects do
		if e.t == t and (tag == nil or e.tag == tag) then
			n += 1
		end
	end
	return n
end

local function q(s: string): string
	return '"' .. string.gsub(s, '[\\"]', "\\%0") .. '"'
end

export type Req = {
	argv: { string }?,
	context: string?,
	source: string?,
	kubeconfig: string?,
	namespace: string?,
	pane: string?,
	cwd: string?,
	files: { { path: string, size: number, sha256: string } }?,
	created: number?,
	timeout: number?,
	fingerprint: string?,
	nonce: string?,
}

-- A guard request whose fingerprint is what the block will compute with M.sha.
function M.request(r: Req): string
	local argv = r.argv or { "kubectl", "scale", "deploy/web", "--replicas=2" }
	local files = r.files or {}
	local fp = r.fingerprint
		or Fingerprint.compute({
			argv = argv,
			context = r.context or "kind-dev",
			kubeconfig = r.kubeconfig,
			namespace = r.namespace,
			cwd = r.cwd or "/work",
			files = files :: any,
		}, M.sha)
	local args: { string } = {}
	for _, a in argv :: { string } do
		table.insert(args, q(a))
	end
	local fs: { string } = {}
	for _, f in files :: { { path: string, size: number, sha256: string } } do
		table.insert(fs, string.format('{"path":%s,"size":%d,"sha256":%s}', q(f.path), f.size, q(f.sha256)))
	end
	return string.format(
		'{"version":1,"nonce":%s,"argv":[%s],"program":"/usr/local/bin/kubectl","cwd":%s,"kubeconfig":%s,'
			.. '"context":%s,"context_source":%s,"namespace":%s,"pane":%s,"files":[%s],"fingerprint":%s,'
			.. '"created_at":%d,"timeout_s":%d}',
		q(r.nonce or M.NONCE),
		table.concat(args, ","),
		q(r.cwd or "/work"),
		if r.kubeconfig then q(r.kubeconfig) else "null",
		q(r.context or "kind-dev"),
		q(r.source or "flag"),
		if r.namespace then q(r.namespace) else "null",
		q(r.pane or "7"),
		table.concat(fs, ","),
		q(fp :: string),
		r.created or 990,
		r.timeout or 600
	)
end

function M.requestPath(nonce: string?): string
	return M.SPOOL .. "/req-" .. (nonce or M.NONCE) .. ".json"
end

return M
