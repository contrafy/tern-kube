--!strict
-- Host glue for lib/env/shellenv.luau. tern.process.run looks programs up on
-- the daemon's PATH, which is minimal when Tern starts from the Dock, Finder
-- or a desktop session. This module reads PATH and KUBECONFIG from the
-- user's login shell once per daemon VM (async, one in-flight read, killed
-- after TIMEOUT_MS), resolves programs against it and runs every external
-- process with the merged PATH, so kubectl's exec credential plugins
-- (aws, gke-gcloud-auth-plugin, kubelogin) are found too.

local ConfigHost = require("./config_host")
local Shellenv = require("./lib/env/shellenv")

local log = tern.log

export type Phase = "idle" | "pending" | "done" | "failed" | "off" | "unsupported"

export type Status = {
	phase: Phase,
	shell: string?,
	tookMs: number?,
	error: string?,
	-- Directories the shell's PATH contributed.
	entries: number?,
	daemonPath: string,
	kubeconfig: string?,
}

export type RunCb = (result: ProcessResult, spawnError: string?) -> ()

type Probe = {
	phase: Phase,
	shell: string?,
	startedAt: number?,
	tookMs: number?,
	error: string?,
	path: { string }?,
	kubeconfig: string?,
}

local M = {}

M.TIMEOUT_MS = 5000
-- A background job started by an rc file can hold the shell's stdout open
-- past the kill; stop waiting for the result shortly after the timeout.
M.GRACE_MS = 1000

local probe: Probe = { phase = "idle" }
local waiters: { () -> () } = {}
-- The known dirs that exist, looked up once per VM.
local knownExisting: { string }? = nil

local function getenv(name: string): string?
	local v = tern.getenv(name)
	return if v == "" then nil else v
end

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function enabled(): boolean
	return ConfigHost.current().general.shell_env
end

local function flush()
	local list = waiters
	waiters = {}
	for _, cb in list do
		local ok, err = pcall(function()
			cb()
		end)
		if not ok then
			log.warn("tern-kube env waiter failed", tostring(err))
		end
	end
end

