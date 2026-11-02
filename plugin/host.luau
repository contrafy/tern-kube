--!strict
local Argv = require("./lib/kubectl/argv")
local Capture = require("./lib/lens/capture")
local Command = require("./lib/kubectl/command")
local ConfigHost = require("./config_host")
local HelmChip = require("./lib/render/helm_chip")
local Link = require("./lib/mutation/link")
local LogsParse = require("./lib/logs/parse")
local LogsRender = require("./lib/logs/render")
local LogsStore = require("./lib/logs/store")
local LogsViewstate = require("./lib/logs/viewstate")
local ModelTypes = require("./lib/model/types")
local Quick = require("./lib/actions/quick")
local Redact = require("./lib/model/redact")
local Values = require("./lib/model/values")
local View = require("./lib/lens/view")
local Viewstate = require("./lib/lens/viewstate")

local json = tern.json
local log = tern.log

type ViewState = Viewstate.ViewState
type Capture = Capture.Capture
type Invocation = ModelTypes.Invocation
type StreamingView = "raw" | "native"

local SPOOL = tern.plugin.data .. "/spool"
local GUARD_CORE = tern.plugin.dir .. "/shell/tern-kube-guard"

pcall(tern.fs.mkdir, tern.plugin.data)
pcall(tern.fs.mkdir, SPOOL)

local function ms(t0: number): number
	return math.floor((os.clock() - t0) * 100000) / 100
end

-- Lens `kubectl` ---------------------------------------------------------------

-- open/line/finish only record: Tern replays them on rehydration, so they
-- must stay side-effect free. Everything else happens in view/event.
-- One lens claims every verb ("claims broad, views strict"); open re-derives
-- the verb: `logs` keeps an incremental records store, everything else the
-- captured lines for the table/describe/mutation pipeline.
type CaptureState = {
	kind: "capture",
	run: LensRun,
	-- An event watch (`get events -w`, `events -w`); liveRaw: it stays raw
	-- while it runs (general.streaming_view is not "native").
	watch: boolean,
	liveRaw: boolean,
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
	streamingView: StreamingView,
}

type LogsState = {
	kind: "logs",
	run: LensRun,
	inv: Invocation,
	store: LogsStore.Store,
	view: LogsViewstate.LogsView,
	native: boolean,
	streamingView: StreamingView,
	pageSize: number,
	warned: boolean,
}

type LensState = CaptureState | LogsState

-- Structured output is only valid as a whole; while it streams, raw is shown.
local NEEDS_FINISH: { [string]: boolean } = { json = true, yaml = true, describe = true }

-- Parsing cost is linear in lines (about 15 us per line in the plugin VM), and
-- Tern waits for `view` before feeding more output: past general.max_rows
-- lines or general.max_capture_bytes the native view would stall the pane, so
-- the block stays raw. While a command still runs, every `view` rebuilds
-- the capture; above this many lines the live view stays raw until the
-- command finishes.
local MAX_RUNNING_LINES = 2000

local function warnOnce(state: { warned: boolean, run: LensRun }, what: string, err: any)
	if not state.warned then
		state.warned = true
		log.warn("tern-kube " .. what .. " failed; showing raw", state.run.line, tostring(err))
	end
end

local function decode(text: string): any
	return json.decode(text)
end

local function captureOf(state: CaptureState): Capture?
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
		if state.liveRaw then
			return nil
		end
		return Capture.build(run, state.lines, nil, { decode = decode, policy = state.policy })
	end
	local capture = Capture.build(run, state.lines, state.status, { decode = decode, policy = state.policy })
	state.capture = capture
	return capture
end

local function copyAction(state: CaptureState, value: string, cx: EffectCx)
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

local function cwdOf(run: LensRun): string?
	local cwd = run.cwd
	return if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil
end

local EXPLORE_ROUTES: { [string]: boolean } = { manifest = true, diff = true, events = true, compare = true }

