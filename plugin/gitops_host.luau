--!strict
-- Host adapter for lib/gitops/index.luau: finds the repo, lists and reads
-- manifest files across timer ticks, runs `kubectl kustomize` and
-- `helm template`, and reads git status. Every result is delivered through
-- callbacks; nothing here decides what is shown.
--
-- Processes cannot be killed: `cancel()` only makes late results be ignored.

local EnvHost = require("./env_host")
local Index = require("./lib/gitops/index")
local Shellenv = require("./lib/env/shellenv")

export type HelmRelease = {
	chart: string,
	release: string,
	namespace: string?,
	values: { string },
}

export type ScanOpts = {
	maxFiles: number?,
	maxBytes: number?,
	maxFileBytes: number?,
	-- Render top-level kustomizations (those no other kustomization lists).
	renderKustomize: boolean?,
	-- Releases to render (config `gitops.helm`); chart and values paths are
	-- absolute or relative to the repo root.
	helm: { HelmRelease }?,
}

export type Progress = {
	phase: "root" | "list" | "read" | "render",
	done: number,
	total: number,
}

export type Scan = { cancel: () -> () }

type Done = (index: Index.Index?, err: string?) -> ()
type TextCb = (text: string?, err: string?) -> ()

local M = {}

M.CHUNK_FILES = 50
M.CHUNK_MS = 100
M.GIT_TIMEOUT_MS = 10000
M.RENDER_TIMEOUT_MS = 30000
M.MAX_RENDERS = 16
M.WALK_DEPTH = 8
M.WALK_MAX_ENTRIES = 20000
M.STATUS_BATCH = 200
-- The helm program; decides whether helm features are offered.
M.HELM = "helm"

local SKIP_DIRS = { [".git"] = true, node_modules = true, vendor = true, [".terraform"] = true }

local function firstLine(text: string): string
	return (string.match(text, "^%s*([^\n]*)") or "") :: string
end

local function failure(what: string, result: ProcessResult): string
	if result.timed_out then
		return what .. " timed out"
	end
	local detail = firstLine(result.stderr)
	return string.format("%s exited %d%s", what, result.status, if detail ~= "" then ": " .. detail else "")
end

-- Runs argv with the user's PATH; spawn failures are reported like process
-- failures.
local function run(argv: { string }, opts: ProcessOptions, cb: (ProcessResult) -> ())
	EnvHost.run(argv, opts, function(result: ProcessResult, spawnError: string?)
		if spawnError then
			cb({ status = -1, stdout = "", stderr = spawnError, timed_out = false })
		else
			cb(result)
		end
	end)
end

local function trimNewline(s: string): string
	return (string.gsub(s, "\n+$", ""))
end

local function absolute(root: string, path: string): string
	return Index.normalize(if string.sub(path, 1, 1) == "/" then path else root .. "/" .. path)
end

-- Renders a kustomization directory with the configured kubectl.
function M.renderKustomize(dir: string, cb: TextCb)
	run({ EnvHost.program("kubectl"), "kustomize", dir }, { timeout_ms = M.RENDER_TIMEOUT_MS }, function(result)
		if result.status == 0 then
			cb(result.stdout, nil)
		else
			cb(nil, failure("kubectl kustomize " .. dir, result))
		end
	end)
end

-- Calls back with the helm executable, or nil when helm is not installed.
function M.helmAvailable(cb: (path: string?) -> ())
	EnvHost.ready(function()
		local r = EnvHost.resolve(M.HELM)
		cb(if r.found then r.program else nil)
	end)
end

-- `helm template <release> <chart> [-n ns] [-f values]...`; spec paths are
-- absolute.
function M.renderHelm(spec: HelmRelease, cb: TextCb)
	M.helmAvailable(function(helm: string?)
		if helm == nil then
			cb(
				nil,
				"helm is not installed (" .. M.HELM .. " is not on your shell's PATH or in a common install location)"
			)
			return
		end
		local argv = { helm, "template", spec.release, spec.chart }
		if spec.namespace then
			table.insert(argv, "-n")
			table.insert(argv, spec.namespace)
		end
		for _, values in spec.values do
			table.insert(argv, "-f")
			table.insert(argv, values)
		end
		run(argv, { timeout_ms = M.RENDER_TIMEOUT_MS }, function(result)
			if result.status == 0 then
				cb(result.stdout, nil)
			else
				cb(nil, failure("helm template " .. spec.release, result))
			end
		end)
	end)
end

