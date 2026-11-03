--!strict
-- The Helm routes of the Explore block (releases, release, history, values,
-- manifest, notes, hooks, resources, revision diff): their state, the helm
-- and kubectl runs they ask the host for and how results advance them.
-- state.luau owns routing and calls in here with a Ctx describing the
-- pinned target; nothing here touches `tern`.
--
-- `enter` is an idempotent "ensure": it starts whatever the route still
-- needs (state.luau calls it again after every helm result), so chained
-- reads (latest status -> its extras, history -> pristine defaults inputs,
-- manifest -> live presence) need no per-route bookkeeping. Every helm call
-- pins --kube-context (helm/query.luau) and carries HELM_DRIVER.

local Config = require("../config")
local Detect = require("../helm/detect")
local ExploreQuery = require("./query")
local Gitops = require("./gitops")
local HelmTypes = require("../helm/types")
local Kinds = require("../kubectl/kinds")
local Command = require("../kubectl/command")
local Link = require("../mutation/link")
local Owner = require("../helm/owner")
local Parse = require("../helm/parse")
local Query = require("../helm/query")
local Redact = require("../model/redact")
local Resource = require("../model/resource")
local RevDiff = require("../helm/revdiff")
local Shellenv = require("../env/shellenv")
local T = require("./types")
local Types = require("../model/types")
local Values = require("../helm/values")
local Yaml = require("../parse/yaml")

type Ref = Types.ResourceRef
export type Route = T.Route
export type Effect = T.Effect
export type Msg = T.Msg
type Item = T.Item
type ProcessResult = T.ProcessResult
type Load<X> = HelmTypes.Load<X>
type Revision = HelmTypes.Revision
type ReleaseRow = HelmTypes.ReleaseRow
type ReleaseStatus = HelmTypes.ReleaseStatus
type Extras = HelmTypes.Extras
type Key = HelmTypes.ReleaseKey

export type H = HelmTypes.ExploreState

export type Ctx = {
	target: ExploreQuery.Target,
	-- Resolved helm program; nil = not found.
	helm: string?,
	-- For the helm-resources live queries.
	kubectl: string,
	config: Config.Config,
	decode: T.Decode,
	-- Tells `[]` from `{}` for empty decoded tables (explore_host).
	isList: ((t: { [any]: any }) -> boolean)?,
	resolved: boolean,
	now: number?,
	-- For the helm-not-found message.
	daemonPath: string?,
	-- tern.plugin.data: the values converter chart and temporary values files.
	dataDir: string?,
	nonce: (() -> string)?,
	-- Chart directories of the manifest index (empty until it is built).
	chartDirs: { HelmTypes.ChartDir },
}

export type Nav = Gitops.Nav

export type ResourceState = "present" | "missing" | "extra" | "hook" | "unknown"
export type ResourceRow = { key: string, ref: Ref, state: ResourceState, source: string? }

-- One live listing of a manifest kind in one namespace.
type Group = { resource: string, namespace: string?, names: { string } }

export type Resources = {
	rows: { ResourceRow },
	notes: { string },
	-- Internal progress: sub-query id -> group, and those still running.
	groups: { [string]: Group },
	pending: { [string]: boolean },
}

-- Steps of a defaults fallback (chart-dir, chart-source) for one revision.
type Fallback = {
	gen: number,
	source: "chart-dir" | "chart-source",
	-- Remaining fallbacks after this one fails.
	rest: { string },
	step: string,
	values: string?,
	tmp: string?,
	revision: number,
	suspect: number?,
	base: string,
}

local M = {}

M.TAG = "helm"
M.MODES = { "changed", "user", "computed", "defaults", "diff" }
M.MANAGED_SELECTOR = "app.kubernetes.io/managed-by=Helm"
M.RELEASE_ANNOTATION = "meta.helm.sh/release-name"
M.NAMESPACE_ANNOTATION = "meta.helm.sh/release-namespace"
M.CONVERTER_DIR = "helm/values-chart"
M.CONVERTER_CHART = "apiVersion: v2\nname: tk-values\nversion: 0.0.0\n"
-- F15: any values YAML comes back as one JSON document.
M.CONVERTER_TEMPLATE = "{{ .Values | toJson }}\n"
M.WRITE_TIMEOUT_MS = 10000

local KINDS: { [string]: boolean } = {
	["helm-releases"] = true,
	["helm-release"] = true,
	["helm-history"] = true,
	["helm-values"] = true,
	["helm-manifest"] = true,
	["helm-notes"] = true,
	["helm-hooks"] = true,
	["helm-resources"] = true,
	["helm-diff"] = true,
}

-- Routes of one release a key or chip opens (`helm-nav=<what>`).
local NAV: { [string]: T.RouteKind } = {
	history = "helm-history",
	values = "helm-values",
	manifest = "helm-manifest",
	notes = "helm-notes",
	hooks = "helm-hooks",
	resources = "helm-resources",
	release = "helm-release",
}

function M.isRoute(kind: string): boolean
	return KINDS[kind] == true
end

function M.validMode(v: any): string?
	return if type(v) == "string" and table.find(M.MODES, v) then v else nil
end

function M.new(): H
	return {
		gen = 0,
		lists = {},
		histories = {},
		statuses = {},
		extras = {},
		computed = {},
		resources = {},
		owners = {},
		marks = {},
		defaults = {},
		diffs = {},
		fallbacks = {},
	}
end

-- Shallow copy: every update works on a fresh H so older states stay valid.
function M.clone(h: H): H
	return table.clone(h)
end

-- Keys -------------------------------------------------------------------------

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s)
end

local function firstLine(s: string): string
	return (string.match(trim(s), "^[^\n]*") or "") :: string
end

function M.releaseKey(route: Route): string
	return (route.namespace or "") .. "/" .. (route.release or "")
end

local function keyOf(route: Route): Key
	return { name = route.release or "", namespace = route.namespace or "" }
end

local function revKey(rk: string, revision: number?): string
	return rk .. "#" .. tostring(revision or 0)
end

function M.scope(ctx: Ctx, route: Route): ExploreQuery.Scope
	if route.namespace == "*" then
		return { namespace = nil, all = true }
	elseif route.namespace then
		return { namespace = route.namespace, all = false }
	end
	-- Same scope as a list route (state.luau M.scope).
	return { namespace = ctx.target.namespace, all = ctx.target.allNamespaces }
end

function M.scopeId(sc: ExploreQuery.Scope): string
	return if sc.all then "*" else (sc.namespace or "")
end

-- The cache key of a route in state.luau (filter, selection, scroll);
-- `scope` is the route's namespace scope (state.luau M.scope).
function M.routeKey(route: Route, targetId: string, scope: ExploreQuery.Scope): string
	local parts: { string } = { route.kind, targetId }
	if route.kind == "helm-releases" then
		table.insert(parts, M.scopeId(scope))
	else
		table.insert(parts, M.releaseKey(route))
		table.insert(parts, tostring(route.revision or ""))
		table.insert(parts, tostring(route.against or ""))
	end
	return table.concat(parts, "|")
end

-- Accessors (helm/view.luau reads through these) ------------------------------

function M.listLoad(h: H, ctx: Ctx, route: Route): Load<{ ReleaseRow }>?
	return h.lists[M.scopeId(M.scope(ctx, route))]
end

