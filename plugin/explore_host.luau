--!strict
-- Host glue for the Explore block: executes the effects the pure core
-- (lib/explore/state.luau) returns and feeds process results, ticks, keys and
-- view events back as messages. All decisions live in the core.
--
-- Processes cannot be killed before their timeout; a closed block or a
-- superseded load just ignores the late callback (state.luau compares
-- generations; `stopped` covers a closed pane).

local ConfigHost = require("./config_host")
local Render = require("./lib/explore/render")
local State = require("./lib/explore/state")

local log = tern.log

type Effect = State.Effect
type Msg = State.Msg

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.LIVENESS_MS = 2000

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("kube-lens explore " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { Effect }) -> ()

-- Applies `msg`; true when the state or the screen changed.
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

local function run(h: Host, e: Effect)
	local argv = e.argv :: { string }
	local t0 = tern.now()
	local function deliver(result: State.ProcessResult, spawnError: string?)
		if h.stopped then
			return
		end
		log.debug(
			"kube-lens explore.run",
			e.tag,
			"status=" .. result.status,
			"timed_out=" .. tostring(result.timed_out),
			"took_ms=" .. math.floor(tern.now() - t0)
		)
		dispatch(h, {
			t = "result",
			tag = e.tag,
			gen = e.gen,
			result = result,
			spawnError = spawnError,
			at = os.time(),
		})
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = e.timeout_ms, cwd = h.cx.cwd }, function(res: ProcessResult)
			deliver(res, nil)
			if not h.stopped then
				h.cx:render()
			end
		end)
	end)
	if not ok then
		deliver({ status = -1, stdout = "", stderr = "", timed_out = false }, tostring(err))
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "run" then
			run(h, e)
		elseif e.t == "copy" then
			h.cx:copy(e.text or "")
		elseif e.t == "toast" then
			h.cx:toast(e.level or "info", e.text or "", e.sub)
		elseif e.t == "open" then
			-- window.luau's route.link claims every kube-lens:// URL.
			h.cx:open(e.url or "")
		elseif e.t == "save" then
			h.cx:save()
		elseif e.t == "focus" then
			h.cx:frame({ { "focus", e.id or State.FILTER_INPUT } })
		elseif e.t == "render" then
			h.cx:render()
		elseif e.t == "exit" then
			h.stopped = true
			h.cx:exit(0)
		end
	end
end

-- Blocks get no close callback: poll the pane list, and use the same timer
-- to age the "fetched … ago" text. Cluster data is never re-read here.
local function watch(h: Host)
	local function tick()
		if h.stopped then
			return
		end
		for _, p in tern.pane.list() do
			if p.pane == h.cx.pane then
				dispatch(h, { t = "tick", now = os.time() })
				tern.timer(M.LIVENESS_MS, tick)
				return
			end
		end
		h.stopped = true
		log.debug("kube-lens explore pane gone", h.cx.pane)
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
					p = { spans = { { t = "Kube Explore could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("explore", {
		init = function(cx: BlockCx, args: { string }, saved: any): Host
			local snap = ConfigHost.load()
			local env = ConfigHost.env()
			local s, effects = State.init(args, saved, snap.config, {
				kubeconfig = env.kubeconfig,
				home = env.home,
				kubectl = ConfigHost.kubectl(),
				decode = tern.json.decode,
				now = os.time(),
			})
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			exec(h, effects)
			watch(h)
			return h
		end,
		view = function(h: Host, cx: BlockCx): BlockView
			-- The visible window of long lists is sized from the block height.
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
			return if ok then title else "Kube Explore"
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key :: any })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "focus" and ev.id == State.FILTER_INPUT then
				dispatch(h, { t = "action", act = "filter-focus" })
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
