--!strict
-- Argo CD and Flux awareness from their own objects (read-only: tern-kube
-- never writes controller objects). Attribution follows the tracking
-- metadata the controllers stamp on what they apply:
--   Argo CD: annotation `argocd.argoproj.io/tracking-id`
--     (`<app>:<group>/<kind>:<namespace>/<name>`, app may be `<ns>_<name>`),
--     else label `app.kubernetes.io/instance` (Argo's default tracking).
--   Flux: labels `kustomize.toolkit.fluxcd.io/{name,namespace}` and
--     `helm.toolkit.fluxcd.io/{name,namespace}`.
-- `app.kubernetes.io/instance` is also Helm's standard label, so it only
-- counts when an Application of that name is known.
local M = {}

export type ControllerKind = "argocd" | "flux-kustomize" | "flux-helm"

export type Source = {
	repoURL: string?,
	-- Directory (Argo/Flux Kustomization) or chart directory (HelmRelease)
	-- inside the repository; nil for charts from chart repositories.
	path: string?,
	chart: string?,
	revision: string?,
}

export type Chart = { name: string?, version: string?, appVersion: string?, revision: number? }

export type Controller = {
	controller: ControllerKind,
	name: string,
	namespace: string?,
	sources: { Source },
	-- Primary source: the first one with a path (the git directory of a
	-- multi-source Application), else the first.
	repoURL: string?,
	path: string?,
	revision: string?,
	sync: string?,
	health: string?,
	message: string?,
	destinationNamespace: string?,
	-- The controller's own status (all optional: older controllers and
	-- missing status leave fields out). What it applied / last tried: Argo
	-- sync and operation revisions, Flux lastApplied/lastAttemptedRevision,
	-- the HelmRelease's history[0] chart version.
	appliedRevision: string?,
	attemptedRevision: string?,
	-- Argo CD last operation.
	phase: string?,
	operationMessage: string?,
	finishedAt: string?,
	-- Flux Ready condition: "True" | "False" | "Unknown".
	ready: string?,
	reason: string?,
	stalled: boolean?,
	reconciling: boolean?,
	-- Argo status.reconciledAt; Flux Ready lastTransitionTime.
	reconciledAt: string?,
	-- Argo conditions whose type ends in Error.
	errors: { count: number, message: string?, type: string? }?,
	-- Argo spec.syncPolicy.automated (enabled ~= false).
	autoSync: { prune: boolean, selfHeal: boolean }?,
	suspended: boolean?,
	interval: string?,
	-- HelmRelease spec.driftDetection.mode == "enabled".
	driftDetection: boolean?,
	chart: Chart?,
}

export type Owner = {
	controller: ControllerKind,
	name: string,
	namespace: string?,
	sources: { Source },
	repoURL: string?,
	path: string?,
	revision: string?,
	sync: string?,
	health: string?,
	message: string?,
	destinationNamespace: string?,
	appliedRevision: string?,
	attemptedRevision: string?,
	phase: string?,
	operationMessage: string?,
	finishedAt: string?,
	ready: string?,
	reason: string?,
	stalled: boolean?,
	reconciling: boolean?,
	reconciledAt: string?,
	errors: { count: number, message: string?, type: string? }?,
	autoSync: { prune: boolean, selfHeal: boolean }?,
	suspended: boolean?,
	interval: string?,
	driftDetection: boolean?,
	chart: Chart?,
	-- Metadata key the attribution rests on, e.g. `label:app.kubernetes.io/instance`.
	provenance: string,
	-- False when the controller object itself was not listed (other
	-- namespace, missing RBAC): only name/namespace are known.
	resolved: boolean,
}

export type Set = { controllers: { Controller }, notes: { string } }

M.APPLICATIONS = "applications.argoproj.io"
M.KUSTOMIZATIONS = "kustomizations.kustomize.toolkit.fluxcd.io"
M.HELMRELEASES = "helmreleases.helm.toolkit.fluxcd.io"
M.GITREPOSITORIES = "gitrepositories.source.toolkit.fluxcd.io"

