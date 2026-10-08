--!strict
local Capture = require("./lib/lens/capture")
local Command = require("./lib/kubectl/command")
local ConfigHost = require("./config_host")
local Quick = require("./lib/actions/quick")
local Redact = require("./lib/model/redact")
local Values = require("./lib/model/values")
local View = require("./lib/lens/view")
local Viewstate = require("./lib/lens/viewstate")

local ui = tern.ui
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

local function with_props(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
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

local function exploreAction(state: LensState, key: string, cx: EffectCx)
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
	cx:open(Command.exploreUrl(capture.invocation, row.ref))
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
			return View.render(capture, state.view, { pageSize = state.pageSize }) :: any
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
				exploreAction(state, value, cx)
			elseif ev.act == "act" then
				quickAction(value, cx)
			end
		end)
		if not ok then
			warnOnce(state, "event " .. tostring(ev.act), err)
		end
	end,
})

require("./explore_host").register()

-- Block `approve` ------------------------------------------------------------

type ApproveState = { path: string, req: any, err: string?, done: boolean }

local function decide(state: ApproveState, decision: string, cx: BlockCx)
	if state.done then
		return
	end
	local resp = (string.gsub(state.path, "req%-([%w%-]+)%.json$", "resp-%1.json"))
	local nonce = if type(state.req) == "table" then state.req.nonce else nil
	local ok, err = pcall(function()
		tern.fs.write(resp, json.encode({ nonce = nonce, decision = decision, at = os.time() }))
	end)
	if not ok then
		log.error("kube-lens approve: cannot write response", resp, tostring(err))
	end
	state.done = true
	-- `tern open --wait` ignores the block's exit code and a non-zero exit
	-- leaves an "exited" sheet that blocks the wait until closed by hand; the
	-- decision travels in the response file only.
	cx:exit(0)
end

tern.block.define("approve", {
	init = function(_cx: BlockCx, block_args: { string }, _saved: any): ApproveState
		local path = block_args[1] or ""
		local state: ApproveState = { path = path, req = nil, err = nil, done = false }
		local ok, text = pcall(tern.fs.read, path, 65536)
		if not ok then
			state.err = tostring(text)
			return state
		end
		local okj, doc = pcall(json.decode, text)
		if okj then
			state.req = doc
		else
			state.err = "unreadable request"
		end
		return state
	end,
	view = function(state: ApproveState, _cx: BlockCx): BlockView
		local argv = if type(state.req) == "table" and type(state.req.argv) == "table"
			then table.concat(state.req.argv, " ")
			else "?"
		return {
			main = ui.col({
				with_props(ui.text({ ui.span("kube-lens guard ", "strong"), ui.span(argv, "mono") }), { key = "head" }),
				with_props(ui.text(ui.span(state.err or state.path, "muted")), { key = "path" }),
				with_props(
					ui.row({
						ui.el("button", {
							key = "approve",
							class = "kl-btn",
							text = "Approve",
							actions = { click = "decide=approve" },
						}),
						ui.el(
							"button",
							{ key = "deny", class = "kl-btn", text = "Deny", actions = { click = "decide=deny" } }
						),
					}),
					{ key = "buttons" }
				),
			}),
		}
	end,
	title = function(_state: ApproveState): string?
		return "Kube Approve"
	end,
	key = function(state: ApproveState, key: Key, cx: BlockCx): boolean?
		if key.name == "escape" then
			decide(state, "deny", cx)
			return true
		end
		return false
	end,
	event = function(state: ApproveState, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" and ev.act == "decide" and state.err == nil then
			decide(state, if ev.value == "approve" then "approve" else "deny", cx)
		end
	end,
})

-- Hooks ----------------------------------------------------------------------

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	spec.env.KUBE_LENS_SPOOL = SPOOL
	return spec
end)
