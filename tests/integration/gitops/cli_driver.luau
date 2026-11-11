--!strict
-- Headless Explore for cli-equivalence.sh: replays the drift routes of each
-- source (and one matrix) through the pure Explore state machine with real
-- kubectl / git / helm answers, presses Y (or the matrix's Copy CLI command
-- chip) and prints what tern-kube-drift must report for the copied command.
-- Standalone luau can neither spawn processes nor read files: run.sh keeps
-- every answer in .transcripts/answers.luau (keyed by argv) and the
-- repository's indexable files in .transcripts/files.luau, and calls this
-- driver again until nothing is missing. Each call replays from init and
-- prints shell lines for the script to eval:
--   tk_need KEY TIMEOUT_MS ARGV...   a run the replay has no answer for
--   tk_write PATH HEX                a temporary manifest Explore wrote (0600)
--   tk_cli NAME COMMAND EXPECTED     the copied command and, one per line, the
--                                    normalized report the CLI must print
--   tk_ok NAME / tk_fail NAME WHY    driver-side assertions
--
--   .tools/bin/luau tests/integration/gitops/cli_driver.luau -a REPO KUBECONFIG DATA HELM ALIAS
local Command = require("../../../plugin/lib/kubectl/command")
local Config = require("../../../plugin/lib/config")
local Gitops = require("../../../plugin/lib/explore/gitops")
local HelmQuery = require("../../../plugin/lib/helm/query")
local Index = require("../../../plugin/lib/gitops/index")
local State = require("../../../plugin/lib/explore/state")
local json = require("../../lib/json")

type State = State.State
type Effect = State.Effect
type Msg = State.Msg
type Answer = { status: number, out: string, err: string, timedOut: boolean }

local args = { ... }
local REPO = args[1] :: string
local KC = args[2] :: string
local DATA = args[3] :: string
local HELM = args[4] :: string
local ALIAS = args[5] :: string
assert(REPO and KC and DATA and HELM and ALIAS, "driver: arguments missing")

local CTX = "kind-tern-kube-dev"
local NS = "tern-test-gitops-cli"
local AT = 1762000000
local CONFIG = string.format(
	'{"gitops":{"helm":[{"chart":"k8s/chart","release":"rel","namespace":"%s","values":["k8s/values-prod.yaml"]}]}}',
	NS
)

local function hex(s: string): string
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

local function unhex(h: string): string
	return (string.gsub(h, "%x%x", function(x: string): string
		return string.char(tonumber(x, 16) :: number)
	end))
end

local answers: { [string]: Answer } = (require :: any)("./.transcripts/answers")
local files: { [string]: string } = (require :: any)("./.transcripts/files")

local arrays: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function decode(text: string): any
	local value, tracked = json.decodeTracking(text)
	for t in tracked do
		arrays[t] = true
	end
	return value
end

local function isList(t: { [any]: any }): boolean
	return arrays[t] == true
end

local function emit(words: { string })
	print(Command.format(words))
end

type World = { s: State, copies: { string }, toasts: { string } }

local needs: { [string]: { string } } = {}
local needTimeouts: { [string]: number } = {}
local writes: { [string]: string } = {}
local MISSING = {}

-- The answer of a run, or nil (recorded as needed).
local function answer(argv: { string }, timeout: number?): Answer?
	local key = hex(table.concat(argv, "\0"))
	local a = answers[key]
	if a == nil then
		needs[key] = argv
		needTimeouts[key] = timeout or 60000
	end
	return a
end

local function result(a: Answer): State.ProcessResult
	return { status = a.status, stdout = unhex(a.out), stderr = unhex(a.err), timed_out = a.timedOut }
end

-- Kustomizations no other kustomization lists (gitops_host.luau renders these).
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