local function lower(s: string?): string
	return string.lower(s or "")
end

-- The releases a list route shows: filter on name/namespace/status/chart,
-- sorted by namespace then name.
function M.releases(h: H, ctx: Ctx, route: Route, filter: string): { ReleaseRow }
	local load = M.listLoad(h, ctx, route)
	local out: { ReleaseRow } = {}
	if load == nil or load.data == nil then
		return out
	end
	local f = lower(filter)
	for _, r in load.data :: { ReleaseRow } do
		local hay = lower(r.name .. " " .. r.namespace .. " " .. r.status .. " " .. r.chart)
		if f == "" or string.find(hay, f, 1, true) then
			table.insert(out, r)
		end
	end
	table.sort(out, function(a, b)
		if a.namespace ~= b.namespace then
			return a.namespace < b.namespace
		end
		return a.name < b.name
	end)
	return out
end

function M.historyLoad(h: H, route: Route): Load<{ Revision }>?
	return h.histories[M.releaseKey(route)]
end

-- History rows newest first, filtered on status/chart/description.
function M.historyRows(h: H, route: Route, filter: string?): { Revision }
	local load = M.historyLoad(h, route)
	local out: { Revision } = {}
	if load == nil or load.data == nil then
		return out
	end
	local f = lower(filter)
	for _, r in load.data :: { Revision } do
		local hay = lower(tostring(r.revision) .. " " .. r.status .. " " .. r.chart .. " " .. r.description)
		if f == "" or string.find(hay, f, 1, true) then
			table.insert(out, r)
		end
	end
	table.sort(out, function(a, b)
		return a.revision > b.revision
	end)
	return out
end

-- A revision's status: its own read, else the latest-status read when that
-- turned out to be the same revision.
function M.statusLoad(h: H, route: Route, revision: number?): Load<ReleaseStatus>?
	local rk = M.releaseKey(route)
	local rev = revision or route.revision
	local own = h.statuses[revKey(rk, rev)]
	if own or rev == nil then
		return own
	end
	local latest = h.statuses[revKey(rk, nil)]
	if latest and latest.data and (latest.data :: ReleaseStatus).revision == rev then
		return latest
	end
	return nil
end

-- The newest revision in the loaded history.
function M.latest(h: H, route: Route): number?
	local load = M.historyLoad(h, route)
	local best: number? = nil
	if load and load.data then
		for _, r in load.data :: { Revision } do
			if best == nil or r.revision > best then
				best = r.revision
			end
		end
	end
	return best
end

-- The revision a release route shows: its own, else the latest status's.
function M.revisionOf(h: H, route: Route): number?
	if route.revision then
		return route.revision
	end
	local st = h.statuses[revKey(M.releaseKey(route), nil)]
	if st and st.data then
		return (st.data :: ReleaseStatus).revision
	end
	return M.latest(h, route)
end

function M.extrasLoad(h: H, route: Route, revision: number): Load<Extras>?
	return h.extras[revKey(M.releaseKey(route), revision)]
end

function M.computedLoad(h: H, route: Route, revision: number): Load<{ [string]: any }>?
	return h.computed[revKey(M.releaseKey(route), revision)]
end

function M.defaultsLoad(h: H, route: Route, revision: number): Load<HelmTypes.DefaultsChoice>?
	return h.defaults[revKey(M.releaseKey(route), revision)]
end

function M.resourcesLoad(h: H, route: Route): Load<Resources>?
	local rev = M.revisionOf(h, route)
	return if rev then h.resources[revKey(M.releaseKey(route), rev)] else nil
end

local function hookRows(extras: Extras?, namespace: string): { ResourceRow }
	local out: { ResourceRow } = {}
	if extras == nil then
		return out
	end
	for _, hook in extras.hooks do
		local info = Kinds.normalize(hook.kind)
		local ref: Ref = {
			kind = if info.known then info.kind else hook.kind,
			group = info.group,
			name = hook.name,
			namespace = if info.namespaced == false then nil else namespace,
			source = "live",
		}
		table.insert(out, { key = "hook:" .. Resource.key(ref), ref = ref, state = "hook", source = hook.path })
	end
	return out
end

-- Manifest objects with their live state, then hooks; filtered on
-- kind/name/state/source.
function M.resourceRows(h: H, route: Route, filter: string?): { ResourceRow }
	local load = M.resourcesLoad(h, route)
	local out: { ResourceRow } = {}
	if load == nil or load.data == nil then
		return out
	end
	local rows = table.clone((load.data :: Resources).rows)
	local rev = M.revisionOf(h, route) :: number
	local ex = M.extrasLoad(h, route, rev)
	for _, r in hookRows(if ex then ex.data else nil, route.namespace or "") do
		table.insert(rows, r)
	end
	local f = lower(filter)
	for _, r in rows do
		local hay = lower(r.ref.kind .. " " .. r.ref.name .. " " .. r.state .. " " .. (r.source or ""))
		if f == "" or string.find(hay, f, 1, true) then
			table.insert(out, r)
		end
	end
	return out
end

local function diffKey(route: Route): string
	return M.releaseKey(route) .. "#" .. tostring(route.revision or 0) .. ".." .. tostring(route.against or 0)
end

function M.diffLoad(h: H, route: Route): Load<RevDiff.Result>?
	return h.diffs[diffKey(route)]
end

function M.mark(h: H, route: Route): number?
	return h.marks[M.releaseKey(route)]
end

local function ownerKey(ctx: Ctx, o: HelmTypes.Owner): string
	return (ctx.target.context or "") .. "|" .. o.namespace .. "/" .. o.release
end

function M.owner(h: H, ctx: Ctx, obj: any): HelmTypes.OwnerInfo?
	local o = Owner.fromObject(obj)
	if o == nil then
		return nil
	end
	return h.owners[ownerKey(ctx, o)] or { owner = o, status = "loading", revision = nil, release = nil, error = nil }
end

-- A list row for the release of a release route: from a loaded list, else
-- built from its history and the latest revision's chart metadata.
function M.releaseRow(h: H, _ctx: Ctx, route: Route): ReleaseRow?
	for _, load in h.lists do
		for _, r in (load.data or {}) :: { ReleaseRow } do
			if r.name == route.release and r.namespace == route.namespace then
				return r
			end
		end
	end
	local latest = M.latest(h, route)
	if latest == nil then
		return nil
	end
	local row: Revision? = nil
	for _, r in (M.historyLoad(h, route) :: Load<{ Revision }>).data :: { Revision } do
		if r.revision == latest then
			row = r
		end
	end
	local rev = row :: Revision
	return {
		name = route.release or "",
		namespace = route.namespace or "",
		revision = rev.revision,
		updated = rev.updated,
		updatedAt = rev.updatedAt,
		status = rev.status,
		chart = rev.chart,
		chartName = rev.chartName,
		chartVersion = rev.chartVersion,
		appVersion = rev.appVersion,
	}
end

-- What `[]` vs a scalar means to the values helpers: JSON arrays decode to
-- sequences; empty ones only the host can tell from `{}`.
local function listTest(ctx: Ctx): (t: any) -> boolean
	return function(t: any): boolean
		if type(t) ~= "table" then
			return false
		end
		if #t > 0 then
			return true
		end
		local isList = ctx.isList
		return next(t) == nil and isList ~= nil and isList(t)
	end
end

