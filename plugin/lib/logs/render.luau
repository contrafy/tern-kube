--!strict
-- The logs lens view (plan 4.4): a header with counts and kubectl's own
-- notices, pointer-only chips (levels, sources, jumps, wrap, time, merge,
-- actions), a records grid with an inline inspector, pages with the newest
-- shown first, and the small context view a jump renders (a lens cannot
-- scroll its pane, so a jump shows only the lines around the target).
-- nil = raw (plan 4.6 and the running policy).
local Grid = require("../render/grid")
local Header = require("../render/header")
local ModelTypes = require("../model/types")
local Parse = require("./parse")
local Query = require("./query")
local Store = require("./store")
local T = require("./types")
local Viewstate = require("./viewstate")
local ui = require("../ui")

type Level = T.Level
type Record = T.Record
type Store = Store.Store
type LogsView = Viewstate.LogsView
type Node = ui.Node

export type Variant = { label: string, url: string, title: string }
-- follow/variants: tern-kube://act/ links (Quick.encode); explore/search:
-- tern-kube://explore links the host opens on `explore-logs=open|search`;
-- otherContainers: the containers are unknown here (`-c` given, no
-- `Defaulted container` line), so a chip sends the user to Explore logs.
export type Links = {
	follow: string?,
	explore: string?,
	search: string?,
	variants: { Variant },
	otherContainers: boolean?,
}
export type Options = { pageSize: number, running: boolean, streamingView: "raw" | "native" }

local M = {}

M.CELL_CAP = 1000
M.INSPECT_CAP = 64 * 1024
M.CONTEXT_RADIUS = 20
M.MAX_VARIANTS = 6
M.TRAILS = "live view trails the stream by about 6 lines; Raw is live"
M.UNATTRIBUTED = "Lines of several pods or containers interleave without --prefix and cannot be told apart"

type LevelChip = { label: string, levels: { Level } }

local LEVEL_CHIPS: { LevelChip } = {
	{ label = "Errors", levels = { "fatal" :: Level, "error" :: Level } },
	{ label = "Warnings", levels = { "warn" :: Level } },
	{ label = "Info", levels = { "info" :: Level } },
	{ label = "Debug", levels = { "debug" :: Level, "trace" :: Level } },
	{ label = "Other", levels = { "none" :: Level } },
}

local LEVEL_TONE: { [Level]: string } = {
	fatal = "error",
	error = "error",
	warn = "warning",
	info = "info",
	debug = "neutral",
	trace = "neutral",
}

local ROW_CLASS: { [Level]: string } = { fatal = "tk-lvl-error", error = "tk-lvl-error", warn = "tk-lvl-warn" }

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function chip(label: string, action: string?, active: boolean, title: string?, key: string?): Node
	local props: { [string]: any } = {
		key = key,
		title = title,
		role = if active then "tern-kube.chip-on" else "tern-kube.chip",
	}
	if action then
		props.actions = { click = action }
	end
	return ui.badge(label, if active then "accent" else "neutral", props)
end

local function with(vs: LogsView, patch: (LogsView) -> ()): string
	local copy = table.clone(vs)
	copy.levels = table.clone(vs.levels)
	copy.sources = table.clone(vs.sources)
	patch(copy)
	return Viewstate.action(copy)
end

-- Raw rules (plan 4.6, minus native_default which the host checks) and the
-- running policy: a following command stays raw unless the user opted in.
function M.showsRaw(store: Store, opts: Options): boolean
	if opts.running and store.opts.follow and opts.streamingView ~= "native" then
		return true
	end
	if Store.size(store) > 0 then
		return false
	end
	if opts.running or (store.status ~= nil and store.status ~= 0) then
		return true
	end
	-- kubectl's own error alone (`logs -p` after the kubelet removed the
	-- previous log exits 0) is what the terminal already shows.
	for _, n in store.notices do
		if n.kind == "error" then
			return true
		end
	end
	return #store.notices == 0
end

-- Sources that own at least one record, 0 (unattributed) included.
local function liveSources(store: Store): { number }
	local out: { number } = {}
	if (store.sourceCounts[0] or 0) > 0 then
		table.insert(out, 0)
	end
	for i = 1, #store.sources do
		if (store.sourceCounts[i] or 0) > 0 then
			table.insert(out, i)
		end
	end
	return out
