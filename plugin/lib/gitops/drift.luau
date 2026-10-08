--!strict
-- Drift report for one manifest source: kubectl diff segments (desired vs
-- live) plus the live listing of the source's kinds in its namespaces sort
-- every disagreement into exactly one bucket:
--   changed    diff modifies the object
--   missing    diff creates it, or it is absent from the live listing
--   unmanaged  live, in the source's namespaces and kinds, in no manifest
--              (also prune deletions)
--   ignored    cluster defaults, owned/bookkeeping/terminating objects,
--              docs another tool renders (kustomize bases and patches)
-- The host runs the queries scope() describes; nothing here touches kubectl.
local Controllers = require("./controllers")
local Diffseg = require("../mutation/diffseg")
local Kinds = require("../kubectl/kinds")
local Command = require("../kubectl/command")
local Resource = require("../model/resource")
local Types = require("../model/types")

type Ref = Types.ResourceRef
type Segment = Diffseg.Segment

local M = {}

export type Source = {
	type: string,
	root: string?,
	path: string,
	label: string?,
}

-- The fields of gitops/index.luau's ManifestDoc this module reads.
export type Doc = {
	-- nil when the namespace is unresolved; "" namespace for cluster-scoped.
	key: string?,
	ref: Ref?,
	file: string,
	startLine: number,
	endLine: number?,
	source: Source,
	namespaceInferred: boolean,
	rendered: boolean,
	-- Kustomization dir listing this file as a resource or patch.
	kustomization: string?,
	patch: boolean?,
}

export type Index = { docs: { Doc } }

export type Options = {
	defaultNamespace: string?,
	-- `gitops.unmanaged_kinds`: Kind or Kind.group tokens replacing the
	-- source's kinds for the live listing / unmanaged check.
	unmanagedKinds: { string }?,
	controllers: Controllers.Set?,
	diffNotes: { string }?,
}

export type Scope = {
	docs: { Doc },
	-- Namespaces of the source's namespaced docs (sorted).
	namespaces: { string },
	-- `get` resource types to list in each namespace (sorted).
	kinds: { string },
}

export type ObjectSummary = {
	apiVersion: string?,
	kind: string,
	namespace: string?,
	name: string,
	created: string?,
	managedBy: string?,
	controller: Controllers.Owner?,
}

export type Changed = { key: string, ref: Ref, segment: Segment, docs: { Doc }, controller: Controllers.Owner? }
export type Missing = { key: string, ref: Ref, docs: { Doc }, segment: Segment?, reason: "create" | "absent" }
export type Unmanaged = { key: string, ref: Ref, object: ObjectSummary, segment: Segment? }
export type Ignored = { key: string, reason: string }

export type Counts = {
	changed: number,
	missing: number,
	unmanaged: number,
	ignored: number,
	inSync: number,
	-- Docs the source declares (ignored docs excluded).
	docs: number,
}

