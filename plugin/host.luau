--!strict
local Capture = require("./lib/lens/capture")
local Command = require("./lib/kubectl/command")
local ConfigHost = require("./config_host")
local Link = require("./lib/mutation/link")
local Quick = require("./lib/actions/quick")
local Redact = require("./lib/model/redact")
local Values = require("./lib/model/values")
local View = require("./lib/lens/view")
local Viewstate = require("./lib/lens/viewstate")

local json = tern.json
local log = tern.log

type ViewState = Viewstate.ViewState
type Capture = Capture.Capture

local SPOOL = tern.plugin.data .. "/spool"

pcall(tern.fs.mkdir, tern.plugin.data)
pcall(tern.fs.mkdir, SPOOL)

local function ms(t0: number): number
	return math.floor((os.clock() - t0) * 100000) / 100
end

-- Lens `kubectl` ---------------------------------------------------------------

-- open/line/finish only record: Tern replays them on rehydration, so they
-- must stay side-effect free. Everything else happens in view/event.
type LensState = {
	run: LensRun,
	lines: { string },
	bytes: number,
	-- Output beyond the native limits: the lens stops recording and shows raw.
	overflow: boolean,
	status: number?,
	view: ViewState,
	capture: Capture?,
	warned: boolean,
	-- Config read (from the cache, no I/O) when the block opened.
	native: boolean,
	maxLines: number,
	maxBytes: number,
	pageSize: number,
	mutations: boolean,
	policy: Redact.Policy,
}

-- Structured output is only valid as a whole; while it streams, raw is shown.
local NEEDS_FINISH: { [string]: boolean } = { json = true, yaml = true, describe = true }

-- Parsing cost is linear in lines (about 15 us per line in the plugin VM), and
-- Tern waits for `view` before feeding more output: past general.max_rows
-- lines or general.max_capture_bytes the native view would stall the pane, so
-- the block stays raw. While a command still runs, every `view` rebuilds
-- the capture; above this many lines the live view stays raw until the
-- command finishes.
local MAX_RUNNING_LINES = 2000

local function warnOnce(state: LensState, what: string, err: any)
	if not state.warned then
		state.warned = true
		log.warn("kube-lens " .. what .. " failed; showing raw", state.run.line, tostring(err))
	end
end

local function decode(text: string): any
	return json.decode(text)
end

local function captureOf(state: LensState): Capture?
	if state.capture then
		return state.capture
	end
	if state.overflow then
		return nil
	end
	local run = { program = state.run.program, args = state.run.args }
	if state.status == nil then
		if #state.lines > MAX_RUNNING_LINES or NEEDS_FINISH[Capture.modeOf(run)] then
			return nil
		end
		return Capture.build(run, state.lines, nil, { decode = decode, policy = state.policy })
	end
	local capture = Capture.build(run, state.lines, state.status, { decode = decode, policy = state.policy })
	state.capture = capture
	return capture
end

local function copyAction(state: LensState, value: string, cx: EffectCx)
	local what, key = string.match(value, "^([%w%-]+)|(.+)$")
	local capture = captureOf(state)
	if what == nil or key == nil or capture == nil then
		return
	end
	local row, tbl = Capture.findRow(capture, key)
	local ref = if row then row.ref else nil
	if row == nil or tbl == nil or ref == nil then
		cx:toast("error", "Nothing to copy", "The row is no longer in this snapshot")
		return
	end
	local containers: number? = nil
	for i, h in tbl.headers do
		if h == "READY" then
			local _, den = Values.ratio(row.cells[i] or "")
			containers = den
		end
	end
	local text = Command.copyText(what :: any, capture.invocation, ref, { containers = containers })
	if text == nil then
		cx:toast("error", "Nothing to copy", what .. " does not apply to " .. ref.kind)
		return
	end
	cx:copy(text)
	cx:toast("success", "Copied", text)
end