end

type Shape = { pods: number, containers: number }

local function shape(store: Store): Shape
	local pods: { [string]: boolean } = {}
	local containers: { [string]: boolean } = {}
	local np, nc = 0, 0
	for _, src in store.sources do
		if src.pod and not pods[src.pod] then
			pods[src.pod] = true
			np += 1
		end
		if src.container and not containers[src.container] then
			containers[src.container] = true
			nc += 1
		end
	end
	return { pods = np, containers = nc }
end

-- The pod-name prefix all distinct pods share, cut after a `-` so each
-- label keeps a whole segment (`web-65d7d99975-` of two ReplicaSet pods);
-- "" for fewer than two pods or nothing in common.
function M.commonPodPrefix(pods: { string }): string
	local first: string? = nil
	local common: string? = nil
	for _, pod in pods do
		if first == nil then
			first = pod
			common = pod
		elseif pod ~= first then
			local c = common :: string
			local n = 0
			while n < #c and n < #pod and string.byte(c, n + 1) == string.byte(pod, n + 1) do
				n += 1
			end
			common = string.sub(c, 1, n)
		end
	end
	if common == nil or common == first then
		return ""
	end
	return string.match(common, "^(.*%-)") or ""
end

-- Display label of every source, computed once per render: the container
-- for one pod, the pod for one container, else both; pod names lose the
-- prefix every pod shares (stern style).
function M.sourceLabels(store: Store): { [number]: string }
	local s = shape(store)
	local pods: { string } = {}
	for _, src in store.sources do
		if src.pod then
			table.insert(pods, src.pod)
		end
	end
	local prefix = if s.pods > 1 then M.commonPodPrefix(pods) else ""
	local out: { [number]: string } = { [0] = "unattributed" }
	for i, src in store.sources do
		local pod = if src.pod then string.sub(src.pod, #prefix + 1) else nil
		if s.pods <= 1 then
			out[i] = src.container or src.pod or "?"
		elseif s.containers <= 1 then
			out[i] = pod or src.container or "?"
		else
			out[i] = (pod or "?") .. "·" .. (src.container or "?")
		end
	end
	return out
end

function M.sourceLabel(store: Store, index: number): string
	return M.sourceLabels(store)[index] or "unattributed"
end

local function sourceTitle(store: Store, index: number): string
	local src = store.sources[index]
	if src == nil then
		return "Lines kubectl printed without a pod/container prefix"
	end
	local parts: { string } = {}
	if src.pod then
		table.insert(parts, "pod/" .. src.pod)
	end
	if src.container then
		table.insert(parts, "container " .. src.container)
	end
	return table.concat(parts, " ")
end

-- HH:MM:SS.mmm of a kubelet or payload time; nil when it has no clock.
function M.clock(text: string?): string?
	if text == nil then
		return nil
	end
	local hms, frac = string.match(text, "(%d%d:%d%d:%d%d)[%.,]?(%d*)")
	if hms == nil then
		return nil
	end
	if frac and frac ~= "" then
		return hms .. "." .. string.sub(frac .. "000", 1, 3)
	end
	return hms
end

local function dateOf(r: Record): string?
	return string.match(r.ts or r.appTime or "", "^(%d%d%d%d%-%d%d%-%d%d)")
end

local function hasTime(store: Store): boolean
	if store.opts.timestamps then
		return true
	end
	for i = store.first, store.last do
		local r = store.records[i]
		if r.appTime and M.clock(r.appTime) then
			return true
		end
	end
	return false
end

local function capped(text: string, cap: number): string
	if #text <= cap then
		return text
	end
	return string.sub(text, 1, cap) .. "…"
end

-- Message, klog location and the first fields (muted), within CELL_CAP.
function M.messageSpans(r: Record): { ui.Span }
	local spans: { ui.Span } = { { t = capped(r.message, M.CELL_CAP) } }
	local budget = M.CELL_CAP - #r.message
	if r.location then
		table.insert(spans, { t = "  " .. r.location, s = "muted" })
	end
	if r.fields then
		for _, f in r.fields do
			local text = " " .. f.key .. "=" .. f.value
			if #text > budget then
				break
			end
			budget -= #text
			table.insert(spans, { t = text, s = "muted" })
		end
	end
	local extra = (if r.extra then #r.extra else 0) + (r.more or 0)
	if extra > 0 then
		table.insert(spans, { t = "  +" .. plural(extra, "line"), s = "accent" })
	end
	return spans
end

-- Payload of a record: the delivered line without --prefix and --timestamps.
local function payload(store: Store, r: Record): string
	local rest = r.raw
	if store.opts.prefix then
		local _, _, after = Parse.splitPrefix(rest)
		rest = after
	end
	if store.opts.timestamps then
		local _, after = Parse.splitTimestamp(rest)
		rest = after
	end
	return rest
end

local function withExtra(first: string, r: Record): string
	if r.extra == nil then
		return first
	end
	return first .. "\n" .. table.concat(r.extra, "\n")
end

-- Clipboard text of a record: "line" is what kubectl printed (prefix and
-- time included, continuation lines too), "msg" the message, "json" the
-- JSON payload (JSON records only).
function M.copyText(store: Store, index: number, what: "line" | "msg" | "json"): string?
	local r = Store.get(store, index)
	if r == nil then
		return nil
	end
	if what == "line" then
		return withExtra(r.raw, r)
	elseif what == "msg" then
		return withExtra(r.message, r)
	elseif r.format == "json" then
		return payload(store, r)
	end
	return nil
end

-- The pod a record came from, when kubectl or the command names it.
function M.podOf(store: Store, index: number): string?
	local r = Store.get(store, index)
	if r == nil then
		return nil
	end
	local src = store.sources[r.source]
	return if src then src.pod else store.opts.pod
end

local HELP: { { string } } = {
	{ "Level and source chips", "Keep those lines; chips in one group widen, groups narrow" },
	{ "Click a line", "Open it: time, source, fields, the whole message and stack, copy chips" },
	{ "First error", "Shows the lines around the first error; Prev/Next error step through them" },
	{ "Wrap / Time / By time", "Wrap long lines; show the time column; merge sources by kubelet time" },
	{ "Pages", "The newest page is shown; earlier pages are one click away" },
	{ "Follow in split", "kubectl logs -f in a new split (raw, live)" },
	{ "Run in split", "A variant of this command typed into a new split, where it gets this view" },
	{ "Open in Explore / Search…", "The Explore logs view of the same source, with a text filter" },
	{ "Raw", "The block's Raw toggle shows the exact output" },
}

local function helpNode(): Node
	local items: { { { ui.SpanLike } } } = table.create(#HELP)
	for i, pair in HELP do
		items[i] = { { ui.span(pair[1], "strong") }, { pair[2] } }
	end
	return ui.card({ "Tern Kube logs" }, { ui.kv(items) }, { key = "help", role = "tern-kube.help" })
end

local NOTICE_TONE: { [string]: string } = {
	["found-pods"] = "muted",
	["defaulted-container"] = "muted",
	error = "error",
	warning = "warning",
	dropped = "warning",
}

function M.countsText(store: Store): string
	local c = store.counts
	local total = 0
	for _, n in c do
		total += n
	end
	local parts = { plural(total, "line") }
	local function n(l: Level): number
		return c[l] or 0
	end
	local errors = n("error") + n("fatal")
	if errors > 0 then
		table.insert(parts, plural(errors, "error"))
	end
	if n("warn") > 0 then
		table.insert(parts, plural(n("warn"), "warning"))
	end
	local s = shape(store)
	if s.pods > 1 then
		table.insert(parts, plural(s.pods, "pod"))
	end
	if s.containers > 1 then
		table.insert(parts, plural(s.containers, "container"))
	end
	return table.concat(parts, " · ")
end

local function headerNode(store: Store, inv: ModelTypes.Invocation, vs: LogsView, opts: Options): Node
	local top: { Node } = {
		if opts.running
			then ui.badge("Live", "accent", { title = "The command is still running" })
			else ui.badge("Snapshot", "muted", { title = "Captured output of this command; not live" }),
		ui.text({ ui.span(Header.commandSummary(inv), "mono strong") }),
		ui.text(Header.target(inv)),
		ui.text({ ui.span(M.countsText(store), "muted") }, { role = "tern-kube.counts" }),
	}
	if store.stopped then
		table.insert(top, ui.badge("stopped (Ctrl-C)", "neutral", { role = "tern-kube.stopped" }))
	elseif store.status ~= nil and store.status ~= 0 then
		table.insert(top, ui.badge("exit " .. store.status, "error", { role = "tern-kube.exit" }))
	end
	table.insert(
		top,
		ui.badge(if vs.help then "? hide help" else "?", if vs.help then "accent" else "neutral", {
			key = "help-chip",
			title = "What you can do here",
			actions = {
				click = with(vs, function(v)
					v.help = not v.help
				end),
			},
		})
	)
	local children: { Node } = { ui.row(top, { key = "bar", wrap = true, role = "tern-kube.bar" }) }
	local notes: { Node } = {}
	for i, n in store.notices do
		local tone = NOTICE_TONE[n.kind]
		if tone then
			table.insert(notes, ui.text({ ui.span(n.text, tone) }, { key = "n" .. i }))
		end
	end
	if #notes > 0 then
		table.insert(children, ui.col(notes, { key = "notices", gap = "none", role = "tern-kube.notices" }))
	end
	if opts.running and store.opts.follow then
		table.insert(children, ui.text({ ui.span(M.TRAILS, "muted") }, { key = "trails", role = "tern-kube.note" }))
	end
	if not store.opts.prefix and (store.opts.multiPod or store.opts.allContainers) then
		table.insert(
			children,
			ui.text({ ui.span(M.UNATTRIBUTED, "muted") }, { key = "unattributed", role = "tern-kube.note" })
		)
	end
	if vs.help then
		table.insert(children, helpNode())
	end
	return ui.col(children, { key = "header", role = "tern-kube.header" })
end

local function levelSet(vs: LogsView): { [Level]: boolean }
	local set: { [Level]: boolean } = {}
	for _, l in vs.levels do
		set[l :: Level] = true
	end
	return set
end

local function levelChips(store: Store, vs: LogsView): Node?
	local on = levelSet(vs)
	local items: { Node } = {}
	for _, lc in LEVEL_CHIPS do
		local count = 0
		local active = true
		for _, l in lc.levels do
			count += store.counts[l :: Level] or 0
			active = active and on[l :: Level] == true
		end
		if count == 0 and not active then
			continue
		end
		local action = with(vs, function(v)
			local set = levelSet(v)
			for _, l in lc.levels do
				if active then
					set[l :: Level] = nil
				else
					set[l :: Level] = true
				end
			end
			local list: { Level } = {}
			for l in set do
				table.insert(list, l)
			end
			v.levels = list
			v.page = nil
			v.ctx = nil
		end)
		table.insert(items, chip(lc.label .. " " .. count, action, active, nil, "lvl-" .. lc.label))
	end
	if #items < 2 and #vs.levels == 0 then
		return nil
	end
	table.insert(items, 1, ui.text({ ui.span("LEVEL", "muted") }))
	return ui.row(items, { key = "levels", wrap = true })
end

local function sourceChips(store: Store, vs: LogsView, live: { number }): Node?
	if #live < 2 then
		return nil
	end
	local on: { [number]: boolean } = {}
	for _, s in vs.sources do
		on[s] = true
	end
	local items: { Node } = { ui.text({ ui.span("SOURCE", "muted") }) }
	local labels = M.sourceLabels(store)
	for _, idx in live do
		local active = on[idx] == true
		local action = with(vs, function(v)
			local list: { number } = {}
			for _, s in v.sources do
				if s ~= idx then
					table.insert(list, s)
				end
			end
			if not active then
				table.insert(list, idx)
			end
			v.sources = list
			v.page = nil
			v.ctx = nil
		end)
		table.insert(
			items,
			chip(
				(labels[idx] or "unattributed") .. " " .. (store.sourceCounts[idx] or 0),
				action,
				active,
				sourceTitle(store, idx),
				"src-" .. idx
			)
		)
	end
	return ui.row(items, { key = "sources", wrap = true })
end

local function viewChips(store: Store, vs: LogsView, live: { number }, timeShown: boolean, timeKnown: boolean): Node
	local items: { Node } = {}
	local fe = store.firstError
	if fe then
		table.insert(
			items,
			chip(
				"First error",
				with(vs, function(v)
					v.ctx = fe
					v.open = fe
				end),
				false,
				"The lines around the first error",
				"first-error"
			)
		)
	end
	table.insert(
		items,
		chip(
			"Wrap",
			with(vs, function(v)
				v.wrap = not v.wrap
			end),
			vs.wrap,
			"Wrap long lines",
			"wrap"
		)
	)
	if timeKnown then
		table.insert(
			items,
			chip(
				"Time",
				with(vs, function(v)
					v.time = not timeShown
				end),
				timeShown,
				"Show the time column",
				"time"
			)
		)
	end
	if #live > 1 or store.opts.multiPod then
		if store.opts.timestamps then
			table.insert(
				items,
				chip(
					"By time",
					with(vs, function(v)
						v.merge = not v.merge
						v.page = nil
					end),
					vs.merge,
					"Merge the sources by kubelet time (kubectl prints them pod by pod)",
					"merge"
				)
			)
		else
			table.insert(
				items,
				ui.badge("By time", "muted", {
					key = "merge",
					title = "Rerun with --timestamps to merge the sources by time",
					role = "tern-kube.chip-off",
				})
			)
		end
	end
	if #vs.levels > 0 or #vs.sources > 0 then
		table.insert(
			items,
			chip(
				"Clear filters",
				with(vs, function(v)
					v.levels = {}
					v.sources = {}
					v.page = nil
				end),
				false,
				nil,
				"clear"
			)
		)
	end
	return ui.row(items, { key = "view", wrap = true })
end

local function actionsNode(links: Links): Node?
	local items: { Node } = {}
	if links.follow then
		table.insert(
			items,
			ui.badge("Follow in split", "info", {
				key = "follow",
				title = "kubectl logs -f in a new split (raw, live)",
				actions = { click = "act=" .. links.follow },
				role = "tern-kube.quick",
			})
		)
	end
	if links.explore then
		table.insert(
			items,
			ui.badge("Open in Explore", "accent", {
				key = "explore",
				title = "The Explore logs view of the same source (runs kubectl)",
				actions = { click = "explore-logs=open" },
			})
		)
	end
	if links.search then
		table.insert(
			items,
			ui.badge("Search…", "accent", {
				key = "search",
				title = "Explore logs with the text filter focused",
				actions = { click = "explore-logs=search" },
			})
		)
	end
	local variants = 0
	local run: { Node } = {}
	for _, v in links.variants do
		if variants >= M.MAX_VARIANTS then
			break
		end
		variants += 1
		table.insert(
			run,
			ui.badge("▸ " .. v.label, "info", {
				key = "run-" .. variants,
				title = v.title,
				actions = { click = "act=" .. v.url },
				role = "tern-kube.quick",
			})
		)
	end
	if links.otherContainers and links.explore and variants < M.MAX_VARIANTS then
		table.insert(
			run,
			ui.badge("▸ other container…", "info", {
				key = "run-other",
				title = "This output does not name the pod's containers; Explore logs lists them",
				actions = { click = "explore-logs=open" },
			})
		)
	end
	if #run > 0 then
		table.insert(items, ui.text({ ui.span("Run in split", "muted") }, { key = "run" }))
		for _, n in run do
			table.insert(items, n)
		end
	end
	if #items == 0 then
		return nil
	end
	return ui.row(items, { key = "actions", wrap = true, role = "tern-kube.logs-actions" })
end

local function inspectorNode(store: Store, r: Record, vs: LogsView): Node
	local idx = r.index
	local items: { { { ui.SpanLike } } } = {}
	local function add(k: string, v: string?, style: string?)
		if v and v ~= "" then
			table.insert(items, { { ui.span(k, "muted") }, { ui.span(v, style) } })
		end
	end
	add("Line", tostring(idx), "mono")
	add("Kubelet time", r.ts, "mono")
	add("Time", r.appTime, "mono")
	if r.source ~= 0 or #store.sources > 0 then
		add("Source", sourceTitle(store, r.source))
	end
	add("Level", if r.level == "none" then nil else r.level)
	add("Format", r.format)
	add("Location", r.location, "mono")
	local children: { Node } = { ui.kv(items) }
	local body = withExtra(r.message, r)
	if r.more then
		body ..= "\n… " .. plural(r.more, "more line")
	end
	table.insert(children, ui.code(capped(body, M.INSPECT_CAP), nil, nil, { key = "msg" }))
	if r.fields and #r.fields > 0 then
		local kv: { { { ui.SpanLike } } } = table.create(#r.fields)
		for i, f in r.fields do
			kv[i] = { { ui.span(f.key, "muted") }, { ui.span(f.value, "mono") } }
		end
		table.insert(children, ui.section({ "Fields" }, { ui.kv(kv) }, { key = "fields" }))
	end
	local chips: { Node } = {
		ui.badge(
			"Copy line",
			"neutral",
			{ title = "The line as kubectl printed it", actions = { click = "copy-line=" .. idx } }
		),
		ui.badge("Copy message", "neutral", { actions = { click = "copy-msg=" .. idx } }),
	}
	if r.format == "json" then
		table.insert(chips, ui.badge("Copy JSON", "neutral", { actions = { click = "copy-json=" .. idx } }))
	end
	if vs.ctx ~= idx then
		table.insert(
			chips,
			chip(
				"Show in context",
				with(vs, function(v)
					v.ctx = idx
					v.open = idx
				end),
				false,
				"The lines around this one, unfiltered"
			)
		)
	end
	if M.podOf(store, idx) then
		table.insert(
			chips,
			ui.badge("Explore pod", "accent", {
				title = "Open the pod in the Explore block (may run kubectl)",
				actions = { click = "explore-pod=" .. idx },
			})
		)
	end
	table.insert(
		chips,
		chip(
			"Close",
			with(vs, function(v)
				v.open = nil
			end),
			false
		)
	)
	table.insert(children, ui.row(chips, { wrap = true }))
	return ui.col(children, { role = "tern-kube.inspector" })
end

local function gridNode(store: Store, indices: { number }, vs: LogsView, timeShown: boolean, showSource: boolean): Node
	local headers: { string } = {}
	if timeShown then
		table.insert(headers, "TIME")
	end
	if showSource then
		table.insert(headers, "SOURCE")
	end
	table.insert(headers, "LEVEL")
	table.insert(headers, "MESSAGE")
	local types: { ModelTypes.ColumnType } = table.create(#headers, "text" :: ModelTypes.ColumnType)
	local rows: { Grid.GridRow } = table.create(#indices)
	local prevDate: string? = nil
	local labels = if showSource then M.sourceLabels(store) else {}
	for n, i in indices do
		local r = store.records[i]
		local cells: { string } = {}
		local nodes: { [number]: Node } = {}
		local col = 0
		if timeShown then
			col += 1
			local t = M.clock(r.ts) or M.clock(r.appTime) or ""
			cells[col] = t
			nodes[col] = ui.text({ ui.span(t, "mono muted") })
		end
		if showSource then
			col += 1
			local label = labels[r.source] or "unattributed"
			cells[col] = label
			nodes[col] = Grid.middleNode(label, "muted")
		end
		col += 1
		local tone = LEVEL_TONE[r.level]
		cells[col] = if tone then string.upper(r.level) else ""
		nodes[col] = if tone then ui.badge(string.upper(r.level), tone) else ui.text({ "" })
		col += 1
		cells[col] = capped(r.message, M.CELL_CAP)
		nodes[col] = ui.text(M.messageSpans(r))
		local date = dateOf(r)
		local divider: string? = nil
		if date and prevDate and date ~= prevDate then
			divider = date
		end
		prevDate = date or prevDate
		local key = tostring(i)
		local open = vs.open == i
		rows[n] = {
			key = key,
			cells = cells,
			nodes = nodes,
			action = with(vs, function(v)
				v.open = if open then nil else i
			end),
			open = open,
			class = ROW_CLASS[r.level],
			divider = divider,
		}
	end
	return Grid.grid({
		key = "records",
		headers = headers,
		types = types,
		rows = rows,
		sortCol = nil,
		desc = false,
		sortAction = function(_col: string): string
			return ""
		end,
		sortable = false,
		class = if vs.wrap then "tk-logs tk-lwrap" else "tk-logs",
		keep = { LEVEL = true, MESSAGE = true },
		middle = { SOURCE = true },
		inspector = function(rowKey: string): Node?
			local r = Store.get(store, tonumber(rowKey) or 0)
			return if r then inspectorNode(store, r, vs) else nil
		end,
	})
end

local function pageChips(window: Query.Window, vs: LogsView, size: number): Node
	local p, pages = window.page, window.pages
	local from = (p - 1) * size + 1
	local to = math.min(window.matched, p * size)
	local items: { Node } = {
		ui.text({ ui.span(string.format("Lines %d-%d of %d", from, to, window.matched), "muted") }),
	}
	local last = 0
	for n = 1, pages do
		if n == 1 or n == pages or math.abs(n - p) <= 2 then
			if last > 0 and n > last + 1 then
				table.insert(items, ui.text({ ui.span("…", "muted") }))
			end
			last = n
			table.insert(
				items,
				chip(
					tostring(n),
					with(vs, function(v)
						v.page = if n == pages then nil else n
						v.open = nil
					end),
					n == p,
					nil,
					"page" .. n
				)
			)
		end
	end
	return ui.row(items, { key = "pages", wrap = true, role = "tern-kube.pages" })
end

local NO_FILTER: Query.Filter = { levels = nil, minLevel = nil, sources = nil, text = nil, merge = false }

local function contextNav(store: Store, ctx: number, vs: LogsView): Node
	local items: { Node } = {
		ui.text({ ui.span("Around line " .. ctx, "muted") }),
	}
	local prev = Query.next(store, NO_FILTER, ctx, -1, "error")
	local nxt = Query.next(store, NO_FILTER, ctx, 1, "error")
	local function jump(label: string, target: number?, key: string)
		if target then
			table.insert(
				items,
				chip(
					label,
					with(vs, function(v)
						v.ctx = target
						v.open = target
					end),
					false,
					nil,
					key
				)
			)
		end
	end
	jump("◂ Prev error", prev, "prev-error")
	jump("Next error ▸", nxt, "next-error")
	table.insert(
		items,
		chip(
			"All lines",
			with(vs, function(v)
				v.ctx = nil
				v.open = nil
			end),
			false,
			"Back to the pages",
			"all-lines"
		)
	)
	return ui.row(items, { key = "context", wrap = true, role = "tern-kube.context" })
end

function M.render(store: Store, inv: ModelTypes.Invocation, vs: LogsView, links: Links, opts: Options): Node?
	if M.showsRaw(store, opts) then
		return nil
	end
	local live = liveSources(store)
	local timeKnown = hasTime(store)
	local timeShown = if vs.time == nil then timeKnown else vs.time
	local children: { Node } = { headerNode(store, inv, vs, opts) }
	local chips: { Node } = {}
	local levels = levelChips(store, vs)
	if levels then
		table.insert(chips, levels)
	end
	local sources = sourceChips(store, vs, live)
	if sources then
		table.insert(chips, sources)
	end
	table.insert(chips, viewChips(store, vs, live, timeShown, timeKnown))
	table.insert(children, ui.col(chips, { key = "chips", role = "tern-kube.chips" }))
	local actions = actionsNode(links)
	if actions then
		table.insert(children, actions)
	end
	local showSource = #live > 1
	local ctx = vs.ctx
	if ctx and Store.get(store, ctx) then
		local window = Query.context(store, ctx, M.CONTEXT_RADIUS)
		table.insert(children, contextNav(store, ctx, vs))
		table.insert(children, gridNode(store, window.indices, vs, timeShown, showSource))
	else
		local size = math.max(1, opts.pageSize)
		local window = Query.apply(store, Viewstate.filterOf(vs), vs.page, size)
		if window.pages > 1 then
			table.insert(children, pageChips(window, vs, size))
		end
		if window.matched == 0 then
			table.insert(children, ui.text({ ui.span("No lines match the filters", "muted") }, { key = "nomatch" }))
		else
			table.insert(children, gridNode(store, window.indices, vs, timeShown, showSource))
		end
	end
	return ui.col(children, { key = "lens", role = "tern-kube.logs" })
end

return M
