--!strict
-- Preview steps per family as argv arrays. Every step pins --context (and
-- --kubeconfig, or KUBECONFIG for a path list) so a `config use-context` in
-- another shell cannot redirect the preview. Original flags are re-emitted as
-- `--name=value` from the parsed invocation: values that start with `-` stay
-- values, and only flags the step's verb accepts are carried over.
local Resource = require("../model/resource")
local T = require("./types")
local Types = require("../model/types")
local flagTables = require("../kubectl/flags")

type Plan = T.Plan
type Step = T.Step
type Invocation = Types.Invocation

local M = {}

M.DEFAULT_TIMEOUT_MS = 30000

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
	if plan.explicitNamespace then
		return plan.explicitNamespace
	end
	if plan.allNamespaces or #plan.filenames > 0 or plan.kustomize ~= nil then
		return nil
	end
	return plan.targetNamespace
end

type Filter = { only: { [string]: boolean }?, drop: { [string]: boolean }? }

local function rebuild(plan: Plan, verb: { string }, filter: Filter, extra: { string }): { string }
	local inv: Invocation = plan.invocation
	local argv: { string } = { plan.program }
	for _, a in M.pins(plan, M.pinnedNamespace(plan)) do
		table.insert(argv, a)
	end
	for _, v in verb do
		table.insert(argv, v)
	end
	for _, p in inv.positionals do
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

local function targets(plan: Plan, label: string): Step
	return step(plan, "targets", "targets", label, rebuild(plan, { "get" }, { only = GET_FLAGS }, { "-o", "json" }))
end

local function dryRun(plan: Plan, verb: { string }, label: string): Step
	return step(plan, "dry-run", "dry-run", label, rebuild(plan, verb, { drop = PRINTER }, { "--dry-run=server" }))
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
	else
		local from = string.match(plan.invocation.flags.from[#plan.invocation.flags.from], "^[^/]+/(.+)$") :: string
		out = {
			getOne(plan, "cronjob", from, "Read the CronJob"),
			dryRun(plan, { "create", "job" }, "Server-side dry run"),
		}
	end
	for _, s in out do
		s.timeoutMs = timeoutMs or M.DEFAULT_TIMEOUT_MS
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

local function firstLine(text: string?): string
	if text == nil then
		return ""
	end
	for line in string.gmatch(text, "[^\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		if trimmed ~= "" then
			return trimmed
		end
	end
	return ""
end

-- `kubectl diff` exits 0 without differences, 1 with differences and >1 on
-- error; every other step succeeds only with 0.
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
	elseif code == 0 then
		return { status = "ok", ok = true, text = s.label .. " succeeded" }
	end
	local detail = firstLine(result.stderr)
	if detail == "" then
		detail = firstLine(result.stdout)
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
