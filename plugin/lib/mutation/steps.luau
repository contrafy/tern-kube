--!strict
-- Preview steps per family as argv arrays. Every step pins --context (and
-- --kubeconfig, or KUBECONFIG for a path list) so a `config use-context` in
-- another shell cannot redirect the preview. Original flags are re-emitted as
-- `--name=value` from the parsed invocation: values that start with `-` stay
-- values, and only flags the step's verb accepts are carried over.
local Argv = require("../kubectl/argv")
local Drain = require("./drain")
local Edit = require("./edit")
local Objdiff = require("./objdiff")
local Query = require("../helm/query")
local Resource = require("../model/resource")
local Rollout = require("./rollout")
local Selection = require("./selection")
local Taint = require("./taint")
local T = require("./types")
local Types = require("../model/types")
local flagTables = require("../kubectl/flags")

type Plan = T.Plan
type Step = T.Step
type Invocation = Types.Invocation

local M = {}

M.DEFAULT_TIMEOUT_MS = 30000
-- Stage-2 previews (undo revisions, edit patches) cover at most this many objects.
M.MAX_OBJECTS = 20
M.MAX_EDIT_PATCH_BYTES = 262144

-- Families whose targets are Nodes: the namespace is never pinned.
M.NODE_FAMILIES = { cordon = true, uncordon = true, drain = true } :: { [string]: boolean }

-- `kubectl set <sub>`: targets read like label, after from the server dry run.
M.SET_FAMILIES = {
	["set-image"] = true,
	["set-env"] = true,
	["set-resources"] = true,
	["set-selector"] = true,
	["set-serviceaccount"] = true,
	["set-subject"] = true,
} :: { [string]: boolean }

-- Families that create objects: no before state, the dry run is the after.
M.CREATE_FAMILIES = { create = true, run = true } :: { [string]: boolean }

-- cordon/uncordon/drain take node names; `node/NAME` is accepted.
function M.nodeName(positional: string): string
	return string.match(positional, "^nodes?/(.+)$") or positional
end

local function longName(entry: string): string
	return string.match(entry, "^([^/]+)/.$") or entry
end

local function nameSet(spec: flagTables.FlagSpec): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, e in spec.bool do
		set[longName(e)] = true
	end
	for _, e in spec.value do
		set[longName(e)] = true
	end
	return set
end

local GLOBAL = nameSet(flagTables.global)
-- Connection flags the pins below own.
local PINNED = { context = true, kubeconfig = true, namespace = true }
-- Printer and dry-run flags are replaced: preview output must stay the
-- default human printer so parse/mutation can read it.
local PRINTER = { ["dry-run"] = true, output = true, template = true }

local DIFF_FLAGS = {
	filename = true,
	kustomize = true,
	recursive = true,
	selector = true,
	prune = true,
	["prune-allowlist"] = true,
	["server-side"] = true,
	["force-conflicts"] = true,
	["field-manager"] = true,
}

local GET_FLAGS = {
	filename = true,
	kustomize = true,
	recursive = true,
	selector = true,
	["field-selector"] = true,
	["all-namespaces"] = true,
	["ignore-not-found"] = true,
}

local HISTORY_FLAGS = { filename = true, kustomize = true, recursive = true, selector = true }
-- drain's --timeout is replaced: the preview bounds its own runs.
local DRAIN_DROP = { ["dry-run"] = true, timeout = true }

local function sortedNames(flags: { [string]: { string } }): { string }
	local names: { string } = {}
	for name in flags do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- `--kubeconfig` takes one file; a colon-separated KUBECONFIG list must
-- travel through the environment instead.
function M.isPathList(kubeconfig: string?): boolean
	return kubeconfig ~= nil and string.find(kubeconfig, ":", 1, true) ~= nil
end

-- Connection pins placed right after the program (kubectl accepts global
-- flags before the verb).
function M.pins(plan: Plan, pinNamespace: string?): { string }
	local out: { string } = {}
	if plan.kubeconfig and plan.kubeconfig ~= "" and not M.isPathList(plan.kubeconfig) then
		table.insert(out, "--kubeconfig")
		table.insert(out, plan.kubeconfig)
	end
	table.insert(out, "--context")
	table.insert(out, plan.targetContext)
	if pinNamespace then
		table.insert(out, "--namespace")
		table.insert(out, pinNamespace)
	end
	return out
end

function M.baseEnv(plan: Plan): { [string]: string }
	local h = plan.helm
	if h then
		return Query.env(h.driver, plan.kubeconfig)
	end
	local env: { [string]: string } = {}
	if M.isPathList(plan.kubeconfig) then
		env.KUBECONFIG = plan.kubeconfig :: string
	end
	return env
end