function M.policy(ctx: Ctx): Redact.Policy
	return Redact.fromConfig(ctx.config)
end

-- Masked strings of the values that can echo into notes, manifests, hooks
-- and diffs (plan §5 rule 3): user values and stored defaults of `revisions`.
function M.secrets(h: H, ctx: Ctx, route: Route, revisions: { number }): { string }
	local out: { string } = {}
	local policy = M.policy(ctx)
	local isList = listTest(ctx)
	local function add(v: any)
		if type(v) == "table" then
			for _, s in Redact.maskTree(v, policy, isList).secrets do
				table.insert(out, s)
			end
		end
	end
	for _, rev in revisions do
		local st = M.statusLoad(h, route, rev)
		if st and st.data then
			add((st.data :: ReleaseStatus).user)
		end
		local ex = M.extrasLoad(h, route, rev)
		if ex and ex.data then
			add((ex.data :: Extras).defaults)
		end
	end
	return out
end

-- The values comparison of a helm-values route; nil while its inputs load.
function M.valuesCompare(h: H, ctx: Ctx, route: Route): Values.Compare?
	local rev = M.revisionOf(h, route)
	if rev == nil then
		return nil
	end
	local st = M.statusLoad(h, route, route.revision)
	local computed = M.computedLoad(h, route, rev)
	local choice = M.defaultsLoad(h, route, rev)
	if st == nil or st.data == nil or choice == nil or choice.status == "loading" then
		return nil
	end
	if computed == nil or computed.status == "loading" then
		return nil
	end
	local ex = M.extrasLoad(h, route, rev)
	local deps = if ex and ex.data then (ex.data :: Extras).chart.dependencies else {}
	local c: HelmTypes.DefaultsChoice = choice.data
		or { source = "unavailable", revision = nil, values = nil, note = choice.error }
	local rows =
		Values.compare(c.values, (st.data :: ReleaseStatus).user, computed.data, deps, listTest(ctx), M.policy(ctx))
	local source: Values.DefaultsSource = c.source :: any
	return {
		rows = rows,
		source = source,
		sourceNote = c.note or Values.note(source, rev, c.revision),
		counts = Values.counts(rows),
	}
end

-- Effects ----------------------------------------------------------------------

local function toast(effects: { Effect }, level: "success" | "info" | "error", text: string, sub: string?)
	table.insert(effects, { t = "toast", level = level, text = text, sub = sub })
end

local function timeout(ctx: Ctx): number
	return ctx.config.explore.query_timeout_ms
end

local function helmEnv(ctx: Ctx): { [string]: string }
	return Query.env(ctx.config.helm.driver, ctx.target.kubeconfig)
end

function M.notFound(ctx: Ctx): string
	return Shellenv.notFoundText("helm", ctx.config.helm.program, ctx.daemonPath)
end

local function failText(ctx: Ctx, what: string, r: ProcessResult?, spawnError: string?): string
	if spawnError then
		if what == "helm" and Shellenv.isNotFound(spawnError) then
			return M.notFound(ctx)
		end
		return what .. " could not start: " .. spawnError
	end
	local res = r :: ProcessResult
	if res.timed_out then
		return what .. " timed out"
	end
	local detail = firstLine(if res.stderr ~= "" then res.stderr else res.stdout)
	local text = string.format("%s exited %d%s", what, res.status, if detail ~= "" then ": " .. detail else "")
	if what == "helm" and Parse.errorKind(res.stderr) == "forbidden" then
		text ..= " (helm reads release records from Secrets; narrow the namespace scope with n)"
	end
	return text
end

local function run(
	h: H,
	ctx: Ctx,
	tag: string,
	argv: { string },
	effects: { Effect },
	env: { [string]: string }?
): number
	h.gen += 1
	table.insert(effects, {
		t = "run",
		tag = M.TAG .. "|" .. tag,
		gen = h.gen,
		argv = argv,
		env = env,
		timeout_ms = timeout(ctx),
	})
	return h.gen
end

-- One of the ExploreState maps of loads ("lists", "statuses", ...).
type MapName = string

local function getMap(h: H, name: MapName): { [string]: Load<any> }
	return (h :: any)[name]
end

local function setEntry(h: H, name: MapName, key: string, load: Load<any>?)
	local map: { [string]: any } = table.clone(getMap(h, name))
	map[key] = load;
	(h :: any)[name] = map
end

-- Starts a helm read into map[key] unless one exists (r: `force`). Without
-- helm nothing starts: the view shows the not-found card instead.
local function load(h: H, ctx: Ctx, name: MapName, key: string, build: (string) -> { string }, effects: { Effect })
	local program = ctx.helm
	if getMap(h, name)[key] ~= nil or program == nil then
		return
	end
	local argv = build(program)
	local gen = run(h, ctx, name .. "|" .. key, argv, effects, helmEnv(ctx))
	setEntry(h, name, key, { status = "loading", gen = gen, data = nil, error = nil, argv = argv, at = nil })
end

local function settled(l: Load<any>?): boolean
	return l ~= nil and (l.status == "ok" or l.status == "error")
end

-- Ensure -----------------------------------------------------------------------

local function ensureStatus(h: H, ctx: Ctx, route: Route, revision: number?, effects: { Effect })
	if revision and M.statusLoad(h, route, revision) then
		return
	end
	load(h, ctx, "statuses", revKey(M.releaseKey(route), revision), function(p)
		return Query.status(p, ctx.target, keyOf(route), revision)
	end, effects)
end

local function ensureHistory(h: H, ctx: Ctx, route: Route, effects: { Effect })
	load(h, ctx, "histories", M.releaseKey(route), function(p)
		return Query.history(p, ctx.target, keyOf(route), ctx.config.helm.history_max)
	end, effects)
end

local function ensureExtras(h: H, ctx: Ctx, route: Route, revision: number, effects: { Effect })
	load(h, ctx, "extras", revKey(M.releaseKey(route), revision), function(p)
		return Query.extras(p, ctx.target, keyOf(route), revision)
	end, effects)
end

local function ensureComputed(h: H, ctx: Ctx, route: Route, revision: number, effects: { Effect })
	load(h, ctx, "computed", revKey(M.releaseKey(route), revision), function(p)
		return Query.valuesAll(p, ctx.target, keyOf(route), revision)
	end, effects)
end

-- The route's status and, once its revision is known, that revision's extras.
local function ensureRelease(h: H, ctx: Ctx, route: Route, effects: { Effect })
	ensureStatus(h, ctx, route, route.revision, effects)
	local rev = M.revisionOf(h, route)
	if rev then
		ensureExtras(h, ctx, route, rev, effects)
	end
end

-- Defaults (plan §4.2/4.3) ------------------------------------------------------

local function setDefaults(h: H, k: string, choice: HelmTypes.DefaultsChoice?, err: string?)
	setEntry(h, "defaults", k, {
		status = if choice then "ok" else "error",
		gen = 0,
		data = choice,
		error = err,
		argv = nil,
		at = nil,
	})
end

local function converterDir(ctx: Ctx): string
	return (ctx.dataDir :: string) .. "/" .. M.CONVERTER_DIR
end

local function chartSourceRef(ctx: Ctx, chart: string): string?
	for _, s in ctx.config.helm.chart_sources do
		if s.chart == chart then
			return s.ref
		end
	end
	return nil
end

