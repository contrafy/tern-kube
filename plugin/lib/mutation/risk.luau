--!strict
-- Confirmation tier for a plan plus what its preview found. Reasons from the
-- argv and preview facts are certain; manifest scans are text heuristics and
-- are marked advisory: tern-kube never claims policy conformance.
local Diffseg = require("./diffseg")
local Kinds = require("../kubectl/kinds")
local T = require("./types")
local Types = require("../model/types")
local Yaml = require("../parse/yaml")

type Plan = T.Plan
type Reason = T.Reason
type Tier = T.Tier

export type Facts = {
	-- nil while the preview is running; false once any step failed.
	previewOk: boolean?,
	failure: string?,
	-- Objects resolved by the `targets` step (delete/scale/restart/debug).
	targets: { Types.ResourceRef }?,
	-- -f contents (or `kubectl kustomize` output) as the host read them.
	manifests: { T.Manifest }?,
	diff: Diffseg.Summary?,
}

local M = {}

local TIER_RANK: { [Tier]: number } = { simple = 1, typed = 2, blocked = 3 }
local SEVERITY_RANK: { [T.Severity]: number } = { high = 1, medium = 2, low = 3, info = 4 }

local WORKLOADS = {
	Pod = true,
	Deployment = true,
	StatefulSet = true,
	DaemonSet = true,
	ReplicaSet = true,
	ReplicationController = true,
	Job = true,
	CronJob = true,
}

local VERB_WORD: { [T.Family]: string } = {
	apply = "apply",
	delete = "delete",
	scale = "scale",
	restart = "restart",
	["debug-pod"] = "debug",
	["debug-node"] = "debug",
	["cronjob-run"] = "run",
}

type Builder = { list: { Reason }, byId: { [string]: Reason } }

local function add(b: Builder, id: string, severity: T.Severity, tier: Tier, text: string, advisory: boolean?)
	if b.byId[id] then
		return
	end
	local r: Reason = {
		id = id,
		severity = severity,
		text = if advisory then text .. " (advisory heuristic)" else text,
		tier = tier,
		advisory = advisory == true,
		overridable = id == "preview-failed",
	}
	b.byId[id] = r
	table.insert(b.list, r)
end

