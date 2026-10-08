--!strict
-- The approve block as an Elm-style core: init/update return the next state
-- and the effects the host (plugin/mutate_host.luau) executes; process
-- results, ticks, keys and clicks come back as messages. No `tern` here.
--
-- Three entry points share one pipeline:
--   native  kube-lens://mutate?... (Explore keys, lens chips, palette): the
--           block executes the pinned argv after confirmation;
--   quick   kube-lens://act/<debug-pod|debug-node|cronjob-run>?...: after
--           confirmation the block grants a single-use token and opens the
--           action link with confirm=<token>; the window runs the split;
--   guard   <spool>/req-<nonce>.json from `tern open --wait` (shell/PROTOCOL.md):
--           the block never executes; it writes resp-<nonce>.env and exits 0.
--
-- Pipeline: resolve the context (when not given) -> `config view --minify`
-- (the context exists; its cluster server is recorded) -> plan -> input
-- digests -> fingerprint -> preview steps (in parallel) -> risk tier. On
-- confirm everything that decides the target is read again (digests,
-- fingerprint, server, current-context when inferred) and any change refuses.
-- A result whose generation is not current is ignored: processes cannot be
-- killed, so "cancel" means dropping late callbacks.
local Audit = require("./audit")
local Command = require("../kubectl/command")
local Confirm = require("./confirm")
local Diffseg = require("./diffseg")
local Fingerprint = require("./fingerprint")
local Link = require("./link")
local ParseMutation = require("../parse/mutation")
local Plan = require("./plan")
local Quick = require("../actions/quick")
local Risk = require("./risk")
local Steps = require("./steps")
local T = require("./types")
local Types = require("../model/types")
local Viewstate = require("../lens/viewstate")

type Diagnostic = T.Diagnostic

export type Mode = "native" | "quick" | "guard"
export type Phase =
	"input"
	| "loading"
	| "previewing"
	| "ready"
	| "verifying"
	| "executing"
	| "done"
	| "responding"
	| "error"
	| "expired"
	| "closed"

export type ProcessResult = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type ReadFile = { path: string, text: string?, error: string? }
export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

-- One record with optional fields per effect kind:
--   run    tag gen argv env cwd stdin timeout_ms   -> Msg result
--   read   tag gen paths                           -> Msg read
--   write  tag gen path text argv  (write path, then run argv) -> Msg result
--   remove path · audit line · grant token url expires · open url
--   focus id · copy text · toast level text · exit
export type Effect = {
	t: string,
	tag: string?,
	gen: number?,
	argv: { string }?,
	env: { [string]: string }?,
	cwd: string?,
	stdin: string?,
	timeout_ms: number?,
	paths: { string }?,
	path: string?,
	text: string?,
	line: string?,
	token: string?,
	url: string?,
	expires: number?,
	id: string?,
	level: string?,
}

export type Msg = {
	t: string,
	now: number?,
	tag: string?,
	gen: number?,
	result: ProcessResult?,
	files: { ReadFile }?,
	key: Key?,
	act: string?,
	value: string?,
	id: string?,
	-- tick: whether the guard request's pane is alive / its cancel marker exists.
	paneAlive: boolean?,
	cancelled: boolean?,
}

export type Config = {
	mutations: Confirm.MutationsConfig,
	previewTimeoutMs: number,
	execTimeoutMs: number,
	-- security.show_secret_values: false redacts Secret last-applied lines in diffs.
	showSecretValues: boolean,
	quick: Quick.Settings,
}

export type Init = {
	args: { string },
	now: number,
	config: Config,
	-- Program for native and quick commands (config > KUBE_LENS_KUBECTL > kubectl).
	kubectl: string,
	-- Host-resolved kubeconfig for native/quick: config file, else daemon KUBECONFIG.
	kubeconfig: string?,
	home: string?,
	-- <plugin data>/spool as the host knows it (not canonicalized).
	spool: string,
	-- Guard mode: the request file as the host read it.
	request: { text: string?, error: string? }?,
	-- Live pane ids at init.
	panes: { string }?,
	decode: (string) -> any,
}

export type GuardRequest = {
	path: string,
	dir: string,
	nonce: string,
	argv: { string },
	program: string,
	cwd: string,
	kubeconfig: string?,
	context: string,
	contextSource: T.ContextSource,
	namespace: string?,
	pane: string,
	files: { Fingerprint.FileDigest },
	fingerprint: string,
	createdAt: number,
	timeoutS: number,
}

export type StepStatus = "pending" | "running" | "ok" | "failed"
export type StepRun = {
	step: T.Step,
	status: StepStatus,
	outcome: Steps.Outcome?,
	stdout: string?,
	stderr: string?,
}

export type TargetInfo = { cluster: string?, server: string?, namespace: string?, user: string? }

export type Exec = {
	startedAt: number,
	finishedAt: number?,
	status: number?,
	timedOut: boolean,
	stdout: string,
	stderr: string,
}

export type Requery = { at: number?, steps: { StepRun } }

export type State = {
	mode: Mode,
	phase: Phase,
	now: number,
	config: Config,
	decode: (string) -> any,
	kubectl: string,
	home: string?,
	spool: string,
	hostKubeconfig: string?,
	link: Link.Request?,
	quick: Quick.Request?,
	launch: Quick.Launch?,
	request: GuardRequest?,
	-- The request is authentic (spool, nonce, pane): a deny can be written.
	canRespond: boolean,
	-- Sent with a deny the block decides on its own (mutations disabled).
	denyReason: string?,
	argv: { string }?,
	env: T.Env?,
	conn: { program: string, kubeconfig: string? },
	errors: { string },
	diagnostics: { Diagnostic },
	plan: T.Plan?,
	target: TargetInfo?,
	files: { Fingerprint.FileDigest }?,
	fingerprint: string?,
	steps: { StepRun },
	manifests: { T.Manifest }?,
	notes: { string },
	diff: Diffseg.Summary?,
	dryRun: Types.MutationParse?,
	targets: { Types.ResourceRef }?,
	replicasNow: { [string]: number },
	assessment: T.Assessment?,
	requirements: Confirm.Requirements?,
	previewedAt: number?,
	gen: number,
	pending: { [string]: boolean },
	verify: { files: { Fingerprint.FileDigest }?, fingerprint: string?, target: TargetInfo?, current: string? },
	typed: string,
	targetConfirmed: boolean,
	override: boolean,
	stale: boolean,
	confirmError: string?,
	notice: string?,
	showCommand: boolean,
	help: boolean,
	expanded: { [number]: boolean },
	focus: number?,
	focused: boolean,
	exec: Exec?,
	resultView: Viewstate.ViewState,
	requery: Requery?,
	decided: boolean,
}

local M = {}