export type Report = {
	source: Source,
	changed: { Changed },
	missing: { Missing },
	unmanaged: { Unmanaged },
	ignored: { Ignored },
	counts: Counts,
	notes: { string },
}

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function under(file: string, dir: string): boolean
	local d = string.gsub(dir, "/+$", "")
	return string.sub(file, 1, #d + 1) == d .. "/"
end

local function inSource(doc: Doc, source: Source): boolean
	if doc.source.path == source.path and doc.source.type == source.type then
		return true
	end
	if doc.rendered then
		return false
	end
	if source.type == "file" then
		return doc.file == source.path
	end
	return source.type == "dir" and under(doc.file, source.path)
end

-- Why a doc of a plain source is not compared on its own.
local function skipReason(doc: Doc): string?
	if doc.patch then
		return "kustomize patch"
	end
	if not doc.rendered and doc.kustomization then
		return "rendered by kustomization " .. doc.kustomization
	end
	return nil
end

local function kindId(group: string?, kind: string): string
	return (group or "") .. "/" .. string.lower(kind)
end

local function clusterScoped(doc: Doc): boolean
	return doc.key ~= nil and doc.ref ~= nil and doc.ref.namespace == nil
end

local function docNamespace(doc: Doc, opts: Options): string?
	local ref = doc.ref
	if ref == nil or clusterScoped(doc) then
		return nil
	end
	return ref.namespace or opts.defaultNamespace
end

-- Key the doc would have in the cluster; nil when its namespace is unknown.
local function resolvedKey(doc: Doc, opts: Options): string?
	if doc.key then
		return doc.key
	end
	local ref = doc.ref
	local ns = opts.defaultNamespace
	if ref == nil or ns == nil then
		return nil
	end
	return Resource.key({ group = ref.group, kind = ref.kind, namespace = ns, name = ref.name, source = "live" })
end

-- Matches a cluster object against a doc; an unresolved namespace matches
-- any namespace when no default is known (kubectl diff used its own).
local function docMatches(doc: Doc, key: string, ref: Ref, opts: Options): boolean
	local k = resolvedKey(doc, opts)
	if k then
		return k == key
	end
	local d = doc.ref
	return d ~= nil
		and opts.defaultNamespace == nil
		and (d.group or "") == (ref.group or "")
		and d.kind == ref.kind
		and d.name == ref.name
end

local function sortedKeys(set: { [string]: boolean }): { string }
	local out: { string } = {}
	for k in set do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

type Partition = { docs: { Doc }, ignored: { Ignored } }

local function partition(source: Source, index: Index, opts: Options): Partition
	local docs: { Doc } = {}
	local ignored: { Ignored } = {}
	for _, doc in index.docs do
		if doc.ref and inSource(doc, source) then
			local reason = skipReason(doc)
			if reason then
				local ref = doc.ref :: Ref
				table.insert(ignored, {
					key = resolvedKey(doc, opts) or Resource.key(ref),
					reason = reason,
				})
			else
				table.insert(docs, doc)
			end
		end
	end
	return { docs = docs, ignored = ignored }
end

local function overrideKinds(tokens: { string }): { [string]: string }
	local out: { [string]: string } = {}
	for _, token in tokens do
		local info = Kinds.normalize(token)
		local ref = { kind = info.kind, group = info.group, name = "", source = "live" } :: Ref
		out[kindId(info.group, info.kind)] = Command.resourceType(ref)
	end
	return out
end

-- kindId -> `get` resource type.
local function coveredKinds(docs: { Doc }, opts: Options): { [string]: string }
	if opts.unmanagedKinds then
		return overrideKinds(opts.unmanagedKinds)
	end
	local out: { [string]: string } = {}
	for _, doc in docs do
		local ref = doc.ref
		if ref and not clusterScoped(doc) then
			out[kindId(ref.group, ref.kind)] = Command.resourceType(ref)
		end
	end
	return out
end

local function namespacesOf(docs: { Doc }, opts: Options): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, doc in docs do
		local ns = docNamespace(doc, opts)
		if ns then
			out[ns] = true
		end
	end
	return out
end

function M.scope(source: Source, index: Index, opts: Options): Scope
	local docs = partition(source, index, opts).docs
	local kinds: { [string]: boolean } = {}
	for _, t in coveredKinds(docs, opts) do
		kinds[t] = true
	end
	return { docs = docs, namespaces = sortedKeys(namespacesOf(docs, opts)), kinds = sortedKeys(kinds) }
end

local function segmentRef(seg: Segment): Ref?
	if seg.kind == nil or seg.name == nil then
		return nil
	end
	return {
		group = seg.group,
		version = seg.version,
		kind = seg.kind :: string,
		namespace = seg.namespace,
		name = seg.name :: string,
		source = "live",
	}
end

local DEFAULTS: { [string]: boolean } = {
	["/configmap/kube-root-ca.crt"] = true,
	["/serviceaccount/default"] = true,
	["/service/default/kubernetes"] = true,
}

local DEFAULT_NAMESPACES =
	{ default = true, ["kube-system"] = true, ["kube-public"] = true, ["kube-node-lease"] = true }

local GENERATED: { [string]: boolean } = {
	["/endpoints"] = true,
	["discovery.k8s.io/endpointslice"] = true,
	["/event"] = true,
	["events.k8s.io/event"] = true,
	["coordination.k8s.io/lease"] = true,
}

local function exclusion(obj: { [string]: any }, ref: Ref): string?
	local meta = obj.metadata
	local id = kindId(ref.group, ref.kind)
	if str(meta.deletionTimestamp) then
		return "being deleted"
	end
	local owners = meta.ownerReferences
	if type(owners) == "table" and type(owners[1]) == "table" then
		return string.format("owned by %s/%s", tostring(owners[1].kind), tostring(owners[1].name))
	end
	if
		DEFAULTS[id .. "/" .. ref.name]
		or (ref.namespace == "default" and DEFAULTS[id .. "/default/" .. ref.name])
		or (id == "/namespace" and DEFAULT_NAMESPACES[ref.name])
	then
		return "cluster default"
	end
	if GENERATED[id] then
		return "generated by the cluster"
	end
	local labels = if type(meta.labels) == "table" then meta.labels else {}
	if
		obj.type == "helm.sh/release.v1" or (labels.owner == "helm" and string.match(ref.name, "^sh%.helm%.release%."))
	then
		return "helm release record"
	end
	if labels["argocd.argoproj.io/secret-type"] ~= nil then
		return "argo cd bookkeeping"
	end
	return nil
end

local function byKey(a: { key: string }, b: { key: string }): boolean
	return a.key < b.key
end

local function summary(obj: { [string]: any }, ref: Ref, opts: Options): ObjectSummary
	local meta = obj.metadata
	local labels = if type(meta.labels) == "table" then meta.labels else {}
	return {
		apiVersion = str(obj.apiVersion),
		kind = ref.kind,
		namespace = ref.namespace,
		name = ref.name,
		created = str(meta.creationTimestamp),
		managedBy = str(labels["app.kubernetes.io/managed-by"]),
		controller = if opts.controllers then Controllers.owner(obj, opts.controllers) else nil,
	}
end

type LiveEntry = { obj: { [string]: any }, ref: Ref }

function M.report(source: Source, index: Index, segments: { Segment }, live: { any }?, opts: Options): Report
	local parts = partition(source, index, opts)
	local docs = parts.docs
	local ignored = parts.ignored
	local notes: { string } = {}
	if opts.diffNotes then
		table.move(opts.diffNotes, 1, #opts.diffNotes, 1, notes)
	end

	local liveByKey: { [string]: LiveEntry } = {}
	local listed: { any } = live or {}
	for _, raw in listed do
		local ref = if type(raw) == "table" then Resource.fromObject(raw, "live") else nil
		if ref then
			liveByKey[Resource.key(ref)] = { obj = raw, ref = ref }
		end
	end

	local function docsFor(key: string, ref: Ref): { Doc }
		local out: { Doc } = {}
		for _, doc in docs do
			if docMatches(doc, key, ref, opts) then
				table.insert(out, doc)
			end
		end
		return out
	end

	local function ownerOf(key: string): Controllers.Owner?
		local entry = liveByKey[key]
		return if entry and opts.controllers then Controllers.owner(entry.obj, opts.controllers) else nil
	end

	local changed: { Changed } = {}
	local missing: { Missing } = {}
	local unmanaged: { [string]: Unmanaged } = {}
	local seen: { [Doc]: boolean } = {}

	for _, seg in segments do
		local ref = segmentRef(seg)
		if ref == nil then
			table.insert(notes, seg.key .. ": unreadable object name in diff output")
			continue
		end
		local key = Resource.key(ref)
		local matched = docsFor(key, ref)
		for _, d in matched do
			seen[d] = true
		end
		if #matched > 1 then
			table.insert(notes, string.format("%s: declared %d times", key, #matched))
		end
		if seg.action == "create" then
			table.insert(missing, { key = key, ref = ref, docs = matched, segment = seg, reason = "create" })
		elseif seg.action == "delete" then
			local entry = liveByKey[key]
			unmanaged[key] = {
				key = key,
				ref = ref,
				object = summary(if entry then entry.obj else { metadata = {} }, ref, opts),
				segment = seg,
			}
		else
			if seg.action == "unknown" then
				table.insert(notes, key .. ": diff could not be classified")
			end
			if #matched == 0 then
				table.insert(notes, key .. ": no manifest in this source")
			end
			table.insert(changed, { key = key, ref = ref, segment = seg, docs = matched, controller = ownerOf(key) })
		end
	end

	local kinds = coveredKinds(docs, opts)
	local namespaces = namespacesOf(docs, opts)

	if live == nil then
		table.insert(notes, "live objects not listed: unmanaged objects not checked")
	else
		for _, doc in docs do
			local ref = doc.ref :: Ref
			local ns = docNamespace(doc, opts)
			local key = resolvedKey(doc, opts)
			if not seen[doc] and key and ns and kinds[kindId(ref.group, ref.kind)] and liveByKey[key] == nil then
				seen[doc] = true
				table.insert(missing, { key = key, ref = ref, docs = { doc }, reason = "absent" })
			end
		end
		for key, entry in liveByKey do
			local ref = entry.ref
			if unmanaged[key] or not ref.namespace or not namespaces[ref.namespace :: string] then
				continue
			end
			if not kinds[kindId(ref.group, ref.kind)] then
				continue
			end
			local indexed = false
			for _, doc in index.docs do
				if not doc.patch and doc.ref and docMatches(doc, key, ref, opts) then
					indexed = true
					break
				end
			end
			if indexed then
				continue
			end
			local reason = exclusion(entry.obj, ref)
			if reason then
				table.insert(ignored, { key = key, reason = reason })
			else
				unmanaged[key] = { key = key, ref = ref, object = summary(entry.obj, ref, opts) }
			end
		end
	end

	local unmanagedList: { Unmanaged } = {}
	for _, u in unmanaged do
		table.insert(unmanagedList, u)
	end
	table.sort(changed, byKey)
	table.sort(missing, byKey)
	table.sort(unmanagedList, byKey)
	table.sort(ignored, byKey)

	local inSync = 0
	for _, doc in docs do
		if not seen[doc] then
			inSync += 1
		end
	end

	return {
		source = source,
		changed = changed,
		missing = missing,
		unmanaged = unmanagedList,
		ignored = ignored,
		counts = {
			changed = #changed,
			missing = #missing,
			unmanaged = #unmanagedList,
			ignored = #ignored,
			inSync = inSync,
			docs = #docs,
		},
		notes = notes,
	}
end

return M