local function flag(plan: Plan, name: string): string?
	local list = plan.invocation.flags[name]
	return if list then list[#list] else nil
end

local function truthy(plan: Plan, name: string): boolean
	local v = flag(plan, name)
	return v ~= nil and v ~= "false"
end

local function label(ref: { kind: string?, namespace: string?, name: string? }): string
	return (ref.kind or "?") .. " " .. (if ref.namespace then ref.namespace .. "/" else "") .. (ref.name or "?")
end

-- Cluster scope of a kind; nil when tern-kube does not know the kind.
local function namespaced(kind: string, group: string?): boolean?
	local info = Kinds.normalize(if group and group ~= "" then string.lower(kind) .. "." .. group else kind)
	return if info.known then info.namespaced else nil
end

type Obj = { kind: string, group: string?, namespace: string?, name: string? }

-- What a delete will remove, from the best source available.
local function deleteObjects(plan: Plan, facts: Facts): { Obj }
	local out: { Obj } = {}
	if facts.targets then
		for _, r in facts.targets do
			table.insert(out, { kind = r.kind, group = r.group, namespace = r.namespace, name = r.name })
		end
		return out
	end
	for _, k in plan.kinds do
		table.insert(out, { kind = k.kind, group = k.group, namespace = nil, name = nil })
	end
	for _, m in facts.manifests or {} :: { T.Manifest } do
		for _, doc in Yaml.split(m.text).docs do
			if doc.kind then
				local group = if doc.apiVersion then string.match(doc.apiVersion, "^([^/]+)/") else nil
				table.insert(
					out,
					{ kind = doc.kind :: string, group = group, namespace = doc.namespace, name = doc.name }
				)
			end
		end
	end
	return out
end

local function argvReasons(b: Builder, plan: Plan, facts: Facts)
	local family = plan.family
	local inv = plan.invocation
	if family == "delete" then
		add(b, "delete", "medium", "typed", "Deletion cannot be undone")
		if plan.selector or plan.fieldSelector then
			add(
				b,
				"broad-selector",
				"high",
				"typed",
				"Deletes every object matching "
					.. (
						if plan.selector
							then "-l " .. plan.selector
							else "--field-selector " .. (plan.fieldSelector :: string)
					)
			)
		end
		if plan.all then
			add(b, "delete-all", "high", "typed", "--all deletes every object of the given types in the namespace")
		end
		if plan.allNamespaces then
			add(b, "all-namespaces", "high", "typed", "-A deletes across all namespaces")
		end
		for _, k in plan.kinds do
			if k.kind == "all" then
				add(b, "all-type", "high", "typed", "`all` expands to every common workload and service type")
			end
		end
		for _, o in deleteObjects(plan, facts) do
			if o.kind == "Namespace" then
				add(b, "namespace-delete", "high", "typed", "Deleting a namespace deletes everything in it")
			elseif o.kind == "CustomResourceDefinition" then
				add(
					b,
					"crd-delete",
					"high",
					"typed",
					"Deleting a CustomResourceDefinition deletes every object of that type in the cluster"
				)
			elseif o.kind ~= "all" and namespaced(o.kind, o.group) == false then
				add(
					b,
					"cluster-scoped-delete",
					"high",
					"typed",
					o.kind .. " is cluster-scoped: the deletion affects the whole cluster"
				)
			end
		end
		if truthy(plan, "force") then
			add(
				b,
				"force",
				"high",
				"typed",
				"--force removes objects immediately without waiting for graceful termination"
			)
		end
		local grace = flag(plan, "grace-period")
		if grace == "0" then
			add(b, "grace-period-zero", "high", "typed", "--grace-period=0 skips graceful termination")
		end
	elseif family == "apply" then
		if truthy(plan, "prune") then
			local scope = if plan.selector then "matching -l " .. plan.selector else "in scope (--all)"
			add(
				b,
				"prune",
				"high",
				"typed",
				"--prune deletes previously applied objects " .. scope .. " that the inputs no longer contain"
			)
		end
		if truthy(plan, "force") then
			add(b, "force", "high", "typed", "--force deletes and re-creates objects that cannot be patched")
		end
		if truthy(plan, "force-conflicts") then
			add(b, "force-conflicts", "medium", "simple", "--force-conflicts takes field ownership from other managers")
		end
	elseif family == "scale" or family == "restart" then
		local word = if family == "scale" then "Scales" else "Restarts"
		if plan.selector or plan.fieldSelector then
			add(
				b,
				"broad-selector",
				"high",
				"typed",
				word .. " every workload matching -l " .. (plan.selector or plan.fieldSelector or "")
			)
		end
		if plan.all then
			add(b, "all-workloads", "high", "typed", word .. " every workload of the given types (--all)")
		end
		if
			family == "restart"
			and #plan.resources == 0
			and #plan.filenames == 0
			and plan.kustomize == nil
			and not plan.selector
		then
			add(
				b,
				"all-workloads",
				"high",
				"typed",
				"rollout restart without a name restarts every workload of that type"
			)
		end
		if family == "scale" and plan.replicas == 0 then
			add(b, "scale-zero", "medium", "simple", "--replicas=0 stops every pod of the workload")
		end
	elseif family == "debug-node" then
		add(
			b,
			"debug-node",
			"high",
			"typed",
			"Creates a privileged pod in the node's host namespaces with the host filesystem mounted"
		)
	end
	if inv.flags.server or inv.cluster then
		add(
			b,
			"target-override",
			"medium",
			"typed",
			"--server/--cluster override the context's cluster: the context shown may not be the real target"
		)
	end
	if inv.flags.as or inv.user or inv.flags.token then
		add(b, "credentials-override", "info", "simple", "The command overrides credentials (--as/--user/--token)")
	end
	if plan.contextSource == "inferred" then
		add(
			b,
			"inferred-context",
			"medium",
			"simple",
			"The target context was inferred from the kubeconfig's current-context"
		)
	end
end

local function docLines(source: { string }, doc: Yaml.Doc): { string }
	local out: { string } = {}
	for i = doc.startLine, doc.endLine do
		local line = source[i]
		if not string.match(line, "^%s*#") then
			table.insert(out, line)
		end
	end
	return out
end

local function anyLine(lines: { string }, pattern: string): boolean
	for _, line in lines do
		if string.match(line, pattern) then
			return true
		end
	end
	return false
end

type Hits = { [string]: { string } }

local function hit(hits: Hits, order: { string }, id: string, what: string)
	local list = hits[id]
	if list == nil then
		list = {}
		hits[id] = list
		table.insert(order, id)
	end
	if not table.find(list, what) then
		table.insert(list, what)
	end
end

local MANIFEST_RULES: { [string]: { severity: T.Severity, tier: Tier, text: string } } = {
	privileged = { severity = "high", tier = "typed", text = "Privileged container" },
	["host-path"] = { severity = "high", tier = "typed", text = "hostPath volume" },
	["host-namespaces"] = { severity = "high", tier = "typed", text = "Host network/PID/IPC namespace" },
	["rbac-wildcard"] = { severity = "high", tier = "typed", text = "RBAC rule with `*` verbs, resources or groups" },
	["cluster-admin"] = { severity = "high", tier = "typed", text = "Binding to cluster-admin" },
	["public-service"] = {
		severity = "medium",
		tier = "simple",
		text = "Service exposed outside the cluster (LoadBalancer/NodePort)",
	},
	ingress = { severity = "medium", tier = "simple", text = "Ingress exposes HTTP routes" },
	["missing-limits"] = { severity = "low", tier = "simple", text = "Workload without resource limits" },
}

local function manifestReasons(b: Builder, manifests: { T.Manifest })
	local hits: Hits = {}
	local order: { string } = {}
	for _, m in manifests do
		local source = Yaml.lines(m.text)
		for _, doc in Yaml.splitLines(source).docs do
			local kind = doc.kind
			if kind == nil then
				continue
			end
			local what = label({ kind = kind, namespace = doc.namespace, name = doc.name })
			local lines = docLines(source, doc)
			if anyLine(lines, "^%s*%-?%s*privileged:%s*true%s*$") then
				hit(hits, order, "privileged", what)
			end
			if anyLine(lines, "^%s*%-?%s*hostPath:") then
				hit(hits, order, "host-path", what)
			end
			if
				anyLine(lines, "^%s*hostNetwork:%s*true%s*$")
				or anyLine(lines, "^%s*hostPID:%s*true%s*$")
				or anyLine(lines, "^%s*hostIPC:%s*true%s*$")
			then
				hit(hits, order, "host-namespaces", what)
			end
			if (kind == "ClusterRole" or kind == "Role") and (anyLine(lines, "[\"']%*[\"']")) then
				hit(hits, order, "rbac-wildcard", what)
			end
			if
				(kind == "ClusterRoleBinding" or kind == "RoleBinding")
				and anyLine(lines, "^%s*name:%s*[\"']?cluster%-admin[\"']?%s*$")
			then
				hit(hits, order, "cluster-admin", what)
			end
			if kind == "Service" and anyLine(lines, "^%s*type:%s*[\"']?(%a+)") then
				for _, line in lines do
					local t = string.match(line, "^%s*type:%s*[\"']?(%a+)")
					if t == "LoadBalancer" or t == "NodePort" then
						hit(hits, order, "public-service", what)
					end
				end
			end
			if kind == "Ingress" then
				hit(hits, order, "ingress", what)
			end
			if WORKLOADS[kind] and not anyLine(lines, "^%s*limits:") then
				hit(hits, order, "missing-limits", what)
			end
		end
	end
	for _, id in order do
		local rule = MANIFEST_RULES[id]
		add(b, id, rule.severity, rule.tier, rule.text .. ": " .. table.concat(hits[id], ", "), true)
	end
end

local function factReasons(b: Builder, plan: Plan, facts: Facts)
	if facts.previewOk == nil then
		add(b, "preview-pending", "high", "blocked", "The preview has not finished")
	elseif facts.previewOk == false then
		add(b, "preview-failed", "high", "blocked", "The preview failed: " .. (facts.failure or "unknown error"))
	end
	local diff = facts.diff
	if plan.family == "apply" and diff and diff.delete > 0 then
		add(b, "prune-deletes", "high", "typed", string.format("%d object(s) would be deleted", diff.delete))
		for _, seg in diff.segments do
			if seg.action == "delete" and seg.kind == "Namespace" then
				add(
					b,
					"prune-namespace",
					"high",
					"typed",
					"Namespace " .. (seg.name or "?") .. " and everything in it would be deleted"
				)
			end
		end
	end
	local namespaces: { [string]: boolean } = {}
	local count = 0
	for _, r in facts.targets or {} :: { Types.ResourceRef } do
		if r.namespace and not namespaces[r.namespace] then
			namespaces[r.namespace] = true
			count += 1
		end
	end
	if count > 1 then
		if plan.family == "delete" then
			add(b, "multiple-namespaces", "high", "typed", string.format("The objects span %d namespaces", count))
		else
			add(b, "multiple-namespaces", "medium", "simple", string.format("The objects span %d namespaces", count))
		end
	end
	if facts.targets and #facts.targets == 0 and plan.family ~= "apply" then
		add(b, "no-targets", "info", "simple", "Nothing matched: the command will change nothing or fail")
	end
end

-- Names the typed tier asks for: the object's name when exactly one object
-- is affected, `<verb> N resources` for several, and the context otherwise.
local function tokenFor(plan: Plan, facts: Facts): string
	local names: { string } = {}
	if facts.targets and plan.family ~= "apply" then
		for _, r in facts.targets do
			table.insert(names, r.name)
		end
	elseif plan.family == "apply" and facts.diff then
		for _, seg in facts.diff.segments do
			table.insert(names, seg.name or seg.key)
		end
	elseif #plan.resources > 0 and #plan.kinds <= 1 and not plan.selector and not plan.all then
		for _, r in plan.resources do
			table.insert(names, r.name)
		end
	end
	if #names == 1 then
		return names[1]
	elseif #names > 1 then
		return string.format("%s %d resources", VERB_WORD[plan.family], #names)
	end
	return plan.targetContext
end

function M.assess(plan: Plan, facts: Facts): T.Assessment
	local b: Builder = { list = {}, byId = {} }
	factReasons(b, plan, facts)
	argvReasons(b, plan, facts)
	if facts.manifests and (plan.family == "apply") then
		manifestReasons(b, facts.manifests)
	end
	local tier: Tier = "simple"
	for _, r in b.list do
		if TIER_RANK[r.tier] > TIER_RANK[tier] then
			tier = r.tier
		end
	end
	local reasons = table.clone(b.list)
	local index: { [Reason]: number } = {}
	for i, r in b.list do
		index[r] = i
	end
	table.sort(reasons, function(x: Reason, y: Reason): boolean
		local sx, sy = SEVERITY_RANK[x.severity], SEVERITY_RANK[y.severity]
		if sx ~= sy then
			return sx < sy
		end
		return index[x] < index[y]
	end)
	return { tier = tier, reasons = reasons, token = tokenFor(plan, facts) }
end

return M