local function exploreAction(state: LensState, key: string, cx: EffectCx, route: string?)
	local capture = captureOf(state)
	if capture == nil then
		return
	end
	local row = Capture.findRow(capture, key)
	if row == nil or row.ref == nil then
		return
	end
	-- window.luau's route.link claims every kube-lens:// URL; an unclaimed
	-- one would fall through to the OS and show a system dialog.
	local cwd = state.run.cwd
	cx:open(Command.exploreUrl(capture.invocation, row.ref, {
		route = route,
		cwd = if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil,
	}))
end

-- Inspector quick-action chips carry a kube-lens://act/ link built by
-- Quick.encode; the window's route.link rebuilds the command from the
-- validated fields. Anything else is dropped here so no stray URL reaches
-- cx:open (an unclaimed scheme would raise an OS dialog).
local function quickAction(url: string, cx: EffectCx)
	local req, err = Quick.decode(url)
	if req == nil then
		log.warn("kube-lens lens quick action ignored", url, tostring(err))
		return
	end
	cx:open(url)
end

-- Delete / Restart / Scale chips carry a kube-lens://mutate link; the window
-- opens the approve block for it, which previews before anything runs.
local function mutateAction(url: string, cx: EffectCx)
	local req, err = Link.decode(url)
	if req == nil then
		log.warn("kube-lens lens mutation ignored", url, tostring(err))
		return
	end
	cx:open(url)
end

tern.lens.define("kubectl", {
	open = function(run: LensRun, _cx: EffectCx): LensState
		local cfg = ConfigHost.current()
		return {
			run = run,
			lines = {},
			bytes = 0,
			overflow = false,
			status = nil,
			view = Viewstate.default(),
			capture = nil,
			warned = false,
			native = cfg.general.native_default,
			maxLines = cfg.general.max_rows,
			maxBytes = cfg.general.max_capture_bytes,
			pageSize = cfg.general.max_rendered_rows,
			mutations = cfg.mutations.enabled,
			policy = Redact.fromConfig(cfg),
		}
	end,
	line = function(state: LensState, l: LensLine)
		if state.overflow then
			return
		end
		state.bytes += #l.text + 1
		if #state.lines >= state.maxLines or state.bytes > state.maxBytes then
			state.overflow = true
			state.lines = {}
			return
		end
		table.insert(state.lines, l.text)
	end,
	finish = function(state: LensState, status: number)
		state.status = status
	end,
	view = function(state: LensState): Node?
		if not state.native then
			return nil
		end
		local t0 = os.clock()
		local ok, node = pcall(function(): Node?
			local capture = captureOf(state)
			if capture == nil then
				return nil
			end
			return View.render(capture, state.view, { pageSize = state.pageSize, mutations = state.mutations }) :: any
		end)
		if not ok then
			warnOnce(state, "view", node)
			return nil
		end
		log.debug(
			"kube-lens lens.view",
			"lines=" .. #state.lines,
			"overflow=" .. tostring(state.overflow),
			"finished=" .. tostring(state.status ~= nil),
			"view_ms=" .. ms(t0),
			"lua_kb=" .. gcinfo()
		)
		return node
	end,
	event = function(state: LensState, ev: UiEvent, cx: EffectCx)
		if ev.ev ~= "action" then
			return
		end
		local value: string = if type(ev.value) == "string" then ev.value else ""
		local ok, err = pcall(function()
			if ev.act == "v" then
				state.view = Viewstate.decode(value)
			elseif ev.act == "copy" then
				copyAction(state, value, cx)
			elseif ev.act == "explore" then
				exploreAction(state, value, cx, nil)
			elseif ev.act == "explore-route" then
				local route, key = string.match(value, "^(%a+)|(.+)$")
				if (route == "manifest" or route == "diff") and key then
					exploreAction(state, key, cx, route)
				end
			elseif ev.act == "act" then
				quickAction(value, cx)
			elseif ev.act == "mutate" then
				mutateAction(value, cx)
			end
		end)
		if not ok then
			warnOnce(state, "event " .. tostring(ev.act), err)
		end
	end,
})

require("./explore_host").register()
require("./mutate_host").register()
require("./settings_host").register()

-- Hooks ----------------------------------------------------------------------

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	spec.env.KUBE_LENS_SPOOL = SPOOL
	return spec
end)