local function exploreAction(state: CaptureState, key: string, cx: EffectCx, route: string?)
	local capture = captureOf(state)
	if capture == nil then
		return
	end
	local row = Capture.findRow(capture, key)
	if row == nil or row.ref == nil then
		return
	end
	-- window.luau's route.link claims every tern-kube:// URL; an unclaimed
	-- one would fall through to the OS and show a system dialog.
	cx:open(Command.exploreUrl(capture.invocation, row.ref, { route = route, cwd = cwdOf(state.run) }))
end

-- Inspector quick-action chips carry a tern-kube://act/ link built by
-- Quick.encode; the window's route.link rebuilds the command from the
-- validated fields. Anything else is dropped here so no stray URL reaches
-- cx:open (an unclaimed scheme would raise an OS dialog).
local function quickAction(url: string, cx: EffectCx)
	local req, err = Quick.decode(url)
	if req == nil then
		log.warn("tern-kube lens quick action ignored", url, tostring(err))
		return
	end
	cx:open(url)
end

-- Mutation chips (Delete, Restart, Label, Drain, ...) carry a
-- tern-kube://mutate link; the window opens the approve block for it, which
-- previews before anything runs.
local function mutateAction(url: string, cx: EffectCx)
	local req, err = Link.decode(url)
	if req == nil then
		log.warn("tern-kube lens mutation ignored", url, tostring(err))
		return
	end
	cx:open(url)
end

-- "Helm release ns/X" chips carry only the release key; the URL pins the
-- invocation's context and kubeconfig, and the window routes it to the
-- helm-release Explore route.
local function helmAction(state: CaptureState, value: string, cx: EffectCx)
	local capture = captureOf(state)
	if capture == nil then
		return
	end
	local url = HelmChip.url(capture.invocation, value, cwdOf(state.run))
	if url == nil then
		log.warn("tern-kube lens helm chip ignored", value)
		return
	end
	cx:open(url)
end

-- This host's quick_actions settings travel in quick-action links: the
-- window opens the split, but this host's config governs its panes.
local function hostQuick(): Quick.Settings
	local qa = ConfigHost.current().quick_actions
	return { placement = qa.placement, logsTail = qa.logs_tail }
end

-- Logs branch ---------------------------------------------------------------------

local function programOf(inv: Invocation): string
	return if string.match(inv.program, "([^/\\]+)$") == "kubecolor" then "kubecolor" else "kubectl"
end

local function containersOf(store: LogsStore.Store): { string }?
	for _, n in store.notices do
		if n.kind == "defaulted-container" and n.containers then
			return n.containers
		end
	end
	return nil
end

