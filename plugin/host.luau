--!strict
local Capture = require("./lib/lens/capture")
local Command = require("./lib/kubectl/command")
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
	status: number?,
	view: ViewState,
	capture: Capture?,
	warned: boolean,
}

-- Structured output is only valid as a whole; while it streams, raw is shown.
local NEEDS_FINISH: { [string]: boolean } = { json = true, yaml = true, describe = true }

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
	local run = { program = state.run.program, args = state.run.args }
	if state.status == nil then
		if NEEDS_FINISH[Capture.modeOf(run)] then
			return nil
		end
		return Capture.build(run, state.lines, nil, { decode = decode })
	end
	local capture = Capture.build(run, state.lines, state.status, { decode = decode })
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

tern.lens.define("kubectl", {
	open = function(run: LensRun, _cx: EffectCx): LensState
		return {
			run = run,
			lines = {},
			status = nil,
			view = Viewstate.default(),
			capture = nil,
			warned = false,
		}
	end,
	line = function(state: LensState, l: LensLine)
		table.insert(state.lines, l.text)
	end,
	finish = function(state: LensState, status: number)
		state.status = status
	end,
	view = function(state: LensState): Node?
		local t0 = os.clock()
		local ok, node = pcall(function(): Node?
			local capture = captureOf(state)
			if capture == nil then
				return nil
			end
			return View.render(capture, state.view) :: any
		end)
		if not ok then
			warnOnce(state, "view", node)
			return nil
		end
		log.debug(
			"kube-lens lens.view",
			"lines=" .. #state.lines,
			"finished=" .. tostring(state.status ~= nil),
			"view_ms=" .. ms(t0)
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
			end
		end)
		if not ok then
			warnOnce(state, "event " .. tostring(ev.act), err)
		end
	end,
})

-- Block `explore` ------------------------------------------------------------

type Pod = { name: string, phase: string }
type Param = { key: string, value: string }
type ExploreState = {
	args: { string },
	params: { Param },
	pods: { Pod },
	sel: number,
	query: string,
	editing: boolean,
	status: string,
	stopped: boolean,
}

local function param(state: ExploreState, key: string): string?
	for _, p in state.params do
		if p.key == key and p.value ~= "" then
			return p.value
		end
	end
	return nil
end

-- The daemon's PATH is not the shell's; the kv key "kubectl" (set by the
-- settings flow or tests) names the binary explicitly.
local function kubectl_program(): string
	local configured = tern.kv.get("kubectl")
	if type(configured) == "string" and configured ~= "" then
		return configured
	end
	local env = tern.getenv("KUBE_LENS_KUBECTL")
	if env and env ~= "" then
		return env
	end
	return "kubectl"
end

local function visible(state: ExploreState): { Pod }
	if state.query == "" then
		return state.pods
	end
	local out: { Pod } = {}
	local q = string.lower(state.query)
	for _, p in state.pods do
		if string.find(string.lower(p.name), q, 1, true) then
			table.insert(out, p)
		end
	end
	return out
end

-- Target flags come from the lensed command (link params), never from the
-- daemon's environment, which may point at another cluster.
local function fetch_argv(state: ExploreState, prog: string): { string }
	local argv = { prog }
	local kubeconfig, context, namespace =
		param(state, "kubeconfig"), param(state, "context"), param(state, "namespace")
	if kubeconfig then
		table.insert(argv, "--kubeconfig")
		table.insert(argv, kubeconfig)
	end
	if context then
		table.insert(argv, "--context")
		table.insert(argv, context)
	end
	for _, a in { "get", "pods", "-o", "json" } do
		table.insert(argv, a)
	end
	if namespace then
		table.insert(argv, "-n")
		table.insert(argv, namespace)
	end
	return argv
end

