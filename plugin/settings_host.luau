--!strict
-- Host glue for the Tern Kube Settings block: reads the config file and the
-- status facts, performs the atomic write the pure core (lib/settings)
-- asks for, and feeds results back as messages. The only file it writes is
-- the config file (through a temporary file in the same directory, renamed
-- over it with mv).

local ConfigHost = require("./config_host")
local PaneEnv = require("./lib/actions/pane_env")
local Render = require("./lib/settings/render")
local State = require("./lib/settings/state")

local log = tern.log

type Effect = State.Effect
type Msg = State.Msg

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.SPOOL = tern.plugin.data .. "/spool"
M.PROBE_TIMEOUT_MS = 5000

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-kube settings " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { Effect }) -> ()

local function dispatch(h: Host, msg: Msg): boolean
	local ok, s, effects = pcall(State.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	local changed = s ~= h.s
	h.s = s
	exec(h, effects)
	return changed or #effects > 0
end

local function deliver(h: Host, msg: Msg)
	if h.stopped then
		return
	end
	dispatch(h, msg)
	-- Synchronous reads deliver during init, before the block is mounted.
	pcall(function()
		h.cx:render()
	end)
end

local function isList(t: any): boolean
	return type(t) == "table" and next(t) == nil and tern.json.encode(t) == "[]"
end

local function dirOf(path: string): string?
	return string.match(path, "^(.*)/[^/]+$")
end

-- Reads a regular file with the config cap; a symlink is resolved with
-- realpath (Tern's capped read refuses symlinks), like config_host does.
local function readConfig(path: string, done: (text: string?, err: string?, target: string?) -> ())
	local okExists, present = pcall(tern.fs.exists, path)
	if okExists and not present then
		done(nil, nil, path)
		return
	end
	local ok, text = pcall(tern.fs.read, path, ConfigHost.MAX_BYTES)
	if ok then
		done(text, nil, path)
		return
	end
	if not string.find(tostring(text), "non-symlink", 1, true) then
		done(nil, "could not read " .. path .. ": " .. tostring(text), path)
		return
	end
	local spawned = pcall(tern.process.run, { "realpath", path }, { timeout_ms = 2000 }, function(r: ProcessResult)
		local target = if r.status == 0 then string.match(r.stdout, "^(/[^\n]+)") else nil
		if target == nil then
			done(nil, path .. " is a symlink whose target could not be resolved", path)
			return
		end
		local tok, ttext = pcall(tern.fs.read, target, ConfigHost.MAX_BYTES)
		if tok then
			done(ttext, nil, target)
		else
			done(nil, "could not read " .. target .. ": " .. tostring(ttext), target)
		end
	end)
	if not spawned then
		done(nil, path .. " is a symlink and realpath could not run", path)
	end
end

local function reload(h: Host)
	local snap = ConfigHost.load()
	dispatch(h, { t = "info", info = { loadStatus = snap.status } })
	local path = snap.path
	if path == nil then
		deliver(h, { t = "file", path = nil, target = nil, text = nil, error = nil })
		return
	end
	readConfig(path, function(text, err, target)
		deliver(h, { t = "file", path = path, target = target, text = text, error = err })
	end)
end

local function nonce(): string
	return string.format("%08x%04x", math.random(0, 0x7fffffff), math.floor(tern.now()) % 0x10000)
end

-- The write: refuse when the file changed since the core read it (the edit
-- was computed from that text), then tmp + mv in the same directory.
local function write(h: Host, e: Effect)
	local target = e.path or ""
	local function finish(ok: boolean, err: string?)
		if ok then
			ConfigHost.load()
		end
		deliver(h, { t = "written", ok = ok, error = err, open = e.open })
	end
	local snap = ConfigHost.snapshot()
	if target == "" or (target ~= snap.path and target ~= h.s.target) then
		finish(false, "refusing to write outside the config path")
		return
	end
	local dir = dirOf(target)
	if dir == nil or dir == "" then
		finish(false, "the config path has no directory")
		return
	end
	local okNow, current = pcall(tern.fs.read, target, ConfigHost.MAX_BYTES)
	local okExists, existsNow = pcall(tern.fs.exists, target)
	local same = if e.existed then okNow and current == e.base else okExists and not existsNow
	if not same then
		finish(false, "the file changed on disk since it was read; reloaded, apply the change again")
		return
	end
	local tmp =
		string.format("%s/.%s.tern-kube-%s.tmp", dir, string.match(target, "([^/]+)$") or "config.json", nonce())
	local ok, err = pcall(function()
		tern.fs.mkdir(dir)
		tern.fs.write(tmp, e.text or "")
	end)
	if not ok then
		pcall(tern.fs.remove, tmp)
		finish(false, tostring(err))
		return
	end
	local spawned, serr = pcall(function()
		tern.process.run({ "mv", "-f", "--", tmp, target }, { timeout_ms = 5000 }, function(r: ProcessResult)
			if r.status ~= 0 then
				pcall(tern.fs.remove, tmp)
				finish(false, "mv failed: " .. (string.match(r.stderr, "^[^\n]*") or ""))
				return
			end
			log.info("tern-kube settings wrote", target)
			finish(true, nil)
		end)
	end)
	if not spawned then
		pcall(tern.fs.remove, tmp)
		finish(false, tostring(serr))
	end
end

-- Status facts: manifest (version, alias claims), pane env records, then
-- the slower process checks (kubectl, tern) as they finish.
local function probe(h: Host)
	local info: { [string]: any } = { pluginDir = tern.plugin.dir, spool = M.SPOOL }
	local okToml, toml = pcall(tern.fs.read, tern.plugin.dir .. "/plugin.toml", 65536)
	if okToml then
		info.pluginVersion = State.manifestVersion(toml)
		local claims, why = State.aliasClaims(toml)
		info.aliasClaims = claims
		info.aliasError = why
	else
		info.aliasError = "could not read plugin.toml: " .. tostring(toml)
	end
	local live: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		live[p.pane] = true
	end
	local records: { State.PaneRecord } = {}
	local okList, names = pcall(tern.fs.list, M.SPOOL)
	for _, pane in State.recordPanes(if okList then names else {}) do
		local path = PaneEnv.path(M.SPOOL, pane)
		local okRead, text = pcall(tern.fs.read, path or "", PaneEnv.MAX_BYTES)
		local kubeconfig, problem = nil, nil
		if okRead then
			kubeconfig, problem = PaneEnv.kubeconfig(text)
		else
			problem = "unreadable"
		end
		table.insert(records, { pane = pane, kubeconfig = kubeconfig, problem = problem, live = live[pane] == true })
	end
	info.paneRecords = records

	local cfg = ConfigHost.current()
	local program = ConfigHost.kubectl()
	local kenv = tern.getenv("TKUBE_KUBECTL")
	local kubectl: State.KubectlInfo = {
		program = program,
		source = State.kubectlSource(cfg, tern.kv.get("kubectl"), kenv),
		resolved = nil,
		version = nil,
		error = nil,
		pending = true,
	}
	info.kubectl = kubectl
	info.ternPending = true
	dispatch(h, { t = "info", info = info })

	local function kubectlDone(patch: { [string]: any })
		local k = table.clone(h.s.info.kubectl or kubectl) :: any
		for key, v in patch do
			k[key] = v
		end
		k.pending = false
		deliver(h, { t = "info", info = { kubectl = k } })
	end
	local resolver = { "sh", "-c", 'command -v -- "$1"', "sh", program }
	local okRun = pcall(tern.process.run, resolver, { timeout_ms = M.PROBE_TIMEOUT_MS }, function(r: ProcessResult)
		local resolved = if r.status == 0 then string.match(r.stdout, "^([^\n]+)") else nil
		if resolved == nil then
			kubectlDone({ error = "not found on the daemon's PATH" })
			return
		end
		local okVer = pcall(
			tern.process.run,
			{ resolved, "version", "--client", "-o", "json" },
			{ timeout_ms = M.PROBE_TIMEOUT_MS },
			function(v: ProcessResult)
				kubectlDone({
					resolved = resolved,
					version = if v.status == 0 then State.kubectlVersion(v.stdout, tern.json.decode) else nil,
				})
			end
		)
		if not okVer then
			kubectlDone({ resolved = resolved })
		end
	end)
	if not okRun then
		kubectlDone({ error = "could not run sh to resolve it" })
	end

	local okTern = pcall(
		tern.process.run,
		{ "tern", "--version" },
		{ timeout_ms = M.PROBE_TIMEOUT_MS },
		function(r: ProcessResult)
			local version = if r.status == 0 then State.ternVersion(r.stdout) else nil
			deliver(h, { t = "info", info = { ternVersion = version, ternPending = false } })
		end
	)
	if not okTern then
		dispatch(h, { t = "info", info = { ternVersion = nil, ternPending = false } })
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "reload" then
			reload(h)
		elseif e.t == "probe" then
			probe(h)
		elseif e.t == "write" then
			write(h, e)
		elseif e.t == "open" then
			if e.path then
				h.cx:open(e.path)
			end
		elseif e.t == "focus" then
			h.cx:frame({ { "focus", e.id or State.EDIT_INPUT } })
		elseif e.t == "exit" then
			h.stopped = true
			h.cx:exit(0)
		end
	end
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "Tern Kube Settings could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("settings", {
		init = function(cx: BlockCx, _args: { string }, saved: any): Host
			local env = ConfigHost.env()
			local s, effects = State.init({ decode = tern.json.decode, isList = isList, home = env.home }, saved)
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			exec(h, effects)
			return h
		end,
		view = function(h: Host, cx: BlockCx): BlockView
			if cx.rows ~= h.s.rows then
				dispatch(h, { t = "resize", rows = cx.rows })
			end
			local ok, v = pcall(Render.view, h.s, cx.cols, cx.rows)
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			local ok, title = pcall(Render.title, h.s)
			return if ok then title else "Tern Kube Settings"
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key :: any })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "focus" and ev.id == State.EDIT_INPUT then
				dispatch(h, { t = "action", act = "edit-focus", value = "" })
			elseif ev.ev == "action" and type(ev.act) == "string" then
				dispatch(h, {
					t = "action",
					act = ev.act,
					value = if type(ev.value) == "string" then ev.value else "",
				})
			end
		end,
		save = function(h: Host): any
			return State.save(h.s)
		end,
	})
end

return M