local function fbTag(k: string, step: string): string
	return "fb|" .. k .. "|" .. step
end

local function setFallback(h: H, k: string, fb: Fallback?)
	local map = table.clone(h.fallbacks)
	map[k] = fb
	h.fallbacks = map
end

local function writeEffect(
	h: H,
	_ctx: Ctx,
	k: string,
	step: string,
	path: string,
	text: string,
	effects: { Effect }
): number
	h.gen += 1
	table.insert(effects, {
		t = "run",
		tag = M.TAG .. "|" .. fbTag(k, step),
		gen = h.gen,
		argv = { "/bin/sh", "-c", Gitops.WRITE_SCRIPT, "tern-kube-tmp", path },
		stdin = text,
		timeout_ms = M.WRITE_TIMEOUT_MS,
	})
	return h.gen
end

local nextFallback: (h: H, ctx: Ctx, route: Route, k: string, fb: Fallback?, rest: { string }, effects: { Effect }) -> ()

-- No fallback left: the suspect record when there is one, else nothing.
local function finishSuspect(h: H, route: Route, k: string, suspect: number?, note: string?)
	setFallback(h, k, nil)
	local ex = if suspect then M.extrasLoad(h, route, suspect) else nil
	if ex and ex.data then
		setDefaults(
			h,
			k,
			{ source = "record-suspect", revision = suspect, values = (ex.data :: Extras).defaults, note = note },
			nil
		)
	else
		setDefaults(h, k, { source = "unavailable", revision = nil, values = nil, note = note }, nil)
	end
end

function nextFallback(h: H, ctx: Ctx, route: Route, k: string, prev: Fallback?, rest: { string }, effects: { Effect })
	local rev = tonumber(string.match(k, "#(%d+)$")) :: number
	local suspect = if prev then prev.suspect else rev
	local ex = M.extrasLoad(h, route, rev)
	local chart = if ex and ex.data then (ex.data :: Extras).chart else nil
	local remaining = table.clone(rest)
	while #remaining > 0 do
		local which = table.remove(remaining, 1) :: string
		local base = ""
		local valuesPath: string? = nil
		if ctx.helm == nil or ctx.dataDir == nil or chart == nil then
			break
		end
		if which == "chart-dir" then
			local dir = Detect.matchChart(ctx.chartDirs, chart.name, chart.version)
			if dir then
				valuesPath = dir.path .. "/values.yaml"
			end
		elseif which == "chart-source" then
			if chartSourceRef(ctx, chart.name) then
				local nonce = if ctx.nonce then ctx.nonce() else tostring(h.gen)
				base = string.format("%s/tmp/values-%d-%s.yaml", ctx.dataDir :: string, ctx.now or 0, nonce)
			end
		end
		if valuesPath or base ~= "" then
			local fb: Fallback = {
				gen = 0,
				source = which :: any,
				rest = remaining,
				step = "chart",
				values = valuesPath,
				tmp = if base ~= "" then base else nil,
				revision = rev,
				suspect = suspect,
				base = base,
			}
			fb.gen = writeEffect(h, ctx, k, "chart", converterDir(ctx) .. "/Chart.yaml", M.CONVERTER_CHART, effects)
			setFallback(h, k, fb)
			return
		end
	end
	finishSuspect(h, route, k, suspect, nil)
end