-- What gitops_host.luau's scan builds, from the listed files and real
-- `kubectl kustomize` / `helm template` answers.
local function scan(opts: any): Index.Index?
	local paths: { string } = {}
	for path in files do
		table.insert(paths, path)
	end
	table.sort(paths)
	local plan =
		Index.plan(paths, { maxFiles = opts.maxFiles, maxBytes = opts.maxBytes, maxFileBytes = opts.maxFileBytes })
	local index = Index.new(REPO, plan.limits)
	for _, path in plan.read do
		Index.addFile(index, path, unhex(files[path]))
	end
	index.scannedFiles = #plan.read
	for _, chart in plan.chartReads do
		if files[chart.file] then
			Index.addChart(index, chart, unhex(files[chart.file]))
		end
	end
	local missing = false
	for _, dir in topKustomizations(index) do
		local a = answer({ "kubectl", "kustomize", dir })
		if a == nil then
			missing = true
		elseif a.status == 0 then
			Index.addRendered(index, Index.source(index, "kustomize", dir, nil), unhex(a.out))
		end
	end
	for _, r in opts.helm do
		local chart = REPO .. "/" .. r.chart
		local values: { string } = {}
		for i, v in r.values do
			values[i] = REPO .. "/" .. v
		end
		local a = answer(HelmQuery.template(HELM, r.release, chart, r.namespace, values))
		if a == nil then
			missing = true
		elseif a.status == 0 then
			local spec = { release = r.release, namespace = r.namespace, values = values }
			Index.addRendered(index, Index.source(index, "helm", chart, spec), unhex(a.out))
		end
	end
	return if missing then nil else index
end

local function settle(w: World, effects: { Effect })
	local queue = table.clone(effects)
	local guard = 0
	local stop = false
	while #queue > 0 do
		guard += 1
		assert(guard < 2000, "settle: too many effects")
		local e = table.remove(queue, 1) :: Effect
		local msg: Msg? = nil
		if e.t == "copy" then
			table.insert(w.copies, e.text or "")
		elseif e.t == "toast" then
			table.insert(w.toasts, (e.text or "") .. (if e.sub then " | " .. e.sub else ""))
		elseif e.t == "scan" and not stop then
			local index = scan(e.scan)
			if index == nil then
				stop = true
			else
				msg = {
					t = "result",
					tag = e.tag,
					gen = e.gen,
					at = AT,
					result = result({ status = 0, out = "", err = "", timedOut = false }),
					index = index,
				}
			end
		elseif e.t == "run" and not stop then
			local argv = e.argv :: { string }
			local a: Answer? = nil
			if argv[1] == "/bin/sh" and argv[3] == Gitops.WRITE_SCRIPT then
				writes[argv[5]] = e.stdin or ""
				a = { status = 0, out = "", err = "", timedOut = false }
			elseif argv[1] == "rm" then
				a = { status = 0, out = "", err = "", timedOut = false }
			else
				a = answer(argv, e.timeout_ms)
			end
			if a == nil then
				stop = true
			else
				msg = { t = "result", tag = e.tag, gen = e.gen, at = AT, now = AT, result = result(a) }
			end
		end
		if msg then
			local s2, more = State.update(w.s, msg :: Msg)
			w.s = s2
			for _, m in more do
				table.insert(queue, m)
			end
		end
	end
	if stop then
		error(MISSING, 0)
	end
end

local function send(w: World, msg: Msg)
	local s2, effects = State.update(w.s, msg)
	w.s = s2
	settle(w, effects)
end

local function key(name: string, ctrl: boolean?): Msg
	local k: { [string]: any } = { name = name, ctrl = ctrl == true, alt = false, shift = false, meta = false }
	if #name == 1 then
		k.text = name
		k.shift = string.upper(name) == name and string.lower(name) ~= name
	end
	return { t = "key", key = k :: any, now = AT }
end

local function open(): World
	local counter = 0
	local cfg = Config.parse(CONFIG, json.decode)
	local link = "tern-kube://explore?context="
		.. CTX
		.. "&cwd="
		.. REPO
		.. "&kind=ConfigMap&kubeconfig="
		.. KC
		.. "&namespace="
		.. NS
	local s, effects = State.init({ link }, nil, cfg, {
		kubeconfig = nil,
		home = "/nonexistent",
		kubectl = "kubectl",
		decode = decode,
		now = AT,
		isList = isList,
		null = json.null,
		cwd = REPO,
		dataDir = DATA,
		helm = HELM,
		nonce = function(): string
			counter += 1
			return "n" .. counter
		end,
	})
	local w: World = { s = s, copies = {}, toasts = {} }
	settle(w, effects)
	return w
end