-- Chips of the logs view. Every URL comes from Quick.encode or
-- Command.exploreUrl over the parsed argv, never from output text.
local function logsLinks(state: LogsState): LogsRender.Links
	local inv = state.inv
	local src = Command.logsSource(inv)
	local ref = src.ref
	local target: Quick.Target = { context = inv.context, kubeconfig = inv.kubeconfig }
	local scoped = if ref == nil and src.selector then { selector = src.selector, namespace = inv.namespace } else nil
	local links: LogsRender.Links = { variants = {} }
	if ref or scoped then
		local followOpts: Quick.Opts = { container = src.container }
		if scoped then
			followOpts.selector = scoped.selector
			followOpts.namespace = scoped.namespace
		end
		links.follow = Quick.encode("logs-follow", target, ref, Quick.withHost("logs-follow", followOpts, hostQuick()))
		local extra: Command.ExploreExtra = {
			route = "logs",
			cwd = cwdOf(state.run),
			container = src.container,
			previous = src.previous,
			selector = if scoped then scoped.selector else nil,
			since = src.since,
		}
		links.explore = Command.exploreUrl(inv, ref, extra)
		local search = table.clone(extra)
		search.search = true
		links.search = Command.exploreUrl(inv, ref, search)
	end
	if ref == nil and scoped == nil then
		return links
	end
	local program = programOf(inv)
	local function base(): Quick.Opts
		return {
			container = src.container,
			allContainers = if src.allContainers then true else nil,
			previous = if src.previous then true else nil,
			since = src.since,
			tail = src.tail,
			timestamps = if src.timestamps then true else nil,
			prefix = if src.prefix then true else nil,
			selector = if scoped then scoped.selector else nil,
			namespace = if scoped then scoped.namespace else nil,
			program = program,
		}
	end
	local function add(label: string, opts: Quick.Opts)
		local url = Quick.encode("logs", target, ref, Quick.withHost("logs", opts, hostQuick()))
		if url == nil then
			return
		end
		local typed = Quick.typedLine(target, ref, opts)
		table.insert(links.variants, { label = label, url = url, title = if typed then typed.line else label })
	end
	local containers = containersOf(state.store)
	if containers then
		local current = src.container or state.store.sources[1] and state.store.sources[1].container
		for _, c in containers do
			if c ~= current then
				local o = base()
				o.container = c
				o.allContainers = nil
				add(c, o)
			end
		end
	elseif src.container and not src.allContainers then
		links.otherContainers = true
	end
	if not src.previous then
		local o = base()
		o.previous = true
		add("--previous", o)
	end
	if not (src.allContainers and src.prefix) then
		local o = base()
		o.container = nil
		o.allContainers = true
		o.prefix = true
		add("--all-containers --prefix", o)
	end
	if not (src.timestamps and src.prefix) then
		local o = base()
		o.timestamps = true
		o.prefix = true
		add("--timestamps --prefix", o)
	end
	return links
end

local function logsView(state: LogsState): Node?
	local running = state.store.status == nil
	return LogsRender.render(state.store, state.inv, state.view, logsLinks(state), {
		pageSize = state.pageSize,
		running = running,
		streamingView = state.streamingView,
	}) :: any
end

