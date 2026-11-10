--!strict
-- Views of the Explore block's Helm routes (releases, release, history,
-- values, manifest, notes, hooks, resources, revision diff) and the "Managed
-- by Helm release" line of the object and relations views. Pure: plain
-- `{k,p,c}` tables. explore/render.luau supplies the shared paged grid and
-- chip builders; explore/helm.luau owns the data and its keys.
--
-- Everything derived from release values is masked here unless
-- security.show_secret_values is on: values trees by key name and shape,
-- Secret documents by Yaml.redact, and every masked value echoed into notes,
-- manifests and hooks (helm renders values into any kind of object).

local Command = require("../kubectl/command")
local Config = require("../config")
local Diffseg = require("../mutation/diffseg")
local GitopsView = require("../gitops/view")
local Helm = require("../explore/helm")
local HelmTypes = require("./types")
local LineDiff = require("../model/linediff")
local Owner = require("./owner")
local Parse = require("./parse")
local Redact = require("../model/redact")
local RevDiff = require("./revdiff")
local SegCard = require("../render/segcard")
local T = require("../explore/types")
local Types = require("../model/types")
local Values = require("./values")
local Yaml = require("../parse/yaml")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type Route = T.Route
type ColumnType = Types.ColumnType
type Status = HelmTypes.Status

export type GridRow = GitopsView.GridRow
export type Cell = GitopsView.Cell
export type Grid = GitopsView.Grid
export type Chip = GitopsView.Chip

export type Ctx = {
	h: HelmTypes.ExploreState,
	hctx: Helm.Ctx,
	route: Route,
	config: Config.Config,
	now: number?,
	-- Key of the selected item (explore/helm.luau items), for the grids.
	selectedKey: string?,
	filter: string,
	grid: Grid,
	chip: Chip,
	policy: Redact.Policy,
	isList: (t: any) -> boolean,
}

local M = {}

M.SENSITIVE = "Values that look secret are masked; set security.show_secret_values to show them"
M.NO_HELM = "helm not found: install Helm 3 or 4, or set helm.program to its full path"
M.NOTES_EXCERPT = 3

local TONE: { [string]: string } = { ok = "success", warn = "warning", error = "error", muted = "neutral" }
local SPAN: { [string]: string } = {
	ok = "success strong",
	warn = "warning strong",
	error = "error strong",
	muted = "muted",
}

local MODE_TEXT: { [string]: string } = {
	changed = "Changed",
	user = "User-supplied",
	computed = "Computed",
	defaults = "Chart defaults",
	diff = "Defaults → computed",
}

local STATE_TONE: { [string]: string } = {
	override = "accent",
	["same-as-default"] = "muted",
	["unknown-key"] = "warning strong",
	subchart = "muted",
	default = "muted",
	removed = "warning",
	user = "accent",
}

local RESOURCE_TONE: { [string]: string } = {
	present = "success strong",
	missing = "error strong",
	extra = "warning strong",
	hook = "muted",
	unknown = "warning",
}

local SOURCE_TONE: { [string]: string } = {
	record = "muted",
	["record-earliest"] = "accent",
	["chart-dir"] = "accent",
	["chart-source"] = "accent",
	["record-suspect"] = "warning",
	unavailable = "warning",
}

-- Helpers --------------------------------------------------------------------

local function typed(argv: { string }): string
	local copy = table.clone(argv)
	if copy[1] and string.find(copy[1], "helm", 1, true) then
		copy[1] = "helm"
	elseif copy[1] and string.find(copy[1], "kubectl", 1, true) then
		copy[1] = "kubectl"
	end
	return Command.format(copy)
end

function M.ageText(seconds: number): string
	local d = math.max(0, math.floor(seconds))
	if d < 60 then
		return d .. "s"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m"
	elseif d < 86400 then
		return math.floor(d / 3600) .. "h"
	end
	return math.floor(d / 86400) .. "d"
end

local function when(text: string, at: number?, now: number?): string
	if at and now then
		return M.ageText(now - at)
	end
	return text
end

local function chartText(name: string, version: string?): string
	return if version then name .. "-" .. version else name
end

local function pair(k: { SpanLike }, v: { SpanLike }): { { SpanLike } }
	return { k, v }
end

local function selectedIndex(keys: { string }, want: string?): number
	if want then
		for i, k in keys do
			if k == want then
				return i
			end
		end
	end
	return if #keys > 0 then 1 else 0
end

local function errorNode(text: string, key: string?): Node
	return ui.text({ ui.span(text, "error") }, { key = key or "error", role = "tern-kube.error" })
end

-- Status of a load without data yet; nil once it has data.
local function pending(load: HelmTypes.Load<any>?, what: string): Node?
	if load == nil or load.status == "idle" then
		return ui.muted("Not loaded. Press r.", { key = "pending-" .. what })
	elseif load.status == "loading" and load.data == nil then
		local cmd = if load.argv then " " .. typed(load.argv) else ""
		return ui.muted("Running" .. cmd .. " …", { key = "pending-" .. what })
	elseif load.status == "error" then
		return errorNode(load.error or "helm failed", "error-" .. what)
	elseif load.data == nil then
		return ui.muted("Not loaded. Press r.", { key = "pending-" .. what })
	end
	return nil
end

local function sortedKeys(t: { [any]: any }): { any }
	local keys: { any } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function quoteString(s: string): string
	return '"'
		.. (string.gsub(s, '[%c"\\]', function(c: string): string
			if c == "\n" then
				return "\\n"
			elseif c == "\t" then
				return "\\t"
			elseif c == '"' or c == "\\" then
				return "\\" .. c
			end
			return string.format("\\u%04x", string.byte(c))
		end))
		.. '"'
end

-- One-line JSON-like text of a values leaf (strings unquoted at the top so
-- the grid reads like `helm get values`).
function M.valueText(value: any, isList: (t: any) -> boolean, nested: boolean?): string
	local kind = type(value)
	if value == nil then
		return ""
	elseif kind == "string" then
		return if nested then quoteString(value) else value
	elseif kind == "number" then
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return tostring(value)
	elseif kind == "table" then
		local parts: { string } = {}
		if isList(value) then
			for _, item in value do
				table.insert(parts, M.valueText(item, isList, true))
			end
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		for _, k in sortedKeys(value) do
			table.insert(parts, tostring(k) .. ": " .. M.valueText(value[k], isList, true))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

-- Statuses and the owner line -------------------------------------------------

function M.statusText(status: Status, stuck: boolean): string
	return if stuck then status .. " (stuck?)" else status
end

local function toneOf(status: Status, stuck: boolean): string
	if stuck then
		return "warn"
	end
	return Parse.tone(status)