local RESOURCES = { M.APPLICATIONS, M.KUSTOMIZATIONS, M.HELMRELEASES, M.GITREPOSITORIES }

local ARGO_TRACKING = "argocd.argoproj.io/tracking-id"
local INSTANCE = "app.kubernetes.io/instance"

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function tbl(v: any): { [any]: any }?
	return if type(v) == "table" then v else nil
end

local function asTable(v: any): { [any]: any }
	return if type(v) == "table" then v else {}
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) :: string
end

-- Resource names (`kubectl api-resources -o name`) worth listing with
-- `get <name> -A -o json`; absent types are never queried.
function M.queries(apiResources: { string }): { string }
	local served: { [string]: boolean } = {}
	for _, line in apiResources do
		served[trim(line)] = true
	end
	local out: { string } = {}
	for _, r in RESOURCES do
		if served[r] then
			table.insert(out, r)
		end
	end
	return out
end

local function items(list: any): { { [string]: any } }
	local out: { { [string]: any } } = {}
	local raw = tbl(list) and tbl(list.items)
	if raw == nil then
		return out
	end
	for _, item in raw do
		local meta = tbl(item) and tbl(item.metadata)
		if meta and str(meta.name) then
			table.insert(out, item)
		end
	end
	return out
end

local function condition(status: any, kind: string): { [string]: any }?
	local conditions = tbl(status) and tbl(status.conditions)
	if conditions == nil then
		return nil
	end
	for _, c in conditions do
		if type(c) == "table" and c.type == kind then
			return c
		end
	end
	return nil
end

local function primary(c: Controller): Controller
	local first = c.sources[1]
	for _, s in c.sources do
		if s.path then
			first = s
			break
		end
	end
	if first then
		c.repoURL, c.path, c.revision = first.repoURL, first.path, first.revision
	end
	return c
end

-- The index the primary source has in a source list (see primary()).
local function primaryIndex(sources: { Source }): number
	for i, s in sources do
		if s.path then
			return i
		end
	end
	return 1
end

local function argoErrors(status: { [string]: any }): { count: number, message: string?, type: string? }?
	local conditions = tbl(status.conditions)
	if conditions == nil then
		return nil
	end
	local count = 0
	local first: { [string]: any }? = nil
	for _, c in conditions do
		if type(c) == "table" and type(c.type) == "string" and string.match(c.type, "Error$") then
			count += 1
			first = first or c
		end
	end
	if first == nil then
		return nil
	end
	return { count = count, message = str(first.message), type = str(first.type) }
end

local function argo(item: { [string]: any }): Controller
	local spec = asTable(item.spec)
	local status = asTable(item.status)
	local sync = asTable(status.sync)
	local health = asTable(status.health)
	local raw: { any } = {}
	if tbl(spec.sources) then
		raw = spec.sources
	elseif tbl(spec.source) then
		raw = { spec.source }
	end
	local revisions = tbl(sync.revisions)
	local sources: { Source } = {}
	for i, s in raw do
		local src = tbl(s)
		if src then
			table.insert(sources, {
				repoURL = str(src.repoURL),
				path = str(src.path),
				chart = str(src.chart),
				revision = if revisions then str(revisions[i]) else str(sync.revision) or str(src.targetRevision),
			})
		end
	end
	local pi = primaryIndex(sources)
	local op = asTable(status.operationState)
	local result = asTable(op.syncResult)
	local resultRevisions = tbl(result.revisions)
	local automated = tbl(asTable(spec.syncPolicy).automated)
	local destination = asTable(spec.destination)
	return primary({
		controller = "argocd",
		name = item.metadata.name,
		namespace = str(item.metadata.namespace),
		sources = sources,
		sync = str(sync.status),
		health = str(health.status),
		message = str(health.message),
		destinationNamespace = str(destination.namespace),
		appliedRevision = if revisions then str(revisions[pi]) else str(sync.revision),
		attemptedRevision = if resultRevisions then str(resultRevisions[pi]) else str(result.revision),
		phase = str(op.phase),
		operationMessage = str(op.message),
		finishedAt = str(op.finishedAt),
		reconciledAt = str(status.reconciledAt),
		errors = argoErrors(status),
		autoSync = if automated and automated.enabled ~= false
			then { prune = automated.prune == true, selfHeal = automated.selfHeal == true }
			else nil,
	})
