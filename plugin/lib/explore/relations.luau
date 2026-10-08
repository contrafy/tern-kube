--!strict
-- Relationship discovery for Explore. Pure: callers run the queries.
--
--   queriesFor(obj, opts)          what to fetch to relate one object
--   pending(root, results, opts)   queries a build to maxDepth still needs
--   build(root, results, opts)     graph over the fetched results
--
-- Host loop: repeat { run pending(...) and merge into results } until pending
-- is empty, then build. results[q.key] = {items = {decoded objects}} (a
-- single `get NAME` wraps the object; queries with `name` should run with
-- --ignore-not-found so absence is {items = {}}); a failed query may be
-- recorded as {items = {}, error = "message"}. Queries with nameOnly = true
-- must run with `-o name` (Secrets: values are never fetched) and be fed back
-- through itemsFromNames.
--
-- RelQuery.namespace = nil means a cluster-scoped kind, never all namespaces.

local Resource = require("../model/resource")
local Kinds = require("../kubectl/kinds")
local Selector = require("./selector")
local Types = require("../model/types")

type Ref = Types.ResourceRef

export type Provenance =
	"root"
	| "ownerReference"
	| "selector (heuristic)"
	| "endpointslice"
	| "endpoint targetRef"
	| "spec reference"
	| "node binding"

export type RelQuery = {
	key: string,
	kind: string,
	namespace: string?,
	selector: string?,
	fieldSelector: string?,
	name: string?,
	nameOnly: boolean,
	reason: string,
	provenance: Provenance,
}

export type QueryResult = { items: { any }, error: string? }
export type Results = { [string]: QueryResult }

export type GraphNode = {
	key: string,
	ref: Ref,
	provenance: Provenance,
	depth: number,
	summary: string,
	parent: string?,
	relation: string?,
	missing: boolean,
}

export type GraphEdge = { from: string, to: string, relation: string, provenance: Provenance }

export type Graph = {
	nodes: { GraphNode },
	edges: { GraphEdge },
	truncated: boolean,
	notes: { string },
}

export type Options = {
	maxNodes: number?,
	maxDepth: number?,
	fanOut: number?,
	childKinds: { string }?,
}

type Direction = "up" | "down" | "ref"

type Link = {
	query: RelQuery,
	relation: string,
	direction: Direction,
	match: (item: any) -> boolean,
	-- Name references: expected names become "missing" nodes when absent.
	names: { string }?,
	missingKind: string?,
	missingGroup: string?,
}

local DEFAULT_MAX_NODES = 250
local DEFAULT_MAX_DEPTH = 2
local DEFAULT_FAN_OUT = 50

local STRENGTH: { [Provenance]: number } = {
	root = 9,
	["endpoint targetRef"] = 5,
	ownerReference = 4,
	["node binding"] = 4,
	["spec reference"] = 3,
	endpointslice = 3,
	["selector (heuristic)"] = 1,
}

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function tbl(v: any): { [any]: any }?
	if type(v) == "table" then
		return v
	end
	return nil
end

local function list(v: any): { any }
	if type(v) == "table" then
		return v
	end
	return {}
end

local EMPTY: { [any]: any } = table.freeze({})

local function fields(v: any): { [any]: any }
	if type(v) == "table" then
		return v
	end
	return EMPTY
end

local function meta(obj: any): { [string]: any }
	return fields(fields(obj).metadata)
end

local function queryKey(q: {
	kind: string,
	namespace: string?,
	name: string?,
	selector: string?,
	fieldSelector: string?,
	nameOnly: boolean,
}): string
	return table.concat({
		q.kind,
		q.namespace or "",
		q.name or "",
		q.selector or "",
		q.fieldSelector or "",
		if q.nameOnly then "name" else "json",
	}, "|")
end