local function fetch(state: ExploreState, cx: BlockCx)
	local prog = kubectl_program()
	local t0 = tern.now()
	local ok, err = pcall(function()
		tern.process.run(fetch_argv(state, prog), { timeout_ms = 10000, cwd = cx.cwd }, function(res: ProcessResult)
			log.debug(
				"kube-lens explore.fetch",
				prog,
				"status=" .. res.status,
				"took_ms=" .. math.floor(tern.now() - t0)
			)
			if state.stopped then
				return
			end
			if res.timed_out then
				state.status = "kubectl timed out"
			elseif res.status ~= 0 then
				state.status = "kubectl failed: " .. string.sub(res.stderr, 1, 200)
			else
				local okj, doc = pcall(json.decode, res.stdout)
				local pods: { Pod } = {}
				if okj and type(doc) == "table" and type(doc.items) == "table" then
					for _, item in doc.items do
						local phase = if type(item.status) == "table" then item.status.phase else nil
						table.insert(pods, { name = item.metadata.name, phase = phase or "?" })
					end
				end
				state.pods = pods
				state.status = #pods .. " pods"
			end
			cx:render()
		end)
	end)
	state.status = if ok then "loading" else "cannot run " .. prog .. ": " .. tostring(err)
end

-- Plugin blocks get no close callback: poll the pane list and stop when the
-- block's pane is gone.
local function watch_liveness(state: ExploreState, cx: BlockCx)
	local function tick()
		if state.stopped then
			return
		end
		for _, p in tern.pane.list() do
			if p.pane == cx.pane then
				tern.timer(2000, tick)
				return
			end
		end
		state.stopped = true
	end
	tern.timer(2000, tick)
end

tern.block.define("explore", {
	init = function(cx: BlockCx, block_args: { string }, saved: any): ExploreState
		local url = block_args[1] or ""
		local state: ExploreState = {
			args = block_args,
			params = if string.sub(url, 1, 12) == "kube-lens://" then Command.parseQuery(url) else {},
			pods = {},
			sel = 1,
			query = if type(saved) == "table" and type(saved.query) == "string" then saved.query else "",
			editing = false,
			status = "starting",
			stopped = false,
		}
		fetch(state, cx)
		watch_liveness(state, cx)
		return state
	end,
	view = function(state: ExploreState, _cx: BlockCx): BlockView
		local pods = visible(state)
		local items: { Node } = {}
		for _, p in pods do
			local tone = Values.statusTone("STATUS", p.phase)
			local style = if tone == "neutral" then "strong" else tone .. " strong"
			table.insert(items, ui.node("item", { key = p.name, label = p.name, value = { ui.span(p.phase, style) } }))
		end
		local sel = pods[state.sel]
		local target: { { Spans } } = {}
		for _, p in state.params do
			table.insert(target, { ui.span(p.key, "muted"), ui.span(p.value, "mono") })
		end
		return {
			main = ui.col({
				with_props(
					ui.text({ ui.span("Explore ", "strong"), ui.span(table.concat(state.args, " "), "mono") }),
					{ key = "head" }
				),
				with_props(ui.kv(target), { key = "target", role = "kube-lens.explore-target" }),
				ui.node("input", {
					key = "query",
					text = state.query,
					cursor = #state.query,
					placeholder = "press / to filter",
					prompt = "/",
				}),
				ui.node("list", {
					key = "items",
					selected = if sel then "main.items." .. sel.name else nil,
					max = { lines = 15 },
					empty = "no pods",
				}, items),
				with_props(
					ui.text(ui.span(state.status .. "  ·  j/k move  / filter  esc close", "muted")),
					{ key = "status" }
				),
			}),
		}
	end,
	title = function(_state: ExploreState): string?
		return "Kube Explore"
	end,
	key = function(state: ExploreState, key: Key, cx: BlockCx): boolean?
		if state.editing then
			if key.name == "escape" or key.name == "enter" then
				state.editing = false
			elseif key.name == "backspace" then
				state.query = string.sub(state.query, 1, -2)
			elseif key.text and not key.ctrl and not key.meta then
				state.query ..= key.text
			else
				return false
			end
			state.sel = 1
			return true
		end
		local n = #visible(state)
		if key.name == "j" or key.name == "down" then
			state.sel = math.min(n, state.sel + 1)
		elseif key.name == "k" or key.name == "up" then
			state.sel = math.max(1, state.sel - 1)
		elseif key.name == "/" then
			state.editing = true
			cx:frame({ { "focus", "main.query" } })
		elseif key.name == "escape" then
			state.stopped = true
			cx:exit(0)
		else
			return false
		end
		return true
	end,
	event = function(state: ExploreState, ev: UiEvent, cx: BlockCx)
		if ev.ev == "focus" and ev.id then
			state.editing = true
			cx:frame({ { "focus", ev.id } })
		end
	end,
	save = function(state: ExploreState): any
		return { query = state.query }
	end,
})

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