M.TYPED_INPUT = "main.typed"
M.MAX_REQUEST_BYTES = 65536
M.MAX_MANIFEST_BYTES = 2097152
-- A request from the future is forged or from a skewed clock.
M.CLOCK_SKEW_S = 60
M.DISABLED = "Mutations are disabled (mutations.enabled is false in the kube-lens config); nothing was run."

M.DIGEST_SCRIPT = [[
set -f
mode=$1 cwd=$2 rec=$3
shift 3
if command -v sha256sum >/dev/null 2>&1; then sha=sha256sum
elif command -v shasum >/dev/null 2>&1; then sha='shasum -a 256'
else echo 'neither sha256sum nor shasum is available' >&2; exit 3
fi
nl='
'
list() {
	for item do
		kind=${item%%:*}
		p=${item#*:}
		case $p in /*) ;; *) p=$cwd/$p ;; esac
		if [ "$mode" = exact ]; then printf '%s\n' "$p"; continue; fi
		if [ -d "$p" ]; then
			while :; do case $p in /) break ;; */) p=${p%/} ;; *) break ;; esac; done
			case $(cd -- "$p" && find . -name "*$nl*") in ?*) printf '!a file name under %s contains a newline\n' "$p"; continue ;; esac
			if [ "$kind" = k ]; then found=$(cd -- "$p" && find . ! -type d)
			elif [ "$rec" = 1 ]; then found=$(cd -- "$p" && find . ! -type d \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \))
			else found=$(cd -- "$p" && find . -mindepth 1 -maxdepth 1 ! -type d \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \))
			fi || { printf '!cannot list %s\n' "$p"; continue; }
			[ "$p" = / ] && p=
			printf '%s\n' "$found" | while IFS= read -r f; do [ -n "$f" ] && printf '%s/%s\n' "$p" "${f#./}"; done
		elif [ "$kind" = k ]; then printf '!-k needs a directory: %s\n' "$p"
		elif [ -e "$p" ]; then printf '%s\n' "$p"
		else printf '!no such file or directory: %s\n' "$p"
		fi
	done
}
list "$@" | LC_ALL=C sort -u | while IFS= read -r p; do
	case $p in '!'*) printf '%s\n' "${p#!}" >&2; exit 4 ;; esac
	[ -f "$p" ] || { printf '%s is not a regular file (stdin, devices and pipes cannot be previewed)\n' "$p" >&2; exit 4; }
	s=$(wc -c <"$p") || exit 4
	h=$($sha <"$p") || exit 4
	h=${h%%[!0-9a-f]*}
	printf '%s %s %s\n' "$((s + 0))" "$h" "$p"
done
]]

M.HASH_SCRIPT = [[
if command -v sha256sum >/dev/null 2>&1; then exec sha256sum; fi
if command -v shasum >/dev/null 2>&1; then exec shasum -a 256; fi
echo 'neither sha256sum nor shasum is available' >&2
exit 3
]]

M.NONCE_SCRIPT = "od -An -N16 -tx1 /dev/urandom | tr -d ' \\n'"
M.RESPOND_SCRIPT = 'chmod 600 "$1" 2>/dev/null; mv -f "$1" "$2"'
M.SPOOL_SCRIPT = 'cd -P -- "$1" && pwd -P'

-- Helpers ---------------------------------------------------------------------

local function nonEmpty(s: string?): string?
	return if s ~= nil and s ~= "" then s else nil
end

