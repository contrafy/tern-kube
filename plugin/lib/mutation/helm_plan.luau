--!strict
-- `helm [globals] rollback RELEASE REVISION [flags]` as a MutationPlan.
-- Strict grammar, fail closed: only flags whose effect the preview models
-- are accepted, the revision must be explicit (helm's implicit "previous"
-- moves with every upgrade) and --timeout must be given (it bounds the wait
-- and the hooks, and the block cannot stop helm once it runs).
local Link = require("./link")
local Query = require("../helm/query")
local Steps = require("./steps")
local T = require("./types")
local Types = require("../model/types")

type Diagnostic = T.Diagnostic
type Plan = T.Plan

local M = {}

local BOOL: { [string]: boolean } = {
	wait = true,
	["wait-for-jobs"] = true,
	["cleanup-on-fail"] = true,
	force = true,
	["dry-run"] = true,
	["no-hooks"] = true,
}
local VALUE: { [string]: boolean } = {
	namespace = true,
	["kube-context"] = true,
	kubeconfig = true,
	timeout = true,
	["history-max"] = true,
}

local function err(code: T.Code, text: string): Diagnostic
	return { severity = "error", code = code, text = text }
end

local function nonEmpty(s: string?): string?
	return if s ~= nil and s ~= "" then s else nil
end

local function basename(path: string): string
	return string.match(path, "([^/]*)$") or path
end

-- An argv this module plans: argv[1] is the resolved helm program or a
-- program named helm.
function M.isHelm(argv: { string }, env: T.Env): boolean
	local first = argv[1]
	return first ~= nil and ((env.helm ~= nil and first == env.helm) or basename(first) == "helm")
end

type Parsed = {
	flags: { [string]: string },
	positionals: { string },
	unknown: { string },
	errors: { Diagnostic },
}

local function parse(argv: { string }): Parsed
	local out: Parsed = { flags = {}, positionals = {}, unknown = {}, errors = {} }
	local i = 2
	while i <= #argv do
		local a = argv[i]
		local name: string?, value: string? = nil, nil
		if a == "-n" then
			name = "namespace"
		elseif string.sub(a, 1, 2) == "--" then
			local n, v = string.match(a, "^%-%-([%w%-]+)=(.*)$")
			name, value = n, v
			if name == nil then
				name = string.sub(a, 3)
			end
		elseif string.sub(a, 1, 1) == "-" then
			local short = string.match(a, "^%-n=?(.+)$")
			if short then
				name, value = "namespace", short
			else
				table.insert(out.unknown, a)
				i += 1
				continue
			end
		else
			table.insert(out.positionals, a)
			i += 1
			continue
		end
		local flag = name :: string
		if BOOL[flag] then
			if value ~= nil and value ~= "true" and value ~= "false" then
				table.insert(out.errors, err("invalid", string.format("--%s takes no value (got %q)", flag, value)))
			end
			out.flags[flag] = value or "true"
		elseif VALUE[flag] then
			if value == nil then
				value = argv[i + 1]
				i += 1
			end
			if value == nil then
				table.insert(out.errors, err("invalid", string.format("--%s needs a value", flag)))
			else
				out.flags[flag] = value
			end
		else
			table.insert(out.unknown, a)
		end
		i += 1
	end
	return out
end

local function on(flags: { [string]: string }, name: string): boolean
	local v = flags[name]
	return v ~= nil and v ~= "false"
end

-- The synthetic invocation risk/fingerprint readers see: no kubectl flags.
local function invocation(program: string, context: string?, kubeconfig: string?, namespace: string?): Types.Invocation
	return {
		program = program,
		verb = "rollback",
		subverb = nil,
		resources = {},
		names = {},
		namespace = namespace,
		allNamespaces = false,
		context = context,
		kubeconfig = kubeconfig,
		cluster = nil,
		user = nil,
		output = "table",
		outputSpec = nil,
		watch = false,
		noHeaders = false,
		showLabels = false,
		showKind = false,
		selector = nil,
		fieldSelector = nil,
		sortBy = nil,
		labelColumns = {},
		filenames = {},
		recursive = false,
		kustomize = nil,
		dryRun = nil,
		flags = {},
		positionals = {},
		afterDash = {},
		unknownFlags = {},
		ambiguities = {},
	}
end