local function query(
	kind: string,
	namespace: string?,
	target: { name: string?, selector: string?, nameOnly: boolean? },
	reason: string,
	provenance: Provenance
): RelQuery
	local q = {
		key = "",
		kind = kind,
		namespace = namespace,
		selector = target.selector,
		fieldSelector = nil,
		name = target.name,
		nameOnly = target.nameOnly == true,
		reason = reason,
		provenance = provenance,
	}
	q.key = queryKey(q)
	return q
end

-- kubectl resource token for a Kind + group: plural when known, else the
-- lowercased Kind qualified by group (kubectl resolves both).
local function kindToken(kind: string, group: string?): (string, boolean)
	local info = Kinds.normalize(if group then kind .. "." .. group else kind)
	if info.known then
		local token = if info.group then info.plural .. "." .. info.group else info.plural
		return token, info.namespaced ~= false
	end
	local lowered = string.lower(kind)
	return if group then lowered .. "." .. group else lowered, true
end

local function hasOwnerUid(item: any, uid: string): boolean
	for _, ref in list(meta(item).ownerReferences) do
		if type(ref) == "table" and ref.uid == uid then
			return true
		end
	end
	return false
end

local function nameIn(names: { [string]: boolean }): (any) -> boolean
	return function(item: any): boolean
		local name = str(meta(item).name)
		return name ~= nil and names[name] == true
	end
end

local function sortedNames(set: { [string]: boolean }): { string }
	local out: { string } = {}
	for name in set do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

local function ownerLinks(obj: any, ns: string?, out: { Link })
	local selfUid = str(meta(obj).uid)
	for _, owner in list(meta(obj).ownerReferences) do
		local kind, name = str(tbl(owner) and owner.kind), str(tbl(owner) and owner.name)
		if kind and name then
			local group = Resource.splitApiVersion(owner.apiVersion)
			local token, namespaced = kindToken(kind, group)
			local uid = str(owner.uid)
			local match = function(item: any): boolean
				local m = meta(item)
				if uid and m.uid then
					return m.uid == uid
				end
				return m.name == name
			end
			if uid == nil or uid ~= selfUid then
				table.insert(out, {
					query = query(
						token,
						if namespaced then ns else nil,
						{ name = name },
						"owner " .. kind .. "/" .. name,
						"ownerReference"
					),
					relation = "owns",
					direction = "up",
					match = match,
					names = { name },
					missingKind = kind,
					missingGroup = group,
				})
			else
				-- Self-ownership: kept so build can report the cycle.
				table.insert(out, {
					query = query(
						token,
						if namespaced then ns else nil,
						{ name = name },
						"self owner",
						"ownerReference"
					),
					relation = "owns",
					direction = "up",
					match = match,
				})
			end
		end
	end
end

local CHILDREN: { [string]: { string } } = {
	Deployment = { "replicasets.apps" },
	ReplicaSet = { "pods" },
	ReplicationController = { "pods" },
	StatefulSet = { "pods" },
	DaemonSet = { "pods" },
	Job = { "pods" },
	CronJob = { "jobs.batch" },
}

local function childLinks(obj: any, ns: string?, opts: Options, out: { Link })
	local uid = str(meta(obj).uid)
	if uid == nil then
		return
	end
	local kind = obj.kind
	local candidates = CHILDREN[kind]
	local narrowing: string? = nil
	if candidates then
		-- The workload selector narrows the list; ownership (uid) decides.
		local sel = Selector.fromLabelSelector(tbl(obj.spec) and obj.spec.selector)
		if sel and #sel.requirements > 0 then
			narrowing = Selector.format(sel)
		end
	else
		candidates = opts.childKinds or {}
	end
	local ownerUid: string = uid
	for _, token in candidates :: { string } do
		table.insert(out, {
			query = query(token, ns, { selector = narrowing }, "owned by " .. kind, "ownerReference"),
			relation = "owns",
			direction = "down",
			match = function(item: any): boolean
				return hasOwnerUid(item, ownerUid)
			end,
		})
	end
end