-- The JSON a converter render printed (after helm's `# Source:` header).
function M.converted(stdout: string, decode: T.Decode): { [string]: any }?
	local start = string.find(stdout, "{", 1, true)
	if start == nil then
		return nil
	end
	local ok, v = pcall(decode, string.sub(stdout, start))
	return if ok and type(v) == "table" then v else nil
end

local function onFallback(h: H, ctx: Ctx, route: Route?, k: string, step: string, msg: Msg, effects: { Effect })
	local fb = h.fallbacks[k] :: Fallback?
	if fb == nil or fb.gen ~= msg.gen or fb.step ~= step or route == nil then
		return
	end
	local r = msg.result :: ProcessResult
	local failed = msg.spawnError ~= nil or r.status ~= 0 or r.timed_out
	local nextFb: Fallback = table.clone(fb)
	local program = ctx.helm :: string
	local tmp = fb.tmp
	local function cleanup()
		if tmp then
			h.gen += 1
			table.insert(effects, {
				t = "run",
				tag = M.TAG .. "|" .. fbTag(k, "rm"),
				gen = h.gen,
				argv = { "rm", "-f", "--", tmp },
				timeout_ms = M.WRITE_TIMEOUT_MS,
			})
		end
	end
	if failed then
		if step ~= "rm" then
			cleanup()
			nextFallback(h, ctx, route, k, fb, fb.rest, effects)
		end
		return
	end
	if step == "chart" then
		nextFb.step = "template-file"
		nextFb.gen = writeEffect(
			h,
			ctx,
			k,
			"template-file",
			converterDir(ctx) .. "/templates/values.yaml",
			M.CONVERTER_TEMPLATE,
			effects
		)
	elseif step == "template-file" and fb.source == "chart-source" then
		local ex = M.extrasLoad(h, route, fb.revision) :: Load<Extras>
		local chart = (ex.data :: Extras).chart
		nextFb.step = "show"
		nextFb.gen = run(h, ctx, fbTag(k, "show"), {
			program,
			"show",
			"values",
			chartSourceRef(ctx, chart.name) :: string,
			"--version",
			chart.version,
		}, effects, helmEnv(ctx))
	elseif step == "show" then
		nextFb.step = "tmp"
		nextFb.values = tmp
		nextFb.gen = writeEffect(h, ctx, k, "tmp", tmp :: string, r.stdout, effects)
	elseif step == "template-file" or step == "tmp" then
		nextFb.step = "render"
		nextFb.gen = run(
			h,
			ctx,
			fbTag(k, "render"),
			Query.template(program, "tk-values", converterDir(ctx), nil, { nextFb.values :: string }),
			effects,
			nil
		)
	elseif step == "render" then
		cleanup()
		local values = M.converted(r.stdout, ctx.decode)
		if values == nil then
			nextFallback(h, ctx, route, k, fb, fb.rest, effects)
			return
		end
		setFallback(h, k, nil)
		setDefaults(h, k, { source = fb.source :: string, revision = nil, values = values, note = nil }, nil)
		return
	else
		return
	end
	setFallback(h, k, nextFb)
end

-- Inputs of Values.pristine, fetched lazily (only the Values view needs them).
local function ensureDefaults(h: H, ctx: Ctx, route: Route, rev: number, effects: { Effect })
	local rk = M.releaseKey(route)
	local k = revKey(rk, rev)
	local existing = h.defaults[k]
	if existing and existing.status ~= "loading" then
		return
	end
	if existing == nil then
		setEntry(h, "defaults", k, { status = "loading", gen = 0, data = nil, error = nil, argv = nil, at = nil })
	end
	if h.fallbacks[k] ~= nil then
		return
	end
	local hist = M.historyLoad(h, route)
	local own = M.extrasLoad(h, route, rev)
	if not settled(hist) or not settled(own) then
		return
	end
	if (hist :: Load<{ Revision }>).status == "error" or (own :: Load<Extras>).status == "error" then
		nextFallback(h, ctx, route, k, nil, { "chart-dir", "chart-source" }, effects)
		return
	end
	local history = (hist :: Load<{ Revision }>).data :: { Revision }
	local needs = Values.needs(history, rev)
	local waiting = false
	for _, r in needs.extras do
		ensureExtras(h, ctx, route, r, effects)
		waiting = waiting or not settled(M.extrasLoad(h, route, r))
	end
	for _, r in needs.users do
		ensureStatus(h, ctx, route, r, effects)
		waiting = waiting or not settled(M.statusLoad(h, route, r))
	end
	if waiting then
		return
	end
	local extras: { [number]: Extras } = {}
	for _, r in needs.extras do
		local l = M.extrasLoad(h, route, r)
		if l and l.data then
			extras[r] = l.data
		end
	end
	extras[rev] = (own :: Load<Extras>).data :: Extras
	local users: { [number]: { [string]: any } } = {}
	for _, r in needs.users do
		local l = M.statusLoad(h, route, r)
		if l and l.data then
			users[r] = (l.data :: ReleaseStatus).user
		end
	end
	local pick, source = Values.pristine(history, extras, users, rev)
	if (source == "record" or source == "record-earliest") and pick and extras[pick] then
		setDefaults(
			h,
			k,
			{ source = source :: string, revision = pick, values = extras[pick].defaults, note = nil },
			nil
		)
		return
	end
	nextFallback(h, ctx, route, k, { suspect = pick } :: any, { "chart-dir", "chart-source" }, effects)
end

-- Revision diff ----------------------------------------------------------------

local function ensureDiff(h: H, ctx: Ctx, route: Route, effects: { Effect })
	local a, b = route.revision, route.against
	if a == nil or b == nil then
		return
	end
	ensureStatus(h, ctx, route, a, effects)
	ensureStatus(h, ctx, route, b, effects)
	ensureExtras(h, ctx, route, a, effects)
	ensureExtras(h, ctx, route, b, effects)
	local dk = diffKey(route)
	if h.diffs[dk] ~= nil then
		return
	end
	local sa, sb = M.statusLoad(h, route, a), M.statusLoad(h, route, b)
	local ea, eb = M.extrasLoad(h, route, a), M.extrasLoad(h, route, b)
	if not (settled(sa) and settled(sb) and settled(ea) and settled(eb)) then
		return
	end
	local la, lb = sa :: Load<ReleaseStatus>, sb :: Load<ReleaseStatus>
	if la.data == nil or lb.data == nil then
		setEntry(h, "diffs", dk, {
			status = "error",
			gen = 0,
			data = nil,
			error = (if la.data == nil then la.error else lb.error) or "revision not readable",
			argv = nil,
			at = nil,
		})
		return
	end
	local hooksA = if ea and ea.data then (ea.data :: Extras).hooks else nil
	local hooksB = if eb and eb.data then (eb.data :: Extras).hooks else nil
	local ok, result = pcall(
		RevDiff.diff,
		(la.data :: ReleaseStatus).manifest,
		(lb.data :: ReleaseStatus).manifest,
		{ namespace = route.namespace or "", policy = M.policy(ctx), secrets = M.secrets(h, ctx, route, { a, b }) },
		hooksA,
		hooksB
	)
	setEntry(h, "diffs", dk, {
		status = if ok then "ok" else "error",
		gen = 0,
		data = if ok then result else nil,
		error = if ok then nil else "Could not diff the revisions: " .. tostring(result),
		argv = nil,
		at = nil,
	})
end

-- Resources --------------------------------------------------------------------

-- `# Source:` path of each document start line in a helm manifest.
local function sources(manifest: string): { [number]: string }
	local out: { [number]: string } = {}
	local current: string? = nil
	for i, line in string.split(manifest, "\n") do
		local path = string.match(line, "^# Source: (.+)$")
		if path then
			current = trim(path)
		elseif line == "---" then
			current = nil
		end
		if current then
			out[i] = current
		end
	end
	return out
end

local function groupId(resource: string, namespace: string?): string
	return resource .. "@" .. (namespace or "")
end

local function annotated(obj: any, key: Key): boolean
	local md = if type(obj) == "table" then obj.metadata else nil
	local ann = if type(md) == "table" then md.annotations else nil
	return type(ann) == "table"
		and ann[M.RELEASE_ANNOTATION] == key.name
		and ann[M.NAMESPACE_ANNOTATION] == key.namespace
end

local function setResources(h: H, k: string, l: Load<Resources>, data: Resources)
	local upd = table.clone(l)
	upd.data = data
	setEntry(h, "resources", k, upd)
end

local function finishResources(h: H, k: string, l: Load<Resources>, data: Resources)
	local upd = table.clone(l)
	upd.data = data
	upd.status = "ok"
	setEntry(h, "resources", k, upd)
end

local function ensureResources(h: H, ctx: Ctx, route: Route, effects: { Effect })
	local rev = M.revisionOf(h, route)
	local st = M.statusLoad(h, route, route.revision)
	if rev == nil or st == nil or st.data == nil then
		return
	end
	local k = revKey(M.releaseKey(route), rev)
	if h.resources[k] ~= nil then
		return
	end
	local manifest = (st.data :: ReleaseStatus).manifest
	local srcs = sources(manifest)
	local rows: { ResourceRow } = {}
	local groups: { [string]: Group } = {}
	for _, doc in Yaml.split(manifest).docs do
		local ref = doc.ref
		if ref == nil then
			continue
		end
		local info = Kinds.normalize(if ref.group and ref.group ~= "" then ref.kind .. "." .. ref.group else ref.kind)
		local ns = ref.namespace
		if info.namespaced == false then
			ns = nil
		elseif ns == nil or ns == "" then
			ns = route.namespace
		end
		local r: Ref = {
			kind = ref.kind,
			group = ref.group,
			version = ref.version,
			name = ref.name,
			namespace = ns,
			source = "live",
		}
		table.insert(rows, { key = Resource.key(r), ref = r, state = "missing", source = srcs[doc.startLine] })
		local resource = Command.resourceType(r)
		local gid = groupId(resource, ns)
		local g = groups[gid] or { resource = resource, namespace = ns, names = {} }
		table.insert(g.names, r.name)
		groups[gid] = g
	end
	local data: Resources = { rows = rows, notes = {}, groups = groups, pending = {} }
	local l: Load<Resources> = { status = "loading", gen = 0, data = data, error = nil, argv = nil, at = nil }
	if next(groups) == nil then
		finishResources(h, k, l, data)
		return
	end
	for gid, g in groups do
		local argv = ExploreQuery.base(ctx.kubectl, ctx.target)
		for _, a in { "get", g.resource, "-l", M.MANAGED_SELECTOR, "-o", "json" } do
			table.insert(argv, a)
		end
		if g.namespace then
			table.insert(argv, "-n")
			table.insert(argv, g.namespace)
		end
		data.pending[gid] = true
		l.gen = run(h, ctx, "res|" .. k .. "|" .. gid, argv, effects, nil)
	end
	setResources(h, k, l, data)
end

local function onResources(h: H, ctx: Ctx, k: string, sub: string, msg: Msg, effects: { Effect })
	local l = h.resources[k] :: Load<Resources>?
	if l == nil or l.status ~= "loading" or l.data == nil then
		return
	end
	local data = table.clone(l.data :: Resources)
	if not data.pending[sub] then
		return
	end
	local pending = table.clone(data.pending)
	pending[sub] = nil
	data.pending = pending
	local rows = table.clone(data.rows)
	data.rows = rows
	local notes = table.clone(data.notes)
	data.notes = notes
	local r = msg.result :: ProcessResult
	local failed = msg.spawnError ~= nil or r.status ~= 0 or r.timed_out
	local relNs, relName = string.match(k, "^([^/]*)/(.-)#%d+$")
	local key: Key = { name = relName or "", namespace = relNs or "" }
	local names = string.match(sub, "^names:(.*)$")
	local gid = names or sub
	local g = data.groups[gid]
	if failed then
		table.insert(notes, failText(ctx, "kubectl", r, msg.spawnError))
		for i, row in rows do
			if row.state == "missing" and groupId(Command.resourceType(row.ref), row.ref.namespace) == gid then
				local upd = table.clone(row)
				upd.state = "unknown"
				rows[i] = upd
			end
		end
	elseif names then
		for _, line in string.split(r.stdout, "\n") do
			local name = string.match(trim(line), "/(.+)$")
			for i, row in rows do
				if
					name
					and row.state == "missing"
					and row.ref.name == name
					and groupId(Command.resourceType(row.ref), row.ref.namespace) == gid
				then
					local upd = table.clone(row)
					upd.state = "present"
					rows[i] = upd
				end
			end
		end
	else
		local ok, doc = pcall(ctx.decode, r.stdout)
		local items = if ok and type(doc) == "table" and type(doc.items) == "table" then doc.items else {}
		local missing: { string } = {}
		for _, obj in items do
			if not annotated(obj, key) then
				continue
			end
			local ref = Resource.fromObject(obj, "live")
			if ref == nil then
				continue
			end
			local rk = Resource.key(ref)
			local found = false
			for i, row in rows do
				if row.key == rk then
					local upd = table.clone(row)
					upd.state = "present"
					rows[i] = upd
					found = true
				end
			end
			if not found then
				table.insert(rows, { key = rk, ref = ref, state = "extra", source = nil })
			end
		end
		for _, row in rows do
			if row.state == "missing" and groupId(Command.resourceType(row.ref), row.ref.namespace) == gid then
				table.insert(missing, row.ref.name)
			end
		end
		-- Objects of releases older than helm 3.2 carry no release annotations.
		if #missing > 0 and g then
			local argv = ExploreQuery.base(ctx.kubectl, ctx.target)
			table.insert(argv, "get")
			table.insert(argv, g.resource)
			for _, n in missing do
				table.insert(argv, n)
			end
			if g.namespace then
				table.insert(argv, "-n")
				table.insert(argv, g.namespace)
			end
			for _, a in { "--ignore-not-found", "-o", "name" } do
				table.insert(argv, a)
			end
			local p2 = table.clone(pending)
			p2["names:" .. gid] = true
			data.pending = p2
			local upd = table.clone(l)
			upd.gen = run(h, ctx, "res|" .. k .. "|names:" .. gid, argv, effects, nil)
			setResources(h, k, upd, data)
			return
		end
	end
	if next(data.pending) == nil then
		finishResources(h, k, l, data)
	else
		setResources(h, k, l, data)
	end
end

-- Enter ------------------------------------------------------------------------

local function releaseScoped(kind: string): boolean
	return kind ~= "helm-releases" and kind ~= "helm-diff"
end

-- Drops what was read for the route's release (or list scope): r reloads it.
local function forget(h: H, ctx: Ctx, route: Route)
	if route.kind == "helm-releases" then
		setEntry(h, "lists", M.scopeId(M.scope(ctx, route)), nil)
		return
	end
	local rk = M.releaseKey(route)
	local prefix = rk .. "#"
	for _, name in { "statuses", "extras", "computed", "defaults", "diffs", "resources" } do
		local map = table.clone(getMap(h, name))
		for k in getMap(h, name) do
			if string.sub(k, 1, #prefix) == prefix then
				map[k] = nil
			end
		end
		(h :: any)[name] = map
	end
	local fbs = table.clone(h.fallbacks)
	for k in h.fallbacks do
		if string.sub(k, 1, #prefix) == prefix then
			fbs[k] = nil
		end
	end
	h.fallbacks = fbs
	setEntry(h, "histories", rk, nil)
end

-- Starts what `route` still needs (force: r reads everything again).
function M.enter(h: H, ctx: Ctx, route: Route, force: boolean, effects: { Effect })
	if not ctx.resolved then
		return
	end
	if force then
		forget(h, ctx, route)
	end
	local kind = route.kind
	if kind == "helm-releases" then
		local sc = M.scope(ctx, route)
		load(h, ctx, "lists", M.scopeId(sc), function(p)
			return Query.list(p, ctx.target, sc, ctx.config.helm.list_max)
		end, effects)
		return
	end
	if route.release == nil or route.namespace == nil then
		return
	end
	if kind == "helm-diff" then
		ensureDiff(h, ctx, route, effects)
		return
	end
	if kind == "helm-history" then
		ensureHistory(h, ctx, route, effects)
		return
	end
	if releaseScoped(kind) then
		ensureRelease(h, ctx, route, effects)
	end
	if kind == "helm-release" or kind == "helm-values" then
		ensureHistory(h, ctx, route, effects)
	end
	local rev = M.revisionOf(h, route)
	-- The release header carries the values summary, which needs both.
	if (kind == "helm-values" or kind == "helm-release") and rev then
		ensureComputed(h, ctx, route, rev, effects)
		ensureDefaults(h, ctx, route, rev, effects)
	elseif kind == "helm-resources" then
		ensureResources(h, ctx, route, effects)
	end
end

-- Items ------------------------------------------------------------------------

function M.items(h: H, ctx: Ctx, route: Route, filter: string?): { Item }
	local out: { Item } = {}
	local kind = route.kind
	if kind == "helm-releases" then
		for _, r in M.releases(h, ctx, route, filter or "") do
			table.insert(out, { key = r.namespace .. "/" .. r.name, value = r.name })
		end
	elseif kind == "helm-history" then
		for _, r in M.historyRows(h, route, filter) do
			table.insert(out, { key = tostring(r.revision), value = tostring(r.revision) })
		end
	elseif kind == "helm-resources" then
		for _, r in M.resourceRows(h, route, filter) do
			table.insert(out, { key = r.key, ref = r.ref })
		end
	end
	return out
end

-- The object keys act on: a helm-resources row (not hooks: helm deletes
-- most of them after they ran).
function M.focusRef(_h: H, _ctx: Ctx, route: Route, selected: Item?): Ref?
	if route.kind == "helm-resources" and selected and selected.ref and string.sub(selected.key, 1, 5) ~= "hook:" then
		return selected.ref
	end
	return nil
end

-- Keys -------------------------------------------------------------------------

local function releaseRoute(kind: T.RouteKind, name: string, namespace: string, revision: number?): Route
	return { kind = kind, release = name, namespace = namespace, revision = revision }
end

-- The release a key acts on: the route's own, or the selected list row.
local function subject(route: Route, selected: Item?): (string?, string?)
	if route.kind == "helm-releases" then
		if selected == nil then
			return nil, nil
		end
		local ns, name = string.match(selected.key, "^([^/]*)/(.+)$")
		return name, ns
	end
	return route.release, route.namespace
end

-- The default rollback target: the highest revision below the latest that
-- was deployed or superseded (F11: a failed upgrade is no target).
function M.defaultTarget(history: { Revision }): number?
	local latest = 0
	for _, r in history do
		latest = math.max(latest, r.revision)
	end
	local best: number? = nil
	for _, r in history do
		if r.revision < latest and (r.status == "deployed" or r.status == "superseded") then
			if best == nil or r.revision > best then
				best = r.revision
			end
		end
	end
	return best
end

local function rollback(h: H, ctx: Ctx, route: Route, revision: number?, effects: { Effect })
	if not ctx.config.mutations.enabled then
		toast(effects, "error", "Mutations are disabled", "mutations.enabled is false in the config")
		return
	end
	if not ctx.resolved then
		toast(effects, "error", "No cluster target yet", "Pick a context first (c)")
		return
	end
	local target = revision
	if target == nil then
		local hist = M.historyLoad(h, route)
		if hist == nil or hist.data == nil then
			toast(effects, "error", "History not loaded yet", "Wait for the release history, then press ctrl+r again")
			return
		end
		target = M.defaultTarget(hist.data :: { Revision })
		if target == nil then
			toast(
				effects,
				"error",
				"No earlier revision to roll back to",
				"No deployed or superseded revision below the latest"
			)
			return
		end
	end
	local t = ctx.target
	local url, err = Link.forRelease(keyOf(route), target :: number, {
		context = t.context,
		source = Link.sourceOf(t.contextSource, t.confirmed),
		kubeconfig = t.kubeconfig,
	}, nil)
	if url == nil then
		toast(effects, "error", "Cannot roll back " .. (route.release or ""), err)
		return
	end
	table.insert(effects, { t = "open", url = url })
end

-- What `=` compares: in history the selected revision against the marked
-- one, else against the latest; in a release route its revision against the
-- previous one.
local function diffRoute(h: H, route: Route, selected: Item?, effects: { Effect }): Route?
	local a: number?, b: number?
	if route.kind == "helm-history" then
		local sel = if selected then tonumber(selected.key) else nil
		local other = M.mark(h, route) or M.latest(h, route)
		if sel == nil or other == nil then
			return nil
		end
		if sel == other then
			toast(effects, "info", "Same revision", "Mark another revision with space, or select an older one")
			return nil
		end
		a, b = math.min(sel, other), math.max(sel, other)
	else
		local rev = M.revisionOf(h, route)
		if rev == nil then
			return nil
		end
		if rev <= 1 then
			toast(effects, "info", "No earlier revision", "Revision 1 is the first one")
			return nil
		end
		a, b = rev - 1, rev
	end
	return { kind = "helm-diff", release = route.release, namespace = route.namespace, revision = a, against = b }
end

local function nextMode(mode: string?): string
	local i = table.find(M.MODES, mode or "changed") or 1
	return M.MODES[i % #M.MODES + 1]
end

local function nav(_h: H, route: Route, what: string, selected: Item?): Nav?
	local kind = NAV[what]
	if kind == nil then
		return nil
	end
	local name, ns = subject(route, selected)
	if name == nil or ns == nil then
		return nil
	end
	local revision = if route.kind == "helm-releases" or kind == "helm-history" then nil else route.revision
	if kind == "helm-values" and route.kind == "helm-values" then
		local upd = table.clone(route)
		upd.mode = nextMode(route.mode)
		return { replace = upd }
	end
	if route.kind == kind then
		return nil
	end
	local r = releaseRoute(kind :: T.RouteKind, name, ns, revision)
	if route.kind == "helm-diff" then
		r.revision = route.against
	end
	return { push = r }
end

local function toggleMark(h: H, route: Route, revision: number?)
	if revision == nil then
		return
	end
	local rk = M.releaseKey(route)
	local marks: { [string]: number? } = table.clone(h.marks)
	marks[rk] = if marks[rk] == revision then nil else revision
	h.marks = marks :: any
end

-- Keys of the Helm routes; false lets the global keys run.
function M.onKey(
	h: H,
	ctx: Ctx,
	route: Route,
	selected: Item?,
	ch: string?,
	key: T.Key,
	effects: { Effect }
): (boolean, Nav?)
	local name = key.name
	local kind = route.kind
	if name == "enter" or name == "return" then
		if selected == nil then
			return kind == "helm-releases" or kind == "helm-history", nil
		end
		if kind == "helm-releases" then
			local nm, ns = subject(route, selected)
			return true, { push = releaseRoute("helm-release", nm :: string, ns :: string, nil) }
		elseif kind == "helm-history" then
			local rev = tonumber(selected.key)
			return true,
				{ push = releaseRoute("helm-release", route.release :: string, route.namespace :: string, rev) }
		elseif kind == "helm-resources" then
			if string.sub(selected.key, 1, 5) == "hook:" or selected.ref == nil then
				return true, nil
			end
			for _, r in M.resourceRows(h, route, nil) do
				if r.key == selected.key and r.state == "missing" then
					toast(effects, "info", "Not in the cluster", r.ref.kind .. " " .. r.ref.name .. " is missing")
					return true, nil
				end
			end
			return true, { push = { kind = "detail", ref = selected.ref } }
		end
		return false, nil
	end
	if key.ctrl then
		if name == "r" then
			if kind == "helm-history" then
				rollback(h, ctx, route, if selected then tonumber(selected.key) else nil, effects)
			elseif kind == "helm-releases" then
				local nm, ns = subject(route, selected)
				if nm == nil then
					toast(effects, "error", "Select a release first")
					return true, nil
				end
				toast(effects, "info", "Open the release first", "ctrl+r rolls back from the release or its history")
				return true, { push = releaseRoute("helm-release", nm, ns :: string, nil) }
			else
				rollback(h, ctx, route, nil, effects)
			end
			return true, nil
		end
		return false, nil
	end
	if ch == "h" and not key.shift then
		local n = nav(h, route, "history", selected)
		return n ~= nil or kind == "helm-history", n
	elseif ch == "v" and not key.shift then
		local n = nav(h, route, "values", selected)
		return n ~= nil, n
	elseif ch == "M" then
		local n = nav(h, route, "manifest", selected)
		return n ~= nil or kind == "helm-manifest", n
	elseif ch == "N" then
		local n = nav(h, route, "notes", selected)
		return n ~= nil or kind == "helm-notes", n
	elseif ch == "K" then
		local n = nav(h, route, "hooks", selected)
		return n ~= nil or kind == "helm-hooks", n
	elseif ch == "R" then
		local n = nav(h, route, "resources", selected)
		return n ~= nil or kind == "helm-resources", n
	elseif ch == "=" then
		if kind == "helm-releases" or kind == "helm-diff" then
			return true, nil
		end
		local r = diffRoute(h, route, selected, effects)
		return true, if r then { push = r } else nil
	elseif (name == "space" or ch == " ") and kind == "helm-history" then
		toggleMark(h, route, if selected then tonumber(selected.key) else nil)
		return true, nil
	elseif ch == "Y" then
		M.copy(h, ctx, route, effects)
		return true, nil
	end
	return false, nil
end

-- Pointer actions of the Helm views (`helm-<what>=<value>`); helm-open also
-- comes from the owner line of non-Helm routes.
function M.onAction(h: H, ctx: Ctx, route: Route, act: string, value: string, effects: { Effect }): (boolean, Nav?)
	if act == "helm-open" then
		local ns, name, rev = string.match(value, "^([^/]+)/([^#]+)#?(%d*)$")
		if ns == nil or name == nil or not Query.validRelease(name) then
			return false, nil
		end
		local revision = tonumber(rev)
		if revision and not Query.validRevision(revision) then
			revision = nil
		end
		return true, { push = releaseRoute("helm-release", name, ns, revision) }
	end
	if not M.isRoute(route.kind) then
		return false, nil
	end
	if act == "helm-nav" then
		if value == "diff" then
			local r = diffRoute(h, route, nil, effects)
			return r ~= nil, if r then { push = r } else nil
		end
		local n = nav(h, route, value, nil)
		return n ~= nil, n
	elseif act == "helm-mode" then
		local mode = M.validMode(value)
		if route.kind ~= "helm-values" or mode == nil then
			return false, nil
		end
		local upd = table.clone(route)
		upd.mode = mode
		return true, { replace = upd }
	elseif act == "helm-rollback" then
		local rev = tonumber(value)
		if rev and not Query.validRevision(rev) then
			return false, nil
		end
		rollback(h, ctx, route, rev, effects)
		return true, nil
	elseif act == "helm-mark" then
		local rev = tonumber(value)
		if route.kind ~= "helm-history" or rev == nil then
			return false, nil
		end
		toggleMark(h, route, rev)
		return true, nil
	end
	return false, nil
end

-- Copy -------------------------------------------------------------------------

local function getVerb(ctx: Ctx, route: Route, what: string, revision: number?): { string }
	local argv = Query.base("helm", ctx.target)
	for _, a in { "get", what, route.release or "", "-n", route.namespace or "" } do
		table.insert(argv, a)
	end
	if revision then
		table.insert(argv, "--revision")
		table.insert(argv, tostring(revision))
	end
	return argv
end

-- The helm command a user would type for the view (`helm`, not the
-- resolved path); nil for views that are not one command.
function M.commandArgv(h: H, ctx: Ctx, route: Route): { string }?
	if ctx.target.context == nil then
		return nil
	end
	local kind = route.kind
	local key = keyOf(route)
	if kind == "helm-releases" then
		return Query.list("helm", ctx.target, M.scope(ctx, route), ctx.config.helm.list_max)
	elseif kind == "helm-history" then
		return Query.history("helm", ctx.target, key, ctx.config.helm.history_max)
	elseif kind == "helm-release" then
		return Query.status("helm", ctx.target, key, route.revision)
	elseif kind == "helm-values" then
		local rev = M.revisionOf(h, route)
		return if rev then Query.valuesAll("helm", ctx.target, key, rev) else nil
	elseif kind == "helm-manifest" or kind == "helm-resources" then
		return getVerb(ctx, route, "manifest", route.revision)
	elseif kind == "helm-notes" then
		return getVerb(ctx, route, "notes", route.revision)
	elseif kind == "helm-hooks" then
		return getVerb(ctx, route, "hooks", route.revision)
	end
	return nil
end

function M.copy(h: H, ctx: Ctx, route: Route, effects: { Effect })
	local argv = M.commandArgv(h, ctx, route)
	if argv == nil then
		toast(effects, "info", "Nothing to copy", "This view is not one helm command")
		return
	end
	local text = Command.format(argv)
	table.insert(effects, { t = "copy", text = text })
	toast(effects, "success", "Copied", text)
end

-- Owners -----------------------------------------------------------------------

-- An opened object managed by a Helm release: look the release up once per
-- context and release.
function M.noticeObject(h: H, ctx: Ctx, obj: any, effects: { Effect })
	local o = Owner.fromObject(obj)
	if o == nil or not ctx.resolved or ctx.helm == nil then
		return
	end
	local k = ownerKey(ctx, o)
	if h.owners[k] ~= nil then
		return
	end
	local owners = table.clone(h.owners)
	owners[k] = { owner = o, status = "loading", revision = nil, release = nil, error = nil }
	h.owners = owners
	run(
		h,
		ctx,
		"owner|" .. k,
		Query.owner(ctx.helm :: string, ctx.target, { name = o.release, namespace = o.namespace }),
		effects,
		helmEnv(ctx)
	)
end

local function onOwner(h: H, ctx: Ctx, k: string, msg: Msg)
	local info = h.owners[k]
	if info == nil or info.status ~= "loading" then
		return
	end
	local upd = table.clone(info)
	local r = msg.result :: ProcessResult
	if msg.spawnError or r.status ~= 0 or r.timed_out then
		upd.status = "error"
		upd.error = failText(ctx, "helm", r, msg.spawnError)
	else
		local rows, err = Parse.list(r.stdout, ctx.decode)
		local row = if rows then rows[1] else nil
		if row then
			upd.status = "ok"
			upd.release = row
			upd.revision = row.revision
		elseif rows then
			upd.status = "missing"
		else
			upd.status = "error"
			upd.error = err
		end
	end
	local owners = table.clone(h.owners)
	owners[k] = upd
	h.owners = owners
end

-- Results ----------------------------------------------------------------------

local PARSERS: { [string]: (string, T.Decode) -> (any, string?) } = {
	lists = Parse.list,
	histories = Parse.history,
	statuses = Parse.status,
	extras = Parse.extras,
	computed = Parse.values,
}

-- route: the route on top (fallback steps need its release).
function M.onResult(h: H, ctx: Ctx, msg: Msg, route: Route?, effects: { Effect }): boolean
	local rest = string.match(msg.tag or "", "^helm|(.*)$")
	if rest == nil then
		return false
	end
	local what, tail = string.match(rest, "^([^|]+)|(.*)$")
	if what == nil or tail == nil then
		return true
	end
	if what == "owner" then
		onOwner(h, ctx, tail, msg)
		return true
	elseif what == "res" then
		local k, sub = string.match(tail, "^([^|]*)|(.*)$")
		if k and sub then
			onResources(h, ctx, k, sub, msg, effects)
		end
		return true
	elseif what == "fb" then
		local k, step = string.match(tail, "^([^|]*)|(.*)$")
		if k and step then
			local fbRoute = route
			local relNs, relName = string.match(k, "^([^/]*)/(.-)#%d+$")
			if fbRoute == nil or fbRoute.release ~= relName or fbRoute.namespace ~= relNs then
				fbRoute = { kind = "helm-values", release = relName, namespace = relNs }
			end
			onFallback(h, ctx, fbRoute, k, step, msg, effects)
		end
		return true
	end
	local parse = PARSERS[what]
	if parse == nil then
		return true
	end
	local name: MapName = what
	local l = getMap(h, name)[tail]
	if l == nil or l.status ~= "loading" or l.gen ~= msg.gen then
		return true
	end
	local upd = table.clone(l)
	upd.at = msg.at
	local r = msg.result :: ProcessResult
	if msg.spawnError or r.status ~= 0 or r.timed_out then
		upd.status = "error"
		upd.error = failText(ctx, "helm", r, msg.spawnError)
	else
		local ok, data, err = pcall(parse, r.stdout, ctx.decode)
		if ok and data ~= nil then
			upd.status = "ok"
			upd.data = data
		else
			upd.status = "error"
			upd.error = "Could not read helm output: " .. tostring(if ok then err else data)
		end
	end
	setEntry(h, name, tail, upd)
	return true
end

return M
