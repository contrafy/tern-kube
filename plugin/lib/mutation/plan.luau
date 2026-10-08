--!strict
-- Turns a typed kubectl command into a MutationPlan: which family it is, the
-- target it will hit, and the preview steps that show what it would do.
-- Fails closed: anything the preview cannot model faithfully (stdin, remote
-- inputs, unknown or ambiguous flags, --raw, interactive prompts) is rejected
-- with an actionable diagnostic instead of being approved blind.
local Argv = require("../kubectl/argv")
local Kinds = require("../kubectl/kinds")
local Steps = require("./steps")
local T = require("./types")
local Types = require("../model/types")

type Plan = T.Plan
type Diagnostic = T.Diagnostic
type Invocation = Types.Invocation

local M = {}

local OPERATION: { [T.Family]: string } = {
	apply = "apply",
	delete = "delete",
	restart = "rollout restart",
	scale = "scale",
	["debug-pod"] = "debug",
	["debug-node"] = "debug node",
	["cronjob-run"] = "create job",
}

local FAMILIES: { [string]: T.Family } = {
	apply = "apply",
	delete = "delete",
	restart = "restart",
	scale = "scale",
	["debug-pod"] = "debug-pod",
	["debug-node"] = "debug-node",
	["cronjob-run"] = "cronjob-run",
}

local DRY_RUN_NOOP = { client = true, server = true, unchanged = true, ["true"] = true }
local DRY_RUN_REAL = { none = true, ["false"] = true }

local function err(code: T.Code, text: string): Diagnostic
	return { severity = "error", code = code, text = text }
end

local function info(code: T.Code, text: string): Diagnostic
	return { severity = "info", code = code, text = text }
end