local function nameRefLink(
	kind: string,
	token: string,
	namespace: string?,
	name: string,
	relation: string,
	provenance: Provenance,
	nameOnly: boolean
): Link
	return {
		query = query(token, namespace, { name = name, nameOnly = nameOnly }, relation .. " " .. name, provenance),
		relation = relation,
		direction = "ref",
		match = nameIn({ [name] = true }),
		names = { name },
		missingKind = kind,
	}
end

local function serviceLinks(obj: any, ns: string?, out: { Link })
	local spec = fields(obj.spec)
	local name = str(meta(obj).name)
	local map = tbl(spec.selector)
	if map and next(map) ~= nil and spec.type ~= "ExternalName" then
		local selectorMap: { [any]: any } = map
		table.insert(out, {
			query = query(
				"pods",
				ns,
				{ selector = Selector.format(Selector.fromMap(map)) },
				"selected by service",
				"selector (heuristic)"
			),
			relation = "selects",
			direction = "down",
			match = function(item: any): boolean
				return Selector.matchesMap(selectorMap, meta(item).labels)
			end,
		})
	end
	if name then
		local serviceName: string = name
		table.insert(out, {
			query = query(
				"endpointslices.discovery.k8s.io",
				ns,
				{ selector = "kubernetes.io/service-name=" .. name },
				"endpoint slices of service",
				"endpointslice"
			),
			relation = "endpoints",
			direction = "down",
			match = function(item: any): boolean
				local labels = tbl(meta(item).labels)
				return labels ~= nil and labels["kubernetes.io/service-name"] == serviceName
			end,
		})
	end
end

local function endpointSliceLinks(obj: any, ns: string?, out: { Link })
	local names: { [string]: boolean } = {}
	local uids: { [string]: string } = {}
	for _, endpoint in list(obj.endpoints) do
		local target = tbl(tbl(endpoint) and endpoint.targetRef)
		if target and target.kind == "Pod" then
			local name = str(target.name)
			if name and (target.namespace == nil or target.namespace == ns) then
				names[name] = true
				local uid = str(target.uid)
				if uid then
					uids[name] = uid
				end
			end
		end
	end
	if next(names) == nil then
		return
	end
	local byName = nameIn(names)
	table.insert(out, {
		query = query("pods", ns, {}, "endpoint targets", "endpoint targetRef"),
		relation = "targets",
		direction = "down",
		match = function(item: any): boolean
			if not byName(item) then
				return false
			end
			local m = meta(item)
			local want = uids[m.name]
			return want == nil or m.uid == nil or m.uid == want
		end,
		names = sortedNames(names),
		missingKind = "Pod",
	})
end

local function ingressLinks(obj: any, ns: string?, out: { Link })
	local spec = fields(obj.spec)
	local services: { [string]: boolean } = {}
	local function backend(b: any)
		local svc = tbl(tbl(b) and b.service)
		local name = str(svc and svc.name)
		if name then
			services[name] = true
		end
	end
	backend(spec.defaultBackend)
	for _, rule in list(spec.rules) do
		local http = tbl(tbl(rule) and rule.http)
		for _, path in list(http and http.paths) do
			backend(tbl(path) and path.backend)
		end
	end
	for _, name in sortedNames(services) do
		table.insert(out, nameRefLink("Service", "services", ns, name, "routes to", "spec reference", false))
	end
	local secrets: { [string]: boolean } = {}
	for _, tls in list(spec.tls) do
		local name = str(tbl(tls) and tls.secretName)
		if name then
			secrets[name] = true
		end
	end
	for _, name in sortedNames(secrets) do
		table.insert(out, nameRefLink("Secret", "secrets", ns, name, "tls", "spec reference", true))
	end
end

type PodRefs = {
	configMaps: { [string]: boolean },
	secrets: { [string]: boolean },
	claims: { [string]: boolean },
}