end

type GitRepos = { [string]: { [string]: any } }

local function nsName(namespace: string?, name: string): string
	return (namespace or "") .. "/" .. name
end

-- Ready condition -> Ready/NotReady/Unknown; Healthy (Kustomization health
-- checks) -> Healthy/Unhealthy.
local function fluxStatus(status: any): (string?, string?, string?)
	local ready = condition(status, "Ready")
	local sync: string? = nil
	if ready then
		sync = if ready.status == "True" then "Ready" elseif ready.status == "False" then "NotReady" else "Unknown"
	end
	local healthy = condition(status, "Healthy")
	local health: string? = nil
	if healthy and healthy.status == "True" then
		health = "Healthy"
	elseif healthy and healthy.status == "False" then
		health = "Unhealthy"
	end
	return sync, health, ready and str(ready.message)
end

local function gitSource(
	notes: { string },
	label: string,
	namespace: string?,
	ref: any,
	repos: GitRepos
): { [string]: any }?
	local r = tbl(ref)
	if r == nil then
		table.insert(notes, label .. ": no sourceRef")
		return nil
	end
	local kind = str(r.kind) or "?"
	local name = str(r.name) or "?"
	if kind ~= "GitRepository" then
		table.insert(notes, string.format("%s: source %s/%s is not a git repository", label, kind, name))
		return nil
	end
	local key = nsName(str(r.namespace) or namespace, name)
	local repo = repos[key]
	if repo == nil then
		table.insert(notes, string.format("%s: GitRepository %s not found", label, key))
	end
	return repo
end

local function gitRevision(repo: { [string]: any }?): string?
	if repo == nil then
		return nil
	end
	local artifact = tbl(repo.status) and tbl(repo.status.artifact)
	if artifact and str(artifact.revision) then
		return str(artifact.revision)
	end
	local ref = tbl(repo.spec) and tbl(repo.spec.ref)
	return ref and (str(ref.commit) or str(ref.tag) or str(ref.semver) or str(ref.branch))
end

local function gitURL(repo: { [string]: any }?): string?
	return repo and tbl(repo.spec) and str(repo.spec.url)
end

-- Flux fields shared by Kustomization and HelmRelease.
local function fluxController(
	kind: ControllerKind,
	item: { [string]: any },
	sources: { Source },
	applied: string?
): Controller
	local spec = asTable(item.spec)
	local status = asTable(item.status)
	local sync, health, message = fluxStatus(status)
	local ready = condition(status, "Ready")
	local stalled = condition(status, "Stalled")
	local reconciling = condition(status, "Reconciling")
	return primary({
		controller = kind,
		name = item.metadata.name,
		namespace = str(item.metadata.namespace),
		sources = sources,
		sync = sync,
		health = health,
		message = message,
		destinationNamespace = str(spec.targetNamespace),
		appliedRevision = applied,
		attemptedRevision = str(status.lastAttemptedRevision),
		ready = ready and str(ready.status),
		reason = ready and str(ready.reason),
		stalled = stalled ~= nil and stalled.status == "True",
		reconciling = reconciling ~= nil and reconciling.status == "True",
		reconciledAt = ready and str(ready.lastTransitionTime),
		suspended = spec.suspend == true,
		interval = str(spec.interval),
	})
end

local function kustomization(item: { [string]: any }, repos: GitRepos, notes: { string }): Controller
	local spec = asTable(item.spec)
	local status = asTable(item.status)
	local namespace = str(item.metadata.namespace)
	local label = "Kustomization " .. nsName(namespace, item.metadata.name)
	local repo = gitSource(notes, label, namespace, spec.sourceRef, repos)
	local sources: { Source } = {
		{
			repoURL = gitURL(repo),
			path = str(spec.path) or "./",
			revision = str(status.lastAppliedRevision) or gitRevision(repo),
		},
	}
	return fluxController("flux-kustomize", item, sources, str(status.lastAppliedRevision))
