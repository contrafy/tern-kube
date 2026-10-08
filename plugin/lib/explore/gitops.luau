--!strict
-- The GitOps routes of the Explore block (manifest, diff, drift, export,
-- git): their state, the effects they ask the host to run and how results
-- advance them. state.luau owns routing and keys and calls in here with a
-- Ctx describing the pinned target; nothing here touches `tern`.
--
-- Everything is user-initiated: the manifest index is built when a GitOps
-- route first needs it (and again on r), controllers are read only when an
-- object carries Argo CD / Flux tracking metadata or the drift chooser
-- opens. Every cluster command pins the target like query.luau does.
-- Temporary manifests (diff input, apply bundles) are written 0600 under
-- the plugin data directory; diff inputs are removed after the diff.

local Config = require("../config")
local Controllers = require("../gitops/controllers")
local Diffseg = require("../mutation/diffseg")
local Drift = require("../gitops/drift")
local Export = require("../gitops/export")
local Index = require("../gitops/index")
local Link = require("../mutation/link")
local Query = require("./query")
local Resource = require("../model/resource")
local T = require("./types")
local Types = require("../model/types")

export type Ref = Types.ResourceRef
export type Effect = T.Effect
export type Msg = T.Msg
export type Route = T.Route
type Item = T.Item
type Doc = Index.ManifestDoc
type Segment = Diffseg.Segment
type ProcessResult = T.ProcessResult

export type Ctx = {
	target: Query.Target,
	program: string,
	config: Config.Config,
	decode: T.Decode,
	resolved: boolean,
	now: number?,
	-- tern.plugin.data; temporary manifests go to <dataDir>/tmp.
	dataDir: string?,
	nonce: () -> string,
	-- Export: tells `[]` from `{}` in decoded JSON (emit.luau).
	isList: ((t: { [any]: any }) -> boolean)?,
	null: any?,
}

export type ScanStatus = "idle" | "scanning" | "ok" | "error"

export type Scan = { status: ScanStatus, gen: number, progress: T.Progress?, error: string?, at: number? }

export type Repo = { status: "idle" | "loading" | "ok", git: boolean, remotes: { string } }

export type Ctl = {
	status: "idle" | "loading" | "ok" | "error",
	gen: number,
	pending: { [string]: boolean },
	lists: { [string]: any },
	set: Controllers.Set?,
	error: string?,
}

export type DiffStatus = "index" | "nomatch" | "reading" | "writing" | "diffing" | "ok" | "error"

export type DiffLoad = {
	status: DiffStatus,
	gen: number,
	ref: Ref,
	pick: number,
	docs: { Doc },
	doc: Doc?,
	tmp: string?,
	argv: { string }?,
	segments: { Segment },
	notes: { string },
	exit: number?,
	error: string?,
	at: number?,
}

export type SourceEntry = {
	id: string,
	type: Index.SourceType,
	path: string,
	label: string,
	source: Index.Source,
	docs: number,
	namespaces: { string },
	note: string?,
	rank: number,
}

export type Filter = "all" | "changed" | "missing" | "unmanaged"

export type Entry = {
	key: string,
	bucket: "changed" | "missing" | "unmanaged",
	ref: Ref,
	docs: { Doc },
	segment: Segment?,
	object: Drift.ObjectSummary?,
	reason: ("create" | "absent")?,
}

export type DriftLoad = {
	status: "index" | "running" | "ok" | "error",
	gen: number,
	source: SourceEntry,
	argv: { string }?,
	tmp: string?,
	diff: Diffseg.Summary?,
	diffDone: boolean,
	diffError: string?,
	livePending: { [string]: boolean },
	live: { any },
	liveErrors: { string },
	report: Drift.Report?,
	error: string?,
	filter: Filter,
	at: number?,
}

export type ExportStatus = "index" | "reading" | "ok" | "writing" | "written" | "error"

export type ExportState = {
	status: ExportStatus,
	gen: number,
	objects: { any },
	label: string,
	dir: string,
	plan: Export.Plan?,
	expanded: { [string]: boolean },
	confirming: boolean,
	written: { string },
	error: string?,
	summary: string?,
}

export type StepStatus = "pending" | "running" | "ok" | "error" | "skipped"

export type GitStep = {
	id: string,
	label: string,
	argv: { string },
	cwd: string?,
	status: StepStatus,
	exit: number?,
	output: string?,
}

export type Checks = {
	pending: { [string]: boolean },
	staged: { string },
	unrelated: { string },
	head: string?,
	origin: boolean,
	gh: string?,
	ghAuth: boolean,
	errors: { string },
}

export type GitState = {
	status: "checking" | "ready" | "running" | "done" | "error",
	gen: number,
	root: string,
	files: { string },
	branch: string,
	message: string,
	push: boolean,
	pr: boolean,
	only: boolean,
	checks: Checks,
	steps: { GitStep },
	summary: string,
	error: string?,
}

export type Bundle = {
	gen: number,
	label: string,
	docs: { Doc },
	pending: { [string]: boolean },
	texts: { [string]: string },
	tmp: string?,
}

export type G = {
	cwd: string?,
	seq: number,
	scan: Scan,
	index: Index.Index?,
	repo: Repo,
	status: { [string]: Index.GitFileStatus },
	ctl: Ctl,
	diffs: { [string]: DiffLoad },
	drifts: { [string]: DriftLoad },
	export: ExportState?,
	git: GitState?,
	bundle: Bundle?,
	-- `m` before the index existed: open this object's manifest when it does.
	pendingOpen: Ref?,
	-- Text inputs while they are edited: "dir", "branch", "message".
	fields: { [string]: string },
}

export type Nav = { push: Route?, pop: boolean?, replace: Route? }

local M = {}

M.TAG = "gitops"
M.GIT_TIMEOUT_MS = 120000
M.STATUS_PATHSPECS = { "*.yaml", "*.yml", "*Kustomization" }
M.NO_CWD = "No working directory: open Explore from a pane inside the repository (or from a lens there)."
-- Writes stdin to "$1" readable by the user only.
M.WRITE_SCRIPT = 'umask 077 && mkdir -p -- "${1%/*}" && cat >"$1"'
M.MAX_STEP_OUTPUT = 4000

local GITOPS_KINDS: { [string]: boolean } = { manifest = true, diff = true, drift = true, export = true, git = true }

function M.isRoute(kind: string): boolean
	return GITOPS_KINDS[kind] == true
end

-- Helpers --------------------------------------------------------------------

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s)
end

local function firstLine(s: string): string
	return (string.match(trim(s), "^[^\n]*") or "") :: string
end

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	return if d == nil or d == "" then "/" else d
end

local function rel(g: G, path: string): string
	local index = g.index
	return if index then Index.relative(index.root, path) else path
end

M.rel = rel

-- "1 object", "3 objects".
function M.count(n: number, word: string, plural: string?): string
	return string.format("%d %s", n, if n == 1 then word else plural or word .. "s")
end

local function lines(text: string): { string }
	local out = string.split(text, "\n")
	for i, l in out do
		if string.byte(l, -1) == 13 then
			out[i] = string.sub(l, 1, -2)
		end
	end
	return out
end