local function logsCopy(state: LogsState, what: "line" | "msg" | "json", value: string, cx: EffectCx)
	local text = LogsRender.copyText(state.store, tonumber(value) or 0, what)
	if text == nil then
		cx:toast("error", "Nothing to copy", "The line is no longer kept; Raw shows everything")
		return
	end
	cx:copy(text)
	cx:toast("success", "Copied", if #text > 120 then string.sub(text, 1, 120) .. "…" else text)
end

local function logsEvent(state: LogsState, act: string, value: string, cx: EffectCx)
	if act == "lv" then
		state.view = LogsViewstate.decode(value)
	elseif act == "copy-line" then
		logsCopy(state, "line", value, cx)
	elseif act == "copy-msg" then
		logsCopy(state, "msg", value, cx)
	elseif act == "copy-json" then
		logsCopy(state, "json", value, cx)
	elseif act == "act" then
		quickAction(value, cx)
	elseif act == "explore-logs" then
		local links = logsLinks(state)
		local url = if value == "search" then links.search else links.explore
		if url then
			cx:open(url)
		end
	elseif act == "explore-pod" then
		local pod = LogsRender.podOf(state.store, tonumber(value) or 0)
		if pod then
			cx:open(Command.exploreUrl(state.inv, {
				clusterContext = state.inv.context,
				namespace = state.inv.namespace,
				group = nil,
				version = nil,
				kind = "Pod",
				name = pod,
				uid = nil,
				source = "snapshot",
			}, { cwd = cwdOf(state.run) }))
		end
	end
end

local function captureEvent(state: CaptureState, act: string, value: string, cx: EffectCx)
	if act == "v" then
		state.view = Viewstate.decode(value)
	elseif act == "copy" then
		copyAction(state, value, cx)
	elseif act == "explore" then
		exploreAction(state, value, cx, nil)
	elseif act == "explore-route" then
		local route, key = string.match(value, "^(%a+)|(.+)$")
		if route and EXPLORE_ROUTES[route] and key then
			exploreAction(state, key, cx, route)
		end
	elseif act == "act" then
		quickAction(value, cx)
	elseif act == "mutate" then
		mutateAction(value, cx)
	elseif act == HelmChip.ACT then
		helmAction(state, value, cx)
	end
end

local function captureView(state: CaptureState): Node?
	local capture = captureOf(state)
	if capture == nil then
		return nil
	end
	local notes = if state.watch and state.status == nil then { LogsRender.TRAILS } else nil
	return View.render(
		capture,
		state.view,
		{ pageSize = state.pageSize, mutations = state.mutations, notes = notes, quick = hostQuick() }
	) :: any
end

tern.lens.define("kubectl", {
	open = function(run: LensRun, _cx: EffectCx): LensState
		local cfg = ConfigHost.current()
		local inv = Argv.parse(run.program, run.args)
		local streamingView: StreamingView = if cfg.general.streaming_view == "native" then "native" else "raw"
		if inv.verb == "logs" and Argv.lensSupport(inv).supported then
			local logs: LogsState = {
				kind = "logs",
				run = run,
				inv = inv,
				store = LogsStore.new(
					LogsParse.optionsFor(inv, decode),
					{ maxLines = cfg.general.max_rows, maxBytes = cfg.general.max_capture_bytes }
				),
				view = LogsViewstate.default(),
				native = cfg.general.native_default,
				streamingView = streamingView,
				pageSize = cfg.general.max_rendered_rows,
				warned = false,
			}
			return logs
		end
		local captured: CaptureState = {
			kind = "capture",
			run = run,
			watch = inv.watch and Argv.isEventsListing(inv),
			liveRaw = View.rawWhileRunning(inv, streamingView),
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
			streamingView = streamingView,
		}
		return captured
	end,
	line = function(state: LensState, l: LensLine)
		if state.kind == "logs" then
			LogsStore.push(state.store, l.text)
			return
		end
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
		if state.kind == "logs" then
			LogsStore.finish(state.store, status)
		else
			state.status = status
		end
	end,
	view = function(state: LensState): Node?
		if not state.native then
			return nil
		end
		local t0 = os.clock()
		local ok, node = pcall(function(): Node?
			if state.kind == "logs" then
				return logsView(state)
			end
			return captureView(state)
		end)
		if not ok then
			warnOnce(state, "view", node)
			return nil
		end
		if state.kind == "logs" then
			log.debug(
				"tern-kube lens.view",
				"kind=logs",
				"lines=" .. state.store.lines,
				"kept=" .. LogsStore.size(state.store),
				"native=" .. tostring(node ~= nil),
				"finished=" .. tostring(state.store.status ~= nil),
				"view_ms=" .. ms(t0),
				"lua_kb=" .. gcinfo()
			)
		else
			log.debug(
				"tern-kube lens.view",
				"lines=" .. #state.lines,
				"overflow=" .. tostring(state.overflow),
				"finished=" .. tostring(state.status ~= nil),
				"view_ms=" .. ms(t0),
				"lua_kb=" .. gcinfo()
			)
		end
		return node
	end,
	event = function(state: LensState, ev: UiEvent, cx: EffectCx)
		if ev.ev ~= "action" then
			return
		end
		local value: string = if type(ev.value) == "string" then ev.value else ""
		local act: string = if type(ev.act) == "string" then ev.act else ""
		local ok, err = pcall(function()
			if state.kind == "logs" then
				logsEvent(state, act, value, cx)
			else
				captureEvent(state, act, value, cx)
			end
		end)
		if not ok then
			warnOnce(state, "event " .. act, err)
		end
	end,
})

require("./explore_host").register()
require("./mutate_host").register()
require("./settings_host").register()
-- The login shell's PATH is read in the background from plugin load, so
-- the first Explore rarely waits for it.
require("./env_host").start()

-- Hooks ----------------------------------------------------------------------

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	spec.env.TKUBE_SPOOL = SPOOL
	-- A remote pane's edit split runs this host's guard; the window only
	-- knows its own plugin path.
	spec.env.TKUBE_GUARD_CORE = GUARD_CORE
	return spec
end)