end

local function helmRelease(item: { [string]: any }, repos: GitRepos, notes: { string }): Controller
	local spec = asTable(item.spec)
	local status = asTable(item.status)
	local namespace = str(item.metadata.namespace)
	local label = "HelmRelease " .. nsName(namespace, item.metadata.name)
	local chartSpec = tbl(spec.chart) and tbl(spec.chart.spec)
	local history = tbl(status.history)
	local latest = if history then tbl(history[1]) else nil
	local chart: Chart? = nil
	if latest then
		chart = {
			name = str(latest.chartName),
			version = str(latest.chartVersion),
			appVersion = str(latest.appVersion),
			revision = if type(latest.version) == "number" then latest.version else nil,
		}
	end
	local applied = (chart and chart.version) or str(status.lastAppliedRevision)
	local source: Source = { revision = applied }
	if chartSpec then
		local ref = tbl(chartSpec.sourceRef)
		if ref and ref.kind == "GitRepository" then
			local repo = gitSource(notes, label, namespace, ref, repos)
			source.repoURL = gitURL(repo)
			source.path = str(chartSpec.chart)
		else
			source.chart = str(chartSpec.chart)
		end
	elseif tbl(spec.chartRef) then
		table.insert(notes, label .. ": chartRef sources are not resolved")
	end
	local c = fluxController("flux-helm", item, { source }, applied)
	c.chart = chart
	c.driftDetection = asTable(spec.driftDetection).mode == "enabled"
	return c
end

-- `lists` maps the resource names from queries() to decoded `-o json` lists;
-- absent entries are simply not known.
function M.parse(lists: { [string]: any }): Set
	local notes: { string } = {}
	local repos: GitRepos = {}
	for _, item in items(lists[M.GITREPOSITORIES]) do
		repos[nsName(str(item.metadata.namespace), item.metadata.name)] = item
	end
	local out: { Controller } = {}
	for _, item in items(lists[M.APPLICATIONS]) do
		table.insert(out, argo(item))
	end
	for _, item in items(lists[M.KUSTOMIZATIONS]) do
		table.insert(out, kustomization(item, repos, notes))
	end
	for _, item in items(lists[M.HELMRELEASES]) do
		table.insert(out, helmRelease(item, repos, notes))
	end
	return { controllers = out, notes = notes }
end

local function ownerOf(c: Controller, provenance: string): Owner
	local o: any = table.clone(c)
	o.provenance = provenance
	o.resolved = true
	return o
end

local function unresolved(kind: ControllerKind, name: string, namespace: string?, provenance: string): Owner
	return {
		controller = kind,
		name = name,
		namespace = namespace,
		sources = {},
		provenance = provenance,
		resolved = false,
	}
end

local function lookup(set: Set, kind: ControllerKind, name: string, namespace: string?): Controller?
	local found: Controller? = nil
	for _, c in set.controllers do
		if c.controller == kind and c.name == name and (namespace == nil or c.namespace == namespace) then
			if found then
				-- Same name in several namespaces and none named: ambiguous.
				return nil
			end
			found = c
		end
	end
	return found
end

-- Argo's app instance value: `<name>` or `<namespace>_<name>` (apps outside
-- the control-plane namespace). Names cannot contain `_`.
local function argoApp(value: string): (string, string?)
	local ns, name = string.match(value, "^([^_]+)_(.+)$")
	if ns and name then
		return name, ns
	end
	return value, nil
end

local function trackingMatches(rest: string, obj: { [string]: any }): boolean
	local group, kind, namespace, name = string.match(rest, "^([^/]*)/([^:]+):([^/]*)/(.+)$")
	if kind == nil then
		return false
	end
	local apiGroup = string.match(str(obj.apiVersion) or "", "^([^/]+)/") or ""
	return group == apiGroup
		and kind == obj.kind
		and namespace == (str(obj.metadata.namespace) or "")
		and name == obj.metadata.name