-- Porcelain status of `files` (absolute, under root), in batches so the
-- argv stays small.
function M.gitStatus(
	root: string,
	files: { string },
	cb: (status: { [string]: Index.GitFileStatus }?, err: string?) -> ()
)
	local merged: { [string]: Index.GitFileStatus } = {}
	local function batch(from: number)
		if from > #files then
			cb(merged, nil)
			return
		end
		local argv = { "git", "-C", root, "status", "--porcelain=v1", "-z", "--" }
		for i = from, math.min(#files, from + M.STATUS_BATCH - 1) do
			table.insert(argv, Index.relative(root, files[i]))
		end
		run(argv, { timeout_ms = M.GIT_TIMEOUT_MS }, function(result)
			if result.status ~= 0 then
				cb(nil, failure("git status", result))
				return
			end
			for path, status in Index.parseGitStatus(root, result.stdout) do
				merged[path] = status
			end
			batch(from + M.STATUS_BATCH)
		end)
	end
	batch(1)
end

-- Scanning ---------------------------------------------------------------------

type ScanState = {
	cwd: string,
	opts: ScanOpts,
	progress: (Progress) -> (),
	done: Done,
	cancelled: boolean,
	finished: boolean,
	root: string,
	git: boolean,
}

local function live(s: ScanState): boolean
	return not s.cancelled and not s.finished
end

local function finish(s: ScanState, index: Index.Index?, err: string?)
	if live(s) then
		s.finished = true
		s.done(index, err)
	end
end

local function report(s: ScanState, phase: "root" | "list" | "read" | "render", done: number, total: number)
	if live(s) then
		s.progress({ phase = phase, done = done, total = total })
	end
end

local function diagnostic(index: Index.Index, severity: "error" | "warning" | "info", file: string?, text: string)
	table.insert(index.diagnostics, { file = file, line = nil, severity = severity, text = text })
end

-- Kustomizations no other kustomization lists: the ones that get applied.
local function topKustomizations(index: Index.Index): { string }
	local listed: { [string]: boolean } = {}
	for _, k in index.kustomizations do
		for _, r in k.resources do
			listed[r] = true
		end
	end
	local out: { string } = {}
	for dir in index.kustomizations do
		if not listed[dir] then
			table.insert(out, dir)
		end
	end
	table.sort(out)
	return out
end

local function render(s: ScanState, index: Index.Index)
	type Job = {
		label: string,
		kind: Index.SourceType,
		path: string,
		helm: Index.HelmSpec?,
		start: (TextCb) -> (),
	}
	local jobs: { Job } = {}
	if s.opts.renderKustomize ~= false then
		for _, dir in topKustomizations(index) do
			table.insert(jobs, {
				label = dir,
				kind = "kustomize",
				path = dir,
				helm = nil,
				start = function(cb: TextCb)
					M.renderKustomize(dir, cb)
				end,
			})
		end
	end
	local releases: { HelmRelease } = s.opts.helm or {}
	for _, release in releases do
		local values: { string } = {}
		for i, v in release.values do
			values[i] = absolute(s.root, v)
		end
		local spec: HelmRelease = {
			chart = absolute(s.root, release.chart),
			release = release.release,
			namespace = release.namespace,
			values = values,
		}
		table.insert(jobs, {
			label = spec.chart,
			kind = "helm",
			path = spec.chart,
			helm = { release = spec.release, namespace = spec.namespace, values = values },
			start = function(cb: TextCb)
				M.renderHelm(spec, cb)
			end,
		})
	end
	if #jobs > M.MAX_RENDERS then
		diagnostic(
			index,
			"warning",
			nil,
			string.format("%d sources found; only the first %d were rendered", #jobs, M.MAX_RENDERS)
		)
		jobs = table.move(jobs, 1, M.MAX_RENDERS, 1, {})
	end
	local i = 0
	local function nextJob()
		if not live(s) then
			return
		end
		i += 1
		local job = jobs[i]
		if job == nil then
			finish(s, index, nil)
			return
		end
		report(s, "render", i - 1, #jobs)
		job.start(function(text: string?, err: string?)
			if not live(s) then
				return
			end
			if text then
				Index.addRendered(index, Index.source(index, job.kind, job.path, job.helm), text)
			else
				diagnostic(index, "error", job.label, err or "render failed")
			end
			nextJob()
		end)
	end
	nextJob()
end

-- tern.fs.read refuses symlinks when capped; realpath(1) resolves them all
-- in one process (one NUL-terminated line per input, empty on failure).
local function resolveLinks(paths: { string }, cb: ({ [string]: string }) -> ())
	if #paths == 0 then
		cb({})
		return
	end
	local argv = { "sh", "-c", 'for f; do printf "%s\\0" "$(realpath -- "$f" 2>/dev/null)"; done', "sh" }
	table.move(paths, 1, #paths, #argv + 1, argv)
	run(argv, { timeout_ms = M.GIT_TIMEOUT_MS }, function(result)
		local out: { [string]: string } = {}
		for i, target in string.split(result.stdout, "\0") do
			if paths[i] and target ~= "" then
				out[paths[i]] = target
			end
		end
		cb(out)
	end)
end

local function readAll(s: ScanState, files: { string })
	local plan = Index.plan(
		files,
		{ maxFiles = s.opts.maxFiles, maxBytes = s.opts.maxBytes, maxFileBytes = s.opts.maxFileBytes }
	)
	local index = Index.new(s.root, plan.limits)
	index.truncated = plan.truncated
	local limited = 0
	for _, skip in plan.skipped do
		if skip.reason == "limit" then
			limited += 1
		end
	end
	if limited > 0 then
		diagnostic(
			index,
			"warning",
			nil,
			string.format("%d files not indexed (limit %d files)", limited, plan.limits.maxFiles)
		)
	end
	local links: { string } = {}
	local stopped = false
	local function add(path: string, text: string)
		if not stopped and not Index.addFile(index, path, text) then
			stopped = true
			diagnostic(index, "warning", path, string.format("indexing stopped at %d bytes", plan.limits.maxBytes))
		end
	end
	local function read(path: string)
		local ok, text = pcall(tern.fs.read, path, plan.limits.maxFileBytes)
		if ok then
			add(path, text)
		elseif string.find(tostring(text), "non-symlink", 1, true) then
			table.insert(links, path)
		else
			diagnostic(index, "warning", path, "not read: " .. Shellenv.errorText(text))
		end
	end
	local i = 0
	local total = #plan.read
	local function tick()
		if not live(s) then
			return
		end
		local t0 = tern.now()
		local n = 0
		while i < total and not stopped and n < M.CHUNK_FILES and tern.now() - t0 < M.CHUNK_MS do
			i += 1
			n += 1
			read(plan.read[i])
		end
		report(s, "read", i, total)
		if i < total and not stopped then
			tern.timer(0, tick)
			return
		end
		resolveLinks(links, function(targets: { [string]: string })
			if not live(s) then
				return
			end
			for _, path in links do
				local target = targets[path]
				local ok, text = false, "symlink target could not be resolved"
				if target then
					ok, text = pcall(tern.fs.read, target, plan.limits.maxFileBytes)
				end
				if ok then
					add(path, text)
				else
					diagnostic(index, "warning", path, "not read: " .. Shellenv.errorText(text))
				end
			end
			render(s, index)
		end)
	end
	tick()
end

-- Bounded breadth-first walk for directories outside git. tern.fs.list
-- raises on files, which is how directories are told apart.
local function walk(s: ScanState)
	local files: { string } = {}
	local queue: { { path: string, depth: number } } = { { path = s.root, depth = 0 } }
	local head, visited = 1, 0
	local function tick()
		if not live(s) then
			return
		end
		local t0 = tern.now()
		while head <= #queue and visited < M.WALK_MAX_ENTRIES and tern.now() - t0 < M.CHUNK_MS do
			local dir = queue[head]
			head += 1
			local ok, names = pcall(tern.fs.list, dir.path)
			if not ok then
				continue
			end
			for _, name in names :: { string } do
				visited += 1
				local path = dir.path .. "/" .. name
				local lower = string.lower(name)
				if string.match(lower, "%.ya?ml$") or name == "Kustomization" then
					table.insert(files, path)
				elseif not SKIP_DIRS[name] and string.sub(name, 1, 1) ~= "." and dir.depth < M.WALK_DEPTH then
					table.insert(queue, { path = path, depth = dir.depth + 1 })
				end
			end
		end
		report(s, "list", #files, 0)
		if head <= #queue and visited < M.WALK_MAX_ENTRIES then
			tern.timer(0, tick)
			return
		end
		readAll(s, files)
	end
	tick()
end

-- Indexes the repo containing `cwd` (or `cwd` itself outside git). Progress
-- is reported per phase; `onDone` runs once with the index or an error.
function M.scan(cwd: string, opts: ScanOpts?, onProgress: (Progress) -> (), onDone: Done): Scan
	local s: ScanState = {
		cwd = cwd,
		opts = opts or {},
		progress = onProgress,
		done = onDone,
		cancelled = false,
		finished = false,
		root = cwd,
		git = false,
	}
	report(s, "root", 0, 1)
	run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { timeout_ms = M.GIT_TIMEOUT_MS }, function(top)
		if not live(s) then
			return
		end
		if top.status ~= 0 then
			walk(s)
			return
		end
		s.git = true
		s.root = trimNewline(top.stdout)
		report(s, "list", 0, 0)
		run({
			"git",
			"-C",
			s.root,
			"ls-files",
			"-co",
			"--exclude-standard",
			"-z",
			"--",
			"*.yaml",
			"*.yml",
			"*Kustomization",
		}, { timeout_ms = M.GIT_TIMEOUT_MS }, function(list)
			if not live(s) then
				return
			end
			if list.status ~= 0 then
				finish(s, nil, failure("git ls-files", list))
				return
			end
			readAll(s, Index.parseFileList(s.root, list.stdout))
		end)
	end)
	return {
		cancel = function()
			s.cancelled = true
		end,
	}
end

return M