end

function M.statusBadge(status: Status, stuck: boolean): Node
	local tone = toneOf(status, stuck)
	return ui.badge(M.statusText(status, stuck), TONE[tone] or "neutral", {
		key = "status",
		role = "tern-kube.helm-status",
		class = "tk-helm-" .. tone,
		title = if stuck
			then string.format(
				"Pending for more than %d minutes: the helm process may have died. Rollback is the recovery.",
				Parse.STUCK_AFTER_S // 60
			)
			else nil,
	})
end

-- STATUS column cells: the status text toned like the badge.
local function statusCell(col: string, _t: ColumnType, value: string): Node
	if col == "STATE" then
		return ui.text({ ui.span(value, RESOURCE_TONE[value] or STATE_TONE[value]) }, { class = "tk-c" })
	elseif col ~= "STATUS" then
		return ui.text({ ui.span(value) }, { class = "tk-c" })
	end
	local base = string.match(value, "^(%S+)") or value
	local tone = if string.find(value, "(stuck?)", 1, true) then "warn" else Parse.tone(Parse.statusOf(base))
	return ui.text({ ui.span(value, SPAN[tone]) }, { class = "tk-c tk-helm-" .. tone })
end

local function ownerAction(namespace: string, release: string, revision: number?): string
	return "helm-open=" .. namespace .. "/" .. release .. (if revision then "#" .. revision else "")
end

-- "Managed by Helm release ns/X rev N (deployed, shop-0.1.0)" with a chip
-- opening the release; hook objects and release records say what they are.
function M.ownerLine(v: Ctx, obj: any): Node?
	if type(obj) ~= "table" then
		return nil
	end
	local record = Owner.record(obj)
	if record then
		local ns = if type(obj.metadata) == "table" and type(obj.metadata.namespace) == "string"
			then obj.metadata.namespace
			else nil
		local spans: { SpanLike } = {
			ui.span("Helm release record ", "muted"),
			ui.span(record.release .. " rev " .. record.revision, "strong"),
		}
		local children: { Node } = { ui.text(spans, { key = "owner" }) }
		if ns then
			table.insert(
				children,
				v.chip("Release revision (H)", ownerAction(ns, record.release, record.revision), {
					key = "helm-open",
					tone = "accent",
					title = "Open this revision of the release",
				})
			)
		end
		return ui.row(children, { key = "helm-owner", wrap = true, role = "tern-kube.helm-owner" })
	end
	local hook = Owner.hook(obj)
	if hook then
		return ui.row({
			ui.text({
				ui.span("Helm hook", "strong"),
				ui.span(
					" (" .. table.concat(hook.events, ", ") .. "): created by helm, not part of the release",
					"muted"
				),
			}, { key = "owner" }),
		}, { key = "helm-owner", wrap = true, role = "tern-kube.helm-owner" })
	end
	local info = Helm.owner(v.h, v.hctx, obj)
	if info == nil then
		return nil
	end
	local o = info.owner
	local probably = o.via == "instance-label"
	local spans: { SpanLike } = {
		ui.span(if probably then "Probably managed by " else "Managed by ", "muted"),
		ui.span("Helm release " .. o.namespace .. "/" .. o.release, "strong"),
	}
	local revision = info.revision or (if info.release then info.release.revision else nil)
	if info.status == "loading" then
		table.insert(spans, ui.span("  checking …", "muted"))
	elseif info.status == "missing" then
		table.insert(spans, ui.span("  (release not found: uninstalled or not readable)", "warning"))
	elseif info.status == "error" then
		table.insert(spans, ui.span("  (helm: " .. (info.error or "failed") .. ")", "warning"))
	elseif revision then
		table.insert(spans, ui.span(" rev " .. revision, "strong"))
	end
	local row = info.release
	local children: { Node } = { ui.text(spans, { key = "owner" }) }
	if info.status == "ok" and row then
		local stuck = Parse.stuck(row, v.now)
		local b = M.statusBadge(row.status, stuck);
		(b.p :: any).key = "owner-status"
		table.insert(children, b)
		table.insert(
			children,
			ui.text({ ui.span(chartText(row.chartName, row.chartVersion), "muted") }, { key = "owner-chart" })
		)
	end
	if probably then
		table.insert(
			children,
			ui.text({ ui.span("(app.kubernetes.io/instance label, no Helm annotations)", "muted") }, { key = "via" })
		)
	end
	table.insert(
		children,
		v.chip("Helm release (H)", ownerAction(o.namespace, o.release, nil), {
			key = "helm-open",
			tone = "accent",
			title = "Open the release: history, values, manifest, rollback",
		})
	)
	return ui.row(children, { key = "helm-owner", wrap = true, role = "tern-kube.helm-owner" })
end

-- Masking ---------------------------------------------------------------------

-- Strings the values masking would hide in the revision's user values,
-- stored defaults and computed values: helm renders them into any object,
-- notes and hooks (F8: reused values end up in the defaults), and kubectl
-- only masks Secret objects. Collected even when secrets are shown, so the
-- view can still warn that it shows them.
local function secretsOf(v: Ctx, revisions: { number }): { string }
	local hiding: Redact.Policy = { showSecrets = false, strict = v.policy.strict }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local function add(tree: any)
		if type(tree) ~= "table" then
			return
		end
		for _, s in Redact.maskTree(tree, hiding, v.isList).secrets do
			if not seen[s] then
				seen[s] = true
				table.insert(out, s)
			end
		end
	end
	for _, rev in revisions do
		local st = Helm.statusLoad(v.h, v.route, rev)
		if st and st.data then
			add(st.data.user)
		end
		local ex = Helm.extrasLoad(v.h, v.route, rev)
		if ex and ex.data then
			add(ex.data.defaults)
		end
		local computed = Helm.computedLoad(v.h, v.route, rev)
		if computed and computed.data then
			add(computed.data)
		end
	end
	return out
end

-- Text with echoed secrets replaced, and how many there were (counted also
-- when they stay visible).
local function maskText(v: Ctx, text: string, secrets: { string }): (string, number)
	local masked, n = Redact.maskEchoes(text, secrets)
	return if v.policy.showSecrets then text else masked, n
end

-- Manifest text with Secret data masked (Yaml.redact) and echoed secrets
-- replaced; returns the text, whether a Secret was in it, and how many
-- echoes were found.
local function maskManifest(v: Ctx, text: string, secrets: { string }): (string, boolean, number)
	local lines = Yaml.lines(text)
	local split = Yaml.split(text)
	local secret = false
	for _, d in split.docs do
		if d.kind == "Secret" then
			secret = true
		end
	end
	local masked = table.concat(Yaml.redact(lines, split.docs, v.policy), "\n")
	local out, echoed = maskText(v, masked, secrets)
	return out, secret, echoed
