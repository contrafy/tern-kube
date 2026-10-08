--!strict
-- Host glue for the approve block (`tern-kube.approve`): executes the effects
-- of lib/mutation/session.luau and feeds results, ticks, keys and view events
-- back as messages. All decisions live in the session.
--
-- Processes cannot be killed before their timeout: a closed block or a
-- superseded preview ignores late callbacks (session generations; `stopped`
-- covers a closed pane). A native mutation, once spawned, runs to the end.

local ConfigHost = require("./config_host")
local Link = require("./lib/mutation/link")
local Render = require("./lib/mutation/render")
local Session = require("./lib/mutation/session")

local log = tern.log

type Effect = Session.Effect
type Msg = Session.Msg

type Host = { s: Session.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.LIVENESS_MS = 1000
M.SPOOL = tern.plugin.data .. "/spool"
M.AUDIT_LOG = tern.plugin.data .. "/audit.log"

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-kube approve " .. what .. " failed", tostring(err))
	end
end

local function settings(): Session.Config
	local cfg = ConfigHost.load().config
	local m = cfg.mutations
	return {
		mutations = {
			enabled = m.enabled,
			require_target_confirmation = m.require_target_confirmation,
			allow_failed_preview_override = m.allow_failed_preview_override,
		},
		previewTimeoutMs = m.preview_timeout_ms,
		execTimeoutMs = m.execute_timeout_ms,
		showSecretValues = cfg.security.show_secret_values,
		quick = {
			shellCommand = cfg.quick_actions.shell_command,
			logsTail = cfg.quick_actions.logs_tail,
			debugImage = cfg.quick_actions.debug_image,
		},
	}
end

local function paneIds(): { string }
	local out: { string } = {}
	for _, p in tern.pane.list() do
		table.insert(out, tostring(p.pane))
	end
	return out
end

local exec: (h: Host, effects: { Effect }) -> ()

local function dispatch(h: Host, msg: Msg): boolean
	if msg.now == nil then
		msg.now = os.time()
	end
	local ok, s, effects, changed = pcall(Session.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	h.s = s
	exec(h, effects)
	return changed
end

local function deliver(h: Host, e: Effect, result: Session.ProcessResult)
	if h.stopped then
		return
	end
	dispatch(h, { t = "result", tag = e.tag, gen = e.gen, result = result })
	if not h.stopped then
		h.cx:render()
	end
end

local function run(h: Host, e: Effect)
	local t0 = tern.now()
	local opts: ProcessOptions = { timeout_ms = e.timeout_ms, cwd = e.cwd, env = e.env, stdin = e.stdin }
	local ok, err = pcall(function()
		tern.process.run(e.argv :: { string }, opts, function(res: ProcessResult)
			log.debug(
				"tern-kube approve.run",
				e.tag,
				"status=" .. res.status,
				"timed_out=" .. tostring(res.timed_out),
				"took_ms=" .. math.floor(tern.now() - t0)
			)
			deliver(h, e, res)
		end)
	end)
	if not ok then
		deliver(h, e, { status = -1, stdout = "", stderr = tostring(err), timed_out = false })
	end
end

local function read(h: Host, e: Effect)
	local files: { Session.ReadFile } = {}
	local paths: { string } = e.paths or {}
	for _, path in paths do
		local ok, text = pcall(tern.fs.read, path, Session.MAX_MANIFEST_BYTES)
		if ok then
			table.insert(files, { path = path, text = text })
		else
			table.insert(files, { path = path, error = tostring(text) })
		end
	end
	-- Delivered on the next tick: effects never re-enter update.
	tern.timer(1, function()
		if not h.stopped then
			dispatch(h, { t = "read", tag = e.tag, gen = e.gen, files = files })
			h.cx:render()
		end
	end)
end

local function write(h: Host, e: Effect)
	local ok, err = pcall(function()
		tern.fs.write(e.path :: string, e.text :: string)
	end)
	if not ok then
		tern.timer(1, function()
			deliver(h, e, { status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end)
		return
	end
	run(h, { t = "run", tag = e.tag, gen = e.gen, argv = e.argv, timeout_ms = 5000 })
end

-- One JSON line appended with O_APPEND (tern.fs.write replaces files).
local function appendAudit(line: string)
	local ok, err = pcall(function()
		tern.process.run(
			{ "/bin/sh", "-c", 'umask 077; cat >>"$1"', "tern-kube-audit", M.AUDIT_LOG },
			{ stdin = line, timeout_ms = 5000 },
			function(res: ProcessResult)
				if res.status ~= 0 then
					log.warn("tern-kube audit append failed", res.stderr)
				end
			end
		)
	end)
	if not ok then
		log.warn("tern-kube audit append failed", tostring(err))
	end
end

local function grant(e: Effect)
	local now = os.time()
	local ttl = math.max(1, (e.expires or now + Link.GRANT_TTL) - now)
	local grants, err = Link.addGrant(tern.kv.get(Link.GRANTS_KEY), e.token :: string, e.url :: string, now, ttl)
	if grants == nil then
		log.warn("tern-kube grant refused", tostring(err))
		return
	end
	tern.kv.set(Link.GRANTS_KEY, grants)
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		local t = e.t
		if t == "run" then
			run(h, e)
		elseif t == "read" then
			read(h, e)
		elseif t == "write" then
			write(h, e)
		elseif t == "remove" then
			pcall(tern.fs.remove, e.path :: string)
		elseif t == "audit" then
			appendAudit(e.line :: string)
		elseif t == "grant" then
			grant(e)
		elseif t == "open" then
			-- window.luau's route.link claims every tern-kube:// URL.
			h.cx:open(e.url :: string)
		elseif t == "focus" then
			-- The input appears in the view this effect comes with: render
			-- it first, focus on the next tick.
			local id = e.id or Session.TYPED_INPUT
			h.cx:render()
			tern.timer(1, function()
				if not h.stopped then
					h.cx:frame({ { "focus", id } })
				end
			end)
		elseif t == "copy" then
			h.cx:copy(e.text or "")
		elseif t == "toast" then
			h.cx:toast((e.level or "info") :: any, e.text or "")
		elseif t == "exit" then
			h.stopped = true
			-- `tern open --wait` ignores the exit code, and a non-zero exit
			-- leaves a sheet that blocks the wait: always 0.
			h.cx:exit(0)
		end
	end
end

-- No close callback: poll the pane list. The same tick reports the guard
-- request's pane and cancel marker to the session.
local function watch(h: Host)
	local function tick()
		if h.stopped then
			return
		end
		local alive = false
		local panes = paneIds()
		for _, p in panes do
			if p == tostring(h.cx.pane) then
				alive = true
			end
		end
		if not alive then
			h.stopped = true
			log.debug("tern-kube approve pane gone", h.cx.pane)
			return
		end
		local w = Session.watch(h.s)
		local msg: Msg = { t = "tick" }
		if w.pane then
			msg.paneAlive = table.find(panes, w.pane) ~= nil
		end
		if w.cancelPath then
			local ok, present = pcall(tern.fs.exists, w.cancelPath :: string)
			msg.cancelled = ok and present == true
		end
		dispatch(h, msg)
		if not h.stopped then
			if w.pane then
				h.cx:render()
			end
			tern.timer(M.LIVENESS_MS, tick)
		end
	end
	tern.timer(M.LIVENESS_MS, tick)
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "Tern Kube Approve could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

local function requestFile(arg: string?): { text: string?, error: string? }?
	if arg == nil or string.sub(arg, 1, #"tern-kube://") == "tern-kube://" then
		return nil
	end
	local ok, text = pcall(tern.fs.read, arg, Session.MAX_REQUEST_BYTES)
	if ok then
		return { text = text }
	end
	return { error = tostring(text) }
end

function M.register()
	pcall(tern.fs.mkdir, M.SPOOL)
	tern.block.define("approve", {
		init = function(cx: BlockCx, args: { string }, _saved: any): Host
			local conf = settings()
			local cfg = ConfigHost.current()
			local env = ConfigHost.env()
			local s, effects = Session.init({
				args = args,
				now = os.time(),
				config = conf,
				kubectl = ConfigHost.kubectl(),
				kubeconfig = cfg.kubeconfig or env.kubeconfig,
				home = env.home,
				spool = M.SPOOL,
				request = requestFile(args[1]),
				panes = paneIds(),
				decode = tern.json.decode,
			})
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			log.info("tern-kube approve.init", s.mode, s.phase, args[1] or "")
			exec(h, effects)
			watch(h)
			return h
		end,
		view = function(h: Host, _cx: BlockCx): BlockView
			local ok, v = pcall(Render.view, h.s)
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			local ok, title = pcall(Render.title, h.s)
			return if ok then title else "Tern Kube Approve"
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key :: any })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "action" and type(ev.act) == "string" then
				dispatch(h, {
					t = "action",
					act = ev.act,
					value = if type(ev.value) == "string" then ev.value else nil,
				})
			elseif ev.ev == "toggle" and type(ev.id) == "string" then
				dispatch(h, { t = "toggle", id = ev.id })
			elseif ev.ev == "focus" and ev.id == Session.TYPED_INPUT then
				dispatch(h, { t = "action", act = "typed-focus" })
			end
		end,
	})
end

return M