end

local function flux(set: Set, labels: { [string]: any }, prefix: string, kind: ControllerKind): Owner?
	local name = str(labels[prefix .. "/name"])
	if name == nil then
		return nil
	end
	local namespace = str(labels[prefix .. "/namespace"])
	local provenance = "label:" .. prefix .. "/name"
	local c = lookup(set, kind, name, namespace)
	return if c then ownerOf(c, provenance) else unresolved(kind, name, namespace, provenance)
end

function M.owner(obj: { [string]: any }, set: Set): Owner?
	local meta = tbl(obj.metadata)
	if meta == nil then
		return nil
	end
	local labels = asTable(meta.labels)
	local annotations = asTable(meta.annotations)

	local tracking = str(annotations[ARGO_TRACKING])
	if tracking then
		local app, rest = string.match(tracking, "^([^:]+):(.+)$")
		if app == nil or rest == nil or not trackingMatches(rest, obj) then
			return nil
		end
		local name, namespace = argoApp(app)
		local provenance = "annotation:" .. ARGO_TRACKING
		local c = lookup(set, "argocd", name, namespace)
		return if c then ownerOf(c, provenance) else unresolved("argocd", name, namespace, provenance)
	end

	local found = flux(set, labels, "kustomize.toolkit.fluxcd.io", "flux-kustomize")
		or flux(set, labels, "helm.toolkit.fluxcd.io", "flux-helm")
	if found then
		return found
	end

	local instance = str(labels[INSTANCE])
	if instance then
		local name, namespace = argoApp(instance)
		local c = lookup(set, "argocd", name, namespace)
		if c then
			return ownerOf(c, "label:" .. INSTANCE)
		end
	end
	return nil
end

-- Canonical `host/path` for a git remote: scheme, user info, port, `.git`
-- and trailing slashes dropped, host lowercased. Local paths yield nil.
function M.normalizeRemote(url: string): string?
	local u = trim(url)
	local host: string, path: string
	local scheme, rest = string.match(u, "^(%a[%w+.-]*)://(.+)$")
	if scheme and rest then
		local authority, p = string.match(rest, "^([^/]+)/(.*)$")
		if authority == nil or p == nil then
			return nil
		end
		local hostPort = string.match(authority, "([^@]+)$") or authority
		host = (string.gsub(hostPort, ":%d*$", ""))
		path = p
	else
		local h, p = string.match(u, "^[^@/]+@([^:/]+):(.+)$")
		if h == nil then
			h, p = string.match(u, "^([%w.-]+%.[%a]+):([^/].*)$")
		end
		if h == nil or p == nil then
			return nil
		end
		host, path = h, p
	end
	path = string.gsub(path, "/+$", "")
	path = string.gsub(path, "%.git$", "")
	path = string.gsub(path, "^/+", "")
	if host == "" or path == "" then
		return nil
	end
	return string.lower(host) .. "/" .. path
end

-- Joins a repository-relative path under root; nil when it would escape.
local function join(root: string, rel: string): string?
	if string.sub(rel, 1, 1) == "/" then
		return nil
	end
	local parts: { string } = {}
	for _, part in string.split(rel, "/") do
		if part == ".." then
			return nil
		elseif part ~= "" and part ~= "." then
			table.insert(parts, part)
		end
	end
	local base = string.gsub(root, "/+$", "")
	if #parts == 0 then
		return base
	end
	return base .. "/" .. table.concat(parts, "/")
end

export type Repo = { root: string, remotes: { string } }

-- Path inside the local checkout for the first source whose repository is
-- one of the checkout's remotes (enables drift against local files).
function M.localPath(info: { sources: { Source } }, repo: Repo): string?
	local remotes: { [string]: boolean } = {}
	for _, r in repo.remotes do
		local n = M.normalizeRemote(r)
		if n then
			remotes[n] = true
		end
	end
	for _, s in info.sources do
		local n = s.repoURL and M.normalizeRemote(s.repoURL)
		if n and remotes[n] and s.path then
			return join(repo.root, s.path)
		end
	end
	return nil