function M.slice(text: string, first: number, last: number): string
	local all = lines(text)
	local out: { string } = {}
	for i = math.max(1, first), math.min(#all, last) do
		table.insert(out, all[i])
	end
	return table.concat(out, "\n") .. "\n"
end

local function toast(effects: { Effect }, level: "success" | "info" | "error", text: string, sub: string?)
	table.insert(effects, { t = "toast", level = level, text = text, sub = sub })
end

local function base(ctx: Ctx): { string }
	return Query.base(ctx.program, ctx.target)
end

local function push(argv: { string }, ...: string): { string }
	for _, a in { ... } do
		table.insert(argv, a)
	end
	return argv
end

local function runEffect(
	tag: string,
	gen: number,
	argv: { string },
	timeout: number,
	opts: { env: { [string]: string }?, cwd: string?, stdin: string? }?
): Effect
	local o: { env: { [string]: string }?, cwd: string?, stdin: string? } = opts
		or { env = nil, cwd = nil, stdin = nil }
	return {
		t = "run",
		tag = tag,
		gen = gen,
		argv = argv,
		timeout_ms = timeout,
		env = o.env,
		cwd = o.cwd,
		stdin = o.stdin,
	}
end

local function queryTimeout(ctx: Ctx): number
	return ctx.config.explore.query_timeout_ms
end

local function diffTimeout(ctx: Ctx): number
	return ctx.config.mutations.preview_timeout_ms
end

local function failText(what: string, r: ProcessResult?, spawnError: string?): string
	if spawnError then
		return what .. " could not start: " .. spawnError
	end
	local res = r :: ProcessResult
	if res.timed_out then
		return what .. " timed out"
	end
	local detail = firstLine(res.stderr ~= "" and res.stderr or res.stdout)
	return string.format("%s exited %d%s", what, res.status, if detail ~= "" then ": " .. detail else "")
end

local function nextGen(g: G): number
	g.seq += 1
	return g.seq
end

local function tmpPath(ctx: Ctx, prefix: string): string?
	if ctx.dataDir == nil then
		return nil
	end
	return string.format("%s/tmp/%s-%d-%s.yaml", ctx.dataDir :: string, prefix, ctx.now or 0, ctx.nonce())
end

local function writeTmp(tag: string, gen: number, path: string, text: string): Effect
	return runEffect(tag, gen, { "/bin/sh", "-c", M.WRITE_SCRIPT, "tern-kube-tmp", path }, 10000, { stdin = text })
end

local function removeTmp(tag: string, gen: number, path: string): Effect
	return runEffect(tag, gen, { "rm", "-f", "--", path }, 10000)
end

local DIFF_ENV: { [string]: string } = { KUBECTL_EXTERNAL_DIFF = "" }

local function diffEnv(): { [string]: string }
	return table.clone(DIFF_ENV)
end

local function redact(ctx: Ctx, summary: Diffseg.Summary): Diffseg.Summary
	return if ctx.config.security.show_secret_values then summary else Diffseg.redactSecrets(summary)
end

-- `kubectl diff` exits 0 in sync, 1 with differences, >1 on error. Exit 1
-- without a single difference is an error too (same rule as
-- bin/tern-kube-drift): showing it as "in sync" would hide the failure.
local function diffOutcome(ctx: Ctx, r: ProcessResult?, spawnError: string?): (Diffseg.Summary?, string?)
	local res = r :: ProcessResult
	if spawnError or res.timed_out or (res.status ~= 0 and res.status ~= 1) then
		return nil, failText("kubectl diff", r, spawnError)
	end
	local summary = Diffseg.parse(res.stdout)
	if res.status == 1 and #summary.segments == 0 then
		return nil, failText("kubectl diff", r, nil) .. " (no differences printed)"
	end
	return redact(ctx, summary), nil
end

-- State ----------------------------------------------------------------------

function M.new(cwd: string?): G
	return {
		cwd = cwd,
		seq = 0,
		scan = { status = "idle", gen = 0 },
		index = nil,
		repo = { status = "idle", git = false, remotes = {} },
		status = {},
		ctl = { status = "idle", gen = 0, pending = {}, lists = {}, set = nil },
		diffs = {},
		drifts = {},
		export = nil,
		git = nil,
		bundle = nil,
		pendingOpen = nil,
		fields = {},
	}
end

-- Shallow copy: every update works on a fresh G so older states stay valid.
function M.clone(g: G): G
	return table.clone(g)
end

function M.scanOpts(cfg: Config.Config): T.ScanOpts
	local helm = {}
	for i, r in cfg.gitops.helm do
		helm[i] = { chart = r.chart, release = r.release, namespace = r.namespace, values = table.clone(r.values) }
	end
	return {
		maxFiles = cfg.gitops.max_files,
		maxBytes = cfg.gitops.max_bytes,
		maxFileBytes = cfg.gitops.max_file_bytes,
		renderKustomize = cfg.gitops.render_kustomize,
		helm = helm,
	}
end

local function ready(g: G): boolean
	return g.scan.status == "ok" and g.index ~= nil
end

M.ready = ready

local function startScan(g: G, ctx: Ctx, effects: { Effect })
	if g.cwd == nil then
		g.scan = { status = "error", gen = g.scan.gen, error = M.NO_CWD }
		return
	end
	local gen = nextGen(g)
	g.scan = { status = "scanning", gen = gen, progress = nil }
	table.insert(effects, {
		t = "scan",
		tag = M.TAG .. "|scan",
		gen = gen,
		cwd = g.cwd,
		scan = M.scanOpts(ctx.config),
	})
end

-- Starts the index scan unless one exists or runs (or failed: r retries).
function M.ensureIndex(g: G, ctx: Ctx, effects: { Effect })
	if g.scan.status == "idle" then
		startScan(g, ctx, effects)
	end
end

function M.rescan(g: G, ctx: Ctx, effects: { Effect })
	if g.scan.status ~= "scanning" then
		startScan(g, ctx, effects)
	end
end

-- Matching -------------------------------------------------------------------

function M.matches(g: G, ctx: Ctx, ref: Ref): { Doc }
	local index = g.index
	if index == nil then
		return {}
	end
	return Index.match(index, ref, { defaultNamespace = ctx.target.namespace })
end

local function openDoc(doc: Doc, effects: { Effect })
	table.insert(effects, { t = "openfile", path = doc.file, line = doc.startLine })
end

-- `m`: opens the best manifest of `ref`; before the index exists it is
-- built first and the manifest opens when it is ready.
function M.openManifest(g: G, ctx: Ctx, ref: Ref, effects: { Effect })
	if not ready(g) then
		g.pendingOpen = ref
		M.ensureIndex(g, ctx, effects)
		if g.scan.status == "error" then
			toast(effects, "error", "Cannot index manifests", g.scan.error)
		end
		return
	end
	local docs = M.matches(g, ctx, ref)
	if #docs == 0 then
		toast(effects, "info", "No manifest declares " .. string.lower(ref.kind) .. "/" .. ref.name, "E exports it")
		return
	end
	openDoc(docs[1], effects)
end

-- Controllers ------------------------------------------------------------------

local TRACKING_LABELS = {
	"app.kubernetes.io/instance",
	"kustomize.toolkit.fluxcd.io/name",
	"helm.toolkit.fluxcd.io/name",
}

-- Whether an object carries Argo CD / Flux tracking metadata.
function M.tracked(obj: any): boolean
	if type(obj) ~= "table" or type(obj.metadata) ~= "table" then
		return false
	end
	local labels = obj.metadata.labels
	local annotations = obj.metadata.annotations
	if type(annotations) == "table" and annotations["argocd.argoproj.io/tracking-id"] ~= nil then
		return true
	end
	if type(labels) == "table" then
		for _, l in TRACKING_LABELS do
			if labels[l] ~= nil then
				return true
			end
		end
	end
	return false
end

function M.loadControllers(g: G, ctx: Ctx, effects: { Effect })
	if g.ctl.status ~= "idle" or not ctx.resolved then
		return
	end
	local gen = nextGen(g)
	g.ctl = { status = "loading", gen = gen, pending = { api = true }, lists = {}, set = nil }
	table.insert(
		effects,
		runEffect(M.TAG .. "|ctl|api", gen, push(base(ctx), "api-resources", "-o", "name"), queryTimeout(ctx))
	)
end

-- An opened object: read the controllers once when it is tracked.
function M.noticeObject(g: G, ctx: Ctx, obj: any, effects: { Effect })
	if M.tracked(obj) then
		M.loadControllers(g, ctx, effects)
	end
end

function M.owner(g: G, obj: any): Controllers.Owner?
	local set = g.ctl.set
	if set == nil or type(obj) ~= "table" then
		return nil
	end
	return Controllers.owner(obj, set)
end

-- The controller's source inside the local checkout, when its repository
-- is one of the checkout's remotes.
function M.localPath(g: G, info: { sources: { Controllers.Source } }): string?
	local index = g.index
	if index == nil or not g.repo.git then
		return nil
	end
	return Controllers.localPath(info, { root = index.root, remotes = g.repo.remotes })
end

local function finishControllers(g: G)
	local ctl = table.clone(g.ctl)
	ctl.status = "ok"
	ctl.set = Controllers.parse(ctl.lists)
	g.ctl = ctl
end

local function onControllers(g: G, ctx: Ctx, part: string, msg: Msg, effects: { Effect })
	if msg.gen ~= g.ctl.gen or g.ctl.status ~= "loading" then
		return
	end
	local ctl = table.clone(g.ctl)
	ctl.pending = table.clone(ctl.pending)
	ctl.lists = table.clone(ctl.lists)
	local r = msg.result :: ProcessResult
	local okRun = msg.spawnError == nil and r.status == 0
	if part == "api" then
		ctl.pending["api"] = nil
		if not okRun then
			ctl.status = "error"
			ctl.error = failText("kubectl api-resources", r, msg.spawnError)
			g.ctl = ctl
			return
		end
		for _, res in Controllers.queries(string.split(r.stdout, "\n")) do
			ctl.pending[res] = true
			table.insert(
				effects,
				runEffect(
					M.TAG .. "|ctl|" .. res,
					ctl.gen,
					push(base(ctx), "get", res, "-A", "-o", "json"),
					queryTimeout(ctx)
				)
			)
		end
	elseif ctl.pending[part] then
		ctl.pending[part] = nil
		if okRun then
			local ok, doc = pcall(ctx.decode, r.stdout)
			if ok and type(doc) == "table" then
				ctl.lists[part] = doc
			end
		end
	end
	g.ctl = ctl
	if next(ctl.pending) == nil then
		finishControllers(g)
	end
end

-- Scan results ---------------------------------------------------------------

local advanceDiff: (g: G, ctx: Ctx, id: string, effects: { Effect }) -> ()
local startDrift: (g: G, ctx: Ctx, id: string, effects: { Effect }) -> ()
local readExport: (g: G, ctx: Ctx, effects: { Effect }) -> ()

local function requestStatus(g: G, effects: { Effect })
	local index = g.index
	if index == nil or not g.repo.git then
		return
	end
	local argv = { "git", "-C", index.root, "status", "--porcelain=v1", "-z", "--" }
	for _, p in M.STATUS_PATHSPECS do
		table.insert(argv, p)
	end
	table.insert(effects, runEffect(M.TAG .. "|status", g.scan.gen, argv, 10000))
end

local function onScanDone(g: G, ctx: Ctx, msg: Msg, effects: { Effect })
	if msg.gen ~= g.scan.gen or g.scan.status ~= "scanning" then
		return
	end
	if msg.index == nil then
		local r = msg.result
		g.scan = {
			status = "error",
			gen = g.scan.gen,
			error = if r then trim(r.stderr) else "manifest scan failed",
			at = msg.at,
		}
		g.pendingOpen = nil
		return
	end
	local index = msg.index :: Index.Index
	g.index = index
	g.scan = { status = "ok", gen = g.scan.gen, at = msg.at, progress = nil }
	g.status = {}
	g.repo = { status = "loading", git = false, remotes = {} }
	table.insert(
		effects,
		runEffect(M.TAG .. "|remotes", g.scan.gen, { "git", "-C", index.root, "remote", "-v" }, 10000)
	)
	local pending = g.pendingOpen
	if pending then
		g.pendingOpen = nil
		M.openManifest(g, ctx, pending, effects)
	end
	for id, load in g.diffs do
		if load.status == "index" then
			advanceDiff(g, ctx, id, effects)
		end
	end
	for id, load in g.drifts do
		if load.status == "index" then
			startDrift(g, ctx, id, effects)
		end
	end
	local ex = g.export
	if ex and ex.status == "index" then
		readExport(g, ctx, effects)
	end
end

function M.onProgress(g: G, msg: Msg): boolean
	if msg.gen ~= g.scan.gen or g.scan.status ~= "scanning" then
		return false
	end
	local scan = table.clone(g.scan)
	scan.progress = msg.progress
	g.scan = scan
	return true
end

local function onRemotes(g: G, msg: Msg, effects: { Effect })
	if msg.gen ~= g.scan.gen then
		return
	end
	local r = msg.result :: ProcessResult
	if msg.spawnError or r.status ~= 0 then
		g.repo = { status = "ok", git = false, remotes = {} }
		return
	end
	local remotes: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, line in string.split(r.stdout, "\n") do
		local url = string.match(line, "^%S+%s+(%S+)")
		if url and not seen[url] then
			seen[url] = true
			table.insert(remotes, url)
		end
	end
	g.repo = { status = "ok", git = true, remotes = remotes }
	requestStatus(g, effects)
end

local function onStatus(g: G, msg: Msg)
	local index = g.index
	local r = msg.result :: ProcessResult
	if index == nil or msg.spawnError or r.status ~= 0 then
		return
	end
	g.status = Index.parseGitStatus(index.root, r.stdout)
end

-- Diff vs manifest -------------------------------------------------------------

function M.diffId(route: Route): string
	return Resource.key(route.ref :: Ref) .. "#" .. tostring(route.doc or 1)
end

local function setDiff(g: G, id: string, load: DiffLoad)
	local diffs = table.clone(g.diffs)
	diffs[id] = load
	g.diffs = diffs
end

local function diffArgv(ctx: Ctx, doc: Doc, ref: Ref, path: string): { string }
	local argv = push(base(ctx), "diff", "-f", path)
	-- A document without metadata.namespace lands in kubectl's default
	-- namespace; pin the namespace of the object it was matched to.
	if doc.declaredNamespace == nil and ref.namespace then
		push(argv, "-n", ref.namespace :: string)
	end
	return argv
end

local function diffWrite(g: G, ctx: Ctx, id: string, load: DiffLoad, text: string, effects: { Effect })
	local path = tmpPath(ctx, "diff")
	if path == nil then
		load.status = "error"
		load.error = "No plugin data directory for the temporary manifest"
		setDiff(g, id, load)
		return
	end
	load.status = "writing"
	load.tmp = path
	load.argv = diffArgv(ctx, load.doc :: Doc, load.ref, path)
	setDiff(g, id, load)
	table.insert(effects, writeTmp(M.TAG .. "|diff|write", load.gen, path, text))
end

function advanceDiff(g: G, ctx: Ctx, id: string, effects: { Effect })
	local load = table.clone(g.diffs[id])
	load.docs = M.matches(g, ctx, load.ref)
	local doc = load.docs[load.pick]
	load.doc = doc
	if doc == nil then
		load.status = "nomatch"
		setDiff(g, id, load)
		return
	end
	if doc.rendered and doc.text then
		diffWrite(g, ctx, id, load, doc.text :: string, effects)
		return
	end
	load.status = "reading"
	setDiff(g, id, load)
	table.insert(effects, { t = "read", tag = M.TAG .. "|diff|read", gen = load.gen, path = doc.file })
end

-- Opens (or re-runs, when `force`) the diff of the route's object against
-- its route.doc-th manifest.
function M.startDiff(g: G, ctx: Ctx, route: Route, force: boolean, effects: { Effect })
	local id = M.diffId(route)
	local existing = g.diffs[id]
	if existing and not force and existing.status ~= "error" then
		return
	end
	if not ctx.resolved then
		return
	end
	local load: DiffLoad = {
		status = "index",
		gen = nextGen(g),
		ref = route.ref :: Ref,
		pick = route.doc or 1,
		docs = {},
		doc = nil,
		segments = {},
		notes = {},
	}
	setDiff(g, id, load)
	if ready(g) then
		advanceDiff(g, ctx, id, effects)
	else
		M.ensureIndex(g, ctx, effects)
	end
end

local function diffByGen(g: G, gen: number?): (string?, DiffLoad?)
	for id, load in g.diffs do
		if load.gen == gen then
			return id, load
		end
	end
	return nil, nil
end

local function onDiff(g: G, ctx: Ctx, part: string, msg: Msg, effects: { Effect })
	local id, found = diffByGen(g, msg.gen)
	if id == nil or found == nil then
		return
	end
	local load = table.clone(found)
	local r = msg.result :: ProcessResult
	local okRun = msg.spawnError == nil and r.status == 0
	if part == "read" and load.status == "reading" then
		if not okRun then
			load.status = "error"
			load.error = "Cannot read " .. rel(g, (load.doc :: Doc).file) .. ": " .. firstLine(r.stderr)
			setDiff(g, id, load)
			return
		end
		local doc = load.doc :: Doc
		diffWrite(g, ctx, id, load, M.slice(r.stdout, doc.startLine, doc.endLine), effects)
	elseif part == "write" and load.status == "writing" then
		if not okRun then
			load.status = "error"
			load.error = failText("Writing the temporary manifest", r, msg.spawnError)
			setDiff(g, id, load)
			return
		end
		load.status = "diffing"
		setDiff(g, id, load)
		table.insert(
			effects,
			runEffect(M.TAG .. "|diff|run", load.gen, load.argv :: { string }, diffTimeout(ctx), { env = diffEnv() })
		)
	elseif part == "run" and load.status == "diffing" then
		if load.tmp then
			table.insert(effects, removeTmp(M.TAG .. "|diff|rm", load.gen, load.tmp :: string))
		end
		load.at = msg.at
		local summary, err = diffOutcome(ctx, r, msg.spawnError)
		if summary then
			load.status = "ok"
			load.exit = r.status
			load.segments = summary.segments
			load.notes = summary.notes
		else
			load.status = "error"
			load.error = err
		end
		setDiff(g, id, load)
	end
end

-- Apply bundles ----------------------------------------------------------------

local function linkOrigin(ctx: Ctx): { context: string?, source: Link.Source?, kubeconfig: string? }
	local t = ctx.target
	return { context = t.context, source = Link.sourceOf(t.contextSource, t.confirmed), kubeconfig = t.kubeconfig }
end

local function openApply(ctx: Ctx, fields: { file: string?, kustomize: string? }, effects: { Effect })
	local origin = linkOrigin(ctx)
	local url, err = Link.encode({
		op = "apply",
		file = fields.file,
		kustomize = fields.kustomize,
		recursive = false,
		context = origin.context,
		source = if origin.context then origin.source else nil,
		kubeconfig = origin.kubeconfig,
	})
	if url == nil then
		toast(effects, "error", "Cannot apply", err)
		return
	end
	table.insert(effects, { t = "open", url = url })
end

local function mayMutate(ctx: Ctx, effects: { Effect }): boolean
	if not ctx.config.mutations.enabled then
		toast(effects, "error", "Mutations are disabled", "mutations.enabled is false in the config")
		return false
	end
	if not ctx.resolved then
		toast(effects, "error", "No cluster target yet", "Pick a context first (c)")
		return false
	end
	return true
end

local function docsInFile(g: G, file: string): number
	local n = 0
	for _, d in (g.index :: Index.Index).docs do
		if not d.rendered and d.file == file then
			n += 1
		end
	end
	return n
end

-- Applies `docs` through the approve block: a document alone in its file is
-- applied from that file; anything else is bundled into a 0600 temporary
-- manifest (kept: the approve block re-reads it when it executes).
function M.applyDocs(g: G, ctx: Ctx, docs: { Doc }, label: string, effects: { Effect })
	if not mayMutate(ctx, effects) then
		return
	end
	if #docs == 0 then
		toast(effects, "error", "Nothing to apply", "No manifest declares " .. label)
		return
	end
	local only = docs[1]
	if #docs == 1 and not only.rendered and docsInFile(g, only.file) == 1 then
		openApply(ctx, { file = only.file }, effects)
		return
	end
	local b: Bundle = { gen = nextGen(g), label = label, docs = docs, pending = {}, texts = {}, tmp = nil }
	local reads: { string } = {}
	for _, d in docs do
		if not d.rendered and b.pending[d.file] == nil then
			b.pending[d.file] = true
			table.insert(reads, d.file)
		end
	end
	g.bundle = b
	for _, file in reads do
		table.insert(effects, { t = "read", tag = M.TAG .. "|apply|read|" .. file, gen = b.gen, path = file })
	end
	if #reads == 0 then
		local path = tmpPath(ctx, "apply")
		if path == nil then
			g.bundle = nil
			toast(effects, "error", "Cannot apply", "No plugin data directory")
			return
		end
		b.tmp = path
		table.insert(effects, writeTmp(M.TAG .. "|apply|write", b.gen, path, M.bundleText(b)))
	end
end

function M.bundleText(b: Bundle): string
	local parts: { string } = {}
	for _, d in b.docs do
		local text = if d.rendered then d.text or "" else M.slice(b.texts[d.file] or "", d.startLine, d.endLine)
		table.insert(parts, (string.gsub(text, "\n*$", "")))
	end
	return table.concat(parts, "\n---\n") .. "\n"
end

local function onApply(g: G, ctx: Ctx, part: string, msg: Msg, effects: { Effect })
	local found = g.bundle
	if found == nil or found.gen ~= msg.gen then
		return
	end
	local b = table.clone(found)
	local r = msg.result :: ProcessResult
	local okRun = msg.spawnError == nil and r.status == 0
	local file = string.match(part, "^read|(.*)$")
	if file then
		if not b.pending[file] then
			return
		end
		if not okRun then
			g.bundle = nil
			toast(effects, "error", "Cannot read " .. rel(g, file), firstLine(r.stderr))
			return
		end
		b.pending = table.clone(b.pending)
		b.texts = table.clone(b.texts)
		b.pending[file] = nil
		b.texts[file] = r.stdout
		g.bundle = b
		if next(b.pending) == nil then
			local path = tmpPath(ctx, "apply")
			if path == nil then
				g.bundle = nil
				toast(effects, "error", "Cannot apply", "No plugin data directory")
				return
			end
			b.tmp = path
			table.insert(effects, writeTmp(M.TAG .. "|apply|write", b.gen, path, M.bundleText(b)))
		end
	elseif part == "write" then
		g.bundle = nil
		if not okRun then
			toast(effects, "error", "Cannot write the apply bundle", failText("sh", r, msg.spawnError))
			return
		end
		openApply(ctx, { file = b.tmp }, effects)
	end
end

-- Drift -------------------------------------------------------------------------

local function sourceId(s: Index.Source): string
	return s.type .. ":" .. s.path .. (if s.helm then ":" .. s.helm.release else "")
end

local function driftOpts(g: G, ctx: Ctx): Drift.Options
	return {
		defaultNamespace = ctx.target.namespace,
		unmanagedKinds = ctx.config.gitops.unmanaged_kinds,
		controllers = g.ctl.set,
		diffNotes = nil,
	}
end

local CONTROLLER_LABEL: { [string]: string } = {
	argocd = "Argo CD app",
	["flux-kustomize"] = "Flux Kustomization",
	["flux-helm"] = "Flux HelmRelease",
}

function M.controllerLabel(kind: string): string
	return CONTROLLER_LABEL[kind] or kind
end

-- Drift sources: directories of plain manifests (each directory and each
-- top-level directory), kustomizations, configured helm releases, and
-- Argo CD / Flux sources whose repository is checked out here. Sources
-- covering the current namespace come first.
function M.sources(g: G, ctx: Ctx): { SourceEntry }
	local index = g.index
	if index == nil then
		return {}
	end
	local byId: { [string]: SourceEntry } = {}
	local order: { string } = {}
	local opts = driftOpts(g, ctx)
	local function add(src: Index.Source, note: string?)
		local id = sourceId(src)
		local existing = byId[id]
		if existing then
			if note then
				existing.note = if existing.note then existing.note .. ", " .. note else note
			end
			return
		end
		local scope = Drift.scope(src :: any, index :: any, opts)
		if #scope.docs == 0 and src.type ~= "helm" then
			return
		end
		-- 2: declares objects in the current namespace; 1: only through
		-- documents without a namespace; 0: elsewhere.
		local rank = 0
		local ns = ctx.target.namespace
		if ns then
			for _, d in scope.docs do
				if d.key and d.ref and d.ref.namespace == ns then
					rank = 2
					break
				end
			end
			if rank == 0 and table.find(scope.namespaces, ns) then
				rank = 1
			end
		end
		byId[id] = {
			id = id,
			type = src.type,
			path = src.path,
			label = src.label,
			source = src,
			docs = #scope.docs,
			namespaces = scope.namespaces,
			note = note,
			rank = rank,
		}
		table.insert(order, id)
	end
	local function dirSource(path: string): Index.Source
		return {
			type = "dir",
			root = index.root,
			path = path,
			helm = nil,
			label = Index.relative(index.root, path) .. "/",
		}
	end
	local tops: { [string]: boolean } = {}
	for _, src in index.sources do
		if src.type == "dir" then
			local relPath = Index.relative(index.root, src.path)
			local first = string.match(relPath, "^([^/]+)/")
			if first and not tops[first] then
				tops[first] = true
				add(dirSource(index.root .. "/" .. first), nil)
			end
			add(dirSource(src.path), nil)
		else
			add(src, nil)
		end
	end
	local set = g.ctl.set
	if set then
		for _, c in set.controllers do
			local path = M.localPath(g, c)
			if path then
				local note = M.controllerLabel(c.controller) .. " " .. c.name
				local k = index.kustomizations[path]
				if k then
					add({
						type = "kustomize",
						root = index.root,
						path = path,
						helm = nil,
						label = Index.relative(index.root, path),
					}, note)
				else
					add(dirSource(path), note)
				end
			end
		end
	end
	local out: { SourceEntry } = {}
	for _, id in order do
		table.insert(out, byId[id])
	end
	table.sort(out, function(a: SourceEntry, b: SourceEntry): boolean
		if a.rank ~= b.rank then
			return a.rank > b.rank
		end
		if (a.note ~= nil) ~= (b.note ~= nil) then
			return a.note ~= nil
		end
		return a.label < b.label
	end)
	return out
end

function M.findSource(g: G, ctx: Ctx, id: string): SourceEntry?
	for _, s in M.sources(g, ctx) do
		if s.id == id then
			return s
		end
	end
	return nil
end

local function setDrift(g: G, id: string, load: DriftLoad)
	local drifts = table.clone(g.drifts)
	drifts[id] = load
	g.drifts = drifts
end

local function renderedText(g: G, source: Index.Source): string
	local parts: { string } = {}
	for _, d in (g.index :: Index.Index).docs do
		if d.rendered and d.source == source and d.text then
			table.insert(parts, (string.gsub(d.text :: string, "\n*$", "")))
		end
	end
	return table.concat(parts, "\n---\n") .. "\n"
end

-- Files to diff for a directory source: those holding its compared docs.
local function sourceFiles(docs: { Drift.Doc }): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, d in docs do
		if not seen[d.file] then
			seen[d.file] = true
			table.insert(out, d.file)
		end
	end
	table.sort(out)
	return out
end

local function finishDrift(g: G, ctx: Ctx, id: string, load: DriftLoad)
	if not load.diffDone or next(load.livePending) ~= nil then
		setDrift(g, id, load)
		return
	end
	if load.diffError then
		load.status = "error"
		load.error = load.diffError
		setDrift(g, id, load)
		return
	end
	local opts = driftOpts(g, ctx)
	local diff = load.diff
	local notes: { string } = if diff then table.clone(diff.notes) else {}
	for _, e in load.liveErrors do
		table.insert(notes, e)
	end
	opts.diffNotes = notes
	local live: { any }? = if #load.liveErrors > 0 and #load.live == 0 then nil else load.live
	load.report =
		Drift.report(load.source.source :: any, g.index :: any, if diff then diff.segments else {}, live, opts)
	load.status = "ok"
	setDrift(g, id, load)
end

local function liveTag(ns: string): string
	return M.TAG .. "|drift|live|" .. ns
end

function startDrift(g: G, ctx: Ctx, id: string, effects: { Effect })
	local found = g.drifts[id]
	local load = table.clone(found)
	local entry = M.findSource(g, ctx, id) or load.source
	load.source = entry
	local scope = Drift.scope(entry.source :: any, g.index :: any, driftOpts(g, ctx))
	load.status = "running"
	load.diff = nil
	load.diffDone = false
	load.diffError = nil
	load.report = nil
	load.error = nil
	load.live = {}
	load.liveErrors = {}
	load.livePending = {}
	local argv = push(base(ctx), "diff")
	local helmText: string? = nil
	if entry.type == "kustomize" then
		push(argv, "-k", entry.path)
	elseif entry.type == "file" then
		push(argv, "-f", entry.path)
	elseif entry.type == "helm" then
		helmText = renderedText(g, entry.source)
		local path = tmpPath(ctx, "drift")
		if path == nil then
			load.status = "error"
			load.error = "No plugin data directory for the rendered chart"
			setDrift(g, id, load)
			return
		end
		load.tmp = path
		push(argv, "-f", path)
	else
		local files = sourceFiles(scope.docs)
		for _, f in files do
			push(argv, "-f", f)
		end
		if #files == 0 then
			load.diffDone = true
			load.diff = Diffseg.parse("")
		end
	end
	load.argv = argv
	if #scope.kinds > 0 then
		local kinds = table.concat(scope.kinds, ",")
		for _, ns in scope.namespaces do
			load.livePending[ns] = true
			table.insert(
				effects,
				runEffect(
					liveTag(ns),
					load.gen,
					push(base(ctx), "get", kinds, "-n", ns, "-o", "json"),
					queryTimeout(ctx)
				)
			)
		end
	end
	if helmText then
		table.insert(effects, writeTmp(M.TAG .. "|drift|write", load.gen, load.tmp :: string, helmText))
	elseif not load.diffDone then
		table.insert(effects, runEffect(M.TAG .. "|drift|diff", load.gen, argv, diffTimeout(ctx), { env = diffEnv() }))
	end
	finishDrift(g, ctx, id, load)
end

-- Opens (or re-runs) the drift report of source `id`.
function M.startDriftReport(g: G, ctx: Ctx, id: string, force: boolean, effects: { Effect })
	local existing = g.drifts[id]
	if existing and not force and existing.status ~= "error" then
		return
	end
	if not ctx.resolved then
		return
	end
	local entry = M.findSource(g, ctx, id)
	if entry == nil and existing then
		entry = existing.source
	end
	if entry == nil then
		return
	end
	setDrift(g, id, {
		status = "index",
		gen = nextGen(g),
		source = entry,
		diffDone = false,
		livePending = {},
		live = {},
		liveErrors = {},
		filter = if existing then existing.filter else "all",
	})
	if ready(g) then
		startDrift(g, ctx, id, effects)
	else
		M.ensureIndex(g, ctx, effects)
	end
end

local function driftByGen(g: G, gen: number?): (string?, DriftLoad?)
	for id, load in g.drifts do
		if load.gen == gen then
			return id, load
		end
	end
	return nil, nil
end

-- Secret values never stay in memory: only their keys are kept.
local function stripSecret(item: any): any
	if type(item) ~= "table" or item.kind ~= "Secret" then
		return item
	end
	local copy = table.clone(item)
	for _, field in { "data", "stringData" } do
		if type(item[field]) == "table" then
			local keys: { [string]: string } = {}
			for k in item[field] do
				keys[k] = ""
			end
			copy[field] = keys
		end
	end
	return copy
end

local function onDrift(g: G, ctx: Ctx, part: string, msg: Msg, effects: { Effect })
	local id, found = driftByGen(g, msg.gen)
	if id == nil or found == nil or found.status ~= "running" then
		return
	end
	local load = table.clone(found)
	local r = msg.result :: ProcessResult
	local okRun = msg.spawnError == nil and r.status == 0
	local ns = string.match(part, "^live|(.*)$")
	if ns then
		if not load.livePending[ns] then
			return
		end
		load.livePending = table.clone(load.livePending)
		load.livePending[ns] = nil
		if okRun then
			local ok, doc = pcall(ctx.decode, r.stdout)
			if ok and type(doc) == "table" and type(doc.items) == "table" then
				load.live = table.clone(load.live)
				for _, item in doc.items do
					table.insert(load.live, stripSecret(item))
				end
			else
				load.liveErrors = table.clone(load.liveErrors)
				table.insert(load.liveErrors, "namespace " .. ns .. ": kubectl printed invalid JSON")
			end
		else
			load.liveErrors = table.clone(load.liveErrors)
			table.insert(load.liveErrors, "namespace " .. ns .. ": " .. failText("kubectl get", r, msg.spawnError))
		end
		load.at = msg.at
		finishDrift(g, ctx, id, load)
	elseif part == "write" then
		if not okRun then
			load.diffDone = true
			load.diffError = failText("Writing the rendered chart", r, msg.spawnError)
			finishDrift(g, ctx, id, load)
			return
		end
		table.insert(
			effects,
			runEffect(M.TAG .. "|drift|diff", load.gen, load.argv :: { string }, diffTimeout(ctx), { env = diffEnv() })
		)
		setDrift(g, id, load)
	elseif part == "diff" then
		if load.tmp then
			table.insert(effects, removeTmp(M.TAG .. "|drift|rm", load.gen, load.tmp :: string))
		end
		load.diffDone = true
		load.at = msg.at
		local summary, err = diffOutcome(ctx, r, msg.spawnError)
		load.diff = summary
		load.diffError = err
		finishDrift(g, ctx, id, load)
	end
end

-- Report entries in display order (changed, missing, unmanaged), filtered.
function M.entries(load: DriftLoad, filter: Filter?): { Entry }
	local out: { Entry } = {}
	local report = load.report
	if report == nil then
		return out
	end
	local f = filter or load.filter
	if f == "all" or f == "changed" then
		for _, c in report.changed do
			table.insert(out, {
				key = "changed:" .. c.key,
				bucket = "changed",
				ref = c.ref,
				docs = c.docs :: any,
				segment = c.segment,
			})
		end
	end
	if f == "all" or f == "missing" then
		for _, m in report.missing do
			table.insert(out, {
				key = "missing:" .. m.key,
				bucket = "missing",
				ref = m.ref,
				docs = m.docs :: any,
				segment = m.segment,
				reason = m.reason,
			})
		end
	end
	if f == "all" or f == "unmanaged" then
		for _, u in report.unmanaged do
			table.insert(out, {
				key = "unmanaged:" .. u.key,
				bucket = "unmanaged",
				ref = u.ref,
				docs = {},
				segment = u.segment,
				object = u.object,
			})
		end
	end
	return out
end

function M.entry(load: DriftLoad, key: string): Entry?
	for _, e in M.entries(load, "all") do
		if e.key == key then
			return e
		end
	end
	return nil
end

local FILTERS: { Filter } = { "all", "changed", "missing", "unmanaged" }

function M.setFilter(g: G, id: string, filter: Filter)
	local load = g.drifts[id]
	if load == nil then
		return
	end
	local upd = table.clone(load)
	upd.filter = filter
	setDrift(g, id, upd)
end

function M.cycleFilter(g: G, id: string)
	local load = g.drifts[id]
	if load then
		local i = table.find(FILTERS, load.filter) or 1
		M.setFilter(g, id, FILTERS[i % #FILTERS + 1])
	end
end

-- The live object of a drift entry, from the source's live listing.
local function liveObject(load: DriftLoad, ref: Ref): any?
	local key = Resource.key(ref)
	for _, obj in load.live do
		local r = Resource.fromObject(obj, "live")
		if r and Resource.key(r) == key then
			return obj
		end
	end
	return nil
end

-- PR body / summary of a drift report (markdown).
function M.driftSummary(load: DriftLoad, context: string?): string
	local report = load.report
	local out: { string } = {}
	table.insert(
		out,
		string.format("Drift of `%s` against context `%s` (tern-kube).", load.source.label, context or "?")
	)
	if report == nil then
		return table.concat(out, "\n") .. "\n"
	end
	local c = report.counts
	table.insert(out, "")
	table.insert(
		out,
		string.format(
			"%d changed, %d missing in cluster, %d unmanaged, %d in sync.",
			c.changed,
			c.missing,
			c.unmanaged,
			c.inSync
		)
	)
	local entries = M.entries(load, "all")
	if #entries > 0 then
		table.insert(out, "")
		table.insert(out, "| Resource | Drift | Lines |")
		table.insert(out, "| --- | --- | --- |")
		for _, e in entries do
			local seg = e.segment
			local id = e.ref.kind .. " " .. (if e.ref.namespace then e.ref.namespace .. "/" else "") .. e.ref.name
			local counts = if seg then string.format("+%d -%d", seg.added, seg.removed) else ""
			table.insert(out, string.format("| %s | %s | %s |", id, e.bucket, counts))
		end
	end
	return table.concat(out, "\n") .. "\n"
end

-- Export ---------------------------------------------------------------------

local function exportLayout(index: Index.Index, dir: string): Export.Layout?
	local layout = Index.layout(index, dir)
	if layout.samples == 0 then
		return nil
	end
	return layout :: any
end

-- An export started before the index existed gets its default directory
-- here, once the index can tell where the objects' manifests live.
function readExport(g: G, ctx: Ctx, effects: { Effect })
	local ex = table.clone(g.export :: ExportState)
	if ex.dir == "" then
		ex.dir = M.defaultDir(g, ctx, ex.objects)
	end
	ex.status = "reading"
	ex.gen = nextGen(g)
	ex.plan = nil
	ex.confirming = false
	ex.error = nil
	g.export = ex
	table.insert(effects, { t = "readtree", tag = M.TAG .. "|export|tree", gen = ex.gen, path = ex.dir })
end

-- The default export directory: where the first object's hand-written
-- manifest lives, else <root>/manifests.
function M.defaultDir(g: G, ctx: Ctx, objects: { any }): string
	local index = g.index
	if index == nil then
		return (g.cwd or "") .. "/manifests"
	end
	for _, obj in objects do
		local ref = Resource.fromObject(obj, "live")
		if ref then
			for _, d in M.matches(g, ctx, ref) do
				if not d.rendered then
					return dirname(d.file)
				end
			end
		end
	end
	return index.root .. "/manifests"
end

-- E: starts an export of `objects` (live objects, already redacted).
function M.startExport(
	g: G,
	ctx: Ctx,
	objects: { any },
	opts: { label: string, dir: string?, summary: string? },
	effects: { Effect }
)
	g.export = {
		status = "index",
		gen = 0,
		objects = objects,
		label = opts.label,
		dir = opts.dir or "",
		plan = nil,
		expanded = {},
		confirming = false,
		written = {},
		error = nil,
		summary = opts.summary,
	}
	if ready(g) then
		readExport(g, ctx, effects)
	else
		M.ensureIndex(g, ctx, effects)
	end
end

local function onExport(g: G, ctx: Ctx, part: string, msg: Msg, effects: { Effect })
	local found = g.export
	if found == nil or found.gen ~= msg.gen then
		return
	end
	local ex = table.clone(found)
	if part == "tree" and ex.status == "reading" then
		local r = msg.result
		if r and r.status ~= 0 then
			ex.status = "error"
			ex.error = "Cannot read " .. ex.dir .. ": " .. firstLine(r.stderr)
			g.export = ex
			return
		end
		local ok, plan = pcall(
			Export.plan,
			ex.objects,
			{ dir = ex.dir, layout = exportLayout(g.index :: Index.Index, ex.dir) },
			msg.files or {},
			{ isList = ctx.isList, null = ctx.null }
		)
		if ok then
			ex.status = "ok"
			ex.plan = plan
		else
			ex.status = "error"
			ex.error = "Export plan failed: " .. tostring(plan)
		end
		g.export = ex
	elseif part == "write" and ex.status == "writing" then
		local r = msg.result :: ProcessResult
		if msg.spawnError or r.status ~= 0 then
			ex.status = "error"
			ex.error = "Writing failed: " .. firstLine(r.stderr)
			g.export = ex
			return
		end
		ex.status = "written"
		g.export = ex
		toast(effects, "success", "Wrote " .. M.count(#ex.written, "file"), dirname(ex.written[1] or ex.dir))
		requestStatus(g, effects)
	end
end

-- Files the export would change (new or modified), kustomization edits included.
function M.exportChanges(ex: ExportState): { Export.FileChange }
	local out: { Export.FileChange } = {}
	local plan = ex.plan
	if plan == nil then
		return out
	end
	for _, f in plan.files do
		if f.status ~= "unchanged" then
			table.insert(out, f)
		end
	end
	for _, f in plan.kustomizationEdits do
		if f.status ~= "unchanged" then
			table.insert(out, f)
		end
	end
	return out
end

local function writeExport(g: G, effects: { Effect })
	local ex = table.clone(g.export :: ExportState)
	local changes = M.exportChanges(ex)
	if #changes == 0 then
		toast(effects, "info", "Nothing to write", "Every file already matches the cluster")
		ex.confirming = false
		g.export = ex
		return
	end
	local files: { T.FileWrite } = {}
	local written: { string } = {}
	for _, f in changes do
		table.insert(files, { path = f.path, text = f.text })
		table.insert(written, f.path)
	end
	ex.status = "writing"
	ex.confirming = false
	ex.written = written
	ex.gen = nextGen(g)
	g.export = ex
	table.insert(effects, { t = "write", tag = M.TAG .. "|export|write", gen = ex.gen, files = files })
end

-- Git ------------------------------------------------------------------------

function M.slug(text: string): string
	local s = string.lower(text)
	s = string.gsub(s, "[^%w]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	if #s > 40 then
		s = string.gsub(string.sub(s, 1, 40), "%-+$", "")
	end
	return if s == "" then "export" else s
end

-- `git check-ref-format --branch` rules that matter for generated and
-- edited names.
function M.validBranch(name: string): boolean
	if name == "" or #name > 200 or string.find(name, "[%c%s~%^:%?%*%[\\]") then
		return false
	end
	if string.sub(name, 1, 1) == "-" or string.sub(name, 1, 1) == "/" or string.sub(name, -1) == "/" then
		return false
	end
	if string.find(name, "..", 1, true) or string.find(name, "//", 1, true) or string.find(name, "@{", 1, true) then
		return false
	end
	if string.sub(name, -5) == ".lock" or string.sub(name, -1) == "." or name == "@" then
		return false
	end
	for part in string.gmatch(name, "[^/]+") do
		if string.sub(part, 1, 1) == "." then
			return false
		end
	end
	return true
end

function M.prTitle(message: string): string
	return firstLine(message)
end

-- The exact commands the git route runs, in order.
function M.gitCommands(git: GitState, ghProgram: string): { GitStep }
	local root = git.root
	local relFiles: { string } = {}
	for i, f in git.files do
		relFiles[i] = Index.relative(root, f)
	end
	local steps: { GitStep } = {}
	local function step(id: string, label: string, argv: { string }, cwd: string?)
		table.insert(steps, { id = id, label = label, argv = argv, cwd = cwd, status = "pending" })
	end
	step("switch", "Create the branch", { "git", "-C", root, "switch", "-c", git.branch })
	local add = { "git", "-C", root, "add", "--" }
	table.move(relFiles, 1, #relFiles, #add + 1, add)
	step("add", "Stage the exported files", add)
	local commit = { "git", "-C", root, "commit", "-m", git.message }
	if git.only then
		table.insert(commit, "--")
		table.move(relFiles, 1, #relFiles, #commit + 1, commit)
	end
	step("commit", if git.only then "Commit only the exported files" else "Commit", commit)
	if git.push then
		step("push", "Push the branch (never forced)", { "git", "-C", root, "push", "-u", "origin", git.branch })
		if git.pr then
			step("pr", "Open a pull request", {
				ghProgram,
				"pr",
				"create",
				"--title",
				M.prTitle(git.message),
				"--body",
				git.summary,
				"--head",
				git.branch,
			}, root)
		end
	end
	return steps
end

-- Why the commands cannot run yet; nil when they can.
function M.gitBlocker(git: GitState): string?
	if next(git.checks.pending) ~= nil then
		return "Checking the repository …"
	end
	if #git.checks.errors > 0 then
		return git.checks.errors[1]
	end
	if #git.checks.unrelated > 0 and not git.only then
		return string.format(
			"%d unrelated staged change(s) (%s). Press o to commit only the exported files, or unstage them.",
			#git.checks.unrelated,
			table.concat(git.checks.unrelated, ", ", 1, math.min(3, #git.checks.unrelated))
		)
	end
	if not M.validBranch(git.branch) then
		return "Branch name " .. string.format("%q", git.branch) .. " is not valid (b edits it)."
	end
	if trim(git.message) == "" then
		return "The commit message is empty (e edits it)."
	end
	if git.push and not git.checks.origin then
		return "No remote named origin to push to (p turns push off)."
	end
	if git.pr and (git.checks.gh == nil or not git.checks.ghAuth) then
		return "gh is not installed or not logged in (gh auth status); P turns the pull request off."
	end
	return nil
end

local function checkRun(git: GitState, name: string, argv: { string }, cwd: string?, effects: { Effect })
	git.checks.pending[name] = true
	table.insert(effects, runEffect(M.TAG .. "|git|check|" .. name, git.gen, argv, 20000, { cwd = cwd }))
end

-- Branch / commit / push / PR for the files the export wrote.
function M.startGit(g: G, ctx: Ctx, effects: { Effect }): boolean
	local ex = g.export
	local index = g.index
	if ex == nil or ex.status ~= "written" or index == nil then
		toast(effects, "error", "Write an export first", "E exports, w writes the files")
		return false
	end
	if not g.repo.git then
		toast(effects, "error", "Not a git repository", index.root)
		return false
	end
	local label = ex.label
	local stamp = os.date("!%Y%m%d-%H%M%S", ctx.now or 0) :: string
	local git: GitState = {
		status = "checking",
		gen = nextGen(g),
		root = index.root,
		files = table.clone(ex.written),
		branch = "tern-kube/" .. M.slug(label) .. "-" .. stamp,
		message = "chore(gitops): export " .. label,
		push = false,
		pr = false,
		only = false,
		checks = {
			pending = {},
			staged = {},
			unrelated = {},
			head = nil,
			origin = false,
			gh = nil,
			ghAuth = false,
			errors = {},
		},
		steps = {},
		summary = ex.summary or M.exportSummary(ex, ctx.target.context, index.root),
		error = nil,
	}
	local root = index.root
	checkRun(git, "status", { "git", "-C", root, "status", "--porcelain=v1", "-z" }, nil, effects)
	checkRun(git, "head", { "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, nil, effects)
	checkRun(git, "remote", { "git", "-C", root, "remote" }, nil, effects)
	checkRun(git, "gh", { "/bin/sh", "-c", 'command -v -- "$1"', "sh", ctx.config.gitops.gh }, nil, effects)
	g.git = git
	return true
end

function M.exportSummary(ex: ExportState, context: string?, root: string): string
	local out: { string } = {
		string.format("Exported %s from context `%s` with tern-kube.", ex.label, context or "?"),
		"",
		"| File | Change |",
		"| --- | --- |",
	}
	local plan = ex.plan
	if plan then
		for _, f in M.exportChanges(ex) do
			table.insert(out, string.format("| %s | %s |", Index.relative(root, f.path), f.status))
		end
	end
	return table.concat(out, "\n") .. "\n"
end

-- Staged paths (index column set) of `git status --porcelain=v1 -z`.
function M.stagedPaths(stdout: string): { string }
	local out: { string } = {}
	local parts = string.split(stdout, "\0")
	local i = 1
	while i <= #parts do
		local entry = parts[i]
		i += 1
		if #entry >= 4 then
			local x = string.sub(entry, 1, 1)
			local path = string.sub(entry, 4)
			if x == "R" or x == "C" then
				i += 1
			end
			if x ~= " " and x ~= "?" and x ~= "!" then
				table.insert(out, path)
			end
		end
	end
	return out
end

local function setGit(g: G, git: GitState)
	g.git = git
end

local function onGitCheck(g: G, name: string, msg: Msg, effects: { Effect })
	local found = g.git
	if found == nil or found.gen ~= msg.gen or found.status ~= "checking" or not found.checks.pending[name] then
		return
	end
	local git = table.clone(found)
	local checks = table.clone(git.checks)
	checks.pending = table.clone(checks.pending)
	checks.errors = table.clone(checks.errors)
	checks.pending[name] = nil
	git.checks = checks
	local r = msg.result :: ProcessResult
	local okRun = msg.spawnError == nil and r.status == 0
	if name == "status" then
		if okRun then
			local mine: { [string]: boolean } = {}
			for _, f in git.files do
				mine[Index.relative(git.root, f)] = true
			end
			checks.staged = M.stagedPaths(r.stdout)
			checks.unrelated = {}
			for _, p in checks.staged do
				if not mine[p] then
					table.insert(checks.unrelated, p)
				end
			end
		else
			table.insert(checks.errors, failText("git status", r, msg.spawnError))
		end
	elseif name == "head" then
		checks.head = if okRun then trim(r.stdout) else nil
	elseif name == "remote" then
		checks.origin = okRun and table.find(string.split(r.stdout, "\n"), "origin") ~= nil
	elseif name == "gh" then
		local path = if okRun then trim(r.stdout) else ""
		if path ~= "" then
			checks.gh = path
			checks.pending.ghauth = true
			table.insert(
				effects,
				runEffect(M.TAG .. "|git|check|ghauth", git.gen, { path, "auth", "status" }, 20000, { cwd = git.root })
			)
		end
	elseif name == "ghauth" then
		checks.ghAuth = okRun
	end
	if next(checks.pending) == nil then
		-- Push and pull request stay opt-in (p / P) even when available.
		git.status = "ready"
	end
	setGit(g, git)
end

local function runStep(git: GitState, i: number, effects: { Effect })
	local steps = table.clone(git.steps)
	local step = table.clone(steps[i])
	step.status = "running"
	steps[i] = step
	git.steps = steps
	table.insert(
		effects,
		runEffect(M.TAG .. "|git|step|" .. i, git.gen, step.argv, M.GIT_TIMEOUT_MS, { cwd = step.cwd })
	)
end

function M.runGit(g: G, ctx: Ctx, effects: { Effect })
	local found = g.git
	if found == nil or found.status ~= "ready" then
		return
	end
	local why = M.gitBlocker(found)
	if why then
		toast(effects, "error", "Cannot run the git commands", why)
		return
	end
	local git = table.clone(found)
	git.gen = nextGen(g)
	git.status = "running"
	git.steps = M.gitCommands(git, git.checks.gh or ctx.config.gitops.gh)
	runStep(git, 1, effects)
	setGit(g, git)
end

local function clip(text: string): string
	local t = trim(text)
	if #t > M.MAX_STEP_OUTPUT then
		return string.sub(t, 1, M.MAX_STEP_OUTPUT) .. " …"
	end
	return t
end

local function onGitStep(g: G, i: number, msg: Msg, effects: { Effect })
	local found = g.git
	if found == nil or found.gen ~= msg.gen or found.status ~= "running" then
		return
	end
	local git = table.clone(found)
	git.steps = table.clone(git.steps)
	local step = table.clone(git.steps[i])
	local r = msg.result :: ProcessResult
	step.exit = if msg.spawnError then -1 else r.status
	step.output = clip(if msg.spawnError then msg.spawnError :: string else (r.stdout .. "\n" .. r.stderr))
	step.status = if msg.spawnError == nil and r.status == 0 then "ok" else "error"
	git.steps[i] = step
	if step.status == "error" then
		for j = i + 1, #git.steps do
			local rest = table.clone(git.steps[j])
			rest.status = "skipped"
			git.steps[j] = rest
		end
		git.status = "error"
		git.error = step.label .. " failed"
		toast(effects, "error", step.label .. " failed", firstLine(step.output or ""))
	elseif i < #git.steps then
		runStep(git, i + 1, effects)
	else
		git.status = "done"
		toast(effects, "success", "Committed on " .. git.branch, if git.push then "Pushed to origin" else nil)
	end
	setGit(g, git)
	if git.status ~= "running" then
		requestStatus(g, effects)
	end
end

-- Text fields ----------------------------------------------------------------

M.FIELDS = { dir = "export", branch = "git", message = "git" }

function M.fieldValue(g: G, field: string): string
	local draft = g.fields[field]
	if draft then
		return draft
	end
	if field == "dir" then
		return if g.export then (g.export :: ExportState).dir else ""
	elseif field == "branch" then
		return if g.git then (g.git :: GitState).branch else ""
	elseif field == "message" then
		return if g.git then (g.git :: GitState).message else ""
	end
	return ""
end

function M.setField(g: G, field: string, text: string)
	local fields = table.clone(g.fields)
	fields[field] = text
	g.fields = fields
end

-- Applies an edited field (enter); the export re-plans for a new directory.
function M.commitField(g: G, ctx: Ctx, field: string, effects: { Effect })
	local value = g.fields[field]
	local fields = table.clone(g.fields)
	fields[field] = nil
	g.fields = fields
	if value == nil then
		return
	end
	value = trim(value)
	if field == "dir" and g.export then
		local index = g.index
		local dir = value
		if string.sub(dir, 1, 1) ~= "/" and index then
			dir = index.root .. "/" .. dir
		end
		dir = Index.normalize(dir)
		local ex = table.clone(g.export :: ExportState)
		if ex.dir ~= dir or ex.status == "error" then
			ex.dir = dir
			g.export = ex
			if ready(g) then
				readExport(g, ctx, effects)
			end
		end
	elseif (field == "branch" or field == "message") and g.git then
		local git = table.clone(g.git :: GitState)
		if field == "branch" then
			git.branch = value
		else
			git.message = value
		end
		g.git = git
	end
end

-- Routes ---------------------------------------------------------------------

-- Starts what `route` shows (force: r).
function M.enter(g: G, ctx: Ctx, route: Route, force: boolean, effects: { Effect })
	local kind = route.kind
	if kind == "manifest" then
		if force then
			M.rescan(g, ctx, effects)
		else
			M.ensureIndex(g, ctx, effects)
		end
	elseif kind == "diff" then
		M.startDiff(g, ctx, route, force, effects)
	elseif kind == "drift" then
		if route.source == nil then
			if force then
				M.rescan(g, ctx, effects)
			else
				M.ensureIndex(g, ctx, effects)
			end
			M.loadControllers(g, ctx, effects)
		elseif route.item == nil then
			M.startDriftReport(g, ctx, route.source :: string, force, effects)
		end
	elseif kind == "export" then
		local ex = g.export
		if force and ex and (ex.status == "ok" or ex.status == "error") and ready(g) then
			readExport(g, ctx, effects)
		end
	end
end

function M.items(g: G, ctx: Ctx, route: Route): { Item }
	local out: { Item } = {}
	local kind = route.kind
	if kind == "manifest" and route.ref and ready(g) then
		for _, d in M.matches(g, ctx, route.ref :: Ref) do
			table.insert(out, { key = d.file .. ":" .. d.startLine, ref = route.ref })
		end
	elseif kind == "drift" and route.source == nil and ready(g) then
		for _, s in M.sources(g, ctx) do
			table.insert(out, { key = s.id, value = s.id })
		end
	elseif kind == "drift" and route.item == nil then
		local load = g.drifts[route.source :: string]
		if load and load.status == "ok" then
			for _, e in M.entries(load) do
				table.insert(out, { key = e.key, ref = e.ref })
			end
		end
	elseif kind == "drift" then
		local load = g.drifts[route.source :: string]
		local e = if load then M.entry(load, route.item :: string) else nil
		if e then
			for _, d in e.docs do
				table.insert(out, { key = d.file .. ":" .. d.startLine, ref = e.ref })
			end
		end
	elseif kind == "export" then
		local ex = g.export
		local plan = if ex then ex.plan else nil
		if plan then
			for _, f in plan.files do
				table.insert(out, { key = f.path, value = f.path })
			end
			for _, f in plan.kustomizationEdits do
				table.insert(out, { key = f.path, value = f.path })
			end
		end
	end
	return out
end

-- The object keys act on in a GitOps route.
function M.focusRef(g: G, _ctx: Ctx, route: Route, selected: Item?): Ref?
	if route.kind == "drift" then
		if route.item then
			local load = g.drifts[route.source :: string]
			local e = if load then M.entry(load, route.item :: string) else nil
			return if e then e.ref else nil
		end
		return if selected then selected.ref else nil
	end
	return route.ref
end

local function docByKey(docs: { Doc }, key: string?): Doc?
	for _, d in docs do
		if d.file .. ":" .. d.startLine == key then
			return d
		end
	end
	return docs[1]
end

local function exportFromDrift(g: G, ctx: Ctx, id: string, entries: { Entry }, effects: { Effect }): Nav?
	local load = g.drifts[id]
	if load == nil then
		return nil
	end
	if load.source.type == "helm" then
		toast(effects, "error", "Charts are not exported", "Export writes plain manifests; edit the chart instead")
		return nil
	end
	local objects: { any } = {}
	local missing = 0
	for _, e in entries do
		if e.bucket ~= "missing" then
			local obj = liveObject(load, e.ref)
			if obj then
				table.insert(objects, obj)
			else
				missing += 1
			end
		end
	end
	if #objects == 0 then
		toast(
			effects,
			"error",
			"Nothing to export",
			if missing > 0 then "Open the object (y) and press E there" else "Select a changed or unmanaged object"
		)
		return nil
	end
	local dir = if load.source.type == "file" then dirname(load.source.path) else load.source.path
	M.startExport(g, ctx, objects, {
		label = M.count(#objects, "object") .. " from " .. load.source.label,
		dir = dir,
		summary = M.driftSummary(load, ctx.target.context),
	}, effects)
	return { push = { kind = "export" } }
end

local function applySource(g: G, ctx: Ctx, entry: SourceEntry, effects: { Effect })
	if not mayMutate(ctx, effects) then
		return
	end
	if entry.type == "kustomize" then
		openApply(ctx, { kustomize = entry.path }, effects)
	elseif entry.type == "file" then
		openApply(ctx, { file = entry.path }, effects)
	else
		local docs = Drift.scope(entry.source :: any, g.index :: any, driftOpts(g, ctx)).docs
		M.applyDocs(g, ctx, docs :: any, entry.label, effects)
	end
end

local function applyEntry(g: G, ctx: Ctx, e: Entry, effects: { Effect })
	if e.bucket == "unmanaged" then
		toast(effects, "info", "No manifest to apply", "Export it (E) or delete it (ctrl+d)")
		return
	end
	M.applyDocs(g, ctx, { e.docs[1] }, string.lower(e.ref.kind) .. "/" .. e.ref.name, effects)
end

-- Keys of the GitOps routes; `selected` is the selected item. Returns
-- whether the key was handled and an optional navigation.
function M.onKey(
	g: G,
	ctx: Ctx,
	route: Route,
	selected: Item?,
	ch: string?,
	key: T.Key,
	effects: { Effect }
): (boolean, Nav?)
	local name = key.name
	local enter = name == "enter" or name == "return"
	local kind = route.kind
	if kind == "manifest" then
		local docs = if route.ref then M.matches(g, ctx, route.ref :: Ref) else {}
		local doc = docByKey(docs, if selected then selected.key else nil)
		if (ch == "m" or enter) and doc then
			openDoc(doc, effects)
			return true, nil
		elseif ch == "=" and doc then
			return true, { push = { kind = "diff", ref = route.ref, doc = table.find(docs, doc) } }
		end
	elseif kind == "diff" then
		local load = g.diffs[M.diffId(route)]
		local docs = if load then load.docs else {}
		if ch == "m" and load and load.doc then
			openDoc(load.doc :: Doc, effects)
			return true, nil
		elseif (ch == "]" or ch == "[") and #docs > 1 then
			local pick = (route.doc or 1) + (if ch == "]" then 1 else -1)
			pick = (pick - 1) % #docs + 1
			return true, { replace = { kind = "diff", ref = route.ref, doc = pick } }
		elseif ch == "a" and load and load.doc then
			local r = route.ref :: Ref
			M.applyDocs(g, ctx, { load.doc :: Doc }, string.lower(r.kind) .. "/" .. r.name, effects)
			return true, nil
		end
	elseif kind == "drift" and route.source == nil then
		if enter and selected then
			return true, { push = { kind = "drift", source = selected.key } }
		end
	elseif kind == "drift" and route.item == nil then
		local id = route.source :: string
		local load = g.drifts[id]
		if ch == "f" then
			M.cycleFilter(g, id)
			return true, nil
		end
		if load == nil or load.status ~= "ok" then
			return false, nil
		end
		local e = if selected then M.entry(load, selected.key) else nil
		if enter and e then
			return true, { push = { kind = "drift", source = id, item = e.key } }
		elseif ch == "m" and e then
			if e.docs[1] then
				openDoc(e.docs[1], effects)
			else
				toast(effects, "info", "Not in any manifest", "E exports it")
			end
			return true, nil
		elseif ch == "a" and e then
			applyEntry(g, ctx, e, effects)
			return true, nil
		elseif ch == "A" then
			applySource(g, ctx, load.source, effects)
			return true, nil
		elseif ch == "E" then
			local entries = if e then { e } else {}
			return true, exportFromDrift(g, ctx, id, entries, effects)
		elseif ch == "X" then
			return true, exportFromDrift(g, ctx, id, M.entries(load), effects)
		end
	elseif kind == "drift" then
		local id = route.source :: string
		local load = g.drifts[id]
		local e = if load then M.entry(load, route.item :: string) else nil
		if e == nil then
			return false, nil
		end
		local doc = docByKey(e.docs, if selected then selected.key else nil)
		if (ch == "m" or enter) and doc then
			openDoc(doc, effects)
			return true, nil
		elseif ch == "a" then
			applyEntry(g, ctx, e, effects)
			return true, nil
		elseif ch == "E" then
			return true, exportFromDrift(g, ctx, id, { e }, effects)
		end
	elseif kind == "export" then
		local ex = g.export
		if ex == nil then
			return false, nil
		end
		if ex.confirming then
			if ch == "y" or enter then
				writeExport(g, effects)
				return true, nil
			elseif name == "escape" or ch == "n" then
				local upd = table.clone(ex)
				upd.confirming = false
				g.export = upd
				return true, nil
			end
			return true, nil
		end
		if enter and selected then
			local upd = table.clone(ex)
			upd.expanded = table.clone(upd.expanded)
			upd.expanded[selected.key] = not upd.expanded[selected.key]
			g.export = upd
			return true, nil
		elseif ch == "w" and ex.status == "ok" then
			local upd = table.clone(ex)
			upd.confirming = true
			g.export = upd
			return true, nil
		elseif ch == "b" and ex.status == "written" then
			if M.startGit(g, ctx, effects) then
				return true, { push = { kind = "git" } }
			end
			return true, nil
		end
	elseif kind == "git" then
		local git = g.git
		if git == nil then
			return false, nil
		end
		if git.status == "ready" then
			local upd = table.clone(git)
			if ch == "p" then
				upd.push = not upd.push
				upd.pr = upd.pr and upd.push
			elseif ch == "P" then
				upd.pr = not upd.pr
				upd.push = upd.push or upd.pr
			elseif ch == "o" then
				upd.only = not upd.only
			elseif enter or ch == "y" then
				M.runGit(g, ctx, effects)
				return true, nil
			else
				return false, nil
			end
			g.git = upd
			return true, nil
		end
	end
	return false, nil
end

-- Pointer actions of the GitOps views (`gitops-<what>=<value>`).
function M.onAction(g: G, ctx: Ctx, route: Route, act: string, value: string, effects: { Effect }): (boolean, Nav?)
	if act == "gitops-open" then
		local file, line = string.match(value, "^(.*):(%d+)$")
		if file and line then
			table.insert(effects, { t = "openfile", path = file, line = tonumber(line) })
			return true, nil
		end
	elseif act == "gitops-source" then
		return true, { push = { kind = "drift", source = value } }
	elseif act == "gitops-entry" and route.kind == "drift" and route.source then
		return true, { push = { kind = "drift", source = route.source, item = value } }
	elseif act == "gitops-filter" and route.kind == "drift" and route.source then
		M.setFilter(g, route.source :: string, value :: Filter)
		return true, nil
	elseif act == "gitops-doc" and route.kind == "diff" then
		return true, { replace = { kind = "diff", ref = route.ref, doc = tonumber(value) or 1 } }
	elseif act == "gitops-diff" and route.ref then
		return true, { push = { kind = "diff", ref = route.ref, doc = tonumber(value) or 1 } }
	elseif act == "gitops-rescan" then
		M.rescan(g, ctx, effects)
		return true, nil
	elseif act == "gitops-toggle" and route.kind == "export" and g.export then
		local ex = table.clone(g.export :: ExportState)
		ex.expanded = table.clone(ex.expanded)
		ex.expanded[value] = not ex.expanded[value]
		g.export = ex
		return true, nil
	end
	return false, nil
end

-- Results ----------------------------------------------------------------------

function M.onResult(g: G, ctx: Ctx, msg: Msg, effects: { Effect }): boolean
	local tag = msg.tag or ""
	local rest = string.match(tag, "^gitops|(.*)$")
	if rest == nil then
		return false
	end
	local what, part = string.match(rest, "^([^|]+)|?(.*)$")
	if what == "scan" then
		onScanDone(g, ctx, msg, effects)
	elseif what == "remotes" then
		onRemotes(g, msg, effects)
	elseif what == "status" then
		onStatus(g, msg)
	elseif what == "ctl" then
		onControllers(g, ctx, part or "", msg, effects)
	elseif what == "diff" then
		onDiff(g, ctx, part or "", msg, effects)
	elseif what == "drift" then
		onDrift(g, ctx, part or "", msg, effects)
	elseif what == "apply" then
		onApply(g, ctx, part or "", msg, effects)
	elseif what == "export" then
		onExport(g, ctx, part or "", msg, effects)
	elseif what == "git" then
		local check = string.match(part or "", "^check|(.*)$")
		local step = string.match(part or "", "^step|(%d+)$")
		if check then
			onGitCheck(g, check, msg, effects)
		elseif step then
			onGitStep(g, tonumber(step) :: number, msg, effects)
		end
	end
	return true
end

return M