local function collectEnv(container: any, refs: PodRefs)
	for _, env in list(tbl(container) and container.env) do
		local from = tbl(tbl(env) and env.valueFrom)
		if from then
			local cm = str(tbl(from.configMapKeyRef) and from.configMapKeyRef.name)
			local sec = str(tbl(from.secretKeyRef) and from.secretKeyRef.name)
			if cm then
				refs.configMaps[cm] = true
			end
			if sec then
				refs.secrets[sec] = true
			end
		end
	end
	for _, src in list(tbl(container) and container.envFrom) do
		local cm = str(tbl(tbl(src) and src.configMapRef) and src.configMapRef.name)
		local sec = str(tbl(tbl(src) and src.secretRef) and src.secretRef.name)
		if cm then
			refs.configMaps[cm] = true
		end
		if sec then
			refs.secrets[sec] = true
		end
	end
end

local function podRefs(spec: { [string]: any }): PodRefs
	local refs: PodRefs = { configMaps = {}, secrets = {}, claims = {} }
	for _, volume in list(spec.volumes) do
		local v = fields(volume)
		local cm = str(tbl(v.configMap) and v.configMap.name)
		local sec = str(tbl(v.secret) and v.secret.secretName)
		local claim = str(tbl(v.persistentVolumeClaim) and v.persistentVolumeClaim.claimName)
		if cm then
			refs.configMaps[cm] = true
		end
		if sec then
			refs.secrets[sec] = true
		end
		if claim then
			refs.claims[claim] = true
		end
		for _, source in list(tbl(v.projected) and v.projected.sources) do
			local s = fields(source)
			local pcm = str(tbl(s.configMap) and s.configMap.name)
			local psec = str(tbl(s.secret) and s.secret.name)
			if pcm then
				refs.configMaps[pcm] = true
			end
			if psec then
				refs.secrets[psec] = true
			end
		end
	end
	for _, field in { "initContainers", "containers", "ephemeralContainers" } do
		for _, container in list(spec[field]) do
			collectEnv(container, refs)
		end
	end
	for _, pull in list(spec.imagePullSecrets) do
		local name = str(tbl(pull) and pull.name)
		if name then
			refs.secrets[name] = true
		end
	end
	return refs
end

local function podLinks(obj: any, ns: string?, out: { Link })
	local spec = fields(obj.spec)
	local node = str(spec.nodeName)
	if node then
		table.insert(out, nameRefLink("Node", "nodes", nil, node, "runs on", "node binding", false))
	end
	local refs = podRefs(spec)
	for _, name in sortedNames(refs.configMaps) do
		table.insert(out, nameRefLink("ConfigMap", "configmaps", ns, name, "uses config", "spec reference", false))
	end
	for _, name in sortedNames(refs.secrets) do
		table.insert(out, nameRefLink("Secret", "secrets", ns, name, "uses secret", "spec reference", true))
	end
	for _, name in sortedNames(refs.claims) do
		table.insert(
			out,
			nameRefLink("PersistentVolumeClaim", "persistentvolumeclaims", ns, name, "mounts", "spec reference", false)
		)
	end
	local account = str(spec.serviceAccountName) or str(spec.serviceAccount)
	if account then
		table.insert(
			out,
			nameRefLink("ServiceAccount", "serviceaccounts", ns, account, "runs as", "spec reference", false)
		)
	end
end

local function links(obj: any, opts: Options): { Link }
	local out: { Link } = {}
	if type(obj) ~= "table" or type(obj.kind) ~= "string" then
		return out
	end
	local ns = str(meta(obj).namespace)
	ownerLinks(obj, ns, out)
	childLinks(obj, ns, opts, out)
	local kind = obj.kind
	if kind == "Service" then
		serviceLinks(obj, ns, out)
	elseif kind == "EndpointSlice" then
		endpointSliceLinks(obj, ns, out)
	elseif kind == "Ingress" then
		ingressLinks(obj, ns, out)
	elseif kind == "Pod" then
		podLinks(obj, ns, out)
	end
	return out
end

