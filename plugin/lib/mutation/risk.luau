--!strict
-- Confirmation tier for a plan plus what its preview found. Reasons from the
-- argv and preview facts are certain; manifest scans are text heuristics and
-- are marked advisory: tern-kube never claims policy conformance.
local Diffseg = require("./diffseg")
local Drain = require("./drain")
local HelmTypes = require("../helm/types")
local Kinds = require("../kubectl/kinds")
local Objdiff = require("./objdiff")
local Placeholder = require("../gitops/placeholder")
local RevDiff = require("../helm/revdiff")
local Rollout = require("./rollout")
local T = require("./types")
local Types = require("../model/types")
local Yaml = require("../parse/yaml")

type Plan = T.Plan
type Reason = T.Reason
type Tier = T.Tier

export type EditFacts = {
	-- Identities only one side of the edit has (kubectl refuses renames).
	renamed: { string },
	-- Objects whose live resourceVersion moved since kubectl read them.
	liveChanged: { string },
	-- First line of the server's rejection (edited file or a dry run).
	rejected: string?,
	-- Objects the edit changes.
	changed: number,
}

-- What a helm rollback preview read: the newest revision (history --max 1),
-- the current and target releases, the target's stored chart and hooks,
-- the change between the two stored manifests and the live diff.
export type HelmFacts = {
	latest: HelmTypes.Revision?,
	current: HelmTypes.ReleaseStatus?,
	target: HelmTypes.ReleaseStatus?,
	extras: HelmTypes.Extras?,
	revdiff: RevDiff.Result?,
	live: Diffseg.Summary?,
}