local function last(list: { string }?): string?
	return if list then list[#list] else nil
end

local function nonEmpty(s: string?): string?
	return if s ~= nil and s ~= "" then s else nil
end

local function familyOf(inv: Invocation): (T.Family?, Diagnostic?)
	local verb = inv.verb
	if inv.flags.help then
		return nil, info("not-mutation", "--help only prints usage")
	end
	if verb == "apply" then
		if inv.subverb == nil then
			return "apply", nil
		elseif inv.subverb == "view-last-applied" then
			return nil, info("not-mutation", "apply view-last-applied only reads")
		end
		return nil,
			err(
				"unsupported",
				string.format(
					"kubectl apply %s cannot be previewed; run it with `command kubectl` if you accept the risk",
					inv.subverb
				)
			)
	elseif verb == "delete" then
		return "delete", nil
	elseif verb == "scale" then
		return "scale", nil
	elseif verb == "rollout" and inv.subverb == "restart" then
		return "restart", nil
	elseif verb == "debug" then
		local first = inv.positionals[1]
		if first and string.match(string.lower(first), "^nodes?/") then
			return "debug-node", nil
		end
		return "debug-pod", nil
	elseif verb == "create" and inv.subverb == "job" and inv.flags.from then
		local from = last(inv.flags.from) or ""
		local typ = string.match(from, "^([^/]+)/")
		if typ and Kinds.normalize(typ).kind == "CronJob" then
			return "cronjob-run", nil
		end
	end
	return nil, info("not-mutation", string.format("kubectl %s is not a guarded mutation", verb or "(no command)"))
end

local function isRemote(path: string): boolean
	return string.find(path, "://", 1, true) ~= nil
end

local function inputErrors(inv: Invocation): { Diagnostic }
	local out: { Diagnostic } = {}
	for _, f in inv.filenames do
		if f == "-" then
			table.insert(
				out,
				err(
					"stdin",
					"`-f -` reads the manifest from stdin, which cannot be previewed and then replayed; "
						.. "save it to a file and run `kubectl "
						.. (inv.verb or "apply")
						.. " -f <file>`"
				)
			)
		elseif isRemote(f) then
			table.insert(
				out,
				err(
					"remote-input",
					string.format(
						"%s is fetched again at execution, so the preview cannot vouch for it; download it and pass the local file",
						f
					)
				)
			)
		end
	end
	if inv.kustomize and isRemote(inv.kustomize) then
		table.insert(
			out,
			err(
				"remote-input",
				string.format(
					"remote kustomization %s cannot be fingerprinted; check it out locally and pass the directory",
					inv.kustomize
				)
			)
		)
	end
	return out
end

local function flagErrors(inv: Invocation): { Diagnostic }
	local out: { Diagnostic } = {}
	if #inv.unknownFlags > 0 then
		table.insert(
			out,
			err(
				"unknown-flag",
				string.format(
					"unknown flag%s %s: kube-lens cannot tell what the command would do",
					if #inv.unknownFlags > 1 then "s" else "",
					table.concat(inv.unknownFlags, ", ")
				)
			)
		)
	end
	for _, a in inv.ambiguities do
		table.insert(out, err("ambiguous", a))
	end
	if inv.flags.raw then
		table.insert(out, err("raw", "--raw sends a request the preview cannot model; use a resource argument instead"))
	end
	if inv.verb == "delete" and inv.flags.interactive and last(inv.flags.interactive) ~= "false" then
		table.insert(
			out,
			err(
				"interactive",
				"`delete -i` prompts on the terminal; the approval block replaces that prompt, so drop -i"
			)
		)
	end
	return out
end

local function kindRefs(inv: Invocation): { T.KindRef }
	local out: { T.KindRef } = {}
	local seen: { [string]: boolean } = {}
	for _, r in inv.resources do
		local key = r.kind .. "|" .. (r.group or "")
		if seen[key] then
			continue
		end
		seen[key] = true
		local namespaced: boolean? = nil
		if r.kind ~= "all" then
			local info_ = Kinds.normalize(if r.group then string.lower(r.kind) .. "." .. r.group else r.kind)
			namespaced = if info_.known then info_.namespaced else nil
		end
		table.insert(out, { kind = r.kind, group = r.group, namespaced = namespaced })
	end
	return out
end

local function hasTypeOnly(inv: Invocation): boolean
	local named = #inv.names > 0
	return #inv.resources > 0 and not named
end

local function targetErrors(family: T.Family, inv: Invocation): { Diagnostic }
	local out: { Diagnostic } = {}
	local fileInputs = #inv.filenames > 0 or inv.kustomize ~= nil
	local selected = inv.selector ~= nil
		or inv.fieldSelector ~= nil
		or (inv.flags.all ~= nil and last(inv.flags.all) ~= "false")
	if family == "apply" then
		if not fileInputs then
			table.insert(out, err("missing-target", "apply needs -f FILE|DIR or -k DIR"))
		elseif #inv.filenames > 0 and inv.kustomize then
			table.insert(out, err("invalid", "apply takes either -f or -k, not both"))
		end
		if #inv.positionals > 0 then
			table.insert(out, err("invalid", "apply takes no arguments, got " .. table.concat(inv.positionals, " ")))
		end
	elseif family == "delete" or family == "scale" then
		if not fileInputs and #inv.positionals == 0 then
			table.insert(out, err("missing-target", family .. " needs TYPE NAME, TYPE/NAME, -f or -k"))
		elseif not fileInputs and hasTypeOnly(inv) and not selected then
			table.insert(
				out,
				err(
					"missing-target",
					string.format("%s %s needs a name, -l SELECTOR or --all", family, inv.positionals[1])
				)
			)
		end
	elseif family == "restart" then
		if not fileInputs and #inv.positionals == 0 then
			table.insert(out, err("missing-target", "rollout restart needs TYPE NAME, TYPE/NAME, -f or -k"))
		end
	elseif family == "debug-pod" or family == "debug-node" then
		if #inv.positionals == 0 then
			table.insert(out, err("missing-target", "debug needs a pod or node/NAME"))
		end
	elseif family == "cronjob-run" then
		if #inv.positionals == 0 then
			table.insert(out, err("missing-target", "create job --from=cronjob/NAME needs a job name"))
		end
	end
	if family == "scale" then
		local replicas = last(inv.flags.replicas)
		if replicas == nil then
			table.insert(out, err("invalid", "scale needs --replicas=N"))
		elseif not string.match(replicas, "^%d+$") then
			table.insert(out, err("invalid", string.format("--replicas=%s is not a whole number", replicas)))
		end
	end
	return out
end

local function ref(kind: string, group: string?, name: string, namespace: string?, context: string): Types.ResourceRef
	return {
		clusterContext = context,
		namespace = namespace,
		group = group,
		version = nil,
		kind = kind,
		name = name,
		uid = nil,
		source = "live",
	}
end

local function resourcesOf(family: T.Family, inv: Invocation, context: string, ns: string?): { Types.ResourceRef }
	local out: { Types.ResourceRef } = {}
	if family == "debug-node" then
		local name = string.match(inv.positionals[1], "^[^/]+/(.+)$") :: string
		table.insert(out, ref("Node", nil, name, nil, context))
		return out
	elseif family == "debug-pod" then
		local first = inv.positionals[1]
		local name = string.match(first, "^[^/]+/(.+)$") or first
		table.insert(out, ref("Pod", nil, name, ns, context))
		return out
	elseif family == "cronjob-run" then
		table.insert(out, ref("Job", "batch", inv.positionals[1], ns, context))
		return out
	end
	for _, r in inv.resources do
		if r.name == nil or r.kind == "all" then
			continue
		end
		local info_ = Kinds.normalize(if r.group then string.lower(r.kind) .. "." .. r.group else r.kind)
		local namespaced = not info_.known or info_.namespaced ~= false
		table.insert(out, ref(r.kind, r.group, r.name :: string, if namespaced then ns else nil, context))
	end
	return out
end

-- argv: the command as typed, program first. env: what the host resolved
-- (context and its provenance, kubeconfig path, default namespace, cwd).
-- Returns nil with an `info` diagnostic for commands that need no approval
-- (not a guarded mutation, or already a dry run) and nil with `error`
-- diagnostics for rejected ones.
function M.fromArgv(argv: { string }, env: T.Env): (Plan?, { Diagnostic })
	if #argv == 0 then
		return nil, { err("invalid", "empty command") }
	end
	local program = nonEmpty(env.program) or argv[1]
	local inv = Argv.parse(argv[1], table.move(argv, 2, #argv, 1, {}))
	local found, why = familyOf(inv)
	if found == nil then
		return nil, { why :: Diagnostic }
	end
	-- Held in a field: luau-lsp 1.70 widens singleton unions held in locals.
	local picked: { family: T.Family } = { family = FAMILIES[found] }

	local diags: { Diagnostic } = {}
	for _, d in flagErrors(inv) do
		table.insert(diags, d)
	end
	for _, d in inputErrors(inv) do
		table.insert(diags, d)
	end
	local dryRun = inv.dryRun
	local noop = false
	if dryRun ~= nil then
		if DRY_RUN_NOOP[dryRun] then
			noop = true
		elseif not DRY_RUN_REAL[dryRun] then
			table.insert(diags, err("invalid", string.format("--dry-run=%s is not none, client or server", dryRun)))
		end
	end
	for _, d in targetErrors(picked.family, inv) do
		table.insert(diags, d)
	end
	local context = nonEmpty(inv.context) or nonEmpty(env.context)
	if context == nil then
		table.insert(
			diags,
			err("no-context", "no kube context could be resolved; pass --context or set a current-context")
		)
	end
	if #diags > 0 then
		return nil, diags
	end
	if noop then
		return nil,
			{
				info(
					"dry-run",
					string.format("--dry-run=%s changes nothing; it runs without approval", dryRun :: string)
				),
			}
	end

	local explicitNamespace = nonEmpty(inv.namespace)
	local targetNamespace = if inv.allNamespaces then nil else explicitNamespace or nonEmpty(env.namespace) or "default"
	local ctx = context :: string
	local replicas = last(inv.flags.replicas)
	local plan: Plan = {
		family = picked.family,
		operation = OPERATION[picked.family],
		program = program,
		argv = table.clone(argv),
		execArgv = {},
		targetContext = ctx,
		contextSource = if nonEmpty(inv.context) then "flag" else env.contextSource or "inferred",
		kubeconfig = nonEmpty(inv.kubeconfig) or nonEmpty(env.kubeconfig) or nonEmpty(env.defaultKubeconfig),
		envKubeconfig = nonEmpty(env.kubeconfig),
		explicitNamespace = explicitNamespace,
		targetNamespace = targetNamespace,
		allNamespaces = inv.allNamespaces,
		cwd = env.cwd,
		filenames = table.clone(inv.filenames),
		recursive = inv.recursive,
		kustomize = inv.kustomize,
		kinds = kindRefs(inv),
		resources = resourcesOf(picked.family, inv, ctx, targetNamespace),
		selector = inv.selector,
		fieldSelector = inv.fieldSelector,
		all = inv.flags.all ~= nil and last(inv.flags.all) ~= "false",
		replicas = if replicas then tonumber(replicas) else nil,
		steps = {},
		invocation = inv,
		validation = {},
	}
	plan.steps = Steps.forPlan(plan, env.timeoutMs)
	plan.execArgv = Steps.execArgv(plan)
	return plan, {}
end

-- Environment the native execution needs besides argv (a KUBECONFIG path list
-- cannot be passed as --kubeconfig).
function M.execEnv(plan: Plan): { [string]: string }
	return Steps.baseEnv(plan)
end

return M