-- What the native path executes: the typed argv with the connection (and
-- the release namespace when -n is absent) pinned before the verb.
local function execArgv(plan: Plan, typed: { context: string?, kubeconfig: string?, namespace: string? }): { string }
	local h = plan.helm :: T.HelmRollback
	local argv: { string } = { plan.program }
	if typed.context == nil then
		table.insert(argv, "--kube-context")
		table.insert(argv, plan.targetContext)
	end
	if typed.kubeconfig == nil and plan.kubeconfig and not Steps.isPathList(plan.kubeconfig) then
		table.insert(argv, "--kubeconfig")
		table.insert(argv, plan.kubeconfig :: string)
	end
	if typed.namespace == nil then
		table.insert(argv, "--namespace")
		table.insert(argv, h.namespace)
	end
	table.move(plan.argv, 2, #plan.argv, #argv + 1, argv)
	return argv
end

function M.fromArgv(argv: { string }, env: T.Env): (Plan?, { Diagnostic })
	local p = parse(argv)
	if p.positionals[1] ~= "rollback" then
		return nil,
			{
				err(
					"unsupported",
					string.format(
						"helm %s does not go through the approve block; only helm rollback does",
						p.positionals[1] or "(no command)"
					)
				),
			}
	end
	local diags: { Diagnostic } = table.clone(p.errors)
	if #p.unknown > 0 then
		table.insert(
			diags,
			err(
				"unknown-flag",
				string.format(
					"unknown flag%s %s: tern-kube cannot tell what the rollback would do",
					if #p.unknown > 1 then "s" else "",
					table.concat(p.unknown, ", ")
				)
			)
		)
	end
	local release, rev = p.positionals[2], p.positionals[3]
	if release == nil or rev == nil then
		table.insert(diags, err("missing-target", "helm rollback needs RELEASE REVISION (an explicit revision)"))
	elseif #p.positionals > 3 then
		table.insert(
			diags,
			err("invalid", "helm rollback takes RELEASE REVISION, got " .. table.concat(p.positionals, " ", 2))
		)
	else
		if not Query.validRelease(release) then
			table.insert(diags, err("invalid", string.format("%q is not a helm release name", release)))
		end
		local n = if string.match(rev, "^%d+$") then tonumber(rev) else nil
		if n == nil or not Query.validRevision(n) then
			table.insert(diags, err("invalid", string.format("revision %q must be a whole number from 1", rev)))
		end
	end
	local f = p.flags
	local timeoutMs: number? = nil
	if f.timeout == nil then
		table.insert(
			diags,
			err("invalid", "helm rollback needs --timeout: it bounds the wait and the hooks the block waits for")
		)
	else
		timeoutMs = Link.durationMs(f.timeout)
		if timeoutMs == nil or timeoutMs < 1000 then
			table.insert(
				diags,
				err("invalid", string.format("--timeout=%s is not a duration of 1s or more", f.timeout))
			)
		end
	end
	if on(f, "wait-for-jobs") and not on(f, "wait") then
		table.insert(diags, err("invalid", "--wait-for-jobs needs --wait"))
	end
	local hmax = f["history-max"]
	if hmax and not string.match(hmax, "^%d+$") then
		table.insert(diags, err("invalid", string.format("--history-max=%s is not a whole number", hmax)))
	end
	local context = nonEmpty(f["kube-context"]) or nonEmpty(env.context)
	if context == nil then
		table.insert(diags, err("no-context", "no kube context could be resolved; pass --kube-context"))
	end
	if #diags > 0 then
		return nil, diags
	end
	if on(f, "dry-run") then
		return nil,
			{ { severity = "info", code = "dry-run", text = "--dry-run changes nothing; it runs without approval" } }
	end

	local explicitNamespace = nonEmpty(f.namespace)
	local namespace = explicitNamespace or nonEmpty(env.namespace) or "default"
	local ctx = context :: string
	local kubeconfig = nonEmpty(f.kubeconfig) or nonEmpty(env.kubeconfig) or nonEmpty(env.defaultKubeconfig)
	local program = argv[1]
	local plan: Plan = {
		family = "helm-rollback",
		operation = "rollback",
		program = program,
		argv = table.clone(argv),
		execArgv = {},
		targetContext = ctx,
		contextSource = if nonEmpty(f["kube-context"]) then "flag" else env.contextSource or "inferred",
		kubeconfig = kubeconfig,
		envKubeconfig = nonEmpty(env.kubeconfig),
		explicitNamespace = explicitNamespace,
		targetNamespace = namespace,
		allNamespaces = false,
		cwd = env.cwd,
		filenames = {},
		recursive = false,
		kustomize = nil,
		kinds = {},
		resources = {},
		selector = nil,
		fieldSelector = nil,
		all = false,
		replicas = nil,
		patchFiles = {},
		edits = {},
		overwrite = false,
		patchType = nil,
		toRevision = nil,
		drain = nil,
		edit = nil,
		helm = {
			release = release :: string,
			namespace = namespace,
			revision = tonumber(rev) :: number,
			options = {
				wait = on(f, "wait"),
				waitForJobs = on(f, "wait-for-jobs"),
				cleanupOnFail = on(f, "cleanup-on-fail"),
				force = on(f, "force"),
				noHooks = on(f, "no-hooks"),
				timeoutS = math.ceil((timeoutMs :: number) / 1000),
			},
			driver = env.helmDriver or "secret",
			kubectl = nonEmpty(env.program) or "kubectl",
		},
		steps = {},
		invocation = invocation(program, f["kube-context"], f.kubeconfig, explicitNamespace),
		validation = {},
	}
	plan.execArgv = execArgv(plan, { context = f["kube-context"], kubeconfig = f.kubeconfig, namespace = f.namespace })
	plan.steps = Steps.forPlan(plan, env.timeoutMs)
	return plan, {}
end

return M