export type Facts = {
	-- nil while the preview is running; false once any step failed.
	previewOk: boolean?,
	failure: string?,
	-- Objects resolved by the `targets` step (delete/scale/restart/debug/...).
	targets: { Types.ResourceRef }?,
	-- -f contents (or `kubectl kustomize` output) as the host read them;
	-- for edit, the edited file.
	manifests: { T.Manifest }?,
	-- edit: the original file; heuristics it already matches are not reported.
	baseline: { T.Manifest }?,
	diff: Diffseg.Summary?,
	-- Decoded `targets` objects (before state).
	live: { any }?,
	-- Before/after object diffs (families without kubectl diff).
	objects: Objdiff.Result?,
	drain: Drain.Facts?,
	undo: { Rollout.UndoTarget }?,
	edit: EditFacts?,
	helm: HelmFacts?,
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
	undo = "undo",
	pause = "pause",
	resume = "resume",
	patch = "patch",
	label = "label",
	annotate = "annotate",
	cordon = "cordon",
	uncordon = "uncordon",
	drain = "drain",
	edit = "edit",
	["helm-rollback"] = "roll back",
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

local function manifestHits(manifests: { T.Manifest }): (Hits, { string })
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
	return hits, order
end

-- Export writes REPLACE_ME for every Secret value; kubectl diff masks both
-- sides, so applying an export as is would silently replace live values.
local function placeholderReasons(b: Builder, manifests: { T.Manifest })
	local parts: { string } = {}
	for _, m in manifests do
		local source = Yaml.lines(m.text)
		for _, doc in Yaml.splitLines(source).docs do
			if doc.kind == "Secret" then
				local keys = Placeholder.textKeys(table.concat(docLines(source, doc), "\n"))
				if #keys > 0 then
					table.insert(
						parts,
						label({ kind = "Secret", namespace = doc.namespace, name = doc.name })
							.. " sets placeholder values ("
							.. table.concat(keys, ", ")
							.. ")"
					)
				end
			end
		end
	end
	if #parts > 0 then
		add(
			b,
			"secret-placeholder",
			"high",
			"typed",
			table.concat(parts, "; ")
				.. ": "
				.. Placeholder.TOKEN
				.. " from a tern-kube export would replace the live values"
		)
	end
end

-- `baseline`: heuristics the original already matches are not reported (edit).
local function manifestReasons(b: Builder, manifests: { T.Manifest }, baseline: { T.Manifest }?)
	local hits, order = manifestHits(manifests)
	local before: Hits = if baseline then (manifestHits(baseline)) else {}
	for _, id in order do
		local fresh: { string } = {}
		for _, what in hits[id] do
			if not (before[id] and table.find(before[id], what)) then
				table.insert(fresh, what)
			end
		end
		if #fresh > 0 then
			local rule = MANIFEST_RULES[id]
			add(b, id, rule.severity, rule.tier, rule.text .. ": " .. table.concat(fresh, ", "), true)
		end
	end
end

-- Per-family facts ---------------------------------------------------------------

local function field(obj: any, ...: string): any
	local v = obj
	for _, k in { ... } do
		if type(v) ~= "table" then
			return nil
		end
		v = v[k]
	end
	return v
end

local function liveObjects(facts: Facts): { any }
	return facts.live or {}
end

local function objectLabel(obj: any): string
	return label({
		kind = field(obj, "kind"),
		namespace = field(obj, "metadata", "namespace"),
		name = field(obj, "metadata", "name"),
	})
end

local function selectorReason(b: Builder, plan: Plan, facts: Facts, word: string)
	local what: string? = nil
	if plan.selector then
		what = "-l " .. plan.selector
	elseif plan.fieldSelector then
		what = "--field-selector " .. (plan.fieldSelector :: string)
	elseif plan.all then
		what = "--all"
	elseif plan.allNamespaces then
		what = "-A"
	end
	if what then
		add(b, "broad-selector", "high", "typed", word .. " every object matching " .. what)
	elseif facts.targets and #facts.targets > 1 then
		add(
			b,
			"multiple-objects",
			"high",
			"typed",
			string.format("%s %d objects at once", word, #(facts.targets :: { Types.ResourceRef }))
		)
	end
end

local function clusterScoped(facts: Facts): { Types.ResourceRef }
	local out: { Types.ResourceRef } = {}
	for _, r in facts.targets or {} :: { Types.ResourceRef } do
		if r.namespace == nil and namespaced(r.kind, r.group) ~= true then
			table.insert(out, r)
		end
	end
	return out
end

local function noChange(b: Builder, facts: Facts)
	local o = facts.objects
	if o and #o.pairs > 0 and #o.summary.segments == 0 then
		add(b, "no-change", "info", "simple", "The server dry run changes nothing")
	end
end

local function images(obj: any): string
	local out: { string } = {}
	for _, c in field(obj, "spec", "template", "spec", "containers") or {} do
		if type(c) == "table" and type(c.image) == "string" then
			table.insert(out, c.image)
		end
	end
	return table.concat(out, ", ")
end

local function undoReasons(b: Builder, plan: Plan, facts: Facts)
	local pairsByKey: { [string]: Objdiff.Pair } = {}
	local pairs_: { Objdiff.Pair } = if facts.objects then facts.objects.pairs else {}
	for _, p in pairs_ do
		pairsByKey[p.key] = p
	end
	local unchanged: { [string]: boolean } = {}
	local unchangedKeys: { string } = if facts.objects then facts.objects.unchanged else {}
	for _, k in unchangedKeys do
		unchanged[k] = true
	end
	local parts: { string } = {}
	for _, u in facts.undo or {} :: { Rollout.UndoTarget } do
		local text = string.format("%s back to revision %d", u.name, u.to)
		local p = pairsByKey[u.key]
		if p then
			local from, to = images(p.before), images(p.after)
			if from ~= to then
				text ..= string.format(" (images %s -> %s)", from, to)
			end
		end
		table.insert(parts, text)
		if unchanged[u.key] then
			add(
				b,
				"undo-noop",
				"info",
				"simple",
				string.format(
					"Revision %d of %s has the current template: kubectl reports it and nothing changes",
					u.to,
					u.name
				)
			)
		end
	end
	add(
		b,
		"undo",
		"high",
		"typed",
		"Rolls the pod template "
			.. (if #parts > 0 then "of " .. table.concat(parts, "; ") else "back")
			.. ": every pod is replaced"
	)
	selectorReason(b, plan, facts, "Rolls back")
end

local function pauseReasons(b: Builder, plan: Plan, facts: Facts)
	local pause = plan.family == "pause"
	for _, obj in liveObjects(facts) do
		local paused = field(obj, "spec", "paused") == true
		local name = objectLabel(obj)
		if pause and paused then
			add(
				b,
				"already-paused",
				"info",
				"simple",
				name .. " is already paused: kubectl will exit 1 and change nothing"
			)
		elseif not pause and not paused then
			add(b, "not-paused", "info", "simple", name .. " is not paused: kubectl will exit 1 and change nothing")
		elseif not pause then
			local gen, observed = field(obj, "metadata", "generation"), field(obj, "status", "observedGeneration")
			if type(gen) == "number" and type(observed) == "number" and gen > observed then
				add(
					b,
					"resume-pending",
					"medium",
					"simple",
					"Resuming starts the rollout of changes made to " .. name .. " while paused"
				)
			end
		end
	end
	selectorReason(b, plan, facts, if pause then "Pauses" else "Resumes")
end

local function restartReasons(b: Builder, facts: Facts)
	for _, obj in liveObjects(facts) do
		if field(obj, "kind") == "Deployment" and field(obj, "spec", "paused") == true then
			add(
				b,
				"restart-paused",
				"medium",
				"simple",
				objectLabel(obj) .. " is paused: kubectl refuses to restart it and exits 1 (run rollout resume first)"
			)
		end
	end
end

local function patchReasons(b: Builder, plan: Plan, facts: Facts)
	if plan.patchType == "json" then
		add(b, "json-patch", "high", "typed", "JSON patch operations can remove or replace any path")
	end
	for _, r in clusterScoped(facts) do
		add(b, "cluster-scoped", "high", "typed", r.kind .. " " .. r.name .. " is cluster-scoped")
	end
	if #plan.filenames > 0 or plan.kustomize then
		add(b, "file-targets", "high", "typed", "Patches every object named in the -f/-k inputs")
	end
	selectorReason(b, plan, facts, "Patches")
	local summary = if facts.objects then facts.objects.summary else nil
	if summary and summary.removed > 0 and summary.added == 0 then
		add(b, "removes-fields", "medium", "simple", "The patch only removes fields")
	end
	local sub = flag(plan, "subresource")
	if sub == "status" or sub == "scale" then
		add(b, "subresource", "info", "simple", "--subresource=" .. sub .. ": controllers overwrite status")
	end
	noChange(b, facts)
end

local SYSTEM_KEY = { "kubernetes%.io/", "k8s%.io/" }
local POD_SECURITY = "pod-security.kubernetes.io/"
local LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration"

local function labelReasons(b: Builder, plan: Plan, facts: Facts)
	local word = if plan.family == "label" then "Labels" else "Annotates"
	local field_ = if plan.family == "label" then "labels" else "annotations"
	selectorReason(b, plan, facts, word)
	local targetKinds: { [string]: boolean } = {}
	for _, r in facts.targets or {} :: { Types.ResourceRef } do
		targetKinds[r.kind] = true
	end
	for _, k in plan.kinds do
		targetKinds[k.kind] = true
	end
	for _, r in clusterScoped(facts) do
		local text = if r.kind == "Node"
			then "Node " .. r.name .. ": node labels steer scheduling and topology"
			elseif r.kind == "Namespace" then "Namespace " .. r.name .. ": namespace labels select policies"
			else r.kind .. " " .. r.name .. " is cluster-scoped"
		add(b, "cluster-scoped", "high", "typed", text)
	end
	local removals: { string } = {}
	local system: { string } = {}
	for _, e in plan.edits do
		if e.remove then
			table.insert(removals, e.key)
		end
		if plan.family == "label" and targetKinds.Namespace and string.sub(e.key, 1, #POD_SECURITY) == POD_SECURITY then
			add(b, "pod-security", "high", "typed", e.key .. " changes Pod Security admission for every pod in it")
		end
		if plan.family == "annotate" and e.key == LAST_APPLIED then
			add(
				b,
				"last-applied",
				"high",
				"typed",
				"Rewrites the last-applied configuration kubectl apply diffs against"
			)
		end
		for _, pattern in SYSTEM_KEY do
			if string.find(e.key, pattern) and not table.find(system, e.key) then
				table.insert(system, e.key)
			end
		end
	end
	if #system > 0 then
		add(b, "system-keys", "medium", "simple", "System-managed keys: " .. table.concat(system, ", "))
	end
	local overwrites = 0
	local ownedPodChange = false
	local objectPairs: { Objdiff.Pair } = if facts.objects then facts.objects.pairs else {}
	for _, p in objectPairs do
		local before = field(p.before, "metadata", field_) or {}
		local after = field(p.after, "metadata", field_) or {}
		local changed = false
		for k, v in before do
			if after[k] ~= v then
				changed = true
				if after[k] ~= nil then
					overwrites += 1
				end
			end
		end
		local owners = field(p.before, "metadata", "ownerReferences")
		if changed and field(p.before, "kind") == "Pod" and type(owners) == "table" and #owners > 0 then
			ownedPodChange = true
		end
	end
	if overwrites > 0 then
		add(b, "overwrites", "medium", "simple", string.format("%d existing value(s) change", overwrites))
	end
	if plan.family == "label" and ownedPodChange then
		add(
			b,
			"pod-owner-labels",
			"medium",
			"simple",
			"Changing labels of a pod with an owner may detach it from its ReplicaSet or Service selector; "
				.. "the controller then creates a replacement",
			true
		)
	end
	if #removals > 0 then
		add(b, "removals", "info", "simple", "Removes " .. table.concat(removals, ", "))
	end
	noChange(b, facts)
end

local CONTROL_PLANE = "node-role.kubernetes.io/control-plane"

local function controlPlane(facts: Facts): { string }
	local out: { string } = {}
	for _, obj in liveObjects(facts) do
		local labels = field(obj, "metadata", "labels")
		if type(labels) == "table" and labels[CONTROL_PLANE] ~= nil then
			table.insert(out, tostring(field(obj, "metadata", "name")))
		end
	end
	return out
end

local function cordonReasons(b: Builder, plan: Plan, facts: Facts)
	local cordon = plan.family == "cordon"
	selectorReason(b, plan, facts, if cordon then "Cordons" else "Uncordons")
	for _, obj in liveObjects(facts) do
		local off = field(obj, "spec", "unschedulable") == true
		local name = tostring(field(obj, "metadata", "name"))
		if cordon and off then
			add(b, "already-cordoned", "info", "simple", "Node " .. name .. " is already cordoned")
		elseif not cordon and not off then
			add(b, "already-uncordoned", "info", "simple", "Node " .. name .. " is already schedulable")
		end
	end
	local cp = controlPlane(facts)
	if #cp > 0 then
		add(b, "control-plane", "medium", "simple", "Control-plane node: " .. table.concat(cp, ", "))
	end
end

local PREFLIGHT_TEXT: { [Drain.Category]: string } = {
	unmanaged = "pods that declare no controller",
	daemonset = "DaemonSet-managed pods",
	["local-storage"] = "pods with local storage",
	other = "pods kubectl refuses to evict",
}

local function podCount(n: number): string
	return string.format("%d pod%s", n, if n == 1 then "" else "s")
end

local function drainReasons(b: Builder, plan: Plan, facts: Facts)
	local d = facts.drain
	local opts = plan.drain
	local nodes: { string } = {}
	for _, r in facts.targets or {} :: { Types.ResourceRef } do
		table.insert(nodes, r.name)
	end
	local nodeText = if #nodes > 0 then table.concat(nodes, ", ") else "the selected nodes"
	if d then
		local namespaces: { [string]: boolean } = {}
		local nsCount = 0
		for _, p in d.evictions do
			if not namespaces[p.namespace] then
				namespaces[p.namespace] = true
				nsCount += 1
			end
		end
		add(
			b,
			"drain",
			"high",
			"typed",
			string.format(
				"Evicts %s from node %s across %d namespace%s; the node stays cordoned",
				podCount(#d.evictions),
				nodeText,
				nsCount,
				if nsCount == 1 then "" else "s"
			)
		)
		if #d.pdbBlocked > 0 then
			add(
				b,
				"pdb-blocked",
				"high",
				"typed",
				string.format(
					"PodDisruptionBudget blocks eviction of %s now: drain cordons the node and retries until --timeout (%s)",
					podCount(#d.pdbBlocked),
					if opts and opts.timeout then opts.timeout :: string else "none: forever"
				)
			)
		end
		if opts and opts.force and #d.unmanaged > 0 then
			add(
				b,
				"force-unmanaged",
				"high",
				"typed",
				podCount(#d.unmanaged) .. " without a controller are deleted and never recreated"
			)
		end
		if opts and opts.deleteEmptyDir then
			add(b, "emptydir-loss", "high", "typed", "emptyDir data of evicted pods is lost (--delete-emptydir-data)")
		end
	else
		add(b, "drain", "high", "typed", "Evicts the pods of node " .. nodeText .. "; the node stays cordoned")
	end
	if opts and opts.disableEviction then
		add(b, "disable-eviction", "high", "typed", "Deletes pods directly, bypassing PodDisruptionBudgets")
	end
	if opts and opts.gracePeriod == 0 then
		add(b, "grace-period-zero", "high", "typed", "--grace-period=0 skips graceful termination")
	end
	if opts and opts.timeout == nil then
		add(b, "no-timeout", "medium", "simple", "No --timeout: a blocked eviction keeps drain retrying forever")
	end
	local cp = controlPlane(facts)
	if #cp > 0 then
		add(b, "control-plane", "high", "typed", "Control-plane node: " .. table.concat(cp, ", "))
	end
end

local SENSITIVE_KINDS = {
	Role = true,
	ClusterRole = true,
	RoleBinding = true,
	ClusterRoleBinding = true,
	MutatingWebhookConfiguration = true,
	ValidatingWebhookConfiguration = true,
	ValidatingAdmissionPolicy = true,
	ValidatingAdmissionPolicyBinding = true,
	CustomResourceDefinition = true,
	Namespace = true,
}

local function editReasons(b: Builder, plan: Plan, facts: Facts)
	local e = facts.edit
	if e then
		if #e.renamed > 0 then
			add(
				b,
				"edit-renamed",
				"high",
				"blocked",
				"The edit changes the apiVersion, kind or name of "
					.. table.concat(e.renamed, ", ")
					.. ": kubectl refuses that; deny and edit again"
			)
		end
		if e.rejected then
			add(
				b,
				"edit-rejected",
				"high",
				"simple",
				"The server rejects this edit: "
					.. (e.rejected :: string)
					.. ". Approve to let kubectl reopen the editor with the error; deny discards it (a copy is saved)."
			)
		end
		if #e.liveChanged > 0 then
			add(
				b,
				"live-changed",
				"medium",
				"simple",
				"Changed since kubectl read it: "
					.. table.concat(e.liveChanged, ", ")
					.. "; the diff is against the live object",
				true
			)
		end
		if e.changed > 1 then
			add(b, "multiple-objects", "high", "typed", string.format("The edit changes %d objects", e.changed))
		end
	end
	for _, r in facts.targets or {} :: { Types.ResourceRef } do
		if SENSITIVE_KINDS[r.kind] then
			add(b, "sensitive-kind", "high", "typed", r.kind .. " " .. r.name .. " controls access or the API itself")
		end
	end
	for _, r in clusterScoped(facts) do
		add(b, "cluster-scoped", "high", "typed", r.kind .. " " .. r.name .. " is cluster-scoped")
	end
	if truthy(plan, "save-config") then
		add(b, "save-config", "info", "simple", "--save-config also rewrites last-applied, which is not previewed")
	end
	if facts.manifests then
		manifestReasons(b, facts.manifests :: { T.Manifest }, facts.baseline or {})
	end
end

local function chartText(name: string?, version: string?, app: string?): string
	return (name or "?")
		.. (if version then "-" .. version else "")
		.. (if app and app ~= "" then " (app " .. app .. ")" else "")
end

local function segId(seg: Diffseg.Segment): string
	return (seg.kind or "?") .. "/" .. (seg.namespace or "") .. "/" .. (seg.name or seg.key)
end

-- Facts from the argv alone: always shown, also before the preview ends.
local function helmArgvReasons(b: Builder, plan: Plan, facts: Facts)
	local h = plan.helm :: T.HelmRollback
	local latest = if facts.helm then facts.helm.latest else nil
	add(
		b,
		"helm-rollback",
		"medium",
		"typed",
		string.format(
			"Rolls %s back from revision %s to %d",
			h.release,
			if latest then tostring(latest.revision) else "?",
			h.revision
		)
	)
	if h.options.force then
		add(b, "helm-force", "high", "typed", "--force deletes and re-creates objects that cannot be patched")
	end
	if not h.options.wait then
		add(b, "helm-no-wait", "info", "simple", "Without --wait helm reports success before the pods are ready")
	end
	if h.options.noHooks then
		add(b, "helm-hooks", "low", "simple", "--no-hooks: the chart's rollback hooks are skipped")
	end
end

local function helmReasons(b: Builder, plan: Plan, facts: Facts)
	local h = plan.helm :: T.HelmRollback
	local f = facts.helm
	if f == nil then
		return
	end
	local latest = f.latest
	if latest then
		if string.sub(latest.status, 1, 8) == "pending-" then
			add(
				b,
				"helm-pending",
				"high",
				"typed",
				string.format(
					"Revision %d is %s (since %s): if another helm process still runs, the rollback races it; "
						.. "a rollback is also how a stuck release recovers",
					latest.revision,
					latest.status,
					latest.updated
				)
			)
		elseif latest.status == "uninstalled" then
			add(b, "helm-uninstalled", "medium", "typed", "The release is uninstalled: the rollback reinstalls it")
		end
		if latest.revision == h.revision then
			add(
				b,
				"helm-same",
				"info",
				"simple",
				string.format("Revision %d is the latest: the rollback re-applies it (repairs drift)", h.revision)
			)
		end
	end
	local target = f.target
	if target and target.info.status == "failed" then
		add(
			b,
			"helm-target-failed",
			"medium",
			"typed",
			string.format("Revision %d failed when it was deployed: %s", h.revision, target.info.description)
		)
	end
	local rd = f.revdiff
	if rd then
		local s = rd.summary
		if s.delete > 0 then
			add(
				b,
				"helm-deletes",
				"high",
				"typed",
				string.format(
					"%d object(s) of the current revision are not in revision %d: helm deletes them",
					s.delete,
					h.revision
				)
			)
		end
		for _, seg in s.segments do
			if seg.kind == "Secret" then
				add(b, "helm-secrets", "low", "simple", "Secret objects change (values masked)")
			end
		end
	end
	local x = f.extras
	if x and not h.options.noHooks then
		local names: { string } = {}
		for _, hook in x.hooks do
			for _, ev in hook.events do
				if ev == "pre-rollback" or ev == "post-rollback" then
					table.insert(names, hook.kind .. "/" .. hook.name .. " (" .. ev .. ")")
				end
			end
		end
		if #names > 0 then
			add(b, "helm-hooks", "info", "simple", "Rollback hooks run: " .. table.concat(names, ", "))
		end
	end
	if x and latest then
		local from = chartText(latest.chartName, latest.chartVersion, latest.appVersion)
		local to = chartText(x.chart.name, x.chart.version, x.chart.appVersion)
		if from ~= to then
			add(b, "helm-chart-change", "info", "simple", "Chart " .. from .. " → " .. to)
		end
	end
	local live = f.live
	if live and rd then
		local recorded: { [string]: boolean } = {}
		for _, seg in rd.summary.segments do
			recorded[segId(seg)] = true
		end
		local outside: { string } = {}
		for _, seg in live.segments do
			if not recorded[segId(seg)] then
				table.insert(outside, (seg.kind or "?") .. " " .. (seg.name or seg.key))
			end
		end
		if #outside > 0 then
			add(
				b,
				"helm-live-drift",
				"low",
				"simple",
				"Live objects differ from the revision where helm's records do not: "
					.. table.concat(outside, ", ")
					.. " (edited outside helm; the rollback overwrites them)",
				true
			)
		end
	end
end

local function familyReasons(b: Builder, plan: Plan, facts: Facts)
	local f = plan.family
	if f == "undo" then
		undoReasons(b, plan, facts)
	elseif f == "pause" or f == "resume" then
		pauseReasons(b, plan, facts)
	elseif f == "restart" then
		restartReasons(b, facts)
	elseif f == "patch" then
		patchReasons(b, plan, facts)
	elseif f == "label" or f == "annotate" then
		labelReasons(b, plan, facts)
	elseif f == "cordon" or f == "uncordon" then
		cordonReasons(b, plan, facts)
	elseif f == "drain" then
		drainReasons(b, plan, facts)
	elseif f == "edit" then
		editReasons(b, plan, facts)
	elseif f == "helm-rollback" then
		helmReasons(b, plan, facts)
	end
end

local function preflightText(d: Drain.Facts): string?
	local parts: { string } = {}
	for _, p in d.preflight do
		local text = PREFLIGHT_TEXT[p.category] .. " (" .. podCount(#p.pods) .. ")"
		if p.flag then
			text ..= " (use " .. (p.flag :: string) .. ")"
		end
		table.insert(parts, text)
	end
	return if #parts > 0 then table.concat(parts, "; ") else nil
end

local function factReasons(b: Builder, plan: Plan, facts: Facts)
	if facts.previewOk == nil then
		add(b, "preview-pending", "high", "blocked", "The preview has not finished")
	elseif facts.previewOk == false then
		local pre = if facts.drain then preflightText(facts.drain :: Drain.Facts) else nil
		add(
			b,
			"preview-failed",
			"high",
			"blocked",
			if pre
				then "kubectl would cordon the node, then stop: " .. pre
				else "The preview failed: " .. (facts.failure or "unknown error")
		)
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
-- is affected, `<verb> N resources` for several, the release for a helm
-- rollback, and the context otherwise.
local function tokenFor(plan: Plan, facts: Facts): string
	if plan.helm then
		return (plan.helm :: T.HelmRollback).release
	end
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
	if plan.helm then
		helmArgvReasons(b, plan, facts)
	end
	if facts.manifests and (plan.family == "apply") then
		manifestReasons(b, facts.manifests :: { T.Manifest }, nil)
		placeholderReasons(b, facts.manifests :: { T.Manifest })
	end
	if facts.previewOk ~= nil then
		familyReasons(b, plan, facts)
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