end

local function noticeNodes(v: Ctx, sensitive: boolean, masked: boolean): { Node }
	local out: { Node } = {}
	for i, notice in Redact.notices(v.policy, sensitive, masked, M.SENSITIVE) do
		table.insert(
			out,
			ui.text(
				{ ui.span(notice, "warning") },
				{ key = if i == 1 then "sensitive" else "sensitive" .. i, role = "tern-kube.sensitive" }
			)
		)
	end
	return out
end

-- Values are always sensitive-looking: the notice shows whenever something
-- was masked, and the reveal warning whenever secrets are shown.
local function valuesNotices(v: Ctx, masked: boolean): { Node }
	if v.policy.showSecrets then
		return noticeNodes(v, true, false)
	end
	return noticeNodes(v, masked, false)
end

-- Releases --------------------------------------------------------------------

local PROBLEM: { [string]: boolean } = {
	failed = true,
	["pending-install"] = true,
	["pending-upgrade"] = true,
	["pending-rollback"] = true,
	uninstalling = true,
}

local function releasesBody(v: Ctx): { Node }
	local load = Helm.listLoad(v.h, v.hctx, v.route)
	local wait = pending(load, "list")
	if wait or load == nil then
		return { wait :: Node }
	end
	local all = load.data :: { HelmTypes.ReleaseRow }
	local rows = Helm.releases(v.h, v.hctx, v.route, v.filter)
	if #all == 0 then
		return {
			ui.muted("No Helm releases (helm list -a) in this namespace scope; n changes it.", { key = "empty" }),
		}
	end
	local problems = 0
	for _, r in all do
		if PROBLEM[r.status] then
			problems += 1
		end
	end
	local summary = string.format("%d release%s", #all, if #all == 1 then "" else "s")
	if v.filter ~= "" then
		summary ..= string.format(" · %d match /%s", #rows, v.filter)
	end
	local head: { Node } = { ui.text({ ui.span(summary, "muted") }, { key = "count" }) }
	if problems > 0 then
		table.insert(
			head,
			ui.badge(string.format("%d need attention", problems), "warning", {
				key = "problems",
				title = "failed, pending-* or uninstalling releases",
			})
		)
	end
	if #all >= v.config.helm.list_max then
		table.insert(
			head,
			ui.badge(string.format("first %d releases (helm.list_max)", v.config.helm.list_max), "warning", {
				key = "cap",
			})
		)
	end
	local out: { Node } = { ui.row(head, { key = "summary", wrap = true }) }
	if #rows == 0 then
		table.insert(out, ui.muted("Nothing matches the filter. Esc clears it.", { key = "empty" }))
		return out
	end
	local grid: { GridRow } = {}
	local keys: { string } = {}
	for i, r in rows do
		local key = r.namespace .. "/" .. r.name
		keys[i] = key
		grid[i] = {
			key = key,
			action = "open=" .. key,
			cells = {
				r.name,
				r.namespace,
				tostring(r.revision),
				M.statusText(r.status, Parse.stuck(r, v.now)),
				r.chartName,
				r.chartVersion or "",
				r.appVersion,
				when(r.updated, r.updatedAt, v.now),
			},
		}
	end
	local types: { ColumnType } = { "text", "text", "number", "status", "text", "text", "text", "text" }
	for _, n in
		v.grid(
			"helm-releases",
			{ "NAME", "NAMESPACE", "REV", "STATUS", "CHART", "VERSION", "APP VERSION", "UPDATED" },
			types,
			grid,
			selectedIndex(keys, v.selectedKey),
			statusCell
		)
	do
		table.insert(out, n)
	end
	return out
end

-- Release ---------------------------------------------------------------------

local function latestOf(history: { HelmTypes.Revision }?): HelmTypes.Revision?
	local best: HelmTypes.Revision? = nil
	if history then
		for _, r in history do
			if best == nil or r.revision > best.revision then
				best = r
			end
		end
	end
	return best
end

local function revisionRow(history: { HelmTypes.Revision }?, n: number?): HelmTypes.Revision?
	if history then
		for _, r in history do
			if r.revision == n then
				return r
			end
		end
	end
	return nil
end

local function navChips(v: Ctx): Node
	local list: { { string } } = {
		{ "History (h)", "helm-nav=history", "Revisions with status and description" },
		{ "Values (v)", "helm-nav=values", "User-supplied values against the chart defaults" },
		{ "Manifest (M)", "helm-nav=manifest", "The rendered manifest of this revision" },
		{ "Notes (N)", "helm-nav=notes", "NOTES.txt as helm printed it" },
		{ "Hooks (K)", "helm-nav=hooks", "Hooks and their last run" },
		{ "Resources (R)", "helm-nav=resources", "Manifest objects and whether they exist" },
		{ "Diff vs previous (=)", "helm-nav=diff", "What changed from the previous revision" },
	}
	local out: { Node } = {}
	for i, c in list do
		table.insert(out, v.chip(c[1], c[2], { key = "h" .. i, title = c[3] }))
	end
	if v.config.mutations.enabled then
		table.insert(
			out,
			v.chip("Rollback (ctrl+r)", "helm-rollback", {
				key = "rollback",
				tone = "warning",
				title = "Roll back to the last good revision before this one; previews in the approve block",
			})
		)
	end
	table.insert(out, v.chip("Copy command (Y)", "copy=cmd", { key = "copy", title = "The pinned helm command" }))
	return ui.row(out, { key = "helm-chips", wrap = true, role = "tern-kube.chips" })
end

local function resourceCounts(manifest: string): string
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, d in Yaml.split(manifest).docs do
		local kind = d.kind or "?"
		if counts[kind] == nil then
			counts[kind] = 0
			table.insert(order, kind)
		end
		counts[kind] += 1
	end
	local parts: { string } = {}
	for _, k in order do
		table.insert(parts, string.format("%s %d", k, counts[k]))
	end
	return table.concat(parts, " · ")
end

local function valuesSummary(v: Ctx): Node
	local cmp = Helm.valuesCompare(v.h, v.hctx, v.route)
	if cmp == nil then
		return ui.muted("Values: loading …", { key = "values" })
	end
	local function count(state: Values.RowState): number
		return cmp.counts[state] or 0
	end
	local spans: { SpanLike } = {
		ui.span("Values  ", "strong"),
		ui.span(string.format("%d overridden", count("override")), "accent"),
		ui.span(string.format(" · %d same as default", count("same-as-default")), "muted"),
	}
	local unknown = count("unknown-key")
	if unknown > 0 then
		table.insert(
			spans,
			ui.span(
				string.format(
					" · %d unknown key%s (typo? the chart never reads it)",
					unknown,
					if unknown == 1 then "" else "s"
				),
				"warning strong"
			)
		)
	end
	local subcharts = count("subchart")
	if subcharts > 0 then
		table.insert(spans, ui.span(string.format(" · %d for subcharts", subcharts), "muted"))
	end
	if cmp.source ~= "record" then
		table.insert(spans, ui.span("  defaults: " .. cmp.source, SOURCE_TONE[cmp.source] or "muted"))
	end
	return ui.text(spans, { key = "values", role = "tern-kube.helm-values-summary" })
end

local function hooksSummary(v: Ctx, rev: number): Node?
	local load = Helm.extrasLoad(v.h, v.route, rev)
	if load == nil or load.data == nil then
		return nil
	end
	local hooks = load.data.hooks
	if #hooks == 0 then
		return ui.muted("Hooks: none", { key = "hooks" })
	end
	local spans: { SpanLike } = { ui.span("Hooks  ", "strong"), ui.span(tostring(#hooks), "muted") }
	local failed: { string } = {}
	for _, hk in hooks do
		if hk.phase == "Failed" then
			table.insert(failed, hk.name)
		end
	end
	if #failed > 0 then
		table.insert(spans, ui.span("  last run failed: " .. table.concat(failed, ", "), "error strong"))
	end
	return ui.text(spans, { key = "hooks", role = "tern-kube.helm-hooks-summary" })
end

local function releaseBody(v: Ctx): { Node }
	local route = v.route
	local history = Helm.historyLoad(v.h, route)
	local load = Helm.statusLoad(v.h, route, route.revision)
	local wait = pending(load, "status")
	if wait or load == nil then
		return { wait :: Node }
	end
	local st = load.data :: HelmTypes.ReleaseStatus
	local rows = if history then history.data else nil
	local latest = latestOf(rows)
	local row = revisionRow(rows, st.revision)
	local stuck = row ~= nil and latest ~= nil and row.revision == latest.revision and Parse.stuck(row, v.now)
	local head: { Node } = {
		ui.text({
			ui.span(st.name, "strong"),
			ui.span("  " .. st.namespace, "muted"),
		}, { key = "name" }),
		M.statusBadge(st.info.status, stuck),
		ui.text({
			ui.span(
				"rev " .. st.revision .. (if latest then " of " .. latest.revision else ""),
				if latest and latest.revision ~= st.revision then "warning strong" else "strong"
			),
		}, { key = "rev" }),
	}
	if row then
		table.insert(
			head,
			ui.text({
				ui.span(chartText(row.chartName, row.chartVersion), "mono"),
				ui.span("  app " .. row.appVersion, "muted"),
			}, { key = "chart" })
		)
	end
	local secrets = secretsOf(v, { st.revision })
	local items: { { { SpanLike } } } = {}
	if st.info.description ~= "" then
		table.insert(items, { { "Description" }, { (maskText(v, st.info.description, secrets)) } })
	end
	if st.info.firstDeployed then
		table.insert(items, { { "First deployed" }, { st.info.firstDeployed :: string } })
	end
	if st.info.lastDeployed then
		table.insert(items, { { "Last deployed" }, { st.info.lastDeployed :: string } })
	end
	local counts = resourceCounts(st.manifest)
	if counts ~= "" then
		table.insert(items, { { "Resources" }, { counts } })
	end
	local out: { Node } = {
		ui.row(head, { key = "head", wrap = true, role = "tern-kube.helm-head" }),
		navChips(v),
	}
	if history and history.status == "error" then
		table.insert(out, errorNode("history: " .. (history.error or "helm failed"), "error-history"))
	end
	if #items > 0 then
		local kv = ui.kv(items);
		(kv.p :: any).key = "meta"
		table.insert(out, kv)
	end
	table.insert(out, valuesSummary(v))
	local hooks = hooksSummary(v, st.revision)
	if hooks then
		table.insert(out, hooks)
	end
	local notes = st.info.notes
	if notes ~= "" then
		local masked, echoed = maskText(v, notes, secrets)
		for _, n in noticeNodes(v, echoed > 0, false) do
			table.insert(out, n)
		end
		local lines = string.split(masked, "\n")
		local shown: { string } = {}
		for i = 1, math.min(#lines, M.NOTES_EXCERPT) do
			shown[i] = lines[i]
		end
		local more = #lines - #shown
		table.insert(
			out,
			ui.card({ ui.span("Notes", "strong"), ui.span(if more > 0 then "  N shows all" else "", "muted") }, {
				ui.code(table.concat(shown, "\n"), "text"),
			}, { key = "notes", inset = true, role = "tern-kube.helm-notes" })
		)
	end
	return out
end

-- History ---------------------------------------------------------------------

local function historyBody(v: Ctx): { Node }
	local load = Helm.historyLoad(v.h, v.route)
	local wait = pending(load, "history")
	if wait or load == nil then
		return { wait :: Node }
	end
	local all = load.data :: { HelmTypes.Revision }
	local rows = Helm.historyRows(v.h, v.route, v.filter)
	local latest = latestOf(all)
	local current: number? = nil
	for _, r in all do
		if r.status == "deployed" and (current == nil or r.revision > current) then
			current = r.revision
		end
	end
	local mark = Helm.mark(v.h, v.route)
	local summary = string.format("%d revision%s", #all, if #all == 1 then "" else "s")
	if v.filter ~= "" then
		summary ..= string.format(" · %d match /%s", #rows, v.filter)
	end
	local out: { Node } = { ui.text({ ui.span(summary, "muted") }, { key = "count" }) }
	if latest and current and latest.revision ~= current then
		table.insert(
			out,
			ui.text({
				ui.span(string.format("Latest revision %d is %s; ", latest.revision, latest.status), "warning strong"),
				ui.span(string.format("revision %d is what runs (deployed).", current), "muted"),
			}, { key = "split", role = "tern-kube.helm-split" })
		)
	end
	if mark then
		table.insert(
			out,
			ui.text({
				ui.span(string.format("Marked revision %d: = compares the selected revision with it", mark), "accent"),
			}, { key = "mark" })
		)
	end
	if #rows == 0 then
		table.insert(out, ui.muted("Nothing matches the filter. Esc clears it.", { key = "empty" }))
		return out
	end
	local grid: { GridRow } = {}
	local keys: { string } = {}
	for i, r in rows do
		local tags: { string } = {}
		if latest and r.revision == latest.revision then
			table.insert(tags, "latest")
		end
		if r.revision == current then
			table.insert(tags, "running")
		end
		if r.revision == mark then
			table.insert(tags, "marked")
		end
		local key = tostring(r.revision)
		keys[i] = key
		grid[i] = {
			key = key,
			action = "open=" .. key,
			cells = {
				key,
				M.statusText(r.status, latest ~= nil and r.revision == latest.revision and Parse.stuck(r, v.now)),
				when(r.updated, r.updatedAt, v.now),
				chartText(r.chartName, r.chartVersion),
				r.appVersion,
				r.description,
				table.concat(tags, " "),
			},
		}
	end
	local types: { ColumnType } = { "number", "status", "text", "text", "text", "text", "text" }
	for _, n in
		v.grid(
			"helm-history",
			{ "REV", "STATUS", "UPDATED", "CHART", "APP VERSION", "DESCRIPTION", "" },
			types,
			grid,
			selectedIndex(keys, v.selectedKey),
			statusCell
		)
	do
		table.insert(out, n)
	end
	return out
end

-- Values ----------------------------------------------------------------------

local CHANGED: { [string]: boolean } = {
	override = true,
	["same-as-default"] = true,
	["unknown-key"] = true,
	subchart = true,
	removed = true,
	user = true,
}

local function modeChips(v: Ctx, mode: string): Node
	local out: { Node } = {}
	for i, m in Helm.MODES do
		table.insert(
			out,
			v.chip(MODE_TEXT[m] or m, "helm-mode=" .. m, {
				key = "mode" .. i,
				tone = if m == mode then "accent" else "neutral",
				title = "v cycles the modes",
			})
		)
	end
	return ui.row(out, { key = "modes", wrap = true, role = "tern-kube.chips" })
end

local function banner(cmp: Values.Compare): Node?
	local note = cmp.sourceNote
	if note == nil or note == "" then
		if cmp.source == "unavailable" then
			note = "Chart defaults unavailable (helm get all --template failed): the default column shows ?"
		else
			return nil
		end
	end
	return ui.text(
		{ ui.span(note :: string, SOURCE_TONE[cmp.source] or "muted") },
		{ key = "source", role = "tern-kube.helm-defaults-source" }
	)
end

local function yamlOf(v: Ctx, tree: { [string]: any }?): (string, number)
	if tree == nil then
		return "", 0
	end
	local masked = Redact.maskTree(tree, v.policy, v.isList)
	return Values.yaml(masked.value, v.isList), masked.masked
end

local function defaultsTree(v: Ctx, rev: number): { [string]: any }?
	local d = Helm.defaultsLoad(v.h, v.route, rev)
	if d and d.data and d.data.values then
		return d.data.values
	end
	local ex = Helm.extrasLoad(v.h, v.route, rev)
	return if ex and ex.data then ex.data.defaults else nil
end

local function treeFor(v: Ctx, mode: string, rev: number): ({ [string]: any }?, HelmTypes.Load<any>?)
	if mode == "user" then
		local st = Helm.statusLoad(v.h, v.route, rev)
		return if st and st.data then st.data.user else nil, st
	elseif mode == "computed" then
		local c = Helm.computedLoad(v.h, v.route, rev)
		return if c then c.data else nil, c
	end
	local d = Helm.defaultsLoad(v.h, v.route, rev)
	local tree = defaultsTree(v, rev)
	return tree, if tree then nil else (d or Helm.extrasLoad(v.h, v.route, rev))
end

local function valuesBody(v: Ctx): { Node }
	local mode = v.route.mode or "changed"
	local rev = Helm.revisionOf(v.h, v.route)
	local out: { Node } = { modeChips(v, mode) }
	if rev == nil then
		table.insert(out, pending(Helm.statusLoad(v.h, v.route, nil), "status") or ui.muted("Not loaded. Press r."))
		return out
	end
	local cmp = Helm.valuesCompare(v.h, v.hctx, v.route)
	if cmp then
		local b = banner(cmp)
		if b then
			table.insert(out, b)
		end
	end
	if mode == "changed" then
		if cmp == nil then
			table.insert(out, ui.muted("Loading values …", { key = "pending" }))
			return out
		end
		local grid: { GridRow } = {}
		local masked = false
		for _, r in cmp.rows do
			if r.masked then
				masked = true
			end
			if CHANGED[r.state] then
				local default = if cmp.source == "unavailable" and r.default == nil
					then "?"
					else M.valueText(r.default, v.isList)
				table.insert(grid, {
					key = r.path,
					action = "noop",
					cells = {
						r.path,
						r.state,
						default,
						M.valueText(r.user, v.isList),
						M.valueText(r.computed, v.isList),
					},
				})
			end
		end
		for _, n in valuesNotices(v, masked) do
			table.insert(out, n)
		end
		if #grid == 0 then
			table.insert(
				out,
				ui.muted("No user-supplied values: the release runs on chart defaults.", { key = "none" })
			)
			return out
		end
		local types: { ColumnType } = { "text", "text", "text", "text", "text" }
		for _, n in
			v.grid(
				"helm-values",
				{ "PATH", "STATE", "DEFAULT", "USER", "COMPUTED" },
				types,
				grid,
				0,
				function(col: string, _t: ColumnType, value: string): Node
					if col == "STATE" then
						return ui.text({ ui.span(value, STATE_TONE[value]) }, { class = "tk-c" })
					end
					return ui.text({ ui.span(value, if col == "PATH" then "mono" else nil) }, { class = "tk-c" })
				end
			)
		do
			table.insert(out, n)
		end
		return out
	elseif mode == "diff" then
		local defaults = defaultsTree(v, rev)
		local computed = Helm.computedLoad(v.h, v.route, rev)
		local wait = pending(computed, "computed")
		if wait then
			table.insert(out, wait)
			return out
		end
		local old, m1 = yamlOf(v, defaults)
		local new, m2 = yamlOf(v, (computed :: HelmTypes.Load<any>).data)
		for _, n in valuesNotices(v, m1 + m2 > 0) do
			table.insert(out, n)
		end
		local text = LineDiff.unified(if defaults then old else nil, new, "values.yaml")
		if text == nil or text == "" then
			table.insert(out, ui.muted("The computed values equal the chart defaults.", { key = "same" }))
		else
			table.insert(out, { k = "diff", p = { key = "diff", text = text, path = "values.yaml", mode = "unified" } })
		end
		return out
	end
	local tree, load = treeFor(v, mode, rev)
	if tree == nil then
		table.insert(
			out,
			pending(load, mode)
				or ui.muted(
					if mode == "defaults" then "Chart defaults unavailable for this revision." else "No values.",
					{ key = "none" }
				)
		)
		return out
	end
	local text, masked = yamlOf(v, tree)
	for _, n in valuesNotices(v, masked > 0) do
		table.insert(out, n)
	end
	if text == "" or text == "{}\n" or text == "{}" then
		table.insert(out, ui.muted("Empty.", { key = "empty" }))
	else
		table.insert(out, ui.code(text, "yaml", nil, { key = "yaml" }))
	end
	return out
end

-- Manifest, notes, hooks -------------------------------------------------------

-- The `# Source: chart/templates/x.yaml` comment helm writes above each
-- document.
local function sourceOf(lines: { string }, first: number): string?
	for i = first, math.max(1, first - 3), -1 do
		local line = lines[i]
		if line == nil or (i < first and string.sub(line, 1, 3) == "---") then
			break
		end
		local src = string.match(line, "^# Source: (.+)$")
		if src then
			return src
		end
	end
	return nil
end

-- One card per document: Secret data masked by Yaml.redact, echoed secrets
-- per document (a multi-line secret must not shift the line mapping).
-- Returns the cards, whether a Secret was among them and the echo count.
local function docCards(v: Ctx, original: string, secrets: { string }, key: string): ({ Node }, boolean, number)
	local split = Yaml.split(original)
	local raw = Yaml.lines(original)
	local masked = Yaml.redact(raw, split.docs, v.policy)
	local out: { Node } = {}
	local secret, echoed = false, 0
	for i, d in split.docs do
		if d.kind == "Secret" then
			secret = true
		end
		local body: { string } = {}
		for l = d.startLine, d.endLine do
			table.insert(body, masked[l] or "")
		end
		local text, n = maskText(v, table.concat(body, "\n"), secrets)
		echoed += n
		local src = sourceOf(raw, d.startLine)
		table.insert(
			out,
			ui.card({
				ui.span((d.kind or "?") .. " ", "strong"),
				ui.span(d.name or "?", "strong"),
				ui.span(if src then "   " .. src else "", "muted mono"),
			}, {
				ui.code(text, "yaml", d.startLine, { key = "yaml" }),
			}, {
				key = key .. i,
				collapsible = true,
				collapsed = false,
				inset = true,
				role = "tern-kube.helm-doc",
			})
		)
	end
	return out, secret, echoed
end

local function revisionLine(v: Ctx, rev: number): Node
	local history = Helm.historyLoad(v.h, v.route)
	local latest = latestOf(if history then history.data else nil)
	return ui.text({
		ui.span("Revision " .. rev, "strong"),
		ui.span(if latest then " of " .. latest.revision else "", "muted"),
	}, { key = "rev" })
end

local function manifestBody(v: Ctx): { Node }
	local load = Helm.statusLoad(v.h, v.route, v.route.revision)
	local wait = pending(load, "status")
	if wait or load == nil then
		return { wait :: Node }
	end
	local st = load.data :: HelmTypes.ReleaseStatus
	local cards, secret, echoed = docCards(v, st.manifest, secretsOf(v, { st.revision }), "doc")
	local out: { Node } = { revisionLine(v, st.revision) }
	for _, n in noticeNodes(v, secret or echoed > 0, false) do
		table.insert(out, n)
	end
	if echoed > 0 and not v.policy.showSecrets then
		table.insert(
			out,
			ui.muted(
				string.format(
					"%d value%s from the release values masked in other objects",
					echoed,
					if echoed == 1 then "" else "s"
				),
				{ key = "echoes" }
			)
		)
	end
	if #cards == 0 then
		table.insert(out, ui.muted("This revision renders no objects.", { key = "empty" }))
	end
	for _, c in cards do
		table.insert(out, c)
	end
	return out
end

local function notesBody(v: Ctx): { Node }
	local load = Helm.statusLoad(v.h, v.route, v.route.revision)
	local wait = pending(load, "status")
	if wait or load == nil then
		return { wait :: Node }
	end
	local st = load.data :: HelmTypes.ReleaseStatus
	local out: { Node } = { revisionLine(v, st.revision) }
	if st.info.notes == "" then
		table.insert(out, ui.muted("This chart has no NOTES.txt.", { key = "empty" }))
		return out
	end
	local text, echoed = maskText(v, st.info.notes, secretsOf(v, { st.revision }))
	for _, n in noticeNodes(v, echoed > 0, false) do
		table.insert(out, n)
	end
	table.insert(out, ui.code(text, "text", nil, { key = "notes", role = "tern-kube.helm-notes" }))
	return out
end

local PHASE_TONE: { [string]: string } = {
	Succeeded = "success",
	Failed = "error",
	Running = "warning",
	Unknown = "neutral",
}

local function hooksBody(v: Ctx): { Node }
	local rev = Helm.revisionOf(v.h, v.route)
	local load = if rev then Helm.extrasLoad(v.h, v.route, rev) else nil
	local out: { Node } = {}
	if rev then
		table.insert(out, revisionLine(v, rev))
	end
	if load and load.status == "error" then
		table.insert(
			out,
			errorNode("Hooks need `helm get all --template`, which failed: " .. (load.error or "?"), "error-extras")
		)
		return out
	end
	local wait = pending(load, "extras")
	if wait or load == nil or rev == nil then
		table.insert(out, wait or ui.muted("Not loaded. Press r."))
		return out
	end
	local hooks = (load.data :: HelmTypes.Extras).hooks
	if #hooks == 0 then
		table.insert(out, ui.muted("This revision has no hooks.", { key = "empty" }))
		return out
	end
	local secrets = secretsOf(v, { rev })
	local anySecret, anyEcho = false, 0
	local cards: { Node } = {}
	for i, hk in hooks do
		local items: { { { SpanLike } } } = {
			{ { "Events" }, { table.concat(hk.events, ", ") } },
			{ { "Weight" }, { tostring(hk.weight) } },
		}
		if #hk.deletePolicies > 0 then
			table.insert(items, { { "Delete policy" }, { table.concat(hk.deletePolicies, ", ") } })
		end
		local run: { SpanLike } = { ui.span(if hk.phase ~= "" then hk.phase else "never ran", PHASE_TONE[hk.phase]) }
		if hk.startedAt then
			table.insert(run, ui.span("  started " .. (hk.startedAt :: string), "muted"))
		end
		if hk.completedAt then
			table.insert(run, ui.span("  completed " .. (hk.completedAt :: string), "muted"))
		end
		table.insert(items, pair({ "Last run" }, run))
		if hk.path ~= "" then
			table.insert(items, pair({ "Template" }, { ui.span(hk.path, "mono") }))
		end
		local body: { Node } = { ui.kv(items) }
		if hk.manifest ~= "" then
			local text, secret, echoed = maskManifest(v, hk.manifest, secrets)
			anySecret = anySecret or secret
			anyEcho += echoed
			table.insert(body, ui.code(text, "yaml", nil, { key = "yaml" }))
		end
		table.insert(
			cards,
			ui.card({ ui.span(hk.kind .. " ", "strong"), ui.span(hk.name, "strong") }, body, {
				key = "hook" .. i,
				collapsible = true,
				collapsed = false,
				inset = true,
				tone = if hk.phase == "Failed" then "error" else nil,
				role = "tern-kube.helm-hook",
			})
		)
	end
	for _, n in noticeNodes(v, anySecret or anyEcho > 0, false) do
		table.insert(out, n)
	end
	for _, c in cards do
		table.insert(out, c)
	end
	return out
end

-- Resources -------------------------------------------------------------------

local function resourcesBody(v: Ctx): { Node }
	local load = Helm.resourcesLoad(v.h, v.route)
	local wait = pending(load, "resources")
	if wait or load == nil then
		return { wait :: Node }
	end
	local data = load.data :: Helm.Resources
	local rows = Helm.resourceRows(v.h, v.route, v.filter)
	local counts: { [string]: number } = {}
	for _, r in data.rows do
		counts[r.state] = (counts[r.state] or 0) + 1
	end
	local spans: { SpanLike } = {}
	for _, state in { "present", "missing", "extra", "hook", "unknown" } do
		local n = counts[state]
		if n then
			table.insert(spans, ui.span(string.format("%d %s  ", n, state), RESOURCE_TONE[state]))
		end
	end
	local out: { Node } = { ui.text(spans, { key = "count" }) }
	for i, note in data.notes do
		table.insert(out, ui.muted(note, { key = "note" .. i }))
	end
	if #rows == 0 then
		table.insert(
			out,
			ui.muted(
				if v.filter ~= "" then "Nothing matches the filter. Esc clears it." else "No objects.",
				{ key = "empty" }
			)
		)
		return out
	end
	local grid: { GridRow } = {}
	local keys: { string } = {}
	for i, r in rows do
		keys[i] = r.key
		grid[i] = {
			key = r.key,
			action = "open=" .. r.key,
			cells = { r.ref.kind, r.ref.name, r.ref.namespace or "", r.state, r.source or "" },
		}
	end
	local types: { ColumnType } = { "text", "text", "text", "status", "text" }
	for _, n in
		v.grid(
			"helm-resources",
			{ "KIND", "NAME", "NAMESPACE", "STATE", "SOURCE" },
			types,
			grid,
			selectedIndex(keys, v.selectedKey),
			statusCell
		)
	do
		table.insert(out, n)
	end
	return out
end

-- Revision diff ---------------------------------------------------------------

type ValueChange = { path: string, old: string, new: string, masked: boolean }

-- User values that differ between two revisions; compared raw, shown masked
-- (a change hidden by masking still counts and says so).
local function valueChanges(v: Ctx, old: { [string]: any }, new: { [string]: any }): { ValueChange }
	local function index(tree: { [string]: any }): { [string]: string }
		local out: { [string]: string } = {}
		for _, leaf in Values.flatten(tree) do
			out[leaf.path] = M.valueText(leaf.value, v.isList)
		end
		return out
	end
	local rawOld, rawNew = index(old), index(new)
	local shownOld = index(Redact.maskTree(old, v.policy, v.isList).value)
	local shownNew = index(Redact.maskTree(new, v.policy, v.isList).value)
	local paths: { [string]: boolean } = {}
	for p in rawOld do
		paths[p] = true
	end
	for p in rawNew do
		paths[p] = true
	end
	local out: { ValueChange } = {}
	for p in paths do
		if rawOld[p] ~= rawNew[p] then
			local a, b = shownOld[p] or "", shownNew[p] or ""
			-- A path missing on one side shows "" on that side, unmasked.
			local collided = a == b and rawOld[p] ~= nil and rawNew[p] ~= nil
			local masked = collided or a ~= (rawOld[p] or "") or b ~= (rawNew[p] or "")
			table.insert(out, { path = p, old = a, new = b, masked = masked })
		end
	end
	table.sort(out, function(x: ValueChange, y: ValueChange): boolean
		return x.path < y.path
	end)
	return out
end

local function hasHunk(seg: Diffseg.Segment): boolean
	for _, l in seg.lines do
		if string.sub(l, 1, 2) == "@@" then
			return true
		end
	end
	return false
end

local function maskedCard(seg: Diffseg.Segment, key: string): Node
	return ui.card({
		ui.span(string.upper(seg.action) .. "  ", "strong"),
		ui.span(
			(seg.kind or "?") .. " " .. (if seg.namespace then seg.namespace .. "/" else "") .. (seg.name or seg.key),
			"strong"
		),
	}, {
		ui.text({ ui.span(RevDiff.MASKED_NOTE, "warning") }, { key = "masked" }),
	}, { key = key, inset = true, tone = "info", role = "tern-kube.gitops-diff" })
end

local function diffBody(v: Ctx): { Node }
	local route = v.route
	local a, b = route.revision, route.against
	local history = Helm.historyLoad(v.h, route)
	local rows = if history then history.data else nil
	local out: { Node } = {
		ui.text({
			ui.span(string.format("Revision %s → %s", tostring(a or "?"), tostring(b or "?")), "strong"),
		}, { key = "pair" }),
	}
	local ra, rb = revisionRow(rows, a), revisionRow(rows, b)
	if ra and rb then
		local ca, cb = chartText(ra.chartName, ra.chartVersion), chartText(rb.chartName, rb.chartVersion)
		if ca ~= cb or ra.appVersion ~= rb.appVersion then
			table.insert(
				out,
				ui.text({
					ui.span("Chart ", "muted"),
					ui.span(ca .. " (app " .. ra.appVersion .. ")", "mono"),
					ui.span(" → ", "muted"),
					ui.span(cb .. " (app " .. rb.appVersion .. ")", "mono strong"),
				}, { key = "chart", role = "tern-kube.helm-chart-change" })
			)
		end
	end
	local load = Helm.diffLoad(v.h, route)
	local wait = pending(load, "diff")
	if wait or load == nil then
		table.insert(out, wait or ui.muted("Not loaded. Press r."))
		return out
	end
	local result = load.data :: RevDiff.Result
	local summary = result.summary
	table.insert(
		out,
		ui.row({
			ui.badge(string.format("%d create", summary.create), "success", { key = "create" }),
			ui.badge(string.format("%d modify", summary.modify), "info", { key = "modify" }),
			ui.badge(string.format("%d delete", summary.delete), "error", { key = "delete" }),
		}, { key = "counts", wrap = true })
	)
	local sa = if a then Helm.statusLoad(v.h, route, a) else nil
	local sb = if b then Helm.statusLoad(v.h, route, b) else nil
	local masked = result.maskedChanges > 0
	if sa and sa.data and sb and sb.data then
		local changes = valueChanges(v, sa.data.user, sb.data.user)
		if #changes > 0 then
			local grid: { GridRow } = {}
			for _, c in changes do
				masked = masked or c.masked
				table.insert(grid, {
					key = c.path,
					action = "noop",
					cells = {
						c.path,
						c.old,
						c.new,
						if c.masked and not v.policy.showSecrets then RevDiff.MASKED_NOTE else "",
					},
				})
			end
			table.insert(out, ui.text({ ui.span("User values", "strong") }, { key = "values-head" }))
			local types: { ColumnType } = { "text", "text", "text", "text" }
			for _, n in v.grid("helm-diff-values", { "PATH", "OLD", "NEW", "" }, types, grid, 0, nil) do
				table.insert(out, n)
			end
		else
			table.insert(out, ui.muted("User values: unchanged", { key = "values-head" }))
		end
	end
	local hooks = result.hooks
	local hookSpans: { SpanLike } = {}
	if #hooks.added > 0 then
		table.insert(hookSpans, ui.span("added " .. table.concat(hooks.added, ", ") .. "  ", "success"))
	end
	if #hooks.removed > 0 then
		table.insert(hookSpans, ui.span("removed " .. table.concat(hooks.removed, ", ") .. "  ", "error"))
	end
	if #hooks.changed > 0 then
		table.insert(hookSpans, ui.span("changed " .. table.concat(hooks.changed, ", "), "accent"))
	end
	if #hookSpans > 0 then
		table.insert(hookSpans, 1, ui.span("Hooks  ", "strong"))
		table.insert(out, ui.text(hookSpans, { key = "hooks" }))
	end
	local secret = false
	for _, seg in summary.segments do
		if seg.kind == "Secret" and seg.group == nil then
			secret = true
		end
	end
	for _, n in noticeNodes(v, secret or masked, false) do
		table.insert(out, n)
	end
	if #summary.segments == 0 then
		table.insert(out, ui.muted("The two revisions render the same objects.", { key = "same" }))
	end
	-- RevDiff already masked with the secrets explore/helm passed; the
	-- view's own set (both revisions, defaults and computed values too)
	-- runs again so a narrower set upstream cannot leak.
	local revs: { number } = {}
	if a then
		table.insert(revs, a)
	end
	if b then
		table.insert(revs, b)
	end
	local secrets = secretsOf(v, revs)
	for i, seg in summary.segments do
		local key = "seg" .. i
		if not v.policy.showSecrets and #secrets > 0 then
			local lines = table.create(#seg.lines)
			for j, l in seg.lines do
				lines[j] = (Redact.maskEchoes(l, secrets))
			end
			seg = table.clone(seg)
			seg.lines = lines
		end
		if result.masked[seg.key] and not hasHunk(seg) then
			table.insert(out, maskedCard(seg, key))
		else
			table.insert(out, SegCard.card(seg, key, false))
			if result.masked[seg.key] then
				table.insert(out, ui.muted(RevDiff.MASKED_NOTE, { key = key .. "-masked" }))
			end
		end
	end
	return out
end

-- Dispatch --------------------------------------------------------------------

function M.body(v: Ctx): { Node }
	if v.hctx.helm == nil then
		return {
			errorNode(M.NO_HELM, "no-helm"),
			ui.row({
				v.chip("Open Settings", "settings", { key = "settings", tone = "accent", title = "Set helm.program" }),
			}, { key = "fix", wrap = true, role = "tern-kube.chips" }),
		}
	end
	local kind = v.route.kind
	if kind == "helm-releases" then
		return releasesBody(v)
	elseif kind == "helm-release" then
		return releaseBody(v)
	elseif kind == "helm-history" then
		return historyBody(v)
	elseif kind == "helm-values" then
		return valuesBody(v)
	elseif kind == "helm-manifest" then
		return manifestBody(v)
	elseif kind == "helm-notes" then
		return notesBody(v)
	elseif kind == "helm-hooks" then
		return hooksBody(v)
	elseif kind == "helm-resources" then
		return resourcesBody(v)
	elseif kind == "helm-diff" then
		return diffBody(v)
	end
	return { ui.muted("Unknown Helm view " .. kind) }
end

local function releaseText(route: Route): string
	return route.release or "?"
end

local function revText(route: Route): string
	return if route.revision then " rev " .. route.revision else ""
end

function M.crumb(route: Route): string
	local kind = route.kind
	if kind == "helm-releases" then
		return "Helm releases"
	elseif kind == "helm-release" then
		return "release " .. (route.namespace or "?") .. "/" .. releaseText(route) .. revText(route)
	elseif kind == "helm-history" then
		return "History " .. releaseText(route)
	elseif kind == "helm-values" then
		return "Values " .. releaseText(route) .. revText(route) .. " (" .. (route.mode or "changed") .. ")"
	elseif kind == "helm-manifest" then
		return "Manifest " .. releaseText(route) .. revText(route)
	elseif kind == "helm-notes" then
		return "Notes " .. releaseText(route) .. revText(route)
	elseif kind == "helm-hooks" then
		return "Hooks " .. releaseText(route) .. revText(route)
	elseif kind == "helm-resources" then
		return "Resources " .. releaseText(route)
	elseif kind == "helm-diff" then
		return string.format(
			"Diff %s rev %s..%s",
			releaseText(route),
			tostring(route.revision or "?"),
			tostring(route.against or "?")
		)
	end
	return kind
end

M.HINTS = {
	["helm-releases"] = "j/k move · enter open · / filter · n namespace · h history · v values · ctrl+r rollback · r refresh · ? help",
	["helm-release"] = "h history · v values · M manifest · N notes · K hooks · R resources · = diff vs previous · ctrl+r rollback · Y copy · esc back",
	["helm-history"] = "j/k move · enter open revision · space mark · = diff vs latest/marked · ctrl+r roll back to it · / filter · esc back",
	["helm-values"] = "v next mode · h history · M manifest · Y copy · r refresh · esc back",
	["helm-manifest"] = "v values · N notes · K hooks · R resources · Y copy · r refresh · esc back",
	["helm-notes"] = "v values · M manifest · Y copy · r refresh · esc back",
	["helm-hooks"] = "v values · M manifest · Y copy · r refresh · esc back",
	["helm-resources"] = "j/k move · enter open object · / filter · r refresh · esc back",
	["helm-diff"] = "h history · ctrl+r roll back to the older revision · Y copy · r refresh · esc back",
}

function M.hint(route: Route): string?
	return M.HINTS[route.kind]
end

return M
