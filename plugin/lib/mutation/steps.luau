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
local Resource = require("../model/resource")
local Rollout = require("./rollout")
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
	if M.NODE_FAMILIES[plan.family] or plan.family == "edit" then
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

local function resourcePositionals(plan: Plan): { string }?
	if plan.family ~= "label" and plan.family ~= "annotate" then
		return nil
	end
	local out: { string } = {}
	for _, p in plan.invocation.positionals do
		if not Argv.isLabelEdit(p) then
			table.insert(out, p)
		end
	end
	return out
end

local function targets(plan: Plan, label: string): Step
	return step(
		plan,
		"targets",
		"targets",
		label,
		rebuild(plan, { "get" }, { only = GET_FLAGS, positionals = resourcePositionals(plan) }, { "-o", "json" })
	)
end

local function dryRun(plan: Plan, verb: { string }, label: string): Step
	return step(plan, "dry-run", "dry-run", label, rebuild(plan, verb, { drop = PRINTER }, { "--dry-run=server" }))
end

local function after(plan: Plan, verb: { string }, label: string): Step
	return step(
		plan,
		"after",
		"after",
		label,
		rebuild(plan, verb, { drop = PRINTER }, { "--dry-run=server", "-o", "json" })
	)
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

function M.forPlan(plan: Plan, timeoutMs: number?): { Step }
	local out: { Step }
	local family = plan.family
	if family == "apply" then
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
-- (`rollout undo` without --to-revision is relative to the newest revision).
function M.verifySteps(plan: Plan): { Step }
	if plan.family ~= "undo" then
		return {}
	end
	for _, s in plan.steps do
		if s.kind == "history" then
			return { s }
		end
	end
	return {}
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

return M
