--!strict
-- Views of the Explore block's GitOps routes (manifest, diff, drift,
-- export, git) and the controller line of the object view. Pure: plain
-- `{k,p,c}` tables. explore/render.luau supplies the shared paged grid and
-- chip builders so these views page, select and click like every other
-- Explore list.

local Command = require("../kubectl/command")
local Controllers = require("./controllers")
local CompareView = require("../compare/view")
local Diffseg = require("../mutation/diffseg")
local Gitops = require("../explore/gitops")
local Index = require("./index")
local Matrix = require("./matrix")
local Placeholder = require("./placeholder")
local T = require("../explore/types")
local SegCard = require("../render/segcard")
local Textfield = require("../textfield")
local Types = require("../model/types")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type Route = T.Route
type Ref = Types.ResourceRef
type ColumnType = Types.ColumnType
type Doc = Index.ManifestDoc

export type GridRow = { key: string, cells: { string }, action: string, open: boolean? }
export type Cell = (col: string, columnType: ColumnType, value: string) -> Node
export type Grid = (
	key: string,
	headers: { string },
	types: { ColumnType },
	rows: { GridRow },
	selected: number,
	cell: Cell?
) -> { Node }
export type Chip = (text: string, action: string, props: { [string]: any }?) -> Node

export type Ctx = {
	g: Gitops.G,
	gctx: Gitops.Ctx,
	route: Route,
	selectedKey: string?,
	grid: Grid,
	chip: Chip,
	-- The live object of the route (manifest/diff), for the controller line.
	object: any?,
	-- Body width in cells (narrow matrix labels) and the scrolled window of
	-- a long matrix; nil: wide, every row.
	width: number?,
	window: CompareView.Window?,
}

local M = {}

M.MAX_DIFF_LINES = SegCard.MAX_LINES
M.SENSITIVE = "Secret values in diffs are masked; set security.show_secret_values to show them"
M.CLI_TITLE = "Copies a tern-kube-drift command that reproduces this report outside Tern "
	.. "(needs bin/tern-kube-drift 0.4.0 or later on PATH)"

local BUCKET_TONE: { [string]: string } = { changed = "info", missing = "success", unmanaged = "warning" }
local BUCKET_TEXT: { [string]: string } = { changed = "changed", missing = "missing", unmanaged = "unmanaged" }

local STATUS_TONE: { [string]: string } = { new = "success", modified = "info", unchanged = "neutral" }

local GIT_TEXT: { [string]: string } = {
	modified = "modified",
	staged = "staged",
	added = "added",
	deleted = "deleted",
	renamed = "renamed",
	untracked = "untracked",
	conflicted = "conflict",
}

local function typed(argv: { string }): string
	local copy = table.clone(argv)
	if copy[1] and string.find(copy[1], "kubectl", 1, true) then
		copy[1] = "kubectl"
	end
	return Command.format(copy)
end

local count = Gitops.count

-- Resource keys (`group/Kind/namespace/name`) as `kind/name`.
local function objectNames(keys: { string }): string
	local out: { string } = {}
	for _, k in keys do
		local kind, name = string.match(k, "^[^/]*/([^/]+)/[^/]*/(.+)$")
		table.insert(out, if kind and name then string.lower(kind) .. "/" .. name else k)
	end
	return table.concat(out, " ")
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

local function refText(ref: Ref): string
	return string.lower(ref.kind) .. "/" .. ref.name .. (if ref.namespace then " -n " .. ref.namespace else "")
end

-- A rendered document (helm template, kustomize build) has no lines in the
-- file it names: a line would point at the wrong text.
local function docPlace(v: Ctx, d: Doc): string
	local where = Gitops.rel(v.g, d.file)
	if not d.rendered and (d.startLine > 1 or d.endLine > 1) then
		where ..= string.format(":%d", d.startLine)
	end
	return where
end

local function lineRange(d: Doc): string
	return if d.rendered then "-" else string.format("%d-%d", d.startLine, d.endLine)
end

local function docKind(d: Doc): string
	local parts: { string } = {}
	if d.rendered then
		table.insert(parts, if d.source.type == "helm" then "helm render" else "kustomize render")
	end
	if d.namespaceInferred then
		table.insert(parts, "namespace inferred")
	end
	if d.kustomization and not d.rendered then
		table.insert(parts, "kustomize resource")
	end
	return if #parts > 0 then table.concat(parts, ", ") else "manifest"
end

local function gitState(v: Ctx, file: string): string
	local st = v.g.status[file]
	if st then
		return GIT_TEXT[st.state] or st.code
	end
	return if v.g.repo.git then "clean" else ""
end

local function badgeCell(tones: { [string]: string }): Cell
	return function(col: string, _t: ColumnType, value: string): Node
		local tone = tones[value]
		local muted = col == "GIT" and value == ("clean" :: string)
		local style = if tone and tone ~= "neutral" then tone .. " strong" elseif muted or tone then "muted" else nil
		return ui.text({ ui.span(value, style) }, { class = "tk-c" })
	end
end

local function chips(v: Ctx, list: { { string } }, key: string): Node
	local out: { Node } = {}
	for i, c in list do
		table.insert(out, v.chip(c[1], c[2], { key = key .. i, tone = c[3] or "neutral", title = c[4] }))
	end
	return ui.row(out, { key = key, wrap = true, role = "tern-kube.chips" })
end

-- Index status ---------------------------------------------------------------

local PHASE: { [string]: string } = {
	root = "finding the repository",
	list = "listing manifest files",
	read = "reading",
	render = "rendering kustomize / helm",
}