end

-- The git commit in a controller revision: Argo's plain 40-hex sha, Flux's
-- `<ref>@sha1:<sha>` / `sha1:<sha>`. Chart versions and branch names: nil.
function M.commit(rev: string?): string?
	if rev == nil then
		return nil
	end
	local r = string.lower(trim(rev))
	local sha = string.match(r, "sha1:(%x+)$") or string.match(r, "^(%x+)$")
	return if sha and #sha == 40 then sha else nil
end

export type Tone = "success" | "warning" | "error"

type StatusInfo = {
	controller: ControllerKind,
	sync: string?,
	health: string?,
	phase: string?,
	ready: string?,
	reason: string?,
	stalled: boolean?,
	reconciling: boolean?,
	suspended: boolean?,
	errors: { count: number, message: string?, type: string? }?,
}

local function withReason(text: string, reason: string?): string
	return if reason then text .. " (" .. reason .. ")" else text
end

-- One line of the controller's own verdict, e.g. `OutOfSync · Degraded`,
-- `Ready`, `Not ready (HealthCheckFailed)`, `Suspended`.
function M.statusText(c: StatusInfo): (string, Tone)
	if c.controller == "argocd" then
		local parts: { string } = {}
		if c.sync then
			table.insert(parts, c.sync :: string)
		end
		if c.health then
			table.insert(parts, c.health :: string)
		end
		local errors = c.errors
		if errors then
			table.insert(parts, errors.type or "Error")
		end
		local failed = c.phase == "Failed" or c.phase == "Error"
		local tone: Tone = "warning"
		if c.health == "Degraded" or errors ~= nil or failed then
			tone = "error"
		elseif c.sync == "Synced" and (c.health == nil or c.health == "Healthy") then
			tone = "success"
		end
		return if #parts > 0 then table.concat(parts, " · ") else "Unknown", tone
	end
	if c.suspended then
		return "Suspended", "warning"
	elseif c.stalled then
		return withReason("Stalled", c.reason), "error"
	elseif c.ready == "False" then
		return withReason("Not ready", c.reason), "error"
	elseif c.ready == "True" then
		return "Ready", "success"
	elseif c.reconciling then
		return "Reconciling", "warning"
	end
	return withReason("Unknown", c.reason), "warning"
end

type RiskInfo = {
	controller: ControllerKind,
	autoSync: { prune: boolean, selfHeal: boolean }?,
	suspended: boolean?,
	interval: string?,
	driftDetection: boolean?,
}

-- Whether the controller undoes a change applied outside Git (advisory).
function M.revertRisk(c: RiskInfo): string?
	if c.controller == "argocd" then
		local auto = c.autoSync
		if auto and auto.selfHeal then
			return "Argo CD self-heal is on: changes applied outside Git are reverted"
		elseif auto then
			return "Argo CD auto-sync: the next sync overwrites changes not in Git"
		end
		return nil
	end
	-- helm-controller leaves manual changes alone unless drift detection is on.
	if c.controller == "flux-helm" and not c.driftDetection then
		return nil
	end
	if c.suspended then
		return string.format(
			"Flux %s suspended: changes stay until it is resumed",
			if c.controller == "flux-helm" then "HelmRelease" else "Kustomization"
		)
	end
	local every = if c.interval then "every " .. c.interval else "on every reconcile"
	return "Flux re-applies this source " .. every .. ": changes applied outside Git are reverted"
end

-- The controllers whose source, in the local checkout, is `path`.
function M.forSource(set: Set, localPathOf: (c: Controller) -> string?, path: string): { Controller }
	local out: { Controller } = {}
	for _, c in set.controllers do
		if localPathOf(c) == path then
			table.insert(out, c)
		end
	end
	return out
end

return M