local function finish(phase: Phase, result: Shellenv.Probe?, err: string?)
	if probe.phase ~= "pending" and not (phase == "done" and probe.phase == "failed") then
		return
	end
	probe.phase = phase
	local took = math.floor(tern.now() - (probe.startedAt or tern.now()))
	probe.tookMs = took
	probe.error = err
	probe.path = if result then result.path else nil
	probe.kubeconfig = if result then result.kubeconfig else nil
	if phase == "done" then
		log.info("tern-kube shell env read", probe.shell or "?", "entries=" .. #(probe.path or {}), "took_ms=" .. took)
	else
		log.warn("tern-kube shell env not read", probe.shell or "?", err or "", "took_ms=" .. took)
	end
	flush()
end

-- Starts the shell read unless it ran, runs, or is turned off
-- (general.shell_env). Called on plugin load and by every `ready`.
function M.start()
	if probe.phase == "off" and enabled() then
		probe = { phase = "idle" }
	end
	if probe.phase ~= "idle" then
		return
	end
	if not enabled() then
		probe = { phase = "off" }
		return
	end
	local shell = getenv("SHELL")
	local argv = Shellenv.probeArgv(shell)
	if argv == nil then
		probe = { phase = "unsupported", shell = shell }
		log.info("tern-kube shell env skipped: unsupported SHELL", shell or "(unset)")
		return
	end
	probe = { phase = "pending", shell = shell, startedAt = tern.now() }
	local opts: ProcessOptions = { timeout_ms = M.TIMEOUT_MS, stdin = "", cwd = getenv("HOME") }
	local ok, err = pcall(function()
		tern.process.run(argv, opts, function(r: ProcessResult)
			local parsed = Shellenv.parseProbe(r.stdout)
			if parsed then
				finish("done", parsed, nil)
			elseif r.timed_out then
				finish("failed", nil, string.format("timed out after %d ms", M.TIMEOUT_MS))
			else
				finish("failed", nil, string.format("printed no PATH (exit %d)", r.status))
			end
		end)
	end)
	if not ok then
		finish("failed", nil, Shellenv.errorText(err))
		return
	end
	tern.timer(M.TIMEOUT_MS + M.GRACE_MS, function()
		finish("failed", nil, string.format("timed out after %d ms", M.TIMEOUT_MS))
	end)
end

-- Calls `cb` once the shell read is no longer pending (at once when done,
-- failed or off).
function M.ready(cb: () -> ())
	M.start()
	if probe.phase == "pending" then
		table.insert(waiters, cb)
	else
		cb()
	end
end

function M.pending(): boolean
	M.start()
	return probe.phase == "pending"
end

function M.daemonPath(): string
	return getenv("PATH") or ""
end

local function tiers(): Shellenv.Tiers
	if knownExisting == nil then
		local list: { string } = {}
		for _, dir in Shellenv.knownDirs(getenv("HOME")) do
			if exists(dir) then
				table.insert(list, dir)
			end
		end
		knownExisting = list
	end
	return {
		shell = if enabled() and probe.phase == "done" then probe.path else nil,
		known = knownExisting :: { string },
		daemon = Shellenv.splitPath(M.daemonPath()),
	}
end

local function explicit(name: string): Shellenv.Explicit?
	local cfg = ConfigHost.current()
	if name == "kubectl" then
		return Shellenv.explicitKubectl(cfg.kubectl, tern.kv.get("kubectl"), getenv("TKUBE_KUBECTL"))
	elseif name == "gh" and cfg.gitops.gh ~= "" and cfg.gitops.gh ~= "gh" then
		return { value = cfg.gitops.gh, source = "config" }
	end
	return nil
end

-- Where `name` resolves now. Reads tern.kv: not for lens callbacks.
function M.resolve(name: string): Shellenv.Resolution
	return Shellenv.resolve(name, explicit(name), tiers(), exists)
end

-- The program to put in argv[1] for `name` (absolute when found).
function M.program(name: string): string
	return M.resolve(name).program
end

-- The KUBECONFIG kubectl would use: the daemon's, else the login shell's.
function M.kubeconfig(): string?
	local own = getenv("KUBECONFIG")
	if own then
		return own
	end
	return if enabled() and probe.phase == "done" then probe.kubeconfig else nil
end

-- Variables for every process: the merged PATH, the shell's KUBECONFIG when
-- the daemon has none, then `extra`.
function M.processEnv(extra: { [string]: string }?): { [string]: string }
	local env: { [string]: string } = { PATH = table.concat(Shellenv.mergePath(tiers()), ":") }
	local kubeconfig = M.kubeconfig()
	if kubeconfig and getenv("KUBECONFIG") == nil then
		env.KUBECONFIG = kubeconfig
	end
	if extra then
		for k, v in extra do
			env[k] = v
		end
	end
	return env
end

-- Runs argv once the shell read settled: a bare argv[1] resolved, the
-- merged PATH set. A spawn failure answers with status -1 and the reason
-- without the Lua traceback (that goes to the log).
function M.run(argv: { string }, opts: ProcessOptions?, cb: RunCb)
	M.ready(function()
		local o: ProcessOptions = if opts then table.clone(opts) else {}
		o.env = M.processEnv(o.env)
		local resolved = table.clone(argv)
		if resolved[1] and not string.find(resolved[1], "/", 1, true) then
			resolved[1] = M.program(resolved[1])
		end
		local ok, err = pcall(function()
			tern.process.run(resolved, o, function(r: ProcessResult)
				cb(r, nil)
			end)
		end)
		if not ok then
			log.warn("tern-kube could not run " .. tostring(resolved[1]), tostring(err))
			cb({ status = -1, stdout = "", stderr = "", timed_out = false }, Shellenv.errorText(err))
		end
	end)
end

function M.status(): Status
	return {
		phase = if probe.phase ~= "pending" and not enabled() then "off" else probe.phase,
		shell = probe.shell or getenv("SHELL"),
		tookMs = probe.tookMs,
		error = probe.error,
		entries = if probe.path then #probe.path else nil,
		daemonPath = M.daemonPath(),
		kubeconfig = M.kubeconfig(),
	}
end

return M