local function firstLine(text: string?): string
	for line in string.gmatch(text or "", "[^\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		if trimmed ~= "" then
			return trimmed
		end
	end
	return ""
end

local function fail(s: State, text: string)
	table.insert(s.errors, text)
	s.phase = "error"
	s.pending = {}
end

local function defaultKubeconfig(s: State): string?
	return if s.home then s.home .. "/.kube/config" else nil
end

type RunOpts = { env: { [string]: string }?, cwd: string?, stdin: string?, timeout: number? }

local function emitRun(s: State, effects: { Effect }, tag: string, argv: { string }, opts: RunOpts?)
	local o: RunOpts = opts or {}
	s.pending[tag] = true
	table.insert(effects, {
		t = "run",
		tag = tag,
		gen = s.gen,
		argv = argv,
		env = o.env or {},
		cwd = o.cwd,
		stdin = o.stdin,
		timeout_ms = o.timeout or s.config.previewTimeoutMs,
	})
end

-- kubectl with the connection the command will use (no context yet).
local function connArgv(s: State, words: { string }): ({ string }, { [string]: string })
	local argv: { string } = { s.conn.program }
	local env: { [string]: string } = {}
	local kc = s.conn.kubeconfig
	if kc then
		if Steps.isPathList(kc) then
			env.KUBECONFIG = kc
		else
			table.insert(argv, "--kubeconfig")
			table.insert(argv, kc)
		end
	end
	for _, w in words do
		table.insert(argv, w)
	end
	return argv, env
end

local function outcomeOf(step: T.Step, r: ProcessResult): Steps.Outcome
	local code: number? = if r.timed_out or r.status == -1 then nil else r.status
	return Steps.outcome(step, { code = code, stdout = r.stdout, stderr = r.stderr, timedOut = r.timed_out })
end

local function audit(s: State, effects: { Effect }, decision: Audit.Decision, exitCode: number?)
	local plan = s.plan
	if plan == nil then
		return
	end
	local exec = s.exec
	local record = Audit.record(plan, {
		mode = if s.mode == "guard" then "guard" else "native",
		decision = decision,
		tier = if s.assessment then s.assessment.tier else nil,
		fingerprint = s.fingerprint,
		exitCode = exitCode,
		previewedAt = s.previewedAt,
		decidedAt = s.now,
		startedAt = if exec then exec.startedAt else nil,
		finishedAt = if exec then exec.finishedAt else nil,
	})
	table.insert(effects, { t = "audit", line = Audit.line(record) })
end

local function exit(s: State, effects: { Effect })
	s.phase = "closed"
	s.pending = {}
	table.insert(effects, { t = "exit" })
end

-- Guard request ---------------------------------------------------------------

local function isHex(v: any, n: number): boolean
	return type(v) == "string" and #v == n and string.find(v, "^[0-9a-f]+$") ~= nil
end

local function isAbs(v: any): boolean
	return type(v) == "string" and string.sub(v, 1, 1) == "/" and string.find(v, "[%c]") == nil
end

local function isInt(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v >= 0
end

-- tern.json.decode drops null object members, so null arrives as nil.
local function optString(v: any): (boolean, string?)
	if v == nil then
		return true, nil
	end
	return type(v) == "string", if type(v) == "string" then nonEmpty(v) else nil
end

function M.parseRequest(path: string, text: string, decode: (string) -> any): (GuardRequest?, string?)
	local dir, nonce = string.match(path, "^(/.*)/req%-([0-9a-f]+)%.json$")
	if dir == nil or nonce == nil or #nonce ~= 32 then
		return nil, "not a kube-lens request path (<spool>/req-<32 hex>.json): " .. path
	end
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "the request is not valid JSON"
	end
	if doc.version ~= 1 then
		return nil, "unsupported request version " .. tostring(doc.version)
	end
	if doc.nonce ~= nonce then
		return nil, "the request's nonce does not match its file name"
	end
	local argv = doc.argv
	if type(argv) ~= "table" or #argv < 2 or argv[1] ~= "kubectl" then
		return nil, "the request argv must start with kubectl"
	end
	-- The host decoder returns locked tables (table.clone refuses them).
	local args: { string } = {}
	for _, a in argv do
		if type(a) ~= "string" then
			return nil, "the request argv must hold strings"
		end
		table.insert(args, a)
	end
	local program = doc.program
	if not isAbs(program) or not string.find(string.match(program, "[^/]+$") or "", "^kube") then
		return nil, "the request program must be an absolute path to kubectl"
	end
	if not isAbs(doc.cwd) then
		return nil, "the request cwd must be an absolute path"
	end
	local kcOk, kubeconfig = optString(doc.kubeconfig)
	local nsOk, namespace = optString(doc.namespace)
	if not kcOk or not nsOk then
		return nil, "the request kubeconfig/namespace must be strings or null"
	end
	if type(doc.context) ~= "string" or doc.context == "" or string.find(doc.context, "%c") then
		return nil, "the request has no context"
	end
	local source: T.ContextSource
	if doc.context_source == "flag" then
		source = "flag"
	elseif doc.context_source == "current-context" then
		source = "inferred"
	else
		return nil, "the request context_source must be flag or current-context"
	end
	if type(doc.pane) ~= "string" or not string.find(doc.pane, "^%d+$") then
		return nil, "the request has no Tern pane"
	end
	if not isHex(doc.fingerprint, 64) then
		return nil, "the request fingerprint is not a sha256 hex digest"
	end
	if not isInt(doc.created_at) or not isInt(doc.timeout_s) or doc.timeout_s <= 0 then
		return nil, "the request created_at/timeout_s are not whole seconds"
	end
	local files: { Fingerprint.FileDigest } = {}
	if type(doc.files) ~= "table" then
		return nil, "the request files must be a list"
	end
	for _, f in doc.files do
		if type(f) ~= "table" or not isAbs(f.path) or not isInt(f.size) or not isHex(f.sha256, 64) then
			return nil, "the request lists a malformed input file"
		end
		table.insert(files, { path = f.path, size = f.size, sha256 = f.sha256 })
	end
	return {
		path = path,
		dir = dir,
		nonce = nonce,
		argv = args,
		program = program,
		cwd = doc.cwd,
		kubeconfig = kubeconfig,
		context = doc.context,
		contextSource = source,
		namespace = namespace,
		pane = doc.pane,
		files = files,
		fingerprint = doc.fingerprint,
		createdAt = doc.created_at,
		timeoutS = doc.timeout_s,
	},
		nil
end

local function deadline(r: GuardRequest): number
	return r.createdAt + r.timeoutS
end

-- Pipeline --------------------------------------------------------------------

local startTarget: (s: State, effects: { Effect }) -> ()

-- Checks the command before anything runs; nil context is filled with a
-- placeholder so only the context error is deferred to resolution.
local function provisional(s: State): boolean
	local env = table.clone(s.env :: T.Env)
	local placeholder = env.context == nil
	if placeholder then
		env.context = "kube-lens-unresolved"
	end
	local plan, diags = Plan.fromArgv(s.argv :: { string }, env)
	if plan == nil then
		s.diagnostics = diags
		local texts: { string } = {}
		for _, d in diags do
			table.insert(texts, d.text)
		end
		if #diags > 0 and diags[1].severity == "info" then
			fail(s, "Nothing to approve: " .. table.concat(texts, "; "))
		else
			fail(s, "The command cannot be previewed: " .. table.concat(texts, "; "))
		end
		return false
	end
	s.conn = { program = plan.program, kubeconfig = plan.kubeconfig }
	local context = plan.invocation.context
	if context then
		local live = s.env :: T.Env
		live.context = context
		live.contextSource = "flag"
	end
	return true
end

local function start(s: State, effects: { Effect })
	if not provisional(s) then
		return
	end
	s.phase = "loading"
	local env = s.env :: T.Env
	if env.context == nil then
		local argv, penv = connArgv(s, { "config", "current-context" })
		emitRun(s, effects, "current", argv, { env = penv })
		return
	end
	startTarget(s, effects)
end

function startTarget(s: State, effects: { Effect })
	local env = s.env :: T.Env
	local argv, penv = connArgv(s, { "config", "view", "--minify", "-o", "json", "--context", env.context :: string })
	emitRun(s, effects, "target", argv, { env = penv })
end

local function parseTarget(s: State, r: ProcessResult, context: string): (TargetInfo?, string?)
	if r.timed_out then
		return nil, "reading the kubeconfig timed out"
	end
	if r.status ~= 0 then
		local detail = firstLine(r.stderr)
		return nil,
			string.format(
				"context %q is not usable in the kubeconfig%s",
				context,
				if detail ~= "" then ": " .. detail else ""
			)
	end
	local ok, doc = pcall(s.decode, r.stdout)
	if not ok or type(doc) ~= "table" then
		return nil, "kubectl config view returned unreadable JSON"
	end
	local contexts = doc.contexts
	if type(contexts) ~= "table" or #contexts ~= 1 or type(contexts[1]) ~= "table" then
		return nil, string.format("context %q does not exist in the kubeconfig", context)
	end
	local c = contexts[1]
	if c.name ~= context then
		return nil, string.format("context %q does not exist in the kubeconfig", context)
	end
	local cctx = if type(c.context) == "table" then c.context else {}
	local info: TargetInfo = {
		cluster = if type(cctx.cluster) == "string" then cctx.cluster else nil,
		namespace = if type(cctx.namespace) == "string" then nonEmpty(cctx.namespace) else nil,
		user = if type(cctx.user) == "string" then cctx.user else nil,
		server = nil,
	}
	local clusters = doc.clusters
	if type(clusters) == "table" and type(clusters[1]) == "table" and type(clusters[1].cluster) == "table" then
		local server = clusters[1].cluster.server
		info.server = if type(server) == "string" then server else nil
	end
	if info.server == nil then
		return nil, string.format("context %q has no cluster server", context)
	end
	return info, nil
end

local function digestArgv(s: State, plan: T.Plan): { string }?
	local argv: { string } = { "/bin/sh", "-c", M.DIGEST_SCRIPT, "kube-lens-digest" }
	local items: { string } = {}
	if s.request then
		table.insert(argv, "exact")
		for _, f in (s.request :: GuardRequest).files do
			table.insert(items, "f:" .. f.path)
		end
	else
		table.insert(argv, "list")
		for _, f in plan.filenames do
			table.insert(items, "f:" .. f)
		end
		if plan.kustomize then
			table.insert(items, "k:" .. plan.kustomize)
		end
	end
	if #items == 0 then
		return nil
	end
	table.insert(argv, plan.cwd)
	table.insert(argv, if plan.recursive then "1" else "0")
	for _, i in items do
		table.insert(argv, i)
	end
	return argv
end

local function parseDigests(r: ProcessResult): ({ Fingerprint.FileDigest }?, string?)
	if r.timed_out then
		return nil, "hashing the input files timed out"
	end
	if r.status ~= 0 then
		local detail = firstLine(r.stderr)
		return nil, "could not read the input files" .. (if detail ~= "" then ": " .. detail else "")
	end
	local out: { Fingerprint.FileDigest } = {}
	for line in string.gmatch(r.stdout, "[^\n]+") do
		local size, sha, path = string.match(line, "^(%d+) (%x+) (/.*)$")
		if size == nil or sha == nil or path == nil or #sha ~= 64 then
			return nil, "unexpected digest line: " .. line
		end
		table.insert(out, { path = path, size = tonumber(size) :: number, sha256 = string.lower(sha) })
	end
	return out, nil
end

local function emitDigest(s: State, effects: { Effect }, tag: string): boolean
	local argv = digestArgv(s, s.plan :: T.Plan)
	if argv == nil then
		return false
	end
	emitRun(s, effects, tag, argv)
	return true
end

local function emitHash(s: State, effects: { Effect }, tag: string, files: { Fingerprint.FileDigest }): boolean
	local text, e = Fingerprint.canonical(Fingerprint.fromPlan(s.plan :: T.Plan, files))
	if text == nil then
		fail(s, "Cannot fingerprint the command: " .. (e or "?"))
		return false
	end
	emitRun(s, effects, tag, { "/bin/sh", "-c", M.HASH_SCRIPT }, { stdin = text })
	return true
end

local function parseHash(r: ProcessResult): string?
	if r.status ~= 0 or r.timed_out then
		return nil
	end
	local hex = string.match(r.stdout, "^(%x+)")
	return if hex and #hex == 64 then string.lower(hex) else nil
end

local function startSteps(s: State, effects: { Effect })
	local plan = s.plan :: T.Plan
	s.phase = "previewing"
	s.steps = {}
	for _, step in plan.steps do
		table.insert(s.steps, { step = step, status = "running" })
		emitRun(s, effects, "step:" .. step.id, step.argv, { env = step.env, cwd = plan.cwd, timeout = step.timeoutMs })
	end
	if plan.family == "apply" then
		if plan.kustomize then
			local argv: { string } = { plan.program, "kustomize", plan.kustomize :: string }
			emitRun(s, effects, "manifests", argv, { env = Steps.baseEnv(plan), cwd = plan.cwd })
		elseif s.files and #(s.files :: { Fingerprint.FileDigest }) > 0 then
			local paths: { string } = {}
			for _, f in s.files :: { Fingerprint.FileDigest } do
				table.insert(paths, f.path)
			end
			s.pending.manifests = true
			table.insert(effects, { t = "read", tag = "manifests", gen = s.gen, paths = paths })
		end
	end
end

local function decodeTargets(s: State, stdout: string): any
	local ok, doc = pcall(s.decode, stdout)
	return if ok then doc else nil
end

local function replicasOf(doc: any): { [string]: number }
	local out: { [string]: number } = {}
	if type(doc) ~= "table" then
		return out
	end
	local items = if type(doc.items) == "table" then doc.items else { doc }
	for _, item in items do
		if type(item) == "table" and type(item.metadata) == "table" and type(item.spec) == "table" then
			local name = item.metadata.name
			local n = item.spec.replicas
			if type(name) == "string" and type(n) == "number" then
				out[name] = n
			end
		end
	end
	return out
end

local function lines(text: string): { string }
	local out = string.split(text, "\n")
	if out[#out] == "" then
		table.remove(out)
	end
	return out
end

local VERB: { [T.Family]: string } = {
	apply = "apply",
	delete = "delete",
	scale = "scale",
	restart = "rollout restart",
	["debug-pod"] = "debug",
	["debug-node"] = "debug",
	["cronjob-run"] = "create",
}

local function finishPreview(s: State, effects: { Effect })
	local plan = s.plan :: T.Plan
	local ok = true
	local failure: string? = nil
	for _, run in s.steps do
		local o = run.outcome
		if o == nil or not o.ok then
			ok = false
			failure = failure or (if o then o.text else run.step.label .. " did not finish")
		end
		if run.step.kind == "diff" and o and o.ok then
			local diff = Diffseg.parse(run.stdout or "")
			s.diff = if s.config.showSecretValues then diff else Diffseg.redactSecrets(diff)
		elseif run.step.kind == "targets" and o and o.ok then
			local doc = decodeTargets(s, run.stdout or "")
			s.targets = Steps.targets(doc)
			s.replicasNow = replicasOf(doc)
		elseif run.step.kind == "dry-run" and o and o.ok then
			s.dryRun = ParseMutation.parse(VERB[plan.family], lines(run.stdout or ""))
		end
	end
	local facts: Risk.Facts = {
		previewOk = ok,
		failure = failure,
		targets = s.targets,
		manifests = s.manifests,
		diff = s.diff,
	}
	s.assessment = Risk.assess(plan, facts)
	s.requirements =
		Confirm.requirements(plan, { assessment = s.assessment :: T.Assessment, fingerprint = s.fingerprint }, s.config)
	s.previewedAt = s.now
	s.phase = "ready"
	local segs = if s.diff then #(s.diff :: Diffseg.Summary).segments else 0
	if segs == 1 then
		s.expanded = { [1] = true }
		s.focus = 1
	end
	local req = s.requirements :: Confirm.Requirements
	if req.typed and #req.blockedBy == 0 and not req.overrideAvailable then
		s.focused = true
		table.insert(effects, { t = "focus", id = M.TYPED_INPUT })
	end
end

local function resetPreview(s: State)
	s.gen += 1
	s.pending = {}
	s.errors = {}
	s.diagnostics = {}
	s.steps = {}
	s.manifests = nil
	s.notes = {}
	s.diff = nil
	s.dryRun = nil
	s.targets = nil
	s.replicasNow = {}
	s.assessment = nil
	s.requirements = nil
	s.files = nil
	s.fingerprint = nil
	s.stale = false
	s.confirmError = nil
	s.override = false
	s.expanded = {}
	s.focus = nil
end

-- Confirmation ----------------------------------------------------------------

local function confirmInput(s: State, fingerprint: string?): Confirm.Input
	return {
		typed = s.typed,
		targetConfirmed = s.targetConfirmed,
		override = s.override,
		fingerprint = fingerprint,
	}
end

local function preview(s: State): Confirm.Preview
	return { assessment = s.assessment :: T.Assessment, fingerprint = s.fingerprint }
end

local function refuse(s: State, effects: { Effect }, why: string)
	s.phase = "ready"
	s.stale = true
	s.pending = {}
	s.confirmError = why
	audit(s, effects, "blocked")
end

local function responseText(s: State, decision: string): string
	local r = s.request :: GuardRequest
	local context = if s.plan then (s.plan :: T.Plan).targetContext else r.context
	local out = {
		"nonce=" .. r.nonce,
		"decision=" .. decision,
		"fingerprint=" .. (s.fingerprint or ""),
		"context=" .. context,
		string.format("approved_at=%d", s.now),
	}
	if decision == "deny" and s.denyReason then
		table.insert(out, "reason=" .. (string.gsub(s.denyReason :: string, "%c", " ")))
	end
	return table.concat(out, "\n") .. "\n"
end

local function respond(s: State, effects: { Effect }, decision: "approve" | "deny")
	local r = s.request :: GuardRequest
	local final = r.dir .. "/resp-" .. r.nonce .. ".env"
	local tmp = final .. ".tmp"
	s.decided = true
	s.phase = "responding"
	s.pending = { respond = true }
	table.insert(effects, {
		t = "write",
		tag = "respond",
		gen = s.gen,
		path = tmp,
		text = responseText(s, decision),
		argv = { "/bin/sh", "-c", M.RESPOND_SCRIPT, "kube-lens-respond", tmp, final },
	})
	audit(s, effects, if decision == "approve" then "approved" else "denied")
end

-- The pinned quick-action link the window will run, bound to what was
-- previewed: the resolved context and kubeconfig, and the debug image.
local function quickLink(s: State, token: string?): string?
	local q = s.quick :: Quick.Request
	local plan = s.plan :: T.Plan
	local opts = table.clone(q.opts)
	opts.confirm = token
	local kubeconfig = if plan.kubeconfig and not Steps.isPathList(plan.kubeconfig) then plan.kubeconfig else nil
	local target: Quick.Target = { context = plan.targetContext, kubeconfig = kubeconfig }
	return (Quick.encode(q.action, target, q.ref, opts))
end

local function proceed(s: State, effects: { Effect })
	local plan = s.plan :: T.Plan
	if s.mode == "guard" then
		respond(s, effects, "approve")
	elseif s.mode == "quick" then
		s.phase = "responding"
		s.decided = true
		emitRun(s, effects, "nonce", { "/bin/sh", "-c", M.NONCE_SCRIPT })
	else
		s.decided = true
		s.phase = "executing"
		s.exec = { startedAt = s.now, timedOut = false, stdout = "", stderr = "" }
		audit(s, effects, "approved")
		emitRun(
			s,
			effects,
			"exec",
			plan.execArgv,
			{ env = Plan.execEnv(plan), cwd = plan.cwd, timeout = s.config.execTimeoutMs }
		)
	end
end

local function finishVerify(s: State, effects: { Effect })
	local plan = s.plan :: T.Plan
	local v = s.verify
	if not Fingerprint.equal(s.fingerprint, v.fingerprint) then
		refuse(
			s,
			effects,
			"The command or its input files changed since the preview (fingerprint mismatch). Press r to preview again."
		)
		return
	end
	local before = s.target :: TargetInfo
	local now = v.target
	if now == nil or now.server ~= before.server or now.cluster ~= before.cluster then
		refuse(
			s,
			effects,
			string.format(
				"Context %s now points to %s (previewed: %s). Refusing; press r to preview again.",
				plan.targetContext,
				if now then (now.server or "?") .. " (cluster " .. (now.cluster or "?") .. ")" else "nothing",
				(before.server or "?") .. " (cluster " .. (before.cluster or "?") .. ")"
			)
		)
		return
	end
	if plan.contextSource == "inferred" and v.current ~= plan.targetContext then
		refuse(
			s,
			effects,
			string.format(
				"The current-context changed from %s to %s since the preview. Refusing; press r to preview again.",
				plan.targetContext,
				v.current or "(none)"
			)
		)
		return
	end
	if s.request and s.now > deadline(s.request :: GuardRequest) then
		s.phase = "expired"
		return
	end
	local ok, why = Confirm.canConfirm(plan, preview(s), confirmInput(s, v.fingerprint), s.config)
	if not ok then
		s.phase = "ready"
		s.confirmError = why
		return
	end
	proceed(s, effects)
end

local function verifyNext(s: State, effects: { Effect }, after: string)
	local plan = s.plan :: T.Plan
	if after == "start" then
		if emitDigest(s, effects, "v-digest") then
			return
		end
		after = "v-digest"
	end
	if after == "v-digest" then
		if not emitHash(s, effects, "v-fp", s.verify.files or {}) then
			return
		end
		return
	end
	if after == "v-fp" then
		local argv, penv = connArgv(s, { "config", "view", "--minify", "-o", "json", "--context", plan.targetContext })
		emitRun(s, effects, "v-target", argv, { env = penv })
		return
	end
	if after == "v-target" then
		if plan.contextSource == "inferred" then
			local argv, penv = connArgv(s, { "config", "current-context" })
			emitRun(s, effects, "v-current", argv, { env = penv })
			return
		end
	end
	finishVerify(s, effects)
end

local function confirm(s: State, effects: { Effect })
	if s.phase ~= "ready" or s.plan == nil or s.assessment == nil then
		return
	end
	if s.stale then
		s.confirmError = "The inputs or the target changed since the preview. Press r to preview again."
		return
	end
	local ok, why = Confirm.canConfirm(s.plan :: T.Plan, preview(s), confirmInput(s, s.fingerprint), s.config)
	if not ok then
		s.confirmError = why
		return
	end
	s.confirmError = nil
	s.gen += 1
	s.pending = {}
	s.phase = "verifying"
	s.verify = {}
	verifyNext(s, effects, "start")
end

local function cancel(s: State, effects: { Effect })
	if s.phase == "executing" then
		s.notice = "The command is running and cannot be cancelled; wait for its result."
		return
	end
	if s.phase == "responding" or s.phase == "closed" then
		return
	end
	if s.mode == "guard" and s.canRespond and not s.decided and s.phase ~= "expired" then
		respond(s, effects, "deny")
		return
	end
	if not s.decided and s.plan then
		audit(s, effects, "cancelled")
	end
	exit(s, effects)
end

local function rerun(s: State, effects: { Effect })
	if s.decided or s.argv == nil or not (s.phase == "ready" or s.phase == "error") then
		return
	end
	if s.request and s.now > deadline(s.request :: GuardRequest) then
		s.phase = "expired"
		return
	end
	resetPreview(s)
	s.plan = nil
	s.target = nil
	start(s, effects)
end

local function requery(s: State, effects: { Effect })
	if s.phase ~= "done" or s.plan == nil then
		return
	end
	local plan = s.plan :: T.Plan
	s.gen += 1
	s.pending = {}
	local rq: Requery = { at = nil, steps = {} }
	s.requery = rq
	for _, step in plan.steps do
		if step.kind == "targets" or step.kind == "diff" then
			table.insert(rq.steps, { step = step, status = "running" })
			emitRun(
				s,
				effects,
				"rq:" .. step.id,
				step.argv,
				{ env = step.env, cwd = plan.cwd, timeout = step.timeoutMs }
			)
		end
	end
end

-- Init ------------------------------------------------------------------------

local function blank(env: Init, mode: Mode): State
	return {
		mode = mode,
		phase = "loading",
		now = env.now,
		config = env.config,
		decode = env.decode,
		kubectl = env.kubectl,
		home = env.home,
		spool = env.spool,
		hostKubeconfig = nonEmpty(env.kubeconfig),
		link = nil,
		quick = nil,
		launch = nil,
		request = nil,
		canRespond = false,
		denyReason = nil,
		argv = nil,
		env = nil,
		conn = { program = env.kubectl, kubeconfig = nil },
		errors = {},
		diagnostics = {},
		plan = nil,
		target = nil,
		files = nil,
		fingerprint = nil,
		steps = {},
		manifests = nil,
		notes = {},
		diff = nil,
		dryRun = nil,
		targets = nil,
		replicasNow = {},
		assessment = nil,
		requirements = nil,
		previewedAt = nil,
		gen = 1,
		pending = {},
		verify = {},
		typed = "",
		targetConfirmed = false,
		override = false,
		stale = false,
		confirmError = nil,
		notice = nil,
		showCommand = false,
		help = false,
		expanded = {},
		focus = nil,
		focused = false,
		exec = nil,
		resultView = Viewstate.default(),
		requery = nil,
		decided = false,
	}
end

local function initNative(s: State, url: string, effects: { Effect })
	local req, e = Link.decode(url)
	if req == nil then
		fail(s, "Invalid mutation link: " .. (e or "?"))
		return
	end
	s.link = req
	s.env = {
		context = req.context,
		contextSource = if req.context then req.source or "chosen" else nil,
		kubeconfig = req.kubeconfig or s.hostKubeconfig,
		defaultKubeconfig = defaultKubeconfig(s),
		program = s.kubectl,
		cwd = Link.cwd(req, s.home),
		timeoutMs = s.config.previewTimeoutMs,
	}
	local argv = Link.argv(req, s.kubectl)
	if argv == nil then
		s.phase = "input"
		s.focused = true
		table.insert(effects, { t = "focus", id = M.TYPED_INPUT })
		return
	end
	s.argv = argv
	start(s, effects)
end

local function initQuick(s: State, url: string, effects: { Effect })
	local req, e = Quick.decode(url)
	if req == nil then
		fail(s, "Invalid quick action link: " .. (e or "?"))
		return
	end
	if not Quick.mutates(req.action) then
		fail(s, "Quick action " .. req.action .. " does not need approval")
		return
	end
	if req.opts.confirm then
		fail(s, "This link already carries a confirmation token")
		return
	end
	local opts = table.clone(req.opts)
	if req.action == "debug-pod" or req.action == "debug-node" then
		opts.image = opts.image or s.config.quick.debugImage or Quick.DEFAULT_IMAGE
	end
	if req.action == "cronjob-run" and opts.suffix == nil then
		-- The job name the preview dry-runs is the one the split creates:
		-- the suffix travels in the confirmed link.
		opts.suffix = string.format("%x", s.now)
	end
	req.opts = opts
	local launch, ce = Quick.command(
		req.action,
		{ context = req.target.context, kubeconfig = req.target.kubeconfig, program = s.kubectl },
		req.ref,
		opts,
		s.config.quick
	)
	if launch == nil then
		fail(s, "Invalid quick action: " .. (ce or "?"))
		return
	end
	s.quick = req
	s.launch = launch
	s.argv = launch.argv
	s.env = {
		context = nil,
		contextSource = nil,
		kubeconfig = s.hostKubeconfig,
		defaultKubeconfig = defaultKubeconfig(s),
		program = s.kubectl,
		cwd = s.home or "/",
		timeoutMs = s.config.previewTimeoutMs,
	}
	start(s, effects)
end

local function initGuard(s: State, path: string, env: Init, effects: { Effect })
	local file = env.request
	if file == nil or file.text == nil then
		fail(s, "Cannot read the approval request: " .. (if file and file.error then file.error else path))
		return
	end
	local req, e = M.parseRequest(path, file.text :: string, s.decode)
	if req == nil then
		fail(s, "Refusing the approval request: " .. (e or "?"))
		return
	end
	if s.now > deadline(req) then
		fail(s, "The approval request expired (the shell stopped waiting); nothing was approved.")
		return
	end
	if req.createdAt > s.now + M.CLOCK_SKEW_S then
		fail(s, "The approval request is dated in the future; refusing it.")
		return
	end
	if env.panes and not table.find(env.panes, req.pane) then
		fail(s, "The pane that asked for approval (" .. req.pane .. ") is gone; nothing to approve.")
		return
	end
	s.request = req
	s.argv = req.argv
	s.env = {
		context = req.context,
		contextSource = req.contextSource,
		kubeconfig = req.kubeconfig,
		defaultKubeconfig = if req.kubeconfig then nil else defaultKubeconfig(s),
		program = req.program,
		cwd = req.cwd,
		timeoutMs = s.config.previewTimeoutMs,
	}
	s.phase = "loading"
	emitRun(s, effects, "spool", { "/bin/sh", "-c", M.SPOOL_SCRIPT, "kube-lens-spool", s.spool })
end

function M.init(env: Init): (State, { Effect })
	local effects: { Effect } = {}
	local arg = env.args[1] or ""
	if string.sub(arg, 1, #Link.SCHEME) == Link.SCHEME or string.sub(arg, 1, #Quick.SCHEME) == Quick.SCHEME then
		local native = string.sub(arg, 1, #Link.SCHEME) == Link.SCHEME
		local s = blank(env, if native then "native" else "quick")
		if not env.config.mutations.enabled then
			fail(s, M.DISABLED)
		elseif native then
			initNative(s, arg, effects)
		else
			initQuick(s, arg, effects)
		end
		return s, effects
	end
	local s = blank(env, "guard")
	if arg == "" then
		fail(s, "The approve block was opened without a request.")
		return s, effects
	end
	initGuard(s, arg, env, effects)
	return s, effects
end

-- Results ---------------------------------------------------------------------

local function onStep(s: State, id: string, r: ProcessResult)
	for _, run in s.steps do
		if run.step.id == id then
			run.outcome = outcomeOf(run.step, r)
			run.status = if (run.outcome :: Steps.Outcome).ok then "ok" else "failed"
			run.stdout = r.stdout
			run.stderr = r.stderr
		end
	end
end

local function onResult(s: State, tag: string, r: ProcessResult, effects: { Effect })
	local plan = s.plan
	if tag == "spool" then
		local canonical = string.match(r.stdout, "^(/[^\n]*)")
		local req = s.request :: GuardRequest
		if r.status ~= 0 or canonical == nil then
			fail(s, "Cannot resolve the kube-lens spool directory " .. s.spool)
		elseif canonical ~= req.dir then
			fail(s, "Refusing a request outside the kube-lens spool (" .. canonical .. "): " .. req.path)
		elseif not s.config.mutations.enabled then
			s.canRespond = true
			s.denyReason = M.DISABLED
			table.insert(s.errors, M.DISABLED)
			respond(s, effects, "deny")
		else
			s.canRespond = true
			start(s, effects)
		end
	elseif tag == "current" then
		local ctx = if r.status == 0 then nonEmpty(firstLine(r.stdout)) else nil
		if ctx == nil then
			fail(s, "No current-context in the kubeconfig: " .. firstLine(r.stderr))
			return
		end
		local env = s.env :: T.Env
		env.context = ctx
		env.contextSource = "inferred"
		startTarget(s, effects)
	elseif tag == "target" then
		local env = s.env :: T.Env
		local info, e = parseTarget(s, r, env.context :: string)
		if info == nil then
			fail(s, e or "?")
			return
		end
		s.target = info
		env.namespace = info.namespace
		local p, diags = Plan.fromArgv(s.argv :: { string }, env)
		if p == nil then
			s.diagnostics = diags
			fail(s, "The command cannot be previewed: " .. (if diags[1] then diags[1].text else "?"))
			return
		end
		s.plan = p
		if not emitDigest(s, effects, "digest") then
			s.files = {}
			emitHash(s, effects, "fp", {})
		end
	elseif tag == "digest" then
		local files, e = parseDigests(r)
		if files == nil then
			fail(s, e or "?")
			return
		end
		s.files = files
		emitHash(s, effects, "fp", files)
	elseif tag == "fp" then
		local fp = parseHash(r)
		if fp == nil then
			fail(s, "Cannot compute the fingerprint: " .. firstLine(r.stderr))
			return
		end
		s.fingerprint = fp
		if s.request and not Fingerprint.equal(fp, (s.request :: GuardRequest).fingerprint) then
			fail(
				s,
				"The request does not match its inputs (fingerprint mismatch): the files, context or "
					.. "command changed after the shell hashed them, or the request was altered. Run the command again."
			)
			return
		end
		startSteps(s, effects)
	elseif string.sub(tag, 1, 5) == "step:" then
		onStep(s, string.sub(tag, 6), r)
	elseif tag == "manifests" and plan then
		if r.status == 0 then
			s.manifests = { { path = plan.kustomize or "kustomize", text = r.stdout } }
		else
			table.insert(s.notes, "Manifest scan skipped: kubectl kustomize failed: " .. firstLine(r.stderr))
		end
	elseif tag == "v-digest" then
		local files, e = parseDigests(r)
		if files == nil then
			refuse(s, effects, "Cannot re-read the inputs: " .. (e or "?"))
			return
		end
		s.verify.files = files
		verifyNext(s, effects, "v-digest")
	elseif tag == "v-fp" then
		s.verify.fingerprint = parseHash(r)
		verifyNext(s, effects, "v-fp")
	elseif tag == "v-target" and plan then
		s.verify.target = parseTarget(s, r, plan.targetContext)
		verifyNext(s, effects, "v-target")
	elseif tag == "v-current" then
		s.verify.current = if r.status == 0 then nonEmpty(firstLine(r.stdout)) else nil
		finishVerify(s, effects)
	elseif tag == "exec" then
		local ex = s.exec :: Exec
		ex.finishedAt = s.now
		ex.status = if r.timed_out then nil else r.status
		ex.timedOut = r.timed_out
		ex.stdout = r.stdout
		ex.stderr = r.stderr
		s.phase = "done"
		audit(s, effects, if r.status == 0 and not r.timed_out then "executed" else "failed", ex.status)
	elseif tag == "respond" then
		if r.status == 0 then
			exit(s, effects)
		else
			s.phase = "error"
			s.canRespond = false
			table.insert(
				s.errors,
				"Could not write the approval response (the shell will refuse): " .. firstLine(r.stderr)
			)
		end
	elseif tag == "nonce" then
		local token = string.match(r.stdout, "^(%x+)$")
		local base = quickLink(s, nil)
		local url = if token and #token == 32 then quickLink(s, token) else nil
		if token == nil or #token ~= 32 or base == nil or url == nil then
			s.phase = "error"
			table.insert(s.errors, "Could not create the confirmation token; nothing was started.")
			return
		end
		table.insert(effects, { t = "grant", token = token, url = base, expires = s.now + Link.GRANT_TTL })
		audit(s, effects, "approved")
		table.insert(effects, { t = "open", url = url })
		exit(s, effects)
	elseif string.sub(tag, 1, 3) == "rq:" and s.requery then
		local rq = s.requery :: Requery
		for _, run in rq.steps do
			if run.step.id == string.sub(tag, 4) then
				run.outcome = outcomeOf(run.step, r)
				run.status = if (run.outcome :: Steps.Outcome).ok then "ok" else "failed"
				run.stdout = r.stdout
				run.stderr = r.stderr
			end
		end
	end
end

local function onRead(s: State, files: { ReadFile })
	local out: { T.Manifest } = {}
	for _, f in files do
		if f.text then
			table.insert(out, { path = f.path, text = f.text :: string })
		else
			table.insert(s.notes, "Manifest scan skipped for " .. f.path .. ": " .. (f.error or "unreadable"))
		end
	end
	s.manifests = out
end

local function settle(s: State, effects: { Effect })
	if next(s.pending) ~= nil then
		return
	end
	if s.phase == "previewing" then
		finishPreview(s, effects)
	elseif s.requery and s.phase == "done" and s.requery.at == nil then
		(s.requery :: Requery).at = s.now
	end
end

-- Keys and actions ------------------------------------------------------------

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

-- The typed-confirmation field takes the keyboard.
function M.typing(s: State): boolean
	if s.phase == "input" then
		return true
	end
	local req = s.requirements
	return s.phase == "ready"
		and req ~= nil
		and req.typed ~= nil
		and #req.blockedBy == 0
		and (not req.overrideAvailable or s.override)
end

local function cycle(s: State, dir: number): boolean
	local n = if s.diff then #(s.diff :: Diffseg.Summary).segments else 0
	if n == 0 then
		return false
	end
	local i = s.focus or (if dir > 0 then 0 else 1)
	i = ((i - 1 + dir) % n) + 1
	s.focus = i
	s.expanded = { [i] = true }
	return true
end

local function submitInput(s: State, effects: { Effect })
	local link = s.link :: Link.Request
	if link.op == "apply" then
		local req, e = Link.withPath(link, s.typed, s.home)
		if req == nil then
			s.confirmError = e
			return
		end
		s.link = req
		link = req
	else
		local n = tonumber(s.typed)
		if not string.find(s.typed, "^%d+$") or n == nil or n > Link.MAX_REPLICAS then
			s.confirmError = "Enter a whole number of replicas"
			return
		end
		link.replicas = n
	end
	s.typed = ""
	s.confirmError = nil
	s.argv = Link.argv(link, s.kubectl)
	start(s, effects)
end

local function applyAction(s: State, act: string, value: string?, effects: { Effect })
	if act == "confirm" then
		if s.phase == "input" then
			submitInput(s, effects)
		else
			confirm(s, effects)
		end
	elseif act == "cancel" or act == "close" then
		cancel(s, effects)
	elseif act == "target" then
		s.targetConfirmed = true
		s.confirmError = nil
	elseif act == "override" then
		if s.requirements and (s.requirements :: Confirm.Requirements).overrideAvailable then
			s.override = true
			s.focused = true
			table.insert(effects, { t = "focus", id = M.TYPED_INPUT })
		end
	elseif act == "command" then
		s.showCommand = not s.showCommand
	elseif act == "copy" then
		local text = M.commandText(s)
		table.insert(effects, { t = "copy", text = text })
		table.insert(effects, { t = "toast", level = "success", text = "Copied the command" })
	elseif act == "help" then
		s.help = not s.help
	elseif act == "rerun" then
		rerun(s, effects)
	elseif act == "requery" then
		requery(s, effects)
	elseif act == "diff" then
		local i = tonumber(value or "")
		if i then
			s.expanded[i] = not s.expanded[i]
			s.focus = i
		end
	elseif act == "v" then
		s.resultView = Viewstate.decode(value or "")
	elseif act == "typed-focus" then
		s.focused = true
	end
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	local name = key.name
	local ch = printable(key)
	if s.help then
		if name == "escape" or ch == "?" then
			s.help = false
			return true
		end
		return false
	end
	if name == "escape" then
		cancel(s, effects)
		return true
	end
	if ch == "?" then
		s.help = true
		return true
	end
	if name == "tab" then
		return cycle(s, if key.shift then -1 else 1)
	end
	if M.typing(s) then
		if name == "enter" or name == "return" then
			-- Enter confirms a typed tier only once the exact token is in the
			-- field: typing it is the deliberate act.
			local req = s.requirements
			if s.phase == "input" then
				submitInput(s, effects)
			elseif req and req.typed == s.typed then
				confirm(s, effects)
			else
				s.confirmError = string.format(
					"Type %q exactly, then press Enter or click Confirm",
					if req then req.typed or "" else ""
				)
			end
			return true
		end
		if name == "backspace" then
			s.typed = string.sub(s.typed, 1, -2)
		elseif name == "paste" and key.text then
			s.typed ..= (string.gsub(key.text :: string, "%c", ""))
		elseif ch then
			s.typed ..= ch
		else
			return false
		end
		s.confirmError = nil
		return true
	end
	if name == "enter" or name == "return" then
		if s.phase == "ready" then
			confirm(s, effects)
			return true
		end
		return false
	end
	if ch == "r" then
		if s.phase == "done" then
			requery(s, effects)
		else
			rerun(s, effects)
		end
		return true
	elseif ch == "y" then
		applyAction(s, "copy", nil, effects)
		return true
	elseif ch == "c" then
		s.showCommand = not s.showCommand
		return true
	elseif ch == "t" then
		if s.phase == "ready" then
			s.targetConfirmed = true
			return true
		end
	end
	return false
end

-- The third value is false when the message changed nothing (an unused key).
function M.update(s: State, msg: Msg): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	if msg.now then
		s.now = msg.now :: number
	end
	local t = msg.t
	if t == "result" or t == "read" then
		local tag = msg.tag or ""
		if msg.gen ~= s.gen or not s.pending[tag] then
			return s, effects, false
		end
		s.pending[tag] = nil
		if t == "read" then
			onRead(s, msg.files or {})
		else
			onResult(s, tag, msg.result :: ProcessResult, effects)
		end
		settle(s, effects)
	elseif t == "key" and msg.key then
		return s, effects, onKey(s, msg.key :: Key, effects)
	elseif t == "action" and msg.act then
		applyAction(s, msg.act :: string, msg.value, effects)
	elseif t == "toggle" and msg.id then
		local i = tonumber(string.match(msg.id :: string, "%.d(%d+)$") or "")
		if i then
			s.expanded[i] = not s.expanded[i]
		end
	elseif t == "tick" then
		local r = s.request
		if r and not s.decided and s.phase ~= "closed" then
			if msg.cancelled then
				if s.plan then
					audit(s, effects, "cancelled")
				end
				table.insert(effects, { t = "remove", path = M.cancelPath(r) })
				exit(s, effects)
			elseif msg.paneAlive == false then
				if s.plan then
					audit(s, effects, "cancelled")
				end
				exit(s, effects)
			elseif s.now > deadline(r) and s.phase ~= "expired" then
				s.phase = "expired"
				s.gen += 1
				s.pending = {}
			end
		end
	end
	return s, effects, true
end

-- Queries for the host and the view ------------------------------------------

function M.cancelPath(r: GuardRequest): string
	return r.dir .. "/cancel-" .. r.nonce
end

-- What the host's liveness timer must report in `tick` messages.
function M.watch(s: State): { pane: string?, cancelPath: string? }
	local r = s.request
	if r == nil or s.decided or s.phase == "closed" then
		return {}
	end
	return { pane = r.pane, cancelPath = M.cancelPath(r) }
end

-- The command as it will run, for display and copying.
function M.commandText(s: State): string
	if s.mode == "guard" and s.request then
		return Command.format((s.request :: GuardRequest).argv)
	elseif s.mode == "quick" and s.launch then
		return Command.format((s.launch :: Quick.Launch).argv)
	end
	local plan = s.plan
	if plan then
		local env = Plan.execEnv(plan)
		local prefix = if env.KUBECONFIG then "KUBECONFIG=" .. Command.quote(env.KUBECONFIG) .. " " else ""
		return prefix .. Command.format(plan.execArgv)
	end
	return Command.format(s.argv or {})
end

function M.deadline(s: State): number?
	return if s.request then deadline(s.request :: GuardRequest) else nil
end

function M.quickLabel(s: State): string
	local q = s.quick
	if q == nil then
		return "quick action"
	end
	local spec = Quick.spec(q.action)
	return (if spec then spec.label else q.action) .. " " .. string.lower(q.ref.kind) .. "/" .. q.ref.name
end

return M