local function top(w: World): State.Route
	return w.s.stack[#w.s.stack]
end

local function load(w: World): Gitops.DriftLoad?
	return Gitops.driftLoad(w.s.gitops, State.gitopsCtx(w.s), top(w))
end

-- The report as tern-kube-drift --format json must print it (normalized by
-- run.sh): diffed objects, unmanaged ones, and those another source of the
-- repository declares (the CLI lists them as unmanaged too).
local function expected(l: Gitops.DriftLoad): { string }
	local out: { string } = {}
	local report = l.report :: any
	for _, c in report.changed do
		table.insert(
			out,
			string.format("resource %s %s +%d -%d", c.key, c.segment.action, c.segment.added, c.segment.removed)
		)
	end
	for _, m in report.missing do
		local seg = m.segment
		if seg then
			table.insert(out, string.format("resource %s %s +%d -%d", m.key, seg.action, seg.added, seg.removed))
		else
			table.insert(out, "absent-without-diff " .. m.key)
		end
	end
	for _, u in report.unmanaged do
		local seg = u.segment
		if seg then
			table.insert(out, string.format("resource %s %s +%d -%d", u.key, seg.action, seg.added, seg.removed))
		else
			table.insert(out, "unmanaged " .. u.key)
		end
	end
	for _, k in report.declaredElsewhere do
		table.insert(out, "unmanaged " .. k)
	end
	table.sort(out)
	return out
end

type Check = { fails: { string } }

local function check(c: Check, ok: boolean, what: string)
	if not ok then
		table.insert(c.fails, what)
	end
end

local function has(c: Check, text: string?, needle: string, what: string)
	check(
		c,
		text ~= nil and string.find(text, needle, 1, true) ~= nil,
		what .. ": " .. string.format("%q", needle) .. " not in: " .. string.sub(text or "(no text)", 1, 600)
	)
end

type Case = { name: string, source: string, want: { string }, avoid: { string } }

local cases: { { name: string, command: string, expected: { string } } } = {}

local function report(c: Check, case: Case)
	local w = open()
	send(w, key("g", true))
	send(w, { t = "action", act = "open", value = case.source, now = AT } :: any)
	local l = load(w)
	check(
		c,
		l ~= nil and l.status == "ok",
		"report of " .. case.source .. " did not finish: " .. tostring(l and l.error)
	)
	if l == nil or l.status ~= "ok" then
		return
	end
	send(w, key("Y"))
	local copied = w.copies[#w.copies]
	check(c, copied ~= nil, "Y copied nothing: " .. table.concat(w.toasts, " / "))
	if copied == nil then
		return
	end
	for _, needle in case.want do
		has(c, copied, needle, "copied command")
	end
	for _, needle in case.avoid do
		check(c, string.find(copied, needle, 1, true) == nil, "copied command has " .. needle .. ": " .. copied)
	end
	table.insert(cases, { name = case.name, command = copied, expected = expected(l) })
end

local q = Command.quote

local CASES: { Case } = {
	{
		-- git lists exactly the compared files: -R, and -n for the
		-- namespace-less ConfigMaps.
		name = "clean-dir",
		source = "dir:" .. REPO .. "/plain",
		want = { "-R -f " .. REPO .. "/plain", "-n " .. NS, "--unmanaged configmap", "--kubeconfig " .. q(KC) },
		avoid = {},
	},
	{
		-- data.json and the git-ignored ignored.yaml are read by kubectl -R
		-- but not by Explore: explicit files.
		name = "mixed-dir",
		source = "dir:" .. REPO .. "/k8s/app",
		want = {
			"-f " .. REPO .. "/k8s/app/config.yaml -f " .. REPO .. "/k8s/app/deploy.yaml",
			"-n " .. NS,
			"--unmanaged configmap,deployment.apps,service",
		},
		avoid = { "-R" },
	},
	{
		name = "top-dir",
		source = "dir:" .. REPO .. "/k8s",
		want = { "-f " .. REPO .. "/k8s/app/config.yaml" },
		avoid = { "-R" },
	},
	{
		name = "quoted-dir",
		source = "dir:" .. REPO .. "/k8s/we'ird dir",
		want = { "-R -f " .. q(REPO .. "/k8s/we'ird dir") },
		avoid = {},
	},
	{
		name = "kustomize",
		source = "kustomize:" .. REPO .. "/k8s/base",
		want = { "-k " .. REPO .. "/k8s/base", "-n " .. NS },
		avoid = {},
	},
	{
		name = "helm-configured",
		source = "helm:" .. REPO .. "/k8s/chart:rel",
		want = {
			"--helm " .. REPO .. "/k8s/chart --release rel --values " .. REPO .. "/k8s/values-prod.yaml",
			"-n " .. NS,
		},
		avoid = { "HELM=" },
	},
}

local MATRIX = "matrix"

-- One source across the block's context and ALIAS (the same cluster under
-- another context name): the chip's command and the matrix cells.
local function matrix(c: Check)
	local w = open()
	send(w, key("g", true))
	send(w, { t = "action", act = "open", value = "dir:" .. REPO .. "/plain", now = AT } :: any)
	send(w, key("x"))
	send(w, { t = "action", act = "open", value = "=" .. ALIAS, now = AT } :: any)
	local ctx = State.gitopsCtx(w.s)
	local mx = Gitops.matrix(w.s.gitops, ctx, top(w))
	check(c, mx ~= nil, "matrix did not open")
	if mx == nil then
		return
	end
	send(w, { t = "action", act = "gitops-copycli", value = "", now = AT } :: any)
	local copied = w.copies[#w.copies]
	check(c, copied ~= nil, "the chip copied nothing: " .. table.concat(w.toasts, " / "))
	if copied == nil then
		return
	end
	has(c, copied, "--context " .. CTX .. " --context " .. ALIAS, "column order")
	local state: { [string]: string } = { changed = "modify", missing = "create" }
	local out: { string } = {}
	for _, row in mx.rows do
		local cells: { string } = {}
		for i, cell in row.cells do
			cells[i] = state[cell.state] or cell.state
		end
		table.insert(out, "cell " .. row.key .. " " .. table.concat(cells, " "))
	end
	-- Objects another source declares: unmanaged in every column for the CLI.
	local m = Gitops.matrixState(w.s.gitops, ctx, top(w)) :: Gitops.MatrixState
	local elsewhere: { [string]: { string } } = {}
	for i, context in m.contexts do
		local t = table.clone(m.base)
		t.context = context
		local d = w.s.gitops.drifts[Gitops.driftId(if context == m.base.context then m.base else t, m.source)]
		for _, k in (if d and d.report then d.report.declaredElsewhere else {}) :: { string } do
			elsewhere[k] = elsewhere[k] or table.create(#m.contexts, "absent")
			elsewhere[k][i] = "unmanaged"
		end
	end
	for k, cells in elsewhere do
		table.insert(out, "cell " .. k .. " " .. table.concat(cells, " "))
	end
	table.sort(out)
	table.insert(cases, { name = MATRIX, command = copied, expected = out })
end

local results: { { name: string, fails: { string } } } = {}
local function run(name: string, fn: (c: Check) -> ())
	local c: Check = { fails = {} }
	local ok, err = pcall(fn :: any, c)
	if not ok and err ~= MISSING then
		table.insert(c.fails, "error: " .. tostring(err))
	end
	table.insert(results, { name = name, fails = c.fails })
end

for _, case in CASES do
	run(case.name, function(c: Check)
		report(c, case)
	end)
end
run(MATRIX, matrix)

local paths: { string } = {}
for p in writes do
	table.insert(paths, p)
end
table.sort(paths)
for _, p in paths do
	emit({ "tk_write", p, hex(writes[p]) })
end

if next(needs) ~= nil then
	local keys: { string } = {}
	for k in needs do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		local words: { string } = { "tk_need", k, tostring(needTimeouts[k]) }
		for _, a in needs[k] do
			table.insert(words, a)
		end
		emit(words)
	end
	return nil
end

for _, r in results do
	if #r.fails == 0 then
		emit({ "tk_ok", r.name })
	else
		for _, f in r.fails do
			emit({ "tk_fail", r.name, f })
		end
	end
end
for _, case in cases do
	emit({ "tk_cli", case.name, case.command, table.concat(case.expected, "\n") })
end
return nil