local function conditionTrue(obj: any, condType: string): boolean?
	for _, c in list(tbl(obj.status) and obj.status.conditions) do
		if type(c) == "table" and c.type == condType then
			return c.status == "True"
		end
	end
	return nil
end

local function num(v: any): number
	return if type(v) == "number" then v else 0
end

local function podSummary(obj: any): string
	local status = fields(obj.status)
	if str(meta(obj).deletionTimestamp) then
		return "Terminating"
	end
	local total, ready = 0, 0
	local reason: string? = nil
	for _, cs in list(status.containerStatuses) do
		if type(cs) == "table" then
			total += 1
			if cs.ready == true then
				ready += 1
			end
			local state = fields(cs.state)
			reason = reason
				or str(tbl(state.waiting) and state.waiting.reason)
				or str(tbl(state.terminated) and state.terminated.reason)
		end
	end
	if total == 0 then
		total = #list(tbl(obj.spec) and obj.spec.containers)
	end
	local phase = str(status.phase) or "Unknown"
	if reason == nil and phase == "Pending" then
		for _, c in list(status.conditions) do
			if type(c) == "table" and c.type == "PodScheduled" and c.status == "False" then
				reason = str(c.reason)
			end
		end
		if reason then
			return string.format("Pending: %s %d/%d", reason, ready, total)
		end
	end
	return string.format("%s %d/%d", reason or phase, ready, total)
end

local function summarize(obj: any): string
	local kind = obj.kind
	local spec = fields(obj.spec)
	local status = fields(obj.status)
	if kind == "Pod" then
		return podSummary(obj)
	elseif kind == "Deployment" or kind == "ReplicaSet" or kind == "StatefulSet" then
		local desired = if type(spec.replicas) == "number" then spec.replicas else 1
		return string.format("ready %d/%d", num(status.readyReplicas), desired)
	elseif kind == "DaemonSet" then
		return string.format("ready %d/%d", num(status.numberReady), num(status.desiredNumberScheduled))
	elseif kind == "Job" then
		if conditionTrue(obj, "Complete") then
			return "Complete"
		elseif conditionTrue(obj, "Failed") then
			return "Failed"
		end
		return string.format("Running %d active", num(status.active))
	elseif kind == "CronJob" then
		local text = "schedule " .. (str(spec.schedule) or "?")
		if spec.suspend == true then
			text ..= ", suspended"
		end
		return text
	elseif kind == "Service" then
		local svcType = str(spec.type) or "ClusterIP"
		if svcType == "ExternalName" then
			return "ExternalName " .. (str(spec.externalName) or "")
		end
		local ip = str(spec.clusterIP)
		return if ip and ip ~= "None"
			then svcType .. " " .. ip
			else svcType .. (if ip == "None" then " headless" else "")
	elseif kind == "EndpointSlice" then
		local total, ready = 0, 0
		for _, e in list(obj.endpoints) do
			if type(e) == "table" then
				total += 1
				if tbl(e.conditions) == nil or e.conditions.ready ~= false then
					ready += 1
				end
			end
		end
		return string.format("%d/%d ready", ready, total)
	elseif kind == "Ingress" then
		local hosts: { string } = {}
		for _, rule in list(spec.rules) do
			local host = str(tbl(rule) and rule.host)
			if host then
				table.insert(hosts, host)
			end
		end
		return if #hosts > 0 then table.concat(hosts, ", ") else "*"
	elseif kind == "Node" then
		local ready = conditionTrue(obj, "Ready")
		return if ready == nil then "Unknown" elseif ready then "Ready" else "NotReady"
	elseif kind == "ConfigMap" then
		local n = 0
		for _, field in { "data", "binaryData" } do
			for _ in fields(obj[field]) do
				n += 1
			end
		end
		return string.format("%d keys", n)
	elseif kind == "Secret" then
		return "reference only"
	end
	local phase = str(status.phase)
	if phase then
		return phase
	end
	local ready = conditionTrue(obj, "Ready")
	return if ready == nil then "" elseif ready then "Ready" else "NotReady"
