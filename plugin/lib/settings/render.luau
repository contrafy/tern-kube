--!strict
-- View of the Kube Lens Settings block (pure). Two pages: the settings
-- editor (every config key, keyboard selection, inline edit input) and the
-- status page (config file, versions, kubectl, alias claims, shell guard,
-- safety tiers, supported operations).

local State = require("./state")
local ui = require("../ui")

type State = State.State
type Field = State.Field
type Node = ui.Node

export type View = { main: Node, dock: Node?, layer: Node? }

local M = {}

local LOAD_TEXT: { [string]: { string } } = {
	loaded = { "loaded", "success" },
	missing = { "no file: defaults", "neutral" },
	unreadable = { "unreadable: defaults", "error" },
	nopath = { "no path: defaults", "error" },
	resolving = { "resolving symlink", "warning" },
}

local function chip(text: string, action: string, props: { [string]: any }?): Node
	local p: { [string]: any } = { actions = { click = action }, role = "kube-lens.chip" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return ui.badge(text, p.tone or "neutral", p)
end

local function problems(s: State): (number, number)
	local errors, warnings = 0, 0
	for _, d in s.diagnostics do
		if d.level == "error" then
			errors += 1
		elseif d.level == "warning" then
			warnings += 1
		end
	end
	return errors, warnings
end

local function header(s: State): Node
	local load = LOAD_TEXT[s.info.loadStatus] or { s.info.loadStatus, "neutral" }
	if s.fileError then
		load = { "invalid: defaults", "error" }
	end
	local errors, warnings = problems(s)
	local bar: { Node } = {
		ui.text({ ui.span("Kube Lens Settings", "strong") }),
		chip("Settings", "page=settings", {
			key = "p-settings",
			tone = if s.page == "settings" then "accent" else "neutral",
			title = "Edit the config file (tab)",
		}),
		chip("Status", "page=status", {
			key = "p-status",
			tone = if s.page == "status" then "accent" else "neutral",
			title = "Versions, kubectl, aliases, shell guard, safety (tab)",
		}),
		ui.badge(load[1], load[2], { key = "load", role = "kube-lens.settings-load" }),
	}
	if errors > 0 then
		table.insert(bar, ui.badge(errors .. (if errors == 1 then " error" else " errors"), "error", { key = "errs" }))
	end
	if warnings > 0 then
		table.insert(
			bar,
			ui.badge(warnings .. (if warnings == 1 then " warning" else " warnings"), "warning", { key = "warns" })
		)
	end
	table.insert(bar, chip("Open config file", "open", { key = "open", title = "Open it in Tern (o)" }))
	table.insert(bar, chip("Reload", "reload", { key = "reload", title = "Re-read the file and status (R)" }))
	table.insert(bar, chip("?", "help", { key = "help", title = "Keys and actions (?)" }))
	local children: { Node } = {
		ui.row(bar, { key = "bar", wrap = true, role = "kube-lens.bar" }),
		ui.text({
			ui.span("config ", "muted"),
			ui.span(s.path or "(unknown: no XDG_CONFIG_HOME or HOME)", "mono"),
			ui.span(if s.target and s.target ~= s.path then "  → " .. s.target else "", "muted mono"),
		}, { key = "path", role = "kube-lens.settings-path" }),
	}
	return ui.col(children, { key = "header", role = "kube-lens.settings-header" })
end

local MESSAGE_STYLE = { info = "muted", success = "success", error = "error" }

local function messageNode(s: State): Node?
	local m = s.message
	if m == nil then
		return nil
	end
	return ui.text({ ui.span(m.text, MESSAGE_STYLE[m.level] or "muted") }, {
		key = "message",
		role = "kube-lens.settings-message",
	})
end

-- Settings page ---------------------------------------------------------------

local function hintFor(f: Field): string
	if f.kind == "bool" then
		return "true or false · enter/space toggles"
	elseif f.kind == "enum" then
		return table.concat(f.values or {}, " | ") .. " · enter/space cycles"
	elseif f.kind == "int" then
		return string.format("integer %d-%d · e edits", f.min or 0, f.max or 0)
	elseif f.kind == "list" then
		return 'JSON list ["a", "b"]' .. (if f.optional then ", empty unsets" else "") .. " · e edits"
	elseif f.kind == "json" then
		return "JSON list of objects · e edits"
	end
	return (if f.optional then "text, empty unsets" else "text") .. " · e edits"
end

local function editInput(s: State): Node
	local f = State.selected(s)
	local editing = s.editing
	local text = if editing then editing.text else State.editText(s, f)
	return {
		k = "input",
		p = {
			key = "edit",
			text = text,
			cursor = #text,
			prompt = f.path .. " = ",
			placeholder = if f.optional then "unset" else hintFor(f),
			class = if editing then "kl-editing" else nil,
		},
	}
end

local ORIGIN: { [string]: { string } } = {
	default = { "default", "neutral" },
	file = { "set", "accent" },
	invalid = { "invalid", "error" },
}

local function fieldRow(s: State, i: number, f: Field): Node
	local selected = i == s.sel
	local origin = State.origin(s, f)
	local o = ORIGIN[origin]
	local value = State.display(s, f)
	if #value > 80 then
		value = string.sub(value, 1, 77) .. "..."
	end
	local controls: { Node } = {}
	if f.kind == "bool" then
		local on = State.configValue(s.config, f) == true
		table.insert(
			controls,
			chip(if on then "on" else "off", "toggle=" .. f.path, {
				key = "t",
				tone = if on then "success" else "neutral",
				title = "Toggle (enter/space)",
			})
		)
	elseif f.kind == "enum" then
		table.insert(controls, chip("Cycle", "toggle=" .. f.path, { key = "t", title = "Next value (enter/space)" }))
	else
		table.insert(controls, chip("Edit", "edit=" .. f.path, { key = "t", title = "Edit (e)" }))
	end
	if origin ~= "default" then
		table.insert(controls, chip("Reset", "reset=" .. f.path, { key = "r", title = "Reset to default (r)" }))
	end
	local cells: { Node } = {
		ui.el("div", { class = "kl-set-c kl-set-key" }, { ui.text({ ui.span(f.key, "mono") }) }),
		ui.el("div", { class = "kl-set-c kl-set-val", title = value }, {
			ui.text({ ui.span(value, if origin == "invalid" then "error mono" else "mono") }),
		}),
		ui.el("div", { class = "kl-set-c" }, { ui.badge(o[1], o[2]) }),
		ui.el("div", { class = "kl-set-c kl-set-ctl" }, { ui.row(controls, { key = "ctl" }) }),
	}
	return ui.el("div", {
		key = f.path,
		class = if selected then "kl-set-r kl-set-sel" else "kl-set-r",
		actions = { click = "sel=" .. f.path },
	}, cells)
end

local function sectionRow(name: string): Node
	return ui.el("div", { key = "s-" .. name, class = "kl-set-sec", text = name })
end

-- The visible slice of the field list: `size` fields around the selection.
function M.window(sel: number, total: number, size: number): (number, number)
	if total <= size then
		return 1, total
	end
	local first = math.clamp(sel - math.floor(size / 2), 1, total - size + 1)
	return first, first + size - 1
end

local function settingsPage(s: State, rows: number): { Node }
	local out: { Node } = {}
	table.insert(out, editInput(s))
	local f = State.selected(s)
	local docSpans: { ui.SpanLike } = { ui.span(f.doc, "muted"), ui.span("   " .. hintFor(f), "muted mono") }
	table.insert(out, ui.text(docSpans, { key = "doc", role = "kube-lens.settings-doc" }))
	for _, d in State.diagnosticsFor(s.diagnostics, f.path) do
		table.insert(out, ui.text({ ui.span(d.message, "error") }, { key = "fdiag" }))
	end
	local total = #State.FIELDS
	local first, last = M.window(s.sel, total, State.viewport(rows))
	local children: { Node } = {}
	if first > 1 then
		table.insert(
			children,
			ui.el("div", { key = "above", class = "kl-set-more", text = "… " .. (first - 1) .. " above" })
		)
	end
	local section: string? = nil
	for i = first, last do
		local field = State.FIELDS[i]
		local name = field.section or "top level"
		if name ~= section then
			section = name
			table.insert(children, sectionRow(name))
		end
		table.insert(children, fieldRow(s, i, field))
	end
	if last < total then
		table.insert(
			children,
			ui.el("div", { key = "below", class = "kl-set-more", text = "… " .. (total - last) .. " below" })
		)
	end
	table.insert(
		out,
		ui.el("div", { key = "fields", class = "kl-set-grid", role = "kube-lens.settings-fields" }, children)
	)
	return out
end

-- Status page -------------------------------------------------------------------

local function kubectlText(s: State): { ui.SpanLike }
	local k = s.info.kubectl
	if k == nil then
		return { ui.span("checking …", "muted") }
	end
	local out: { ui.SpanLike } = { ui.span(k.program, "mono"), ui.span("  from " .. k.source, "muted") }
	if k.pending then
		table.insert(out, ui.span("  · resolving …", "muted"))
	elseif k.error then
		table.insert(out, ui.span("  · " .. k.error, "error"))
	else
		if k.resolved and k.resolved ~= k.program then
			table.insert(out, ui.span("  → " .. k.resolved, "mono"))
		end
		if k.version then
			table.insert(out, ui.span("  " .. k.version, "muted"))
		end
	end
	return out
end

local function aliasText(s: State): { ui.SpanLike }
	local info = s.info
	if info.aliasError then
		return { ui.span(info.aliasError, "error") }
	end
	local claims = info.aliasClaims
	if claims == nil then
		return { ui.span("checking …", "muted") }
	end
	local names = State.aliasNames(claims)
	local out: { ui.SpanLike } = {}
	if #names == 0 then
		table.insert(out, ui.span("none (kubectl and kubecolor only)", "muted"))
	else
		table.insert(out, ui.span(table.concat(names, ", "), "mono"))
		table.insert(out, ui.span(string.format("  (%d globs)", #claims), "muted"))
	end
	local missing: { string } = {}
	for _, name in s.config.aliases.additional do
		if not table.find(names, name) then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		table.insert(
			out,
			ui.span(
				"  · configured but not claimed: "
					.. table.concat(missing, ", ")
					.. " (scripts/kube-lens-aliases add NAME)",
				"warning"
			)
		)
	end
	return out
end

local function guardText(s: State): { ui.SpanLike }
	local info = s.info
	local out: { ui.SpanLike } = {
		ui.span("new panes get KUBE_LENS_SPOOL=", "muted"),
		ui.span(info.spool or "?", "mono"),
	}
	return out
end

local function recordsText(s: State): { ui.SpanLike }
	local records = s.info.paneRecords
	if #records == 0 then
		return { ui.span("none (no shell snippet has recorded KUBECONFIG)", "muted") }
	end
	local parts: { string } = {}
	local live = 0
	for _, r in records do
		if r.live then
			live += 1
		end
		table.insert(
			parts,
			string.format("pane %d%s: %s", r.pane, if r.live then "" else " (closed)", r.kubeconfig or r.problem or "?")
		)
	end
	return {
		ui.span(string.format("%d recorded, %d live  ", #records, live), "muted"),
		ui.span(table.concat(parts, " · "), "mono"),
	}
end

local function statusPage(s: State): { Node }
	local info = s.info
	local errors, warnings = problems(s)
	local items: { { { ui.SpanLike } } } = {
		{ { "Config file" }, { ui.span(s.path or "unknown", "mono") } },
		{
			{ "Load status" },
			{
				ui.span((LOAD_TEXT[info.loadStatus] or { info.loadStatus })[1]),
				ui.span(string.format("  %d errors, %d warnings", errors, warnings), "muted"),
			},
		},
		{
			{ "Plugin" },
			{
				ui.span("kube-lens " .. (info.pluginVersion or "?"), "mono"),
				ui.span("  " .. (info.pluginDir or ""), "muted mono"),
			},
		},
		{
			{ "Tern" },
			{
				if info.ternPending
					then ui.span("checking …", "muted")
					else ui.span(
						info.ternVersion or "unknown (`tern` is not on the daemon's PATH)",
						if info.ternVersion then "mono" else "muted"
					),
			},
		},
		{ { "kubectl" }, kubectlText(s) },
		{ { "Alias claims" }, aliasText(s) },
		{ { "Shell guard" }, guardText(s) },
		{ { "Pane env records" }, recordsText(s) },
		{
			{ "Guard wanted" },
			{
				ui.span(tostring(s.config.mutations.interactive_guard), "mono"),
				ui.span("  (mutations.interactive_guard)", "muted"),
			},
		},
	}
	local out: { Node } = {
		ui.section(
			{ ui.span("Status", "strong") },
			{ ui.kv(items) },
			{ key = "status", role = "kube-lens.settings-status" }
		),
		ui.text({
			ui.span("Whether the guard is active in a shell cannot be seen from the plugin: run ", "muted"),
			ui.span("kube-lens-guard-status", "mono"),
			ui.span(" in that pane (setup: shell/README.md).", "muted"),
		}, { key = "guard-note" }),
	}
	if #s.diagnostics > 0 or s.fileError then
		local lines: { Node } = {}
		if s.fileError then
			table.insert(lines, ui.text({ ui.span(s.fileError, "error") }, { key = "ferr" }))
		end
		for i, d in s.diagnostics do
			local style = if d.level == "error" then "error" elseif d.level == "warning" then "warning" else "muted"
			table.insert(lines, ui.text({ ui.span(d.level .. "  ", style), ui.span(d.message) }, { key = "d" .. i }))
		end
		table.insert(
			out,
			ui.section(
				{ ui.span("Diagnostics", "strong") },
				lines,
				{ key = "diags", role = "kube-lens.settings-diags" }
			)
		)
	end
	local tiers: { { { ui.SpanLike } } } = {}
	for _, t in State.TIERS do
		table.insert(tiers, { { ui.span(t.tier, "strong") }, { ui.span(t.text) } })
	end
	table.insert(
		out,
		ui.section({ ui.span("Confirmation tiers", "strong") }, {
			ui.kv(tiers),
			ui.muted(
				if s.config.mutations.enabled
					then "Every native mutation previews first: server dry run, then kubectl diff per resource."
					else "mutations.enabled is false: every mutation is refused."
			),
		}, { key = "tiers", role = "kube-lens.settings-tiers" })
	)
	local ops: { { { ui.SpanLike } } } = {}
	for _, o in State.OPERATIONS do
		table.insert(ops, { { ui.span(o.what, "strong") }, { ui.span(o.text) } })
	end
	table.insert(
		out,
		ui.section(
			{ ui.span("Supported operations", "strong") },
			{ ui.kv(ops) },
			{ key = "ops", role = "kube-lens.settings-ops" }
		)
	)
	return out
end

-- Dock and help -------------------------------------------------------------------

local function dock(s: State): Node
	local spans: { ui.SpanLike }
	if s.editing then
		spans = {
			ui.span(s.editing.path .. ": ", "accent"),
			ui.span("type · enter saves · esc cancels · ctrl+u clears", "muted"),
		}
	elseif s.page == "status" then
		spans = { ui.span("tab settings · o open file · R reload · ? help · esc close", "muted") }
	else
		spans = {
			ui.span(
				"j/k move · enter/space toggle or edit · e edit · r reset · o open file · tab status · ? help",
				"muted"
			),
		}
	end
	return ui.col(
		{ ui.text(spans, { key = "status", role = "kube-lens.status" }) },
		{ role = "kube-lens.settings-dock" }
	)
end

M.KEYS = {
	{ "j / k, down / up", "Move the selection", "Click a row" },
	{ "g / G, pageup / pagedown", "First / last setting, by a window", "" },
	{ "enter / space", "Toggle a boolean, cycle a choice, edit anything else", "on/off, Cycle, Edit" },
	{ "e", "Edit the value (enter saves, esc cancels)", "Edit, or click the input" },
	{ "r", "Reset to default (removes the key from the file)", "Reset" },
	{ "o", "Open the config file in Tern (created when missing)", "Open config file" },
	{ "tab", "Switch between Settings and Status", "Settings / Status" },
	{ "R", "Re-read the file and the status", "Reload" },
	{ "?", "This help", "?" },
	{ "esc", "Close help, cancel an edit, or close the block", "" },
}

local function help(): Node
	local items: { { { ui.SpanLike } } } = {}
	for _, k in M.KEYS do
		local pointer = if k[3] ~= "" then "  ·  " .. k[3] else ""
		table.insert(items, { { ui.span(k[1], "mono strong") }, { ui.span(k[2]), ui.span(pointer, "muted") } })
	end
	return ui.col({
		ui.text(
			{ ui.span("Kube Lens Settings keys", "strong"), ui.span("   esc or ? closes", "muted") },
			{ key = "title" }
		),
		ui.kv(items),
		ui.muted("Every change is validated like the file is at load, then written atomically; unknown keys are kept."),
	}, { key = "help", role = "kube-lens.settings-help" })
end

function M.view(s: State, _cols: number, rows: number): View
	local children: { Node } = { header(s) }
	local msg = messageNode(s)
	if msg then
		table.insert(children, msg)
	end
	if s.fileError and s.page == "settings" then
		table.insert(children, ui.text({ ui.span(s.fileError, "error") }, { key = "ferr", role = "kube-lens.error" }))
	end
	local body: { Node } = if s.page == "settings" then settingsPage(s, rows) else statusPage(s)
	for _, n in body do
		table.insert(children, n)
	end
	return {
		main = ui.col(children, { role = "kube-lens.settings" }),
		dock = dock(s),
		layer = if s.help then ui.col({ help() }, { role = "kube-lens.settings-layer" }) else nil,
	}
end

function M.title(s: State): string
	return if s.page == "status" then "Kube Lens Settings · Status" else "Kube Lens Settings"
end

return M
