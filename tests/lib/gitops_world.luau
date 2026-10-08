--!strict
-- A fake host for the Explore GitOps routes: a repository of manifests
-- (the drift world captured from kind by scripts/fixtures/capture-drift.sh,
-- mounted at ROOT/drift), a plugin data directory, git, gh and kubectl
-- answers (real captured diffs and listings). `drive` executes the effects
-- the core returns (run, scan, read, readtree, write) and feeds the results
-- back until nothing is left, recording what was run, written and removed.
local Gitops = require("../../plugin/lib/explore/gitops")
local Index = require("../../plugin/lib/gitops/index")
local Query = require("../../plugin/lib/explore/query")
local T = require("../../plugin/lib/explore/types")
local Yaml = require("../../plugin/lib/parse/yaml")
local fixtures = require("./fixtures")
local json = require("./json")
local W = require("./explore")

type Effect = T.Effect
type Msg = T.Msg
export type Result = T.ProcessResult

local M = {}

M.ROOT = "/repo"
M.DATA = "/data"
M.CTX = "kind-tern-kube-dev"
M.NS = "tern-test-drift"
M.AT = 1000
M.REMOTE = "/tmp/remote.git"

export type World = {
	files: { [string]: string },
	tmp: { [string]: string },
	removed: { string },
	runs: { { string } },
	stdin: { [number]: string },
	effects: { Effect },
	toasts: { Effect },
	opened: { string },
	-- Per-argv override: return a result to answer, nil to fall through.
	answer: ((argv: { string }, e: Effect) -> Result?)?,
	-- git answers.
	staged: string,
	remotes: string,
	gh: string?,
	scanError: string?,
	-- kustomize / helm renders added to the index after the files.
	rendered: { { kind: Index.SourceType, path: string, helm: Index.HelmSpec?, text: string } },
	-- Last argv run per diff file (the temp file's text at diff time).
	diffInputs: { string },
}

local function ok(stdout: string): Result
	return { status = 0, stdout = stdout, stderr = "", timed_out = false }
end

function M.fail(status: number, stderr: string): Result
	return { status = status, stdout = "", stderr = stderr, timed_out = false }
end

M.ok = ok

-- The drift world's manifests at ROOT/drift/<rel>.
function M.driftFiles(): { [string]: string }
	local out: { [string]: string } = {}
	for _, key in fixtures.list("drift/manifests/") do
		local rel = string.sub(key, #"drift/manifests/" + 1)
		out[M.ROOT .. "/drift/" .. rel] = fixtures.read(key)
	end
	return out
end

function M.new(files: { [string]: string }?): World
	return {
		files = files or M.driftFiles(),
		tmp = {},
		removed = {},
		runs = {},
		stdin = {},
		effects = {},
		toasts = {},
		opened = {},
		answer = nil,
		staged = "",
		remotes = "origin\t" .. M.REMOTE .. " (fetch)\norigin\t" .. M.REMOTE .. " (push)\n",
		gh = nil,
		scanError = nil,
		rendered = {},
		diffInputs = {},
	}
end

function M.index(w: World): Index.Index
	local rels: { string } = {}
	for path in w.files do
		if string.sub(path, 1, #M.ROOT + 1) == M.ROOT .. "/" then
			table.insert(rels, string.sub(path, #M.ROOT + 2))
		end
	end
	local plan = Index.plan(rels, {})
	local index = Index.new(M.ROOT, plan.limits)
	for _, rel in plan.read do
		Index.addFile(index, M.ROOT .. "/" .. rel, w.files[M.ROOT .. "/" .. rel])
	end
	index.scannedFiles = #plan.read
	for _, r in w.rendered do
		Index.addRendered(index, Index.source(index, r.kind, r.path, r.helm), r.text)
	end
	return index
end

function M.target(ns: string?): Query.Target
	return {
		kubeconfig = nil,
		context = M.CTX,
		contextSource = "flag",
		namespace = ns or M.NS,
		allNamespaces = false,
		confirmed = true,
		inferredAt = nil,
	}
end

function M.ctx(cfgText: string?, ns: string?): Gitops.Ctx
	local counter = 0
	return {
		target = M.target(ns),
		program = "kubectl",
		config = W.config(cfgText),
		decode = json.decode,
		resolved = true,
		now = M.AT,
		dataDir = M.DATA,
		nonce = function(): string
			counter += 1
			return "n" .. counter
		end,
		isList = function(_t: { [any]: any }): boolean
			return false
		end,
		null = json.null,
	}
end

local function has(argv: { string }, word: string): boolean
	return table.find(argv, word) ~= nil
end

local function flagValues(argv: { string }, name: string): { string }
	local out: { string } = {}
	for i, a in argv do
		if a == name and argv[i + 1] then
			table.insert(out, argv[i + 1])
		end
	end
	return out
end

-- Captured `kubectl diff` output for one manifest file of the drift world.
local DIFFS: { [string]: string } = {
	["drift/baseline/app.yaml"] = "changed/diff_-f_drift+baseline+app.yaml",
	["drift/baseline/service.yaml"] = "unchanged/diff_-f_drift+baseline+service.yaml",
	["drift/baseline/widgets.yaml"] = "crd/diff_-f_drift+baseline+widgets.yaml",
	["drift/pending/extra.yaml"] = "missing/diff_-f_drift+pending+extra.yaml",
	["drift/namespace.yaml"] = "cluster-scoped/diff_-f_drift+namespace.yaml",
}

function M.capturedDiff(rel: string): Result
	local key = DIFFS[rel]
	if key == nil then
		return ok("")
	end
	local exit = tonumber((string.gsub(fixtures.read("drift/" .. key .. ".exit"), "%s", ""))) or 0
	return { status = exit, stdout = fixtures.read("drift/" .. key .. ".txt"), stderr = "", timed_out = false }
end

-- The repo-relative file a temp diff input was cut from (by content).
local function originOf(w: World, text: string): string?
	for path, body in w.files do
		if string.find(body, (string.gsub(text, "\n+$", "")), 1, true) then
			return string.sub(path, #M.ROOT + 2)
		end
	end
	return nil
end

-- Keeps the `diff -u -N` blocks of the objects `text` declares: a temp
-- input holds one document of a multi-document file.
local function only(stdout: string, text: string): string
	local names: { string } = {}
	for _, d in Yaml.split(text).docs do
		if d.ref then
			table.insert(names, "." .. d.ref.kind .. ".")
			table.insert(names, "." .. d.ref.name .. " ")
		end
	end
	local out: { string } = {}
	local keep = false
	for _, line in string.split(stdout, "\n") do
		if string.sub(line, 1, 11) == "diff -u -N " then
			keep = false
			for i = 1, #names, 2 do
				if string.find(line, names[i], 1, true) and string.find(line, names[i + 1], 1, true) then
					keep = true
					break
				end
			end
		end
		if keep then
			table.insert(out, line)
		end
	end
	return if #out > 0 then table.concat(out, "\n") .. "\n" else ""
end

local function kubectl(w: World, argv: { string }): Result
	if has(argv, "diff") then
		local files = flagValues(argv, "-f")
		local out: { string } = {}
		local exit = 0
		for _, f in files do
			local rel: string?
			local text = w.tmp[f]
			if text then
				table.insert(w.diffInputs, text)
				rel = originOf(w, text)
			else
				rel = string.sub(f, #M.ROOT + 2)
			end
			local r = M.capturedDiff(rel or "")
			local stdout = if text then only(r.stdout, text) else r.stdout
			table.insert(out, stdout)
			if stdout ~= "" then
				exit = math.max(exit, r.status)
			end
		end
		return { status = exit, stdout = table.concat(out), stderr = "", timed_out = false }
	elseif has(argv, "api-resources") then
		return ok(fixtures.read("drift/controllers/api-resources.list"))
	elseif has(argv, "get") and has(argv, "-A") then
		for _, name in { "applications", "kustomizations", "helmreleases", "gitrepositories" } do
			for _, a in argv do
				if string.sub(a, 1, #name + 1) == name .. "." then
					return ok(fixtures.read("drift/controllers/" .. name .. ".json"))
				end
			end
		end
		return ok('{"items":[]}')
	elseif has(argv, "get") and has(argv, "-n") then
		local ns = flagValues(argv, "-n")[1]
		if ns == M.NS then
			return ok(fixtures.read("drift/live/objects.json"))
		end
		return ok('{"apiVersion":"v1","items":[],"kind":"List"}')
	end
	return M.fail(1, "fake kubectl: unhandled " .. table.concat(argv, " "))
end

local function git(w: World, argv: { string }): Result
	local verb = argv[4]
	if verb == "remote" and argv[5] == "-v" then
		return ok(w.remotes)
	elseif verb == "remote" then
		return ok(if w.remotes ~= "" then "origin\n" else "")
	elseif verb == "status" and has(argv, "--") then
		return ok("")
	elseif verb == "status" then
		return ok(w.staged)
	elseif verb == "rev-parse" then
		return ok("main\n")
	end
	return ok("")
end

function M.respond(w: World, e: Effect): Result
	local argv = e.argv :: { string }
	table.insert(w.runs, argv)
	if e.stdin then
		w.stdin[#w.runs] = e.stdin :: string
	end
	if w.answer then
		local r = (w.answer :: any)(argv, e)
		if r then
			return r
		end
	end
	local p = argv[1]
	if p == "/bin/sh" and argv[3] == Gitops.WRITE_SCRIPT then
		w.tmp[argv[5]] = e.stdin or ""
		return ok("")
	elseif p == "/bin/sh" and string.find(argv[3] or "", "command -v", 1, true) then
		return if w.gh then ok(w.gh :: string .. "\n") else M.fail(1, "")
	elseif p == "rm" then
		local path = argv[#argv]
		w.tmp[path] = nil
		table.insert(w.removed, path)
		return ok("")
	elseif p == "git" then
		return git(w, argv)
	elseif w.gh and p == w.gh then
		return ok("")
	elseif p == "kubectl" then
		return kubectl(w, argv)
	end
	return M.fail(127, p .. ": not found")
end

-- Every argv run, joined by spaces.
function M.lines(w: World): { string }
	local out: { string } = {}
	for _, argv in w.runs do
		table.insert(out, table.concat(argv, " "))
	end
	return out
end

-- Whether any run argv contains `word` (exact element).
function M.ran(w: World, pred: (argv: { string }) -> boolean): { string }?
	for _, argv in w.runs do
		if pred(argv) then
			return argv
		end
	end
	return nil
end

-- Executes effects until none is left; `update` applies a result message
-- and returns the effects it asked for.
function M.drive(w: World, effects: { Effect }, update: (msg: Msg) -> { Effect })
	local queue = table.clone(effects)
	local guard = 0
	while #queue > 0 do
		guard += 1
		assert(guard < 1000, "drive: too many effects")
		local e = table.remove(queue, 1) :: Effect
		table.insert(w.effects, e)
		local msg: Msg? = nil
		if e.t == "run" then
			msg = { t = "result", tag = e.tag, gen = e.gen, result = M.respond(w, e), at = M.AT }
		elseif e.t == "scan" then
			if w.scanError then
				msg = { t = "result", tag = e.tag, gen = e.gen, result = M.fail(1, w.scanError :: string), at = M.AT }
			else
				msg = { t = "result", tag = e.tag, gen = e.gen, result = ok(""), index = M.index(w), at = M.AT }
			end
		elseif e.t == "read" then
			local text = w.files[e.path :: string]
			msg = {
				t = "result",
				tag = e.tag,
				gen = e.gen,
				result = if text then ok(text) else M.fail(1, "no such file " .. tostring(e.path)),
				at = M.AT,
			}
		elseif e.t == "readtree" then
			local dir = (e.path :: string) .. "/"
			local found: { [string]: string } = {}
			for path, text in w.files do
				if string.sub(path, 1, #dir) == dir then
					found[path] = text
				end
			end
			msg = { t = "result", tag = e.tag, gen = e.gen, result = ok(""), files = found, at = M.AT }
		elseif e.t == "write" then
			for _, f in e.files :: { T.FileWrite } do
				w.files[f.path] = f.text
			end
			msg = { t = "result", tag = e.tag, gen = e.gen, result = ok(""), at = M.AT }
		elseif e.t == "toast" then
			table.insert(w.toasts, e)
		elseif e.t == "openfile" then
			table.insert(w.opened, (e.path :: string) .. ":" .. tostring(e.line))
		elseif e.t == "open" then
			table.insert(w.opened, e.url :: string)
		end
		if msg then
			for _, n in update(msg :: Msg) do
				table.insert(queue, n)
			end
		end
	end
end

-- Drives the pure GitOps core directly.
function M.core(w: World, g: Gitops.G, ctx: Gitops.Ctx, effects: { Effect })
	M.drive(w, effects, function(msg: Msg): { Effect }
		local out: { Effect } = {}
		Gitops.onResult(g, ctx, msg, out)
		return out
	end)
end

function M.key(name: string, extra: { [string]: any }?): T.Key
	local k: { [string]: any } = { name = name }
	if #name == 1 then
		k.text = name
	end
	for a, b in extra or ({} :: { [string]: any }) do
		k[a] = b
	end
	return k :: any
end

-- Sends a key to the GitOps core of `route` and drives what it starts.
function M.press(
	w: World,
	g: Gitops.G,
	ctx: Gitops.Ctx,
	route: T.Route,
	selected: T.Item?,
	name: string
): (boolean, Gitops.Nav?)
	local effects: { Effect } = {}
	local k = M.key(name)
	local ch = if #name == 1 then name else nil
	local handled, nav = Gitops.onKey(g, ctx, route, selected, ch, k, effects)
	M.core(w, g, ctx, effects)
	return handled, nav
end

-- A G whose index is built (scan driven through the core).
function M.ready(w: World, ctx: Gitops.Ctx): Gitops.G
	local g = Gitops.new(M.ROOT)
	local effects: { Effect } = {}
	Gitops.ensureIndex(g, ctx, effects)
	M.core(w, g, ctx, effects)
	return g
end

function M.toastTexts(w: World): { string }
	local out: { string } = {}
	for _, e in w.toasts do
		table.insert(out, (e.text or "") .. (if e.sub then " | " .. e.sub else ""))
	end
	return out
end

return M