function M.scanLine(g: Gitops.G): Node
	local scan = g.scan
	if scan.status == "idle" then
		return ui.muted("Manifest index not built yet (r builds it).", { key = "scan" })
	elseif scan.status == "scanning" then
		local p = scan.progress
		local text = "Indexing manifests under " .. (g.cwd or "?") .. " …"
		if p then
			text = string.format("Indexing manifests: %s", PHASE[p.phase] or p.phase)
			if p.total > 0 then
				text ..= string.format(" %d/%d", p.done, p.total)
			elseif p.done > 0 then
				text ..= string.format(" (%d files)", p.done)
			end
		end
		return ui.text({ ui.span(text, "accent") }, { key = "scan", role = "tern-kube.gitops-scan" })
	elseif scan.status == "error" then
		return ui.text(
			{ ui.span("Manifest index failed: " .. (scan.error or "?"), "error") },
			{ key = "scan", role = "tern-kube.error" }
		)
	end
	local index = g.index :: Index.Index
	local rendered = 0
	for _, d in index.docs do
		if d.rendered then
			rendered += 1
		end
	end
	local spans: { SpanLike } = {
		ui.span(count(#index.docs - rendered, "manifest"), "muted"),
		ui.span(" in " .. count(index.scannedFiles, "file"), "muted"),
	}
	if rendered > 0 then
		table.insert(spans, ui.span(string.format(" · %d rendered", rendered), "muted"))
	end
	table.insert(spans, ui.span(" under ", "muted"))
	table.insert(spans, ui.span(index.root, "mono"))
	if index.truncated then
		table.insert(spans, ui.span("  index truncated (gitops.max_files / max_bytes)", "warning"))
	end
	local errors = 0
	for _, d in index.diagnostics do
		if d.severity == "error" then
			errors += 1
		end
	end
	if errors > 0 then
		table.insert(spans, ui.span(string.format("  %d render/parse errors", errors), "warning"))
	end
	return ui.text(spans, { key = "scan", role = "tern-kube.gitops-scan" })
end

-- Controller line ------------------------------------------------------------

-- "Managed by Argo CD app X (Synced/Healthy) @4f2a9c1" for a tracked object,
-- the reconcile reason when not ready and whether the controller reverts
-- changes applied by hand.
function M.controllerLine(v: Ctx, obj: any): Node?
	if obj == nil or not Gitops.tracked(obj) then
		return nil
	end
	local g = v.g
	local ctl = Gitops.ctl(g, v.gctx)
	if ctl and ctl.status == "loading" and ctl.set == nil then
		return ui.muted("Checking Argo CD / Flux …", { key = "ctl" })
	elseif ctl and ctl.status == "error" then
		return ui.muted("Argo CD / Flux unknown: " .. (ctl.error or "?"), { key = "ctl" })
	end
	local owner = Gitops.owner(g, v.gctx, obj)
	if owner == nil then
		return nil
	end
	local status: { string } = {}
	if owner.sync then
		table.insert(status, owner.sync :: string)
	end
	if owner.health then
		table.insert(status, owner.health :: string)
	end
	local spans: { SpanLike } = {
		ui.span("Managed by ", "muted"),
		ui.span(Gitops.controllerLabel(owner.controller) .. " " .. owner.name, "strong"),
	}
	if owner.namespace then
		table.insert(spans, ui.span(" in " .. owner.namespace, "muted"))
	end
	if #status > 0 then
		table.insert(spans, ui.span(" (" .. table.concat(status, "/") .. ")", "accent"))
	elseif not owner.resolved then
		table.insert(spans, ui.span(" (controller object not readable)", "muted"))
	end
	local rev = Gitops.shortRevision(owner.appliedRevision)
	if rev then
		table.insert(spans, ui.span(" applied " .. rev, "muted mono"))
	end
	if owner.ready == "False" and owner.reason then
		table.insert(spans, ui.span(" · not ready: " .. owner.reason, "warning"))
	end
	local children: { Node } = { ui.text(spans, { key = "owner" }) }
	local path = Gitops.localPath(g, owner)
	if path then
		table.insert(
			children,
			v.chip("Source " .. Gitops.rel(g, path), "gitops-open=" .. path .. ":1", {
				key = "ctl-path",
				tone = "accent",
				title = "The app's path in this checkout; ctrl+g compares it with the cluster",
			})
		)
	elseif owner.path then
		table.insert(children, ui.muted("path " .. owner.path .. " (repository not checked out here)"))
	end
	if owner.resolved then
		local risk = Controllers.revertRisk(owner)
		if risk then
			table.insert(children, ui.text({ ui.span(risk, "warning") }, { key = "ctl-risk" }))
		end
	end
	return ui.row(children, { key = "ctl", wrap = true, role = "tern-kube.gitops-controller" })
end

-- One card per Argo CD / Flux controller deploying the report's source:
-- its own verdict, what it applied against the checkout, its last
-- operation.
local CARD_TONE: { [string]: string } = { success = "success", warning = "warning", error = "error" }

function M.controllerCards(v: Ctx, load: Gitops.DriftLoad): { Node }
	local out: { Node } = {}
	local head = v.g.repo.head
	for i, c in Gitops.sourceControllers(v.g, v.gctx, load) do
		local text, tone = Controllers.statusText(c)
		local lines: { Node } = {
			ui.text({
				ui.span(Gitops.controllerLabel(c.controller) .. " " .. c.name .. ": ", "strong"),
				ui.span(text, CARD_TONE[tone] .. " strong"),
			}, { key = "status" }),
		}
		local applied = c.appliedRevision
		if applied then
			local spans: { SpanLike } = {
				ui.span("applied ", "muted"),
				ui.span(Gitops.shortRevision(applied) :: string, "mono"),
			}
			local sha = Controllers.commit(applied)
			if sha and head then
				local own = string.sub(head, 1, 7)
				if sha == head then
					table.insert(spans, ui.span(" · your checkout " .. own .. " (same)", "muted"))
				else
					table.insert(spans, ui.span(" · your checkout " .. own, "muted"))
					table.insert(
						spans,
						ui.span(": this report compares your checkout, not what the controller applied", "warning")
					)
				end
			end
			local attempted = c.attemptedRevision
			if attempted and attempted ~= applied then
				table.insert(spans, ui.span(" · attempted " .. Gitops.shortRevision(attempted) :: string, "muted"))
			end
			table.insert(lines, ui.text(spans, { key = "rev" }))
		end
		local last: { string } = {}
		if c.phase then
			table.insert(
				last,
				"last sync " .. c.phase .. (if c.operationMessage then ": " .. c.operationMessage else "")
			)
		elseif c.ready ~= "True" and c.message then
			table.insert(last, c.message :: string)
		end
		local errors = c.errors
		if errors and errors.message then
			table.insert(last, errors.message :: string)
		end
		if c.reconciledAt then
			table.insert(last, "reconciled " .. c.reconciledAt)
		end
		if #last > 0 then
			table.insert(lines, ui.muted(table.concat(last, " · "), { key = "op" }))
		end
		table.insert(out, ui.col(lines, { key = "ctl-card" .. i, role = "tern-kube.gitops-controller-status" }))
	end
	return out
end

-- The revert warnings of the report's controllers (above the apply chips).
function M.revertRisks(v: Ctx, load: Gitops.DriftLoad): { Node }
	local out: { Node } = {}
	for i, c in Gitops.sourceControllers(v.g, v.gctx, load) do
		local risk = Controllers.revertRisk(c)
		if risk then
			table.insert(
				out,
				ui.text({
					ui.span(Gitops.controllerLabel(c.controller) .. " " .. c.name .. ": ", "muted"),
					ui.span(risk, "warning"),
				}, {
					key = "risk" .. i,
					role = "tern-kube.gitops-controller-risk",
				})
			)
		end
	end
	return out
end

-- Manifest -------------------------------------------------------------------

local function manifestBody(v: Ctx): { Node }
	local g = v.g
	local ref = v.route.ref :: Ref
	local out: { Node } = { M.scanLine(g) }
	local line = M.controllerLine(v, v.object)
	if line then
		table.insert(out, line)
	end
	if not Gitops.ready(g) then
		return out
	end
	local docs = Gitops.matches(g, v.gctx, ref)
	if #docs == 0 then
		table.insert(
			out,
			ui.text({
				ui.span("No manifest declares " .. refText(ref) .. ".", "warning"),
				ui.span("  E exports it to the repository.", "muted"),
			}, { key = "none", role = "tern-kube.gitops-none" })
		)
		table.insert(out, chips(v, { { "Export (E)", "gitops=export", "accent" } }, "mc"))
		return out
	end
	local rows: { GridRow } = {}
	local keys: { string } = {}
	local handWritten = 0
	for i, d in docs do
		local key = d.file .. ":" .. d.startLine
		if not d.rendered then
			handWritten += 1
		end
		rows[i] = {
			key = key,
			cells = {
				Gitops.rel(g, d.file),
				lineRange(d),
				d.source.label,
				docKind(d),
				gitState(v, d.file),
			},
			action = "open=" .. key,
		}
		keys[i] = key
	end
	table.insert(
		out,
		ui.muted(
			string.format(
				"%s %s %s",
				count(#docs, "manifest"),
				if #docs == 1 then "declares" else "declare",
				refText(ref)
			),
			{ key = "count" }
		)
	)
	for _, n in
		v.grid(
			"mf",
			{ "FILE", "LINES", "SOURCE", "KIND", "GIT" },
			{ "text", "text", "text", "text", "text" },
			rows,
			selectedIndex(keys, v.selectedKey),
			badgeCell({
				modified = "info",
				staged = "info",
				untracked = "warning",
				added = "success",
				conflict = "error",
			})
		)
	do
		table.insert(out, n)
	end
	if handWritten > 1 then
		table.insert(
			out,
			ui.text({
				ui.span(
					string.format("Declared in %d hand-written places: only one should be applied.", handWritten),
					"warning"
				),
			}, { key = "dup" })
		)
	end
	local sel = selectedIndex(keys, v.selectedKey)
	table.insert(
		out,
		chips(v, {
			{ "Open at line (m)", "gitops-key=m", "accent", "Opens the file in a Tern file block" },
			{ "Diff vs manifest (=)", "gitops-diff=" .. sel, "accent", "kubectl diff of this manifest" },
			{ "Rescan (r)", "refresh" },
		}, "mc")
	)
	return out
end

-- Diff -----------------------------------------------------------------------

local function hasSecret(segments: { Diffseg.Segment }): boolean
	for _, s in segments do
		if s.kind == "Secret" and s.group == nil then
			return true
		end
	end
	return false
end

local STEP_TEXT: { [string]: string } = {
	index = "Waiting for the manifest index …",
	chart = "No manifest declares it: rendering the chart of its Helm release …",
	reading = "Reading the manifest …",
	writing = "Writing the manifest to a temporary file (0600) …",
	diffing = "Running kubectl diff …",
}

-- After an apply was offered or an export written; leaving and coming back
-- (or r) compares again.
local function staleNode(): Node
	return ui.text({
		ui.span("Out of date: ", "warning strong"),
		ui.span("an apply or export ran since this comparison; r compares again.", "muted"),
	}, { key = "stale", role = "tern-kube.gitops-stale" })
end

local function diffBody(v: Ctx): { Node }
	local g = v.g
	local route = v.route
	local ref = route.ref :: Ref
	local load = g.diffs[Gitops.diffId(route)]
	local out: { Node } = {}
	if not Gitops.ready(g) then
		table.insert(out, M.scanLine(g))
	end
	if load == nil then
		table.insert(out, ui.muted("Not compared yet (r).", { key = "idle" }))
		return out
	end
	local doc = load.doc
	if doc then
		local spans: { SpanLike } = {
			ui.span("Live " .. refText(ref) .. " vs ", "muted"),
			ui.span(docPlace(v, doc), "mono strong"),
		}
		if doc.rendered then
			table.insert(spans, ui.span("  (" .. docKind(doc) .. " of " .. doc.source.label .. ")", "muted"))
		end
		table.insert(out, ui.text(spans, { key = "against" }))
	end
	if #load.docs > 1 then
		local docChips: { Node } = {}
		for i, d in load.docs do
			table.insert(
				docChips,
				v.chip(string.format("%d %s", i, docPlace(v, d)), "gitops-doc=" .. i, {
					key = "doc" .. i,
					tone = if i == load.pick then "accent" else "neutral",
					title = docKind(d),
				})
			)
		end
		table.insert(out, ui.row(docChips, { key = "docs", wrap = true, role = "tern-kube.chips" }))
	end
	local status = load.status
	if load.stale and (status == "ok" or status == "error" or status == "nomatch") then
		table.insert(out, staleNode())
	end
	if STEP_TEXT[status] then
		local text = STEP_TEXT[status]
		if status == "diffing" and load.argv then
			text = "Running " .. typed(load.argv :: { string }) .. " …"
		end
		table.insert(out, ui.muted(text, { key = "status" }))
	elseif status == "nomatch" and load.helm then
		table.insert(
			out,
			ui.text({
				ui.span("Managed by Helm release " .. (load.helm :: string) .. ".", "warning"),
				ui.span("  No chart directory in this repository renders it; H opens the release.", "muted"),
			}, { key = "status", role = "tern-kube.gitops-none" })
		)
	elseif status == "nomatch" then
		table.insert(
			out,
			ui.text({
				ui.span("No manifest declares " .. refText(ref) .. ".", "warning"),
				ui.span("  E exports it.", "muted"),
			}, { key = "status", role = "tern-kube.gitops-none" })
		)
	elseif status == "error" then
		table.insert(
			out,
			ui.text(
				{ ui.span(load.error or "kubectl diff failed", "error") },
				{ key = "status", role = "tern-kube.error" }
			)
		)
	elseif status == "ok" then
		if #load.segments == 0 then
			table.insert(
				out,
				ui.text({
					ui.span("In sync: ", "success strong"),
					ui.span("the live object matches the manifest.", "muted"),
				}, { key = "status", role = "tern-kube.gitops-insync" })
			)
		else
			local cards: { Node } = {}
			for i, seg in load.segments do
				table.insert(cards, SegCard.card(seg, "seg" .. i, false))
			end
			table.insert(out, ui.col(cards, { key = "diffs" }))
			if hasSecret(load.segments) and not v.gctx.config.security.show_secret_values then
				table.insert(out, ui.text({ ui.span(M.SENSITIVE, "warning") }, { key = "sensitive" }))
			end
		end
		for i, note in load.notes do
			table.insert(out, ui.muted(note, { key = "note" .. i }))
		end
		if load.argv then
			table.insert(
				out,
				ui.text(
					{ ui.span("ran ", "muted"), ui.span(typed(load.argv :: { string }), "muted mono") },
					{ key = "argv" }
				)
			)
		end
	end
	local list: { { string } } = {}
	if doc then
		table.insert(list, { "Open manifest (m)", "gitops-key=m", "accent" })
		if v.gctx.config.mutations.enabled then
			table.insert(list, { "Apply manifest (a)", "gitops-key=a", "warning", "Previews in the approve block" })
		end
	end
	if #load.docs > 1 then
		table.insert(list, { "Next manifest (])", "gitops-key=]" })
	end
	table.insert(list, { "Diff again (r)", "refresh" })
	table.insert(out, chips(v, list, "dc"))
	return out
end

-- Drift ----------------------------------------------------------------------

local TYPE_TEXT: { [string]: string } = {
	dir = "directory",
	file = "file",
	kustomize = "kustomize",
	helm = "helm",
}

local function chooserBody(v: Ctx): { Node }
	local g = v.g
	local out: { Node } = { M.scanLine(g) }
	local ctl = Gitops.ctl(g, v.gctx)
	if ctl and ctl.status == "loading" then
		table.insert(out, ui.muted("Reading Argo CD / Flux applications …", { key = "ctl" }))
	elseif ctl and ctl.status == "error" then
		table.insert(out, ui.muted("Argo CD / Flux unknown: " .. (ctl.error or "?"), { key = "ctl" }))
	elseif ctl and ctl.set and #ctl.set.controllers > 0 then
		local at = ctl.fetchedAt
		table.insert(
			out,
			ui.muted(
				count(#ctl.set.controllers, "Argo CD / Flux controller")
					.. (if at then " read " .. (os.date("!%H:%M UTC", at) :: string) else "")
					.. " · r reads them again",
				{ key = "ctl" }
			)
		)
	end
	if ctl and ctl.set then
		for i, note in ctl.set.notes do
			table.insert(out, ui.muted(note, { key = "ctl-note" .. i }))
		end
	end
	local releases = g.releases
	if releases.status == "loading" then
		table.insert(out, ui.muted("Reading helm releases for chart auto-detect …", { key = "releases" }))
	elseif releases.status == "error" then
		table.insert(
			out,
			ui.text(
				{ ui.span("Chart auto-detect unavailable: " .. (releases.error or "?"), "error") },
				{ key = "releases", role = "tern-kube.error" }
			)
		)
	end
	if not Gitops.ready(g) then
		return out
	end
	local sources, hidden = Gitops.chooserSources(g, v.gctx)
	if #sources == 0 then
		table.insert(out, ui.muted("No manifest sources found under the repository.", { key = "empty" }))
		return out
	end
	local rows: { GridRow } = {}
	local keys: { string } = {}
	for i, s in sources do
		rows[i] = {
			key = s.id,
			cells = {
				s.label,
				TYPE_TEXT[s.type] or s.type,
				if s.auto and s.docs == 0 then "-" else tostring(s.docs),
				table.concat(s.namespaces, " "),
				s.note or "",
			},
			action = "open=" .. s.id,
		}
		keys[i] = s.id
	end
	local summary = count(#sources, "source") .. " · enter compares one with the cluster"
	if hidden > 0 then
		summary ..= string.format(
			" · %s of releases in other namespaces hidden (n changes the namespace)",
			count(hidden, "chart match", "chart matches")
		)
	end
	table.insert(out, ui.muted(summary, { key = "count" }))
	for _, n in
		v.grid(
			"src",
			{ "NAME", "TYPE", "DOCS", "NAMESPACE", "NOTE" },
			{ "text", "text", "count", "text", "text" },
			rows,
			selectedIndex(keys, v.selectedKey)
		)
	do
		table.insert(out, n)
	end
	return out
end

-- Several documents declare the object: kubectl diff compared only the one
-- it read last, so the row cannot name "the" manifest.
local function entryManifest(v: Ctx, e: Gitops.Entry): string
	local d = e.docs[1]
	if d == nil then
		return ""
	end
	if #e.docs > 1 then
		return string.format("ambiguous: %d manifests", #e.docs)
	end
	return docPlace(v, d)
end

local function entryLines(e: Gitops.Entry): string
	local seg = e.segment
	local diff = if seg then string.format("+%d −%d", seg.added, seg.removed) else ""
	if e.placeholders then
		return if diff == "" then "placeholder" else "placeholder " .. diff
	end
	return diff
end

local function countsRow(v: Ctx, load: Gitops.DriftLoad): Node
	local report = load.report
	local out: { Node } = {}
	if report == nil then
		return ui.row(out, { key = "counts" })
	end
	local c = report.counts
	local list: { { any } } = {
		{ "all", "All", c.changed + c.missing + c.unmanaged, "accent" },
		{ "changed", "Changed", c.changed, "info" },
		{ "missing", "Missing in cluster", c.missing, "success" },
		{ "unmanaged", "Unmanaged", c.unmanaged, "warning" },
	}
	for _, f in list do
		local on = load.filter == f[1]
		table.insert(
			out,
			v.chip(string.format("%s %d", f[2], f[3]), "gitops-filter=" .. f[1], {
				key = "f-" .. f[1],
				tone = if on then f[4] else "neutral",
				title = "f cycles the filter",
			})
		)
	end
	table.insert(out, ui.badge(string.format("in sync %d", c.inSync), "neutral", { key = "insync" }))
	if c.ignored > 0 then
		table.insert(
			out,
			ui.badge(string.format("ignored %d", c.ignored), "neutral", {
				key = "ignored",
				title = "Cluster defaults, owned and bookkeeping objects, kustomize bases and patches",
			})
		)
	end
	return ui.row(out, { key = "counts", wrap = true, role = "tern-kube.chips" })
end

local function reportBody(v: Ctx, load: Gitops.DriftLoad): { Node }
	local g = v.g
	local src = load.source
	local out: { Node } = {
		ui.text({
			ui.span("Drift of ", "muted"),
			ui.span(src.label, "strong mono"),
			ui.span("  " .. (TYPE_TEXT[src.type] or src.type), "muted"),
			ui.span(if src.note then "  · " .. src.note else "", "muted"),
		}, { key = "src" }),
	}
	local auto = src.auto
	if auto then
		local how = if auto.useDeployedValues
			then string.format(
				"Rendered with the deployed values of %s/%s (written 0600 for the render, then removed).",
				auto.release.namespace,
				auto.release.name
			)
			else "Rendered with " .. Gitops.rel(g, (auto.values :: { string })[1]) .. "."
		table.insert(out, ui.muted(how, { key = "auto" }))
	end
	for _, card in M.controllerCards(v, load) do
		table.insert(out, card)
	end
	if load.stale and (load.status == "ok" or load.status == "error") then
		table.insert(out, staleNode())
	end
	if load.status == "index" then
		table.insert(out, M.scanLine(g))
		return out
	elseif load.status == "running" then
		local pending = 0
		for _ in load.livePending do
			pending += 1
		end
		local text = if load.render == "values"
			then "Reading the release's deployed values …"
			elseif load.render == "template" then "Rendering the chart …"
			else "Comparing with the cluster: "
				.. (if load.diffDone then "diff done" else "kubectl diff running")
				.. (if pending > 0 then string.format(", listing %d namespaces", pending) else "")
				.. " …"
		table.insert(out, ui.muted(text, { key = "status" }))
		if load.argv then
			table.insert(out, ui.muted(typed(load.argv :: { string }), { key = "argv" }))
		end
		return out
	elseif load.status == "error" then
		table.insert(
			out,
			ui.text({ ui.span(load.error or "drift failed", "error") }, { key = "status", role = "tern-kube.error" })
		)
		return out
	end
	table.insert(out, countsRow(v, load))
	local entries = Gitops.entries(load)
	if #entries == 0 then
		table.insert(
			out,
			ui.text({
				ui.span(if load.filter == "all" then "No drift: " else "Nothing in this filter. ", "success strong"),
				ui.span(
					if load.filter == "all" then "the cluster matches the manifests." else "f shows more.",
					"muted"
				),
			}, { key = "insync-all", role = "tern-kube.gitops-insync" })
		)
	else
		local rows: { GridRow } = {}
		local keys: { string } = {}
		for i, e in entries do
			rows[i] = {
				key = e.key,
				cells = {
					BUCKET_TEXT[e.bucket],
					e.ref.kind,
					e.ref.namespace or "",
					e.ref.name,
					entryManifest(v, e),
					entryLines(e),
				},
				action = "open=" .. e.key,
			}
			keys[i] = e.key
		end
		for _, n in
			v.grid(
				"drift",
				{ "DRIFT", "KIND", "NAMESPACE", "NAME", "MANIFEST", "LINES" },
				{ "text", "text", "text", "text", "text", "text" },
				rows,
				selectedIndex(keys, v.selectedKey),
				badgeCell(BUCKET_TONE)
			)
		do
			table.insert(out, n)
		end
	end
	local report = load.report
	if report then
		for i, note in report.notes do
			table.insert(out, ui.muted(note, { key = "note" .. i }))
		end
	end
	if load.renderArgv then
		table.insert(
			out,
			ui.text({
				ui.span("rendered by ", "muted"),
				ui.span(table.concat(load.renderArgv :: { string }, " "), "muted mono"),
			}, { key = "render-argv" })
		)
	end
	if load.argv then
		table.insert(
			out,
			ui.text({ ui.span("ran ", "muted"), ui.span(typed(load.argv :: { string }), "muted mono") }, {
				key = "argv",
			})
		)
	end
	for _, risk in M.revertRisks(v, load) do
		table.insert(out, risk)
	end
	local list: { { string } } = { { "Open (enter)", "gitops-key=enter" }, { "Manifest (m)", "gitops-key=m" } }
	if v.gctx.config.mutations.enabled then
		table.insert(
			list,
			{ "Apply (a)", "gitops-key=a", "warning", "Apply the selected manifest via the approve block" }
		)
		table.insert(
			list,
			{ "Apply source (A)", "gitops-key=A", "warning", "Apply the whole source via the approve block" }
		)
	end
	if src.type ~= "helm" then
		table.insert(list, { "Export (E)", "gitops-key=E", "accent", "Write the selected live object to manifests" })
		table.insert(list, { "Export all shown (X)", "gitops-key=X", "accent" })
	elseif #Gitops.entries(load, "unmanaged") > 0 then
		table.insert(list, {
			"Export unmanaged (E)",
			"gitops-key=E",
			"accent",
			"Write the selected unmanaged object to manifests; chart objects stay in the chart",
		})
		table.insert(list, { "Export all unmanaged (X)", "gitops-key=X", "accent" })
	end
	if src.auto then
		table.insert(list, {
			"Copy as gitops.helm entry",
			"gitops-copyhelm=",
			"accent",
			if src.auto.useDeployedValues
				then "Copies a config entry without values: the deployed values (and --set) cannot be configured"
				else "Copies the config entry for this source; the config is not changed",
		})
	end
	table.insert(list, { "Filter (f)", "gitops-key=f" })
	table.insert(list, { "Copy CLI command (Y)", "gitops-key=Y", "accent", M.CLI_TITLE })
	table.insert(list, { "Across contexts (x)", "gitops-key=x", "accent", "Run this source against several contexts" })
	table.insert(list, { "Compare again (r)", "refresh" })
	table.insert(out, chips(v, list, "rc"))
	return out
end

local function itemBody(v: Ctx, load: Gitops.DriftLoad, e: Gitops.Entry): { Node }
	local context = load.target.context or "?"
	local foreign = Gitops.foreign(v.gctx, v.route)
	local out: { Node } = {
		ui.row({
			ui.badge(BUCKET_TEXT[e.bucket], BUCKET_TONE[e.bucket], { key = "bucket" }),
			ui.text({ ui.span(refText(e.ref), "strong mono") }, { key = "ref" }),
			ui.text({ ui.span("in context ", "muted"), ui.span(context, "strong mono") }, { key = "ctx" }),
		}, { key = "head", wrap = true }),
	}
	if foreign then
		table.insert(
			out,
			ui.text({
				ui.span("Read-only: ", "warning strong"),
				ui.span("switch to " .. context .. " (c) to change it.", "muted"),
			}, { key = "ro" })
		)
	end
	if e.bucket == "missing" then
		table.insert(
			out,
			ui.muted(
				if e.reason == "absent"
					then "Declared in the source but not found in the cluster."
					else "kubectl diff would create it.",
				{ key = "why" }
			)
		)
	elseif e.bucket == "unmanaged" then
		table.insert(
			out,
			ui.muted("Live in a namespace and kind the source covers, but no manifest declares it.", { key = "why" })
		)
		local o = e.object
		if o then
			local items: { { { SpanLike } } } = {}
			if o.created then
				table.insert(items, { { "Created" }, { o.created :: string } })
			end
			if o.managedBy then
				table.insert(items, { { "Managed by" }, { o.managedBy :: string } })
			end
			if o.controller then
				table.insert(items, {
					{ "Controller" },
					{ Gitops.controllerLabel(o.controller.controller) .. " " .. o.controller.name },
				})
			end
			if #items > 0 then
				local kv = ui.kv(items);
				(kv.p :: any).key = "obj"
				table.insert(out, kv)
			end
		end
	end
	local held = e.placeholders
	if held then
		table.insert(
			out,
			ui.text({
				ui.span("Placeholder: ", "warning strong"),
				ui.span(
					string.format(
						"%s still %s %s from an export. Applying would overwrite the live %s, so apply leaves "
							.. "this Secret out; put the real values in the manifest first.",
						table.concat(held, ", "),
						if #held == 1 then "holds" else "hold",
						Placeholder.TOKEN,
						if #held == 1 then "value" else "values"
					),
					"muted"
				),
			}, { key = "placeholder" })
		)
	end
	if #e.docs > 1 then
		table.insert(
			out,
			ui.text({
				ui.span("Ambiguous: ", "warning strong"),
				ui.span(
					string.format(
						"%d documents declare this object. kubectl diff compared the one it read last; "
							.. "applying applies the first listed below.",
						#e.docs
					),
					"muted"
				),
			}, { key = "ambiguous" })
		)
	end
	if #e.docs > 0 then
		local rows: { GridRow } = {}
		local keys: { string } = {}
		for i, d in e.docs do
			local key = d.file .. ":" .. d.startLine
			rows[i] = {
				key = key,
				cells = { Gitops.rel(v.g, d.file), lineRange(d), docKind(d) },
				action = "open=" .. key,
			}
			keys[i] = key
		end
		for _, n in
			v.grid(
				"docs",
				{ "FILE", "LINES", "KIND" },
				{ "text", "text", "text" },
				rows,
				selectedIndex(keys, v.selectedKey)
			)
		do
			table.insert(out, n)
		end
	end
	local seg = e.segment
	if seg then
		table.insert(out, SegCard.card(seg, "seg", false))
	end
	local list: { { string } } = {}
	local mutable = v.gctx.config.mutations.enabled and not foreign
	if #e.docs > 0 then
		table.insert(list, { "Open manifest (m)", "gitops-key=m", "accent" })
		if mutable then
			table.insert(list, { "Apply (a)", "gitops-key=a", "warning", "Previews in the approve block" })
		end
	end
	if e.bucket ~= "missing" and load.source.type ~= "helm" and not foreign then
		table.insert(list, { "Export (E)", "gitops-key=E", "accent" })
	end
	if e.bucket == "unmanaged" and mutable then
		table.insert(list, { "Delete (ctrl+d)", "mutate=delete", "warning", "Previews, then typed confirmation" })
	end
	table.insert(list, { "Copy CLI command (Y)", "gitops-key=Y", "accent", M.CLI_TITLE })
	table.insert(list, { "Across contexts (x)", "gitops-key=x", "accent" })
	table.insert(out, chips(v, list, "ic"))
	return out
end

local function driftBody(v: Ctx): { Node }
	local route = v.route
	if route.source == nil then
		return chooserBody(v)
	end
	local load = Gitops.driftLoad(v.g, v.gctx, route)
	if load == nil then
		return { ui.muted("Not compared yet (r).", { key = "idle" }) }
	end
	if route.item then
		local e = Gitops.entry(load, route.item :: string)
		if e == nil then
			return { ui.muted("No longer in the report (r compares again).", { key = "gone" }) }
		end
		return itemBody(v, load, e)
	end
	return reportBody(v, load)
end

-- Matrix ---------------------------------------------------------------------

-- The source's label from any drift load of it (crumbs have no target).
local function sourceLabel(g: Gitops.G, source: string): string
	for _, load in g.drifts do
		if load.source.id == source then
			return load.source.label
		end
	end
	return source
end

local MATRIX_FILTER_TEXT: { [string]: string } = {
	all = "all",
	drifted = "drifted anywhere",
	differs = "differs between contexts",
}

local MATRIX_EMPTY: { [string]: string } = {
	all = "The source declares nothing and no context has unmanaged objects.",
	drifted = "In sync in every context (f shows all).",
	differs = "Every context has the same drift (f shows all).",
}

local function clock(at: number?): string
	return if at then os.date("!%H:%M:%S UTC", at) :: string else ""
end

local function pickerBody(v: Ctx): { Node }
	local load = Gitops.contexts(v.g, v.gctx)
	local out: { Node } = {
		ui.text({
			ui.span("Run ", "muted"),
			ui.span(sourceLabel(v.g, v.route.source or ""), "strong mono"),
			ui.span(" against several contexts of the kubeconfig", "muted"),
		}, { key = "src" }),
	}
	if load == nil or load.status == "loading" then
		table.insert(out, ui.muted("Reading the kubeconfig's contexts …", { key = "status" }))
		return out
	elseif load.status == "error" then
		table.insert(
			out,
			ui.text({ ui.span(load.error or "kubectl config view failed", "error") }, {
				key = "status",
				role = "tern-kube.error",
			})
		)
		return out
	end
	for _, n in CompareView.picker(Gitops.choices(v.g, v.gctx), v.selectedKey) do
		table.insert(out, n)
	end
	return out
end

-- Whether the matrix needs short column labels in `width` columns.
local function narrow(v: Ctx, mx: Matrix.Matrix): boolean
	local width = v.width
	if width == nil then
		return false
	end
	local need = 32
	for _, c in mx.columns do
		need += math.max(#c.context, 14) + 3
	end
	return need > width
end

local function matrixBody(v: Ctx): { Node }
	local route = v.route
	if route.across == nil then
		return pickerBody(v)
	end
	local m = Gitops.matrixState(v.g, v.gctx, route)
	if m == nil or m.status == "contexts" then
		return { ui.muted("Reading the kubeconfig's contexts …", { key = "status" }) }
	elseif m.status == "error" then
		return {
			ui.text({ ui.span(m.error or "matrix failed", "error") }, { key = "status", role = "tern-kube.error" }),
			chips(v, { { "Choose contexts (x)", "gitops-key=x", "accent" } }, "mc"),
		}
	end
	local full = Gitops.matrix(v.g, v.gctx, route) :: Matrix.Matrix
	local mx = Matrix.filter(full, m.filter)
	local title = string.format(
		"Drift of %s across %s (namespace %s) · filter: %s",
		sourceLabel(v.g, m.source),
		Gitops.count(#m.contexts, "context"),
		m.base.namespace or "default",
		MATRIX_FILTER_TEXT[m.filter]
	)
	local out: { Node } = {}
	for i, c in full.columns do
		local spans: { SpanLike } = {
			ui.span(if i == 1 then "base " else "", "muted"),
			ui.span(c.context, "strong mono"),
		}
		if c.server then
			table.insert(spans, ui.span("  " .. c.server, "muted mono"))
		end
		if c.fetchedAt then
			table.insert(spans, ui.span("  fetched " .. clock(c.fetchedAt), "muted"))
		end
		table.insert(spans, ui.span("  " .. Matrix.summary(full, i), "muted"))
		table.insert(out, ui.text(spans, { key = "prov" .. i }))
	end
	for _, n in
		CompareView.matrix(mx, v.selectedKey, {
			narrow = narrow(v, mx),
			filter = if m.filter == "all" then "all" else "differs",
			title = title,
			context = Gitops.matrixColumn(v.g, v.gctx, route),
			window = v.window,
			empty = MATRIX_EMPTY[m.filter],
		})
	do
		table.insert(out, n)
	end
	table.insert(
		out,
		chips(v, {
			{ "Open cell (enter)", "gitops-key=enter" },
			{ "Previous context ([)", "gitops-key=[" },
			{ "Next context (])", "gitops-key=]" },
			{ "Filter (f)", "gitops-key=f" },
			{ "Choose contexts (x)", "gitops-key=x", "accent" },
			{ "Copy commands (Y)", "gitops-key=Y" },
			{ "Copy CLI command", "gitops-copycli=", "accent", M.CLI_TITLE },
			{ "Compare again (r)", "refresh" },
		}, "mc")
	)
	table.insert(
		out,
		ui.muted("Read-only: to change a context, switch to it (c) and open its drift report.", { key = "ro" })
	)
	return out
end

-- Export ---------------------------------------------------------------------

local function diffText(diff: string?): string
	if diff == nil then
		return ""
	end
	local out: { string } = {}
	local started = false
	for _, l in string.split(diff, "\n") do
		if string.sub(l, 1, 2) == "@@" then
			started = true
		end
		if started and #out < M.MAX_DIFF_LINES then
			table.insert(out, l)
		end
	end
	return table.concat(out, "\n")
end

local function exportBody(v: Ctx): { Node }
	local g = v.g
	local ex = g.export
	if ex == nil then
		return { ui.muted("Nothing to export. E in a list or object view starts an export.", { key = "idle" }) }
	end
	local out: { Node } = {
		ui.text({
			ui.span("Export ", "muted"),
			ui.span(ex.label, "strong"),
			ui.span(" to ", "muted"),
			ui.span(if ex.dir ~= "" then ex.dir else "…", "mono strong"),
		}, { key = "head" }),
	}
	if ex.status == "index" then
		table.insert(out, M.scanLine(g))
		return out
	elseif ex.status == "reading" then
		table.insert(out, ui.muted("Reading the existing files under " .. ex.dir .. " …", { key = "status" }))
		return out
	elseif ex.status == "error" then
		table.insert(
			out,
			ui.text({ ui.span(ex.error or "export failed", "error") }, { key = "status", role = "tern-kube.error" })
		)
		table.insert(
			out,
			chips(v, { { "Change directory (t)", "field-focus=dir" }, { "Read again (r)", "refresh" } }, "xc")
		)
		return out
	end
	local plan = ex.plan
	if plan == nil then
		return out
	end
	local index = g.index
	local layout = if index then Index.layout(index, ex.dir) else nil
	if layout and layout.samples > 0 and layout.style ~= "unknown" then
		table.insert(
			out,
			ui.muted(
				string.format(
					"Matches the directory's layout: %s, files named %s%s%s",
					layout.style,
					layout.naming,
					layout.ext,
					if layout.kustomization then ", kustomization.yaml kept current" else ""
				),
				{ key = "layout" }
			)
		)
	else
		local kustomization = layout == nil or layout.samples == 0 or layout.kustomization
		table.insert(
			out,
			ui.muted(
				(if layout and layout.samples > 0 then "No single layout in this directory; using " else "Layout ")
					.. "<namespace>/<kind>/<name>"
					.. (if layout then layout.ext else ".yaml")
					.. (if kustomization then " with a kustomization.yaml per directory" else ""),
				{ key = "layout" }
			)
		)
	end
	local rows: { GridRow } = {}
	local keys: { string } = {}
	local counts: { [string]: number } = { new = 0, modified = 0, unchanged = 0 }
	local all: { any } = {}
	for _, f in plan.files do
		table.insert(all, f)
	end
	for _, f in plan.kustomizationEdits do
		table.insert(all, f)
	end
	for i, f in all do
		counts[f.status] += 1
		rows[i] = {
			key = f.path,
			cells = {
				f.status,
				if index then Index.relative(index.root, f.path) else f.path,
				objectNames(f.keys or {}),
			},
			action = "open=" .. f.path,
		}
		keys[i] = f.path
	end
	table.insert(
		out,
		ui.muted(
			string.format(
				"%d new · %d modified · %d unchanged · enter shows a file's diff",
				counts.new,
				counts.modified,
				counts.unchanged
			),
			{ key = "count" }
		)
	)
	for _, n in
		v.grid(
			"files",
			{ "STATUS", "FILE", "OBJECTS" },
			{ "text", "text", "text" },
			rows,
			selectedIndex(keys, v.selectedKey),
			badgeCell(STATUS_TONE)
		)
	do
		table.insert(out, n)
	end
	for i, f in all do
		if ex.expanded[f.path] and f.diff then
			table.insert(
				out,
				ui.card({
					ui.span(string.upper(f.status) .. "  ", "strong"),
					ui.span(if index then Index.relative(index.root, f.path) else f.path, "strong mono"),
				}, {
					{ k = "diff", p = { key = "diff", text = diffText(f.diff), path = f.path, mode = "unified" } },
				}, {
					key = "fd" .. i,
					collapsible = true,
					inset = true,
					tone = STATUS_TONE[f.status],
					role = "tern-kube.gitops-diff",
				})
			)
		end
	end
	for i, n in plan.notes do
		table.insert(
			out,
			ui.text({
				ui.span(n.text, if n.severity == "warning" then "warning" else "muted"),
				ui.span(if n.key then "  " .. n.key else "", "muted mono"),
			}, { key = "note" .. i })
		)
	end
	local changes = #Gitops.exportChanges(ex)
	if ex.confirming then
		table.insert(
			out,
			ui.row({
				ui.text({
					ui.span(string.format("Write %s under %s?", count(changes, "file"), ex.dir), "warning strong"),
					ui.span("  enter or y writes · esc cancels", "muted"),
				}, { key = "q" }),
				v.chip("Write", "gitops-key=y", { key = "yes", tone = "warning" }),
				v.chip("Cancel", "gitops-key=escape", { key = "no" }),
			}, { key = "confirm", wrap = true, role = "tern-kube.gitops-confirm" })
		)
	elseif ex.status == "writing" then
		table.insert(out, ui.muted("Writing …", { key = "status" }))
	elseif ex.status == "written" then
		table.insert(
			out,
			ui.text({
				ui.span("Wrote " .. count(#ex.written, "file") .. ".", "success strong"),
				ui.span(if g.repo.git then "  b creates a branch and commit." else "", "muted"),
			}, { key = "status", role = "tern-kube.gitops-written" })
		)
		if g.repo.git then
			table.insert(out, chips(v, { { "Branch & commit (b)", "gitops-key=b", "accent" } }, "xc"))
		end
	else
		table.insert(
			out,
			chips(v, {
				{
					"Write " .. count(changes, "file") .. " (w)",
					"gitops-key=w",
					if changes > 0 then "warning" else "neutral",
					"Asks for confirmation first",
				},
				{ "Change directory (t)", "field-focus=dir" },
				{ "Read again (r)", "refresh" },
			}, "xc")
		)
	end
	return out
end

-- Git ------------------------------------------------------------------------

local STEP_TONE: { [string]: string } = {
	pending = "neutral",
	running = "accent",
	ok = "success",
	error = "error",
	skipped = "neutral",
}

local function onOff(v: Ctx, label: string, on: boolean, key: string, title: string): Node
	return v.chip(label .. (if on then ": on" else ": off") .. " (" .. key .. ")", "gitops-key=" .. key, {
		key = "t-" .. key,
		tone = if on then "accent" else "neutral",
		title = title,
	})
end

local function gitBody(v: Ctx): { Node }
	local git = v.g.git
	if git == nil then
		return { ui.muted("Write an export first (E, then w), then b.", { key = "idle" }) }
	end
	local checks = git.checks
	local out: { Node } = {
		ui.text({
			ui.span("Repository ", "muted"),
			ui.span(git.root, "mono strong"),
			ui.span(if checks.head then " on " .. checks.head else "", "muted"),
		}, { key = "head" }),
	}
	if git.status == "checking" then
		table.insert(out, ui.muted("Checking the repository, remotes and gh …", { key = "status" }))
		return out
	end
	local ghText = if checks.gh
		then "gh " .. (checks.gh :: string) .. (if checks.ghAuth then " (logged in)" else " (not logged in)")
		else "gh not found"
	table.insert(
		out,
		ui.row({
			onOff(v, "Push", git.push, "p", "git push -u origin <branch> (never forced)"),
			onOff(v, "Pull request", git.pr, "P", "gh pr create with a drift / export summary"),
			onOff(v, "Only exported files", git.only, "o", "git commit -- <files>: other staged changes stay staged"),
			ui.text({ ui.span(ghText, "muted") }, { key = "gh" }),
			ui.text({ ui.span(if checks.origin then "remote origin" else "no remote origin", "muted") }, {
				key = "origin",
			}),
		}, { key = "toggles", wrap = true, role = "tern-kube.chips" })
	)
	if #checks.unrelated > 0 then
		table.insert(
			out,
			ui.text({
				ui.span(string.format("%d staged change(s) not from this export: ", #checks.unrelated), "warning"),
				ui.span(table.concat(checks.unrelated, ", "), "mono"),
			}, { key = "unrelated" })
		)
	end
	local steps: { Gitops.GitStep } = if #git.steps > 0
		then git.steps
		else Gitops.gitCommands(git, checks.gh or v.gctx.config.gitops.gh)
	local cards: { Node } = {}
	for i, step in steps do
		local body: { Node } = {
			ui.code(Command.format(step.argv), "sh", nil, { key = "cmd" }),
		}
		if step.output and step.output ~= "" then
			table.insert(body, ui.code(step.output :: string, nil, nil, { key = "out" }))
		end
		table.insert(
			cards,
			ui.card(
				{
					ui.span(string.format("%d  ", i), "muted"),
					ui.span(step.label, "strong"),
					ui.span(
						if step.status ~= "pending"
							then "   " .. step.status .. (if step.exit then " (exit " .. step.exit .. ")" else "")
							else "",
						"muted"
					),
				},
				body,
				{
					key = "s" .. i,
					inset = true,
					tone = STEP_TONE[step.status],
					role = "tern-kube.gitops-step",
				}
			)
		)
	end
	table.insert(out, ui.col(cards, { key = "steps" }))
	if git.status == "ready" then
		local why = Gitops.gitBlocker(git)
		if why then
			table.insert(
				out,
				ui.text({ ui.span(why, "error") }, { key = "blocked", role = "tern-kube.gitops-blocked" })
			)
		end
		table.insert(
			out,
			chips(v, {
				{
					string.format("Run %d commands (enter)", #steps),
					"gitops-key=enter",
					if why then "neutral" else "warning",
					"Runs the commands above in order; stops at the first failure",
				},
				{ "Edit branch (b)", "field-focus=branch" },
				{ "Edit message (e)", "field-focus=message" },
			}, "gc")
		)
	elseif git.status == "running" then
		table.insert(out, ui.muted("Running …", { key = "status" }))
	elseif git.status == "done" then
		table.insert(
			out,
			ui.text({ ui.span("Done: committed on " .. git.branch, "success strong") }, {
				key = "status",
				role = "tern-kube.gitops-done",
			})
		)
	elseif git.status == "error" then
		table.insert(
			out,
			ui.text({ ui.span(git.error or "failed", "error") }, { key = "status", role = "tern-kube.error" })
		)
	end
	return out
end

-- Entry points ---------------------------------------------------------------

function M.body(v: Ctx): { Node }
	local kind = v.route.kind
	if kind == "manifest" then
		return manifestBody(v)
	elseif kind == "diff" then
		return diffBody(v)
	elseif kind == "drift" then
		return driftBody(v)
	elseif kind == "matrix" then
		return matrixBody(v)
	elseif kind == "export" then
		return exportBody(v)
	end
	return gitBody(v)
end

-- Text inputs of the export / git routes (direct children of the block's
-- main column, like the filter, so focus events carry `main.<key>`).
-- `input` is the caret and history of the field being edited.
function M.inputs(g: Gitops.G, route: Route, editing: string?, input: Textfield.Field?): { Node }
	local fields: { { string } } = {}
	if route.kind == "export" and g.export then
		fields = { { "dir", "directory ", "t edits the target directory" } }
	elseif route.kind == "git" and g.git and (g.git :: Gitops.GitState).status == "ready" then
		fields = {
			{ "branch", "branch ", "b edits the branch name" },
			{ "message", "message ", "e edits the commit message" },
		}
	end
	local out: { Node } = {}
	for _, f in fields do
		local text = Gitops.fieldValue(g, f[1])
		table.insert(out, {
			k = "input",
			p = {
				key = "gitops-" .. f[1],
				text = text,
				cursor = Textfield.caretFor(if editing == f[1] then input else nil, text),
				placeholder = f[3],
				prompt = f[2],
				class = if editing == f[1] then "tk-editing" else nil,
			},
		})
	end
	return out
end

function M.crumb(g: Gitops.G, route: Route): string
	local kind = route.kind
	local ref = route.ref
	if kind == "manifest" then
		return "Manifest " .. (if ref then string.lower(ref.kind) .. "/" .. ref.name else "")
	elseif kind == "diff" then
		return "Diff vs manifest " .. (if ref then string.lower(ref.kind) .. "/" .. ref.name else "")
	elseif kind == "drift" then
		if route.source == nil then
			return "Drift sources"
		end
		local at = if route.context then " @ " .. route.context else ""
		if route.item then
			return "Drift " .. (string.match(route.item :: string, "/([^/]+)$") or route.item :: string) .. at
		end
		return "Drift " .. sourceLabel(g, route.source :: string) .. at
	elseif kind == "matrix" then
		local label = sourceLabel(g, route.source or "")
		return if route.across then "Across contexts " .. label else "Contexts for " .. label
	elseif kind == "export" then
		return "Export"
	end
	return "Git"
end

M.HINTS = {
	manifest = "j/k move · m open at line · = diff · E export · r rescan · esc back",
	diff = "m open manifest · a apply · [ ] other manifests · r diff again · esc back",
	["diff-none"] = "E export · r diff again · esc back",
	["diff-helm"] = "H helm release · r diff again · esc back",
	drift = "j/k move · enter open · r rescan · esc back",
	["drift-report"] = "enter details · f filter · m manifest · a apply · A apply source · E export · X export all · ctrl+d delete unmanaged · Y copy CLI · x across contexts · r again",
	["drift-report-helm"] = "enter details · f filter · m manifest · a apply · A apply source · E export unmanaged · X all unmanaged · ctrl+d delete unmanaged · Y copy CLI · x across contexts · r again",
	["drift-item"] = "m open manifest · a apply · E export · ctrl+d delete (unmanaged) · Y copy CLI · x across contexts · esc back",
	["drift-changed"] = "m open manifest · a apply · E export · Y copy CLI · x across contexts · esc back",
	["drift-chart"] = "m open manifest · a apply · Y copy CLI · x across contexts · esc back",
	["drift-unmanaged"] = "E export · ctrl+d delete · Y copy CLI · x across contexts · esc back",
	["drift-other"] = "m open manifest · read-only: c switches context · Y copy CLI · x across contexts · esc back",
	["matrix-pick"] = "j/k move · enter choose · esc back",
	matrix = "enter open cell · [ ] context · f filter · x contexts · Y copy commands · r again · esc back",
	export = "j/k move · enter diff · t directory · w write · b branch & commit · r read again · esc back",
	git = "b branch · e message · p push · P pull request · o only exported files · enter run · esc back",
}

-- The drift item's keys follow its bucket (and a Helm source: its chart
-- objects are not exported); without the state the generic line is used.
local function itemHint(load: Gitops.DriftLoad?, key: string): string
	local e = if load then Gitops.entry(load, key) else nil
	if load == nil or e == nil then
		return M.HINTS["drift-item"]
	elseif e.bucket == "unmanaged" then
		return M.HINTS["drift-unmanaged"]
	elseif e.bucket == "changed" and load.source.type ~= "helm" then
		return M.HINTS["drift-changed"]
	end
	return M.HINTS["drift-chart"]
end

function M.hint(route: Route, g: Gitops.G?, gctx: Gitops.Ctx?): string
	local load = if g and gctx then Gitops.driftLoad(g, gctx, route) else nil
	if route.kind == "drift" then
		if route.item then
			return if route.context then M.HINTS["drift-other"] else itemHint(load, route.item)
		elseif route.source then
			local helm = load ~= nil and load.source.type == "helm"
			return M.HINTS[if helm then "drift-report-helm" else "drift-report"]
		end
	elseif route.kind == "diff" and g and route.ref then
		local diff = g.diffs[Gitops.diffId(route)]
		if diff and diff.status == "nomatch" then
			return if diff.helm then M.HINTS["diff-helm"] else M.HINTS["diff-none"]
		end
	elseif route.kind == "matrix" and route.across == nil then
		return M.HINTS["matrix-pick"]
	end
	return M.HINTS[route.kind] or "? help"
end

return M