-- Namespace for preview/exec pins: the command's -n, else the context's
-- default when pinning cannot conflict with namespaces declared in -f/-k
-- inputs (kubectl rejects an explicit -n that differs from the manifest's).
function M.pinnedNamespace(plan: Plan): string?
	if M.NODE_FAMILIES[plan.family] or plan.family == "edit" or plan.family == "taint" then
		return nil
	end
	if plan.explicitNamespace then
		return plan.explicitNamespace
	end
	if plan.allNamespaces or #plan.filenames > 0 or plan.kustomize ~= nil then
		return nil
	end
	return plan.targetNamespace
end

type Filter = { only: { [string]: boolean }?, drop: { [string]: boolean }?, positionals: { string }? }

local function rebuild(plan: Plan, verb: { string }, filter: Filter, extra: { string }): { string }
	local inv: Invocation = plan.invocation
	local argv: { string } = { plan.program }
	for _, a in M.pins(plan, M.pinnedNamespace(plan)) do
		table.insert(argv, a)
	end
	for _, v in verb do
		table.insert(argv, v)
	end
	for _, p in filter.positionals or inv.positionals do
		table.insert(argv, p)
	end
	for _, name in sortedNames(inv.flags) do
		if PINNED[name] then
			continue
		end
		local keep = GLOBAL[name] or (if filter.only then filter.only[name] == true else true)
		if filter.drop and filter.drop[name] then
			keep = false
		end
		if not keep then
			continue
		end
		for _, value in inv.flags[name] do
			table.insert(argv, "--" .. name .. "=" .. value)
		end
	end
	for _, e in extra do
		table.insert(argv, e)
	end
	return argv
end

local function step(plan: Plan, id: string, kind: T.StepKind, label: string, argv: { string }): Step
	local env = M.baseEnv(plan)
	if kind == "diff" then
		-- Empty means kubectl's built-in `diff -u -N`, the format diffseg reads.
		env.KUBECTL_EXTERNAL_DIFF = ""
	end
	return { id = id, kind = kind, label = label, argv = argv, env = env, timeoutMs = 0 }
end

local function setTargets(positionals: { string }, sub: string?): { string }
	if sub == "serviceaccount" then
		return table.move(positionals, 1, #positionals - 1, 1, {})
	end
	local out: { string } = {}
	for _, p in positionals do
		if not Argv.isLabelEdit(p) then
			table.insert(out, p)
		end
	end
	return out
end

local function resourcePositionals(plan: Plan): { string }?
	local f = plan.family
	local inv = plan.invocation
	if f == "label" or f == "annotate" then
		return setTargets(inv.positionals, nil)
	elseif M.SET_FAMILIES[f] then
		return setTargets(inv.positionals, plan.subverb)
	elseif f == "taint" then
		local out: { string } = {}
		for _, p in inv.positionals do
			if not Argv.isTaintSpec(p) then
				table.insert(out, p)
			end
		end
		return out
	end
	return nil
end

-- Flags `get` shares with the command: expose's --selector and -l set the
-- Service's selector and labels, they select nothing.
local function getFlags(plan: Plan): { [string]: boolean }
	if plan.family == "expose" then
		return { filename = true, kustomize = true, recursive = true }
	end
	return GET_FLAGS
end

local function targets(plan: Plan, label: string): Step
	return step(
		plan,
		"targets",
		"targets",
		label,
		rebuild(plan, { "get" }, { only = getFlags(plan), positionals = resourcePositionals(plan) }, { "-o", "json" })
	)
end

local function dryRun(plan: Plan, verb: { string }, label: string): Step
	return step(plan, "dry-run", "dry-run", label, rebuild(plan, verb, { drop = PRINTER }, { "--dry-run=server" }))
end

-- `tail`: words after the dry-run flags (`--` and the container command).
local function after(plan: Plan, verb: { string }, label: string, drop: { [string]: boolean }?, tail: { string }?): Step
	local extra = { "--dry-run=server", "-o", "json" }
	for _, w in (tail or {}) :: { string } do
		table.insert(extra, w)
	end
	return step(plan, "after", "after", label, rebuild(plan, verb, { drop = drop or PRINTER }, extra))
end

local function nodeTargets(plan: Plan): Step
	local names: { string } = {}
	for _, p in plan.invocation.positionals do
		table.insert(names, M.nodeName(p))
	end
	return step(
		plan,
		"targets",
		"targets",
		"Read the nodes",
		rebuild(plan, { "get", "nodes" }, { only = { selector = true }, positionals = names }, { "-o", "json" })
	)
end

local function prefixed(plan: Plan, pinNamespace: string?, words: { string }): { string }
	local argv: { string } = { plan.program }
	for _, a in M.pins(plan, pinNamespace) do
		table.insert(argv, a)
	end
	for _, w in words do
		table.insert(argv, w)
	end
	return argv
end

local function convert(plan: Plan, id: string, file: string, label: string): Step
	-- Offline (`--local`): no pins, kubectl's own YAML decoder.
	local argv = { plan.program, "patch", "--local", "--type=merge", "-p", "{}", "-f", file, "-o", "json" }
	local s = step(plan, id, "convert", label, argv)
	s.env = {}
	return s
end

local function historyStep(plan: Plan): Step
	return step(
		plan,
		"history",
		"history",
		"Read the rollout history",
		rebuild(plan, { "rollout", "history" }, { only = HISTORY_FLAGS }, {})
	)
end

local function getOne(plan: Plan, kind: string, name: string, label: string): Step
	local argv: { string } = { plan.program }
	for _, a in M.pins(plan, if kind == "node" then nil else M.pinnedNamespace(plan)) do
		table.insert(argv, a)
	end
	for _, a in { "get", kind, name, "-o", "json" } do
		table.insert(argv, a)
	end
	return step(plan, "targets", "targets", label, argv)
end

-- Read-only context for risk (types.luau `nodes`, `pdbs`). Soft: a denied
-- list is an unknown risk states, not a failed preview.
local function factStep(plan: Plan, kind: T.StepKind, label: string, argv: { string }): Step
	local s = step(plan, kind, kind, label, argv)
	s.soft = true
	return s
end

local function nodesStep(plan: Plan): Step
	return factStep(
		plan,
		"nodes",
		"Read every node (is another one schedulable?)",
		prefixed(plan, nil, {
			"get",
			"nodes",
			"-o",
			"json",
		})
	)
end

-- The pinned namespace's budgets; -f/-k inputs may name any namespace.
local function pdbsStep(plan: Plan): Step
	local ns = M.pinnedNamespace(plan)
	local words = { "get", "poddisruptionbudgets" }
	if ns == nil then
		table.insert(words, "--all-namespaces")
	end
	table.insert(words, "-o")
	table.insert(words, "json")
	return factStep(plan, "pdbs", "Read the PodDisruptionBudgets", prefixed(plan, ns, words))
end

local function helmTarget(plan: Plan): Query.Target
	return { context = plan.targetContext, kubeconfig = plan.kubeconfig }
end

local function helmKey(plan: Plan): Query.Key
	local h = plan.helm :: T.HelmRollback
	return { name = h.release, namespace = h.namespace }
end

local function helmLatest(plan: Plan, id: string, max: number): Step
	return step(
		plan,
		id,
		"helm-history",
		"Read the latest revision",
		Query.history(plan.program, helmTarget(plan), helmKey(plan), max)
	)
end

-- `helm rollback --dry-run` renders nothing and validates nothing on the
-- server: it only proves the target revision exists. What changes comes
-- from the two stored manifests and, in stage 2, `kubectl diff`.
local function helmSteps(plan: Plan): { Step }
	local h = plan.helm :: T.HelmRollback
	local target, key = helmTarget(plan), helmKey(plan)
	local dry = table.clone(plan.execArgv)
	table.insert(dry, "--dry-run")
	local out = {
		step(plan, "helm-current", "helm-status", "Read the deployed release", Query.status(plan.program, target, key)),
		step(
			plan,
			"helm-target",
			"helm-status",
			string.format("Read revision %d", h.revision),
			Query.status(plan.program, target, key, h.revision)
		),
		helmLatest(plan, "helm-latest", 1),
		step(
			plan,
			"helm-hooks",
			"helm-extras",
			string.format("Read revision %d's chart and hooks", h.revision),
			Query.extras(plan.program, target, key, h.revision)
		),
		step(plan, "dry-run", "dry-run", "helm rollback --dry-run (the revision exists)", dry),
	}
	out[4].soft = true
	return out
end

-- kubectl refuses a dry run with the attach flags (and --rm without them):
-- `run` is previewed without attaching.
local RUN_DROP = {
	["dry-run"] = true,
	output = true,
	template = true,
	stdin = true,
	tty = true,
	attach = true,
	rm = true,
	["leave-stdin-open"] = true,
	quiet = true,
}
-- `replace` refuses these without --force.
local PROBE_DROP = {
	["dry-run"] = true,
	output = true,
	template = true,
	force = true,
	wait = true,
	timeout = true,
	["grace-period"] = true,
	cascade = true,
}
local DELETE_FLAGS = { filename = true, kustomize = true, recursive = true, cascade = true, ["grace-period"] = true }

-- `--` and the container command (run, create deployment|job|cronjob).
local function dashTail(plan: Plan): { string }?
	local rest = plan.invocation.afterDash
	if #rest == 0 then
		return nil
	end
	local out = { "--" }
	table.move(rest, 1, #rest, 2, out)
	return out
end

local function commandWords(plan: Plan, verb: string): { string }
	local out = { verb }
	for w in string.gmatch(plan.subverb or "", "%S+") do
		table.insert(out, w)
	end
	return out
end

-- replace --force: the file's objects as JSON, offline (`--local`, kubectl's
-- own decoder): kubectl cannot dry-run a forced replace.
local function fileObjects(plan: Plan): Step
	local argv: { string } = { plan.program, "patch", "--local", "--type=merge", "-p", "{}" }
	for _, f in plan.filenames do
		table.insert(argv, "-f")
		table.insert(argv, f)
	end
	if plan.kustomize then
		table.insert(argv, "-k")
		table.insert(argv, plan.kustomize :: string)
	end
	if plan.recursive then
		table.insert(argv, "-R")
	end
	table.insert(argv, "-o")
	table.insert(argv, "json")
	local s = step(plan, "convert", "convert", "Read the file's objects", argv)
	s.env = {}
	return s
end

local function addsEffect(plan: Plan, effect: string): boolean
	for _, t in plan.taints do
		if not t.remove and t.effect == effect then
			return true
		end
	end
	return false
end

-- set/replace/taint/create/run/expose (the guard's v1.2 verbs).
local function newVerbSteps(plan: Plan): { Step }
	local f = plan.family
	if M.SET_FAMILIES[f] then
		return { targets(plan, "Read the objects"), after(plan, commandWords(plan, "set"), "Server-side dry run") }
	elseif f == "replace" and plan.force then
		local probe = after(plan, { "replace" }, "Replace without --force (server dry run)", PROBE_DROP)
		probe.id = "probe"
		probe.kind = "probe"
		probe.soft = true
		return {
			targets(plan, "Read the live objects"),
			fileObjects(plan),
			step(
				plan,
				"dry-run",
				"dry-run",
				"Delete server dry run",
				rebuild(plan, { "delete" }, { only = DELETE_FLAGS, drop = PRINTER }, { "--dry-run=server" })
			),
			probe,
		}
	elseif f == "replace" then
		-- The file as written: an object without resourceVersion overwrites
		-- concurrent changes (risk replace-no-rv).
		local file = fileObjects(plan)
		file.soft = true
		return { targets(plan, "Read the live objects"), file, after(plan, { "replace" }, "Server-side dry run") }
	elseif f == "taint" then
		local out = { targets(plan, "Read the nodes"), after(plan, { "taint" }, "Server-side dry run") }
		if addsEffect(plan, "NoSchedule") then
			table.insert(out, nodesStep(plan))
		end
		return out
	elseif f == "run" then
		return { after(plan, { "run" }, "Server-side dry run (without attaching)", RUN_DROP, dashTail(plan)) }
	elseif f == "expose" then
		return { targets(plan, "Read the object to expose"), after(plan, { "expose" }, "Server-side dry run") }
	end
	return { after(plan, commandWords(plan, "create"), "Server-side dry run", nil, dashTail(plan)) }
end

function M.forPlan(plan: Plan, timeoutMs: number?): { Step }
	local out: { Step }
	local family = plan.family
	if family == "helm-rollback" then
		out = helmSteps(plan)
	elseif family == "apply" then
		out = {
			dryRun(plan, { "apply" }, "Server-side dry run"),
			step(
				plan,
				"diff",
				"diff",
				"Diff against the live objects",
				rebuild(plan, { "diff" }, { only = DIFF_FLAGS }, {})
			),
		}
	elseif family == "delete" then
		out = {
			targets(plan, "Resolve the objects to delete"),
			dryRun(plan, { "delete" }, "Server-side dry run"),
		}
	elseif family == "scale" then
		out = {
			targets(plan, "Read current replicas"),
			dryRun(plan, { "scale" }, "Server-side dry run"),
		}
		if plan.replicas == 0 then
			table.insert(out, pdbsStep(plan))
		end
	elseif family == "restart" then
		-- kubectl v1.34 `rollout restart` has no --dry-run: resolving the
		-- targets is the whole preview.
		out = { targets(plan, "Resolve the workloads to restart") }
	elseif family == "debug-node" then
		local ref = plan.resources[1]
		out = { getOne(plan, "node", ref.name, "Read the node") }
	elseif family == "debug-pod" then
		local ref = plan.resources[1]
		out = { getOne(plan, "pod", ref.name, "Read the pod") }
	elseif family == "cronjob-run" then
		local from = string.match(plan.invocation.flags.from[#plan.invocation.flags.from], "^[^/]+/(.+)$") :: string
		out = {
			getOne(plan, "cronjob", from, "Read the CronJob"),
			dryRun(plan, { "create", "job" }, "Server-side dry run"),
		}
	elseif family == "undo" then
		out = {
			targets(plan, "Read the workloads"),
			historyStep(plan),
			dryRun(plan, { "rollout", "undo" }, "Server-side dry run"),
		}
	elseif family == "pause" or family == "resume" then
		-- kubectl has no dry run for pause/resume: the after state is local.
		out = { targets(plan, "Read the deployments") }
	elseif family == "patch" or family == "label" or family == "annotate" then
		out = {
			targets(plan, "Read the objects"),
			after(plan, { family }, "Server-side dry run"),
		}
	elseif family == "cordon" or family == "uncordon" then
		out = { nodeTargets(plan), dryRun(plan, { family }, "Server-side dry run") }
		if family == "cordon" then
			table.insert(out, nodesStep(plan))
		end
	elseif family == "drain" then
		local budget = timeoutMs or M.DEFAULT_TIMEOUT_MS
		out = {
			nodeTargets(plan),
			step(
				plan,
				"dry-run",
				"dry-run",
				"Client dry run (pods to evict)",
				rebuild(plan, { "drain" }, { drop = DRAIN_DROP }, { "--dry-run=client" })
			),
		}
		if not (plan.drain and plan.drain.disableEviction) then
			table.insert(
				out,
				step(
					plan,
					"evict",
					"evict",
					"Eviction probe (PodDisruptionBudgets)",
					rebuild(
						plan,
						{ "drain" },
						{ drop = DRAIN_DROP },
						{ "--dry-run=server", string.format("--timeout=%ds", Drain.probeTimeoutS(budget)) }
					)
				)
			)
		end
		table.insert(out, nodesStep(plan))
	elseif family ~= "edit" then
		out = newVerbSteps(plan)
	else
		local edit = plan.edit :: T.EditInput
		out = {
			convert(plan, "convert-original", edit.original, "Read the original"),
			convert(plan, "convert-edited", edit.file, "Read your edit"),
			step(
				plan,
				"targets",
				"targets",
				"Read the live objects",
				prefixed(plan, nil, { "get", "-f", edit.original, "-o", "json" })
			),
		}
		out[2].soft = true
	end
	for _, s in out do
		s.timeoutMs = timeoutMs or M.DEFAULT_TIMEOUT_MS
	end
	return out
end

export type StepResult = { ok: boolean, code: number?, stdout: string, stderr: string }

-- A Kind.version.group resource type as `kubectl get` resolves it (core
-- group: `ConfigMap.v1.`), from an object's apiVersion and kind.
function M.typeRef(obj: any): string?
	if type(obj) ~= "table" or type(obj.apiVersion) ~= "string" or type(obj.kind) ~= "string" then
		return nil
	end
	local group, version = string.match(obj.apiVersion, "^(.+)/([^/]+)$")
	return string.format("%s.%s.%s", obj.kind, version or obj.apiVersion, group or "")
end

local function metaOf(obj: any): { [string]: any }
	return if type(obj) == "table" and type(obj.metadata) == "table" then obj.metadata else {}
end

export type UndoPlan = { target: Rollout.UndoTarget, live: any, typeRef: string, namespace: string? }

-- What `rollout undo` restores per object: live objects from the targets
-- step paired with their revision list from the history step.
function M.undoPlans(plan: Plan, results: { [string]: StepResult }, decode: (string) -> any): ({ UndoPlan }?, string?)
	local t, h = results.targets, results.history
	if t == nil or h == nil then
		return nil, "the preview did not read the workloads and their history"
	end
	local live, err = Objdiff.decodeStream(t.stdout, decode)
	if live == nil then
		return nil, "unreadable workloads: " .. (err or "?")
	end
	if #live > M.MAX_OBJECTS then
		return nil, string.format("preview covers at most %d objects; narrow the command", M.MAX_OBJECTS)
	end
	local histories = Rollout.parseHistory(h.stdout)
	local out: { UndoPlan } = {}
	for _, obj in live do
		local meta = metaOf(obj)
		local key, typeRef = Objdiff.identity(obj), M.typeRef(obj)
		local name = meta.name
		if key == nil or typeRef == nil or type(name) ~= "string" then
			return nil, "a workload without apiVersion, kind or name"
		end
		local kind = string.lower(obj.kind)
		local found: Rollout.History? = nil
		for _, entry in histories do
			if entry.kind == kind and entry.name == name then
				found = entry
			end
		end
		if found == nil then
			return nil, string.format("no rollout history for %s/%s", kind, name)
		end
		local revisions = (found :: Rollout.History).revisions
		local to, why = Rollout.target(revisions, plan.toRevision)
		if to == nil then
			return nil, string.format("%s/%s: %s", kind, name, why or "?")
		end
		table.insert(out, {
			target = { key = key, name = name, from = revisions[#revisions] or 0, to = to :: number },
			live = obj,
			typeRef = typeRef,
			namespace = if type(meta.namespace) == "string" then meta.namespace else nil,
		})
	end
	return out, nil
end

local function editSteps(plan: Plan, results: { [string]: StepResult }, timeoutMs: number): ({ Step }?, string?)
	local edited = results["convert-edited"]
	if edited == nil or not edited.ok then
		return nil, nil
	end
	local set, err = Edit.plan(results["convert-original"].stdout, edited.stdout)
	if set == nil then
		return nil, err
	end
	local changes = (set :: Edit.EditSet).changes
	if #changes > M.MAX_OBJECTS then
		return nil, string.format("preview covers at most %d objects; narrow the command", M.MAX_OBJECTS)
	end
	local bytes = 0
	for _, c in changes do
		bytes += #c.patch
	end
	if bytes > M.MAX_EDIT_PATCH_BYTES then
		return nil, "the edit's patches exceed 256 KiB; preview it in smaller edits"
	end
	local flags = plan.invocation.flags
	local out: { Step } = {}
	for _, c in changes do
		local words = { "patch", c.typeRef .. "/" .. c.name }
		if c.namespace then
			table.insert(words, "--namespace")
			table.insert(words, c.namespace :: string)
		end
		for _, w in { "--type=merge", "-p", c.patch, "--dry-run=server", "-o", "json" } do
			table.insert(words, w)
		end
		for _, name in { "subresource", "field-manager" } do
			local v = flags[name]
			if v and #v > 0 then
				table.insert(words, "--" .. name .. "=" .. v[#v])
			end
		end
		local s = step(plan, "after:" .. c.key, "after", "Server dry run of " .. c.key, prefixed(plan, nil, words))
		s.object = c.key
		s.soft = true
		s.timeoutMs = timeoutMs
		table.insert(out, s)
	end
	return out, nil
end

-- The rollback's target manifest against the live objects: `kubectl diff
-- -f -` with the manifest on stdin (never a file: it holds the revision's
-- Secrets). Objects without metadata.namespace go to the release namespace,
-- as helm applies them. Soft: helm merges three ways, so this diff is an
-- approximation, and a failure is a finding, not a failed preview.
local function helmDiffSteps(
	plan: Plan,
	results: { [string]: StepResult },
	budget: number,
	decode: (string) -> any
): ({ Step }?, string?)
	local target = results["helm-target"]
	if target == nil or not target.ok then
		return nil, nil
	end
	local ok, doc = pcall(decode, target.stdout)
	if not ok or type(doc) ~= "table" then
		return nil, "helm status returned unreadable JSON for the target revision"
	end
	local manifest = doc.manifest
	if
		type(manifest) ~= "string"
		or not string.find(manifest, "\n%s*kind:") and not string.find(manifest, "^kind:")
	then
		return nil, nil
	end
	local h = plan.helm :: T.HelmRollback
	local argv: { string } = { h.kubectl }
	for _, a in M.pins(plan, h.namespace) do
		table.insert(argv, a)
	end
	for _, a in { "diff", "-f", "-" } do
		table.insert(argv, a)
	end
	local env: { [string]: string } = { KUBECTL_EXTERNAL_DIFF = "" }
	if M.isPathList(plan.kubeconfig) then
		env.KUBECONFIG = plan.kubeconfig :: string
	end
	local s: Step = {
		id = "diff",
		kind = "diff",
		label = string.format("Diff revision %d against the live objects", h.revision),
		argv = argv,
		env = env,
		timeoutMs = budget,
		soft = true,
		stdin = manifest,
	}
	return { s }, nil
end

function M.podsStepId(node: string): string
	return "pods:" .. node
end

-- Nodes whose server dry run adds a NoExecute taint or changes its value,
-- in targets order; `before`/`after` by node name.
function M.noExecuteNodes(
	results: { [string]: StepResult },
	decode: (string) -> any
): ({ string }, { [string]: any }, { [string]: any })
	local names: { string } = {}
	local before: { [string]: any } = {}
	local afterBy: { [string]: any } = {}
	local t, a = results.targets, results.after
	if t == nil or a == nil or not t.ok or not a.ok then
		return names, before, afterBy
	end
	for _, obj in (Objdiff.decodeStream(a.stdout, decode) or {}) :: { any } do
		local name = metaOf(obj).name
		if type(name) == "string" then
			afterBy[name] = obj
		end
	end
	for _, obj in (Objdiff.decodeStream(t.stdout, decode) or {}) :: { any } do
		local name = metaOf(obj).name
		if type(name) == "string" then
			before[name] = obj
			if afterBy[name] and #Taint.newNoExecute(obj, afterBy[name]) > 0 then
				table.insert(names, name)
			end
		end
	end
	return names, before, afterBy
end

-- taint: the pods on each node a NoExecute taint lands on (soft: an
-- unreadable list is an unknown risk states). At most MAX_OBJECTS nodes;
-- beyond that the evictions are reported as not computed.
function M.taintPodSteps(
	plan: Plan,
	results: { [string]: StepResult },
	budget: number,
	decode: (string) -> any
): { Step }?
	local names = M.noExecuteNodes(results, decode)
	if #names == 0 or #names > M.MAX_OBJECTS then
		return nil
	end
	local out: { Step } = {}
	for _, node in names do
		local s = factStep(
			plan,
			"pods",
			"Read the pods on " .. node,
			prefixed(plan, nil, {
				"get",
				"pods",
				"--all-namespaces",
				"--field-selector",
				"spec.nodeName=" .. node,
				"-o",
				"json",
			})
		)
		s.id = M.podsStepId(node)
		s.timeoutMs = budget
		table.insert(out, s)
	end
	return out
end

-- Stage 2, from the stage-1 results keyed by step id: nil, nil when the
-- family has none; an error string fails the preview with that text.
function M.followUp(
	plan: Plan,
	results: { [string]: StepResult },
	timeoutMs: number?,
	decode: (string) -> any
): ({ Step }?, string?)
	local budget = timeoutMs or M.DEFAULT_TIMEOUT_MS
	if plan.family == "edit" then
		return editSteps(plan, results, budget)
	elseif plan.family == "helm-rollback" then
		return helmDiffSteps(plan, results, budget, decode)
	elseif plan.family == "taint" then
		return M.taintPodSteps(plan, results, budget, decode), nil
	elseif plan.family ~= "undo" then
		return nil, nil
	end
	local plans, err = M.undoPlans(plan, results, decode)
	if plans == nil then
		return nil, err
	end
	local out: { Step } = {}
	for _, u in plans :: { UndoPlan } do
		local words = { "rollout", "history", u.typeRef .. "/" .. u.target.name }
		if u.namespace then
			table.insert(words, "--namespace")
			table.insert(words, u.namespace :: string)
		end
		table.insert(words, string.format("--revision=%d", u.target.to))
		table.insert(words, "-o")
		table.insert(words, "json")
		local s = step(
			plan,
			"revision:" .. u.target.key,
			"revision",
			string.format("Read revision %d of %s", u.target.to, u.target.name),
			prefixed(plan, nil, words)
		)
		s.object = u.target.key
		s.timeoutMs = budget
		table.insert(out, s)
	end
	return out, nil
end

-- Re-read at confirm: what decided the preview must not have moved
-- (`rollout undo` without --to-revision is relative to the newest revision;
-- a helm upgrade or another rollback since the preview changes what the
-- rollback replaces; a selector or --all matches again when kubectl runs).
function M.verifySteps(plan: Plan): { Step }
	local out: { Step } = {}
	local kind: T.StepKind? = if plan.family == "undo"
		then "history"
		elseif plan.family == "helm-rollback" then "helm-history"
		else nil
	if kind then
		for _, s in plan.steps do
			if s.kind == kind then
				table.insert(out, s)
				break
			end
		end
	end
	local sel = Selection.step(plan)
	if sel then
		table.insert(out, sel)
	end
	return out
end

-- Re-read after a run: the targets and the diff again; for a helm rollback
-- the two newest revisions (the rollback's own and the one it replaced).
function M.requerySteps(plan: Plan): { Step }
	if plan.family == "helm-rollback" then
		local s = helmLatest(plan, "helm-after", 2)
		s.label = "Release history"
		s.timeoutMs = (plan.steps[1] and plan.steps[1].timeoutMs) or M.DEFAULT_TIMEOUT_MS
		return { s }
	end
	local out: { Step } = {}
	for _, s in plan.steps do
		if s.kind == "targets" or s.kind == "diff" then
			table.insert(out, s)
		end
	end
	return out
end

-- Native execution: the typed command with the same pins as the preview.
function M.execArgv(plan: Plan): { string }
	local inv = plan.invocation
	local argv: { string } = { plan.program }
	local pins: { string } = {}
	if inv.kubeconfig == nil and plan.kubeconfig and not M.isPathList(plan.kubeconfig) then
		table.insert(pins, "--kubeconfig")
		table.insert(pins, plan.kubeconfig :: string)
	end
	if inv.context == nil then
		table.insert(pins, "--context")
		table.insert(pins, plan.targetContext)
	end
	local ns = M.pinnedNamespace(plan)
	if inv.namespace == nil and ns then
		table.insert(pins, "--namespace")
		table.insert(pins, ns)
	end
	table.move(pins, 1, #pins, 2, argv)
	table.move(plan.argv, 2, #plan.argv, #argv + 1, argv)
	return argv
end

export type ProcessResult = { code: number?, stdout: string?, stderr: string?, timedOut: boolean? }
export type OutcomeStatus = "ok" | "changes" | "no-changes" | "failed" | "timeout"
export type Outcome = { status: OutcomeStatus, ok: boolean, text: string }

-- The line of kubectl output that says why it failed. kubectl prints client
-- and server warnings before the error (1.37's `rollout undo` warns about
-- last-applied-configuration first), so `Warning:` lines lose to `error:` /
-- `Error from server` lines and to any other line.
function M.headline(text: string?): string
	local first: string? = nil
	local other: string? = nil
	for line in string.gmatch(text or "", "[^\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		if trimmed ~= "" then
			if string.find(trimmed, "^error:") or string.find(trimmed, "^Error from server") then
				return trimmed
			end
			first = first or trimmed
			if other == nil and not string.find(trimmed, "^Warning:") then
				other = trimmed
			end
		end
	end
	return other or first or ""
end

-- `kubectl diff` exits 0 without differences, 1 with differences and >1 on
-- error; the drain eviction probe ends on its --timeout (exit 1) when a
-- PodDisruptionBudget blocks a pod, which is a finding; every other step
-- succeeds only with 0.
function M.outcome(s: Step, result: ProcessResult): Outcome
	if result.timedOut then
		return { status = "timeout", ok = false, text = string.format("%s timed out after %d ms", s.label, s.timeoutMs) }
	end
	local code = result.code
	if code == nil then
		return { status = "failed", ok = false, text = s.label .. " did not exit normally" }
	end
	if s.kind == "diff" then
		if code == 0 then
			return { status = "no-changes", ok = true, text = "No differences" }
		elseif code == 1 then
			return { status = "changes", ok = true, text = "Differences found" }
		end
	elseif s.kind == "evict" and code ~= 0 then
		if Drain.probeOutcome(code, result.stdout or "", result.stderr or "") == "pdb-blocked" then
			return { status = "ok", ok = true, text = "A PodDisruptionBudget blocks evictions now" }
		end
	elseif code == 0 then
		return { status = "ok", ok = true, text = s.label .. " succeeded" }
	end
	local detail = M.headline(result.stderr)
	if detail == "" then
		detail = M.headline(result.stdout)
	end
	return {
		status = "failed",
		ok = false,
		text = string.format("%s failed (exit %d)%s", s.label, code, if detail ~= "" then ": " .. detail else ""),
	}
end

-- Objects named by a decoded `get -o json` (a List or a single object).
function M.targets(decoded: any): { Types.ResourceRef }
	local out: { Types.ResourceRef } = {}
	if type(decoded) ~= "table" then
		return out
	end
	local items = decoded.items
	if type(items) == "table" then
		for _, item in items do
			local ref = if type(item) == "table" then Resource.fromObject(item, "live") else nil
			if ref then
				table.insert(out, ref)
			end
		end
		return out
	end
	local ref = Resource.fromObject(decoded, "live")
	if ref then
		table.insert(out, ref)
	end
	return out
end

export type FactRun = { step: Step, outcome: Outcome?, stdout: string? }

local function listItems(run: FactRun, decode: (string) -> any): ({ any }?, string?)
	local o = run.outcome
	if o == nil then
		return nil, run.step.label .. " did not finish"
	elseif not o.ok then
		return nil, o.text
	end
	local ok, doc = pcall(decode, run.stdout or "")
	if not ok or type(doc) ~= "table" or type(doc.items) ~= "table" then
		return nil, "unreadable JSON"
	end
	return doc.items, nil
end

-- Folds one step run into what the `nodes` and `pdbs` steps read; stays
-- nil while no run is one of them. One run at a time: a session's own run
-- records are wider than FactRun, and arrays of them would not convert.
function M.clusterFact(facts: T.ClusterFacts?, run: FactRun, decode: (string) -> any): T.ClusterFacts?
	local kind = run.step.kind
	if kind ~= "nodes" and kind ~= "pdbs" then
		return facts
	end
	local out: T.ClusterFacts = if facts then table.clone(facts) else {}
	if kind == "nodes" then
		out.nodes, out.nodesUnknown = listItems(run, decode)
	else
		out.pdbs, out.pdbsUnknown = listItems(run, decode)
	end
	return out
end

return M
