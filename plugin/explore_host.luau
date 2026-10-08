--!strict
-- Host glue for the Explore block: executes the effects the pure core
-- (lib/explore/state.luau) returns and feeds process results, ticks, keys and
-- view events back as messages. All decisions live in the core.
--
-- Processes cannot be killed before their timeout; a closed block or a
-- superseded load just ignores the late callback (state.luau compares
-- generations; `stopped` covers a closed pane).

local ConfigHost = require("./config_host")
local GitopsHost = require("./gitops_host")
local Render = require("./lib/explore/render")
local State = require("./lib/explore/state")

local log = tern.log

type Effect = State.Effect
type Msg = State.Msg

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean, scan: GitopsHost.Scan? }

local M = {}

M.TMP = tern.plugin.data .. "/tmp"
-- Temporary manifests older than this are removed when a block opens.
M.TMP_MAX_AGE_S = 86400
M.TREE_MAX_FILES = 2000
M.TREE_DEPTH = 8
M.TREE_FILE_BYTES = 1048576

M.LIVENESS_MS = 2000

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-kube explore " .. what .. " failed", tostring(err))
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
			"tern-kube explore.run",
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
		tern.process.run(argv, {
			timeout_ms = e.timeout_ms,
			cwd = e.cwd or h.cx.cwd,
			env = e.env,
			stdin = e.stdin,
		}, function(res: ProcessResult)
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

local function deliverResult(h: Host, e: Effect, extra: { [string]: any })
	if h.stopped then
		return
	end
	local msg: { [string]: any } = {
		t = "result",
		tag = e.tag,
		gen = e.gen,
		result = { status = 0, stdout = "", stderr = "", timed_out = false },
		at = os.time(),
	}
	for k, v in extra do
		msg[k] = v
	end
	dispatch(h, msg :: any)
	h.cx:render()
end

local function failed(err: any): ProcessResult
	return { status = 1, stdout = "", stderr = tostring(err), timed_out = false }
end

-- The manifest index (gitops_host.scan): progress messages, then one result.
local function scan(h: Host, e: Effect)
	if h.scan then
		h.scan.cancel()
	end
	h.scan = GitopsHost.scan(e.cwd or "", e.scan :: any, function(progress)
		if not h.stopped then
			dispatch(h, { t = "progress", tag = e.tag, gen = e.gen, progress = progress :: any })
			h.cx:render()
		end
	end, function(index, err)
		h.scan = nil
		if index then
			deliverResult(h, e, { index = index })
		else
			deliverResult(h, e, { result = failed(err or "manifest scan failed") })
		end
	end)
end

local function readFile(h: Host, e: Effect)
	local ok, text = pcall(tern.fs.read, e.path or "")
	deliverResult(h, e, {
		result = if ok then { status = 0, stdout = text, stderr = "", timed_out = false } else failed(text),
	})
end

local MANIFEST_NAMES = { ["kustomization.yaml"] = true, ["kustomization.yml"] = true, Kustomization = true }

-- YAML and kustomization files under a directory (bounded); a missing
-- directory is empty.
local function readTree(h: Host, e: Effect)
	local files: { [string]: string } = {}
	local count = 0
	local function walk(dir: string, depth: number)
		local ok, names = pcall(tern.fs.list, dir)
		if not ok then
			return
		end
		for _, name in names :: { string } do
			if count >= M.TREE_MAX_FILES then
				return
			end
			local path = dir .. "/" .. name
			if string.match(string.lower(name), "%.ya?ml$") or MANIFEST_NAMES[name] then
				local okRead, text = pcall(tern.fs.read, path, M.TREE_FILE_BYTES)
				if not okRead then
					okRead, text = pcall(tern.fs.read, path)
				end
				if okRead then
					files[path] = text
					count += 1
				end
			elseif depth < M.TREE_DEPTH and string.sub(name, 1, 1) ~= "." then
				walk(path, depth + 1)
			end
		end
	end
	walk(e.path or "", 0)
	deliverResult(h, e, { files = files })
end

-- Export writes: parents are created, every file replaced; the core only
-- asks after the user confirmed the previewed diff.
local function writeFiles(h: Host, e: Effect)
	local writes: { { path: string, text: string } } = e.files or {}
	for _, f in writes do
		local ok, err = pcall(function()
			local dir = string.match(f.path, "^(.*)/[^/]*$")
			if dir and dir ~= "" then
				tern.fs.mkdir(dir)
			end
			tern.fs.write(f.path, f.text)
		end)
		if not ok then
			deliverResult(h, e, { result = failed(f.path .. ": " .. tostring(err)) })
			return
		end
	end
	deliverResult(h, e, {})
end

-- Removes temporary manifests left behind (apply bundles the approve block
-- no longer needs, diff inputs of a closed block).
local function sweepTmp()
	local ok, names = pcall(tern.fs.list, M.TMP)
	if not ok then
		return
	end
	local now = os.time()
	for _, name in names :: { string } do
		local at = tonumber(string.match(name, "^%a+%-(%d+)%-[%w]+%.yaml$") or "")
		if at and now - at > M.TMP_MAX_AGE_S then
			pcall(tern.fs.remove, M.TMP .. "/" .. name)
		end
	end
end

local function nonce(): string
	return string.format("%08x%04x", math.random(0, 0x7fffffff), math.floor(tern.now()) % 0x10000)
end

local function isList(t: { [any]: any }): boolean
	return next(t) == nil and tern.json.encode(t) == "[]"
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
			-- window.luau's route.link claims every tern-kube:// URL.
			h.cx:open(e.url or "")
		elseif e.t == "save" then
			h.cx:save()
		elseif e.t == "focus" then
			h.cx:frame({ { "focus", e.id or State.FILTER_INPUT } })
		elseif e.t == "render" then
			h.cx:render()
		elseif e.t == "scan" then
			scan(h, e)
		elseif e.t == "read" then
			readFile(h, e)
		elseif e.t == "readtree" then
			readTree(h, e)
		elseif e.t == "write" then
			writeFiles(h, e)
		elseif e.t == "openfile" then
			-- Tern opens `<path>:<line>` in a file block at that line.
			h.cx:open((e.path or "") .. (if e.line then ":" .. e.line else ""))
		elseif e.t == "exit" then
			h.stopped = true
			if h.scan then
				h.scan.cancel()
			end
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
		if h.scan then
			h.scan.cancel()
		end
		log.debug("tern-kube explore pane gone", h.cx.pane)
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
					p = { spans = { { t = "Tern Kube Explore could not render: " .. tostring(err), s = "error" } } },
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
			pcall(sweepTmp)
			local s, effects = State.init(args, saved, snap.config, {
				kubeconfig = env.kubeconfig,
				home = env.home,
				kubectl = ConfigHost.kubectl(),
				decode = tern.json.decode,
				now = os.time(),
				cwd = cx.cwd,
				dataDir = tern.plugin.data,
				nonce = nonce,
				isList = isList,
				null = tern.json.null,
			})
			local h: Host = { s = s, cx = cx, stopped = false, warned = false, scan = nil }
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
			return if ok then title else "Tern Kube Explore"
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key :: any })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "focus" and ev.id == State.FILTER_INPUT then
				dispatch(h, { t = "action", act = "filter-focus" })
			elseif ev.ev == "focus" and type(ev.id) == "string" and string.sub(ev.id, 1, 12) == "main.gitops-" then
				dispatch(h, { t = "action", act = "field-focus", value = string.sub(ev.id, 13) })
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