end

local function refOf(item: any): Ref?
	if type(item) ~= "table" then
		return nil
	end
	return Resource.fromObject(item, "live")
end

type Record = { node: GraphNode, obj: any, direction: Direction | "root" }
type Candidate = { key: string, ref: Ref, obj: any, missing: boolean, summary: string }

local function traverse(root: any, results: Results, opts: Options?, wanted: { RelQuery }?): Graph
	local o: Options = opts or {}
	local maxNodes = o.maxNodes or DEFAULT_MAX_NODES
	local maxDepth = o.maxDepth or DEFAULT_MAX_DEPTH
	local fanOut = o.fanOut or DEFAULT_FAN_OUT

	local graph: Graph = { nodes = {}, edges = {}, truncated = false, notes = {} }
	local byKey: { [string]: Record } = {}
	local byUid: { [string]: string } = {}
	local edgeSeen: { [string]: boolean } = {}
	local wantedSeen: { [string]: boolean } = {}
	local noteSeen: { [string]: boolean } = {}
	local budgetHit = false

	local function note(text: string)
		if not noteSeen[text] then
			noteSeen[text] = true
			table.insert(graph.notes, text)
		end
	end

	local function addEdge(from: string, to: string, relation: string, provenance: Provenance)
		local id = from .. "\0" .. to .. "\0" .. relation
		if edgeSeen[id] then
			return
		end
		edgeSeen[id] = true
		table.insert(graph.edges, { from = from, to = to, relation = relation, provenance = provenance })
	end

	local rootRef = refOf(root)
	if rootRef == nil then
		note("root object has no kind/name")
		return graph
	end
	local rootKey = Resource.key(rootRef)
	local rootRecord: Record = {
		node = {
			key = rootKey,
			ref = rootRef,
			provenance = "root",
			depth = 0,
			summary = summarize(root),
			parent = nil,
			relation = nil,
			missing = false,
		},
		obj = root,
		direction = "root",
	}
	table.insert(graph.nodes, rootRecord.node)
	byKey[rootKey] = rootRecord
	if rootRef.uid then
		byUid[rootRef.uid] = rootKey
	end

	local function isAncestor(key: string, of: Record): boolean
		local cursor: string? = of.node.parent
		while cursor do
			if cursor == key then
				return true
			end
			cursor = byKey[cursor].node.parent
		end
		return false
	end

	local queue: { Record } = { rootRecord }
	local head = 1
	while head <= #queue and not budgetHit do
		local current = queue[head]
		head += 1
		if current.node.depth >= maxDepth or current.obj == nil then
			continue
		end
		local currentKey = current.node.key
		local qualified = Resource.qualifiedId(current.node.ref)
		for _, link in links(current.obj, o) do
			if budgetHit then
				break
			end
			if current.direction == "up" and link.direction ~= "up" then
				continue
			elseif current.direction ~= "up" and current.direction ~= "root" and link.direction == "up" then
				continue
			end
			local q = link.query
			local result = results[q.key]
			if result == nil and wanted and not wantedSeen[q.key] then
				wantedSeen[q.key] = true
				table.insert(wanted, q)
			end
			if result and result.error then
				note(string.format("%s: %s", q.reason, result.error))
			end

			local found: { Candidate } = {}
			local foundNames: { [string]: boolean } = {}
			for _, item in list(result and result.items) do
				if link.match(item) then
					local ref = refOf(item)
					if ref then
						local key = (ref.uid and byUid[ref.uid]) or Resource.key(ref)
						if key == currentKey then
							note(string.format("cycle: %s lists itself as owner", qualified))
						else
							foundNames[ref.name] = true
							table.insert(found, { key = key, ref = ref, obj = item, missing = false, summary = "" })
						end
					end
				end
			end
			for _, name in (link.names or {}) :: { string } do
				if not foundNames[name] and link.missingKind then
					local ref: Ref = {
						clusterContext = nil,
						namespace = q.namespace,
						group = link.missingGroup,
						version = nil,
						kind = link.missingKind :: string,
						name = name,
						uid = nil,
						source = "live",
					}
					local summary = if result == nil
						then "not fetched"
						elseif result.error then "fetch failed"
						else "not found"
					table.insert(
						found,
						{ key = Resource.key(ref), ref = ref, obj = nil, missing = true, summary = summary }
					)
				end
			end
			table.sort(found, function(a, b)
				return a.key < b.key
			end)
			if #found > fanOut then
				graph.truncated = true
				note(
					string.format(
						"+%d more %s (%s) from %s not shown (fan-out limit %d)",
						#found - fanOut,
						q.kind,
						link.relation,
						qualified,
						fanOut
					)
				)
			end
			for i = 1, math.min(#found, fanOut) do
				local c = found[i]
				local edgeFrom, edgeTo = currentKey, c.key
				if link.direction == "up" then
					edgeFrom, edgeTo = c.key, currentKey
				end
				local existing = byKey[c.key]
				if existing then
					if link.direction == "up" and isAncestor(c.key, current) then
						note(
							string.format("cycle: ownership loops back to %s", Resource.qualifiedId(existing.node.ref))
						)
					end
					if STRENGTH[q.provenance] > STRENGTH[existing.node.provenance] then
						existing.node.provenance = q.provenance
					end
					addEdge(edgeFrom, edgeTo, link.relation, q.provenance)
				elseif #graph.nodes >= maxNodes then
					budgetHit = true
					graph.truncated = true
					note(string.format("node budget of %d reached; graph is incomplete", maxNodes))
					break
				else
					local record: Record = {
						node = {
							key = c.key,
							ref = c.ref,
							provenance = q.provenance,
							depth = current.node.depth + 1,
							summary = if c.missing then c.summary else summarize(c.obj),
							parent = currentKey,
							relation = link.relation,
							missing = c.missing,
						},
						obj = c.obj,
						direction = link.direction,
					}
					byKey[c.key] = record
					if c.ref.uid then
						byUid[c.ref.uid] = c.key
					end
					table.insert(graph.nodes, record.node)
					table.insert(queue, record)
					addEdge(edgeFrom, edgeTo, link.relation, q.provenance)
				end
			end
		end
	end
	return graph
end

local M = {}

M.DEFAULT_MAX_NODES = DEFAULT_MAX_NODES
M.DEFAULT_MAX_DEPTH = DEFAULT_MAX_DEPTH
M.DEFAULT_FAN_OUT = DEFAULT_FAN_OUT

function M.queriesFor(obj: any, opts: Options?): { RelQuery }
	local out: { RelQuery } = {}
	local seen: { [string]: boolean } = {}
	for _, link in links(obj, opts or {}) do
		if not seen[link.query.key] then
			seen[link.query.key] = true
			table.insert(out, link.query)
		end
	end
	return out
end

function M.pending(root: any, results: Results, opts: Options?): { RelQuery }
	local wanted: { RelQuery } = {}
	traverse(root, results, opts, wanted)
	return wanted
end

function M.build(root: any, results: Results, opts: Options?): Graph
	return traverse(root, results, opts, nil)
end

-- Turns `kubectl get <kind> [name] -o name` output into metadata-only items
-- for a nameOnly query (core kinds only; nothing beyond kind/name/namespace).
function M.itemsFromNames(q: RelQuery, stdout: string): QueryResult
	local info = Kinds.normalize(q.kind)
	local items: { any } = {}
	for line in string.gmatch(stdout, "[^\r\n]+") do
		local name = string.match(line, "^%s*[^/%s]+/(%S+)%s*$")
		if name then
			table.insert(items, {
				apiVersion = if info.group then info.group .. "/v1" else "v1",
				kind = info.kind,
				metadata = { name = name, namespace = q.namespace },
			})
		end
	end
	return { items = items }
end

return M
