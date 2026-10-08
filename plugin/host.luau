--!strict
local args = require("./lib/args")
local columns = require("./lib/columns")
local lui = require("./lib/ui")
local rowslib = require("./lib/rows")
local viewstate = require("./lib/viewstate")

local ui = tern.ui
local json = tern.json
local log = tern.log

type ViewState = viewstate.ViewState
type Row = columns.Row
type Column = columns.Column

local SPOOL = tern.plugin.data .. "/spool"
local MAX_ROWS = 500

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

local function chip(label: string, action: string, tone: string, title: string?): Node
	return lui.badge(label, tone, { actions = { click = action }, title = title }) :: any
end

local STATUS_TONE: { [string]: string } = {
	Running = "success",
	Completed = "muted",
	Succeeded = "muted",
	Pending = "warning",
	ContainerCreating = "warning",
	Terminating = "warning",
	CrashLoopBackOff = "error",
	Error = "error",
	ImagePullBackOff = "error",
	ErrImagePull = "error",
	OOMKilled = "error",
}

local function cell(col: string, value: string): lui.Span
	if col == "STATUS" then
		return lui.span(value, (STATUS_TONE[value] or "") .. " strong")
	elseif col == "NAME" then
		return lui.span(value, "strong")
	end
	return lui.span(value)
end

-- Lens `get` -----------------------------------------------------------------

type LensState = {
	run: LensRun,
	lines: { string },
	status: number?,
	view: ViewState,
	t_lines: number,
}

local function inspector(cols: { Column }, row: Row, v: ViewState): lui.Node
	local items: { { { lui.SpanLike } } } = {}
	for _, c in cols do
		local key: { lui.SpanLike } = { c.head }
		local value: { lui.SpanLike } = { cell(c.id, row.cells[c.id] or "") }
		table.insert(items, { key, value })
	end
	return lui.col({
		lui.kv(items),
		lui.row({
			chip("Explore", "explore=" .. row.id, "accent", "Open the Explore block"),
			chip("Copy name", "copy-name=" .. row.id, "neutral"),
			chip("Close", viewstate.action(viewstate.toggled(v, row.id)), "neutral"),
		}),
	}, { role = "kube-lens.inspector" })
end

local function grid(cols: { Column }, rows: { Row }, v: ViewState): lui.Node
	local cells: { lui.Node } = table.create(#cols + #rows * (#cols + 1))
	for _, c in cols do
		local label = c.head
		if v.sort == c.id then
			label ..= if v.desc then " v" else " ^"
		end
		table.insert(
			cells,
			lui.el("div", {
				class = "kl-h",
				text = label,
				title = "Sort by " .. c.head,
				actions = { click = viewstate.action(viewstate.sorted_by(v, c.id)) },
			})
		)
	end
	for _, r in rows do
		local is_open = v.open == r.id
		local tds: { lui.Node } = table.create(#cols)
		for i, c in cols do
			tds[i] = lui.el("div", { class = "kl-c" }, { lui.text({ cell(c.id, r.cells[c.id] or "") }) })
		end
		table.insert(
			cells,
			lui.el("div", {
				key = r.id,
				class = if is_open then "kl-r kl-open" else "kl-r",
				actions = { click = viewstate.action(viewstate.toggled(v, r.id)) },
			}, tds)
		)
		if is_open then
			table.insert(cells, lui.el("div", { key = r.id .. "/insp", class = "kl-insp" }, { inspector(cols, r, v) }))
		end
	end
	return lui.el("div", { key = "grid", class = "kl-grid kl-cols-" .. math.min(#cols, 12) }, cells)
end

local function table_lines(lines: { string }): { string }
	local n = #lines
	if n > 0 and string.match(lines[n], "^%^C") then
		n -= 1
	end
	return table.move(lines, 1, n, 1, table.create(n))
end

local function view_table(state: LensState): Node?
	local parsed = columns.parse(table_lines(state.lines))
	if parsed == nil then
		return nil
	end
	local v = state.view
	local rows = rowslib.sorted(parsed.rows, v.sort, v.desc)
	local hidden = 0
	if #rows > MAX_ROWS then
		hidden = #rows - MAX_ROWS
		rows = table.move(rows, 1, MAX_ROWS, 1, table.create(MAX_ROWS))
	end
	local summary = (#rows + hidden) .. " rows"
	if v.sort then
		summary ..= "  ·  sorted by " .. v.sort .. (if v.desc then " (desc)" else "")
	end
	local children: { lui.Node } = { lui.text({ lui.span(summary, "muted") }), grid(parsed.cols, rows, v) }
	if hidden > 0 then
		table.insert(children, lui.text({ lui.span("… " .. hidden .. " more (Raw shows everything)", "muted") }))
	end
	if state.status ~= nil and state.status ~= 0 then
		table.insert(children, lui.text({ lui.span("exit " .. state.status, "error") }))
	end
	return lui.col(children, { role = "kube-lens.get" }) :: any
end

tern.lens.define("get", {
	open = function(run: LensRun, _cx: EffectCx): LensState
		log.debug("kube-lens lens.open", run.line)
		return { run = run, lines = {}, status = nil, view = viewstate.default(), t_lines = 0 }
	end,
	line = function(state: LensState, l: LensLine)
		local t0 = os.clock()
		table.insert(state.lines, l.text)
		state.t_lines += ms(t0)
	end,
	finish = function(state: LensState, status: number)
		state.status = status
	end,
	view = function(state: LensState): Node?
		local t0 = os.clock()
		local run_args = state.run.args
		if args.verb(run_args) ~= "get" then
			return nil
		end
		local node: Node?
		local fmt = args.output(run_args)
		if fmt == "json" then
			node = if state.status ~= nil then tern.parse.json_tree(table.concat(state.lines, "\n")) else nil
		elseif fmt == nil or fmt == "wide" or string.match(fmt, "^custom%-columns") then
			node = view_table(state)
		end
		log.debug(
			"kube-lens lens.view",
			"lines=" .. #state.lines,
			"finished=" .. tostring(state.status ~= nil),
			"line_ms=" .. state.t_lines,
			"view_ms=" .. ms(t0)
		)
		return node
	end,
	event = function(state: LensState, ev: UiEvent, cx: EffectCx)
		if ev.ev ~= "action" then
			return
		end
		local value: string = ev.value or ""
		if ev.act == "v" then
			state.view = viewstate.decode(value)
		elseif ev.act == "explore" then
			cx:open("kube-lens://explore?kind=pods&name=" .. value)
		elseif ev.act == "copy-name" then
			cx:copy(value)
			cx:toast("success", "Copied " .. value)
		end
	end,
})

-- Block `explore` ------------------------------------------------------------

type Pod = { name: string, phase: string }
type ExploreState = {
	args: { string },
	pods: { Pod },
	sel: number,
	query: string,
	editing: boolean,
	status: string,
	stopped: boolean,
}

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

local function fetch(state: ExploreState, cx: BlockCx)
	local prog = kubectl_program()
	local t0 = tern.now()
	local ok, err = pcall(function()
		tern.process.run(
			{ prog, "get", "pods", "-o", "json" },
			{ timeout_ms = 10000, cwd = cx.cwd },
			function(res: ProcessResult)
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
			end
		)
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
		local state: ExploreState = {
			args = block_args,
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
			table.insert(items, ui.node("item", { key = p.name, label = p.name, value = { cell("STATUS", p.phase) } }))
		end
		local sel = pods[state.sel]
		return {
			main = ui.col({
				with_props(
					ui.text({ ui.span("Explore ", "strong"), ui.span(table.concat(state.args, " "), "mono") }),
					{ key = "head" }
				),
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
