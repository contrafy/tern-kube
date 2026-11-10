--!strict
-- Explore's keys for the help layer. Rows whose text starts with a view's
-- name ("Logs:", "Helm:") belong to that view; the help lists the current
-- view's keys first, then the ones that work everywhere, then the rest.

local M = {}

export type Entry = { string }
export type Section = { title: string, entries: { Entry } }

-- { key, what, pointer equivalent, "mutates" when mutations.enabled gates it }
M.KEYS = {
	{ "j / k, down / up", "Move the selection", "Click a row" },
	{ "gg / G, home / end", "First / last row", "" },
	{ "PageDown / PageUp", "Move by a window (also ctrl+f / ctrl+b)", "" },
	{ "enter", "Open the selected object (in an object: its relations)", "Click a row" },
	{ "esc", "Back; at the root clear the filter, then esc twice closes the block", "Breadcrumbs" },
	{ "backspace", "Back (never closes the block)", "" },
	{ "/", "Filter rows (enter keeps, esc ends editing)", "Click the filter" },
	{ "r", "Refresh this view (the only way data is re-read)", "Refresh" },
	{ "c", "Choose the context", "context chip" },
	{ "n", "Choose the namespace scope", "namespace chip" },
	{ ":", "Choose a resource kind", "" },
	{ "d", "Describe (native view)", "Describe" },
	{ "y", "Object view (fields as a tree)", "Object" },
	{ "R", "Related objects with provenance", "Relations" },
	{ "L", "Log records: the last explore.logs_tail lines with level, source and time", "Logs" },
	{ "v / V", "Events timeline of the namespace / of the focused object (with what it owns)", "Events" },
	{ "] / [", "Logs: next / previous error; events: next / previous Warning", "Next error" },
	{ "x", "Logs: level floor (all, warnings+, errors+); events: Warning only", "Level chips" },
	{
		"x",
		"Compare across contexts: the list in view, or the focused object; pick one context, all, or the configured set",
		"Compare across contexts",
	},
	{ "[ / ]", "Compare: previous / next other context (column, or the other side of the diff)", "Next context" },
	{ "f", "Compare: show all objects / only what differs / only missing or extra", "Show chip" },
	{ "enter", "Compare: pick the context; open the pairwise diff of a row (no new query)", "Click a row" },
	{ "r / Y", "Compare: refetch every context / copy every pinned command, one per line", "Copy commands" },
	{ "w / o / a", "Logs: wrap long lines, previous instance, cycle the container", "Wrap, previous, containers" },
	{ "enter", "Logs: inspect the selected line (fields, stack, copy line / message / JSON)", "Click a line" },
	{ "s", "Shell in a new split (workloads: a ready pod)", "Shell" },
	{ "l", "Follow logs in a new split", "Follow logs" },
	{ "shift+f", "Port-forward in a new split", "Port-forward" },
	{ "ctrl+d", "Delete: preview, then typed confirmation in the approve block", "Delete", "mutates" },
	{
		"ctrl+r",
		"Rollout restart (deployments, statefulsets, daemonsets): preview, then confirm",
		"Restart",
		"mutates",
	},
	{ "shift+s", "Scale: asks for replicas, previews, then confirm", "Scale", "mutates" },
	{ "e", "Edit in a new split (kubectl edit); the approve block previews after you save", "Edit", "mutates" },
	{
		"t / T",
		"Label / annotate: asks for KEY=VALUE or KEY-, previews, then confirm",
		"Label, Annotate",
		"mutates",
	},
	{ "X", "Patch: asks for [--type=strategic|merge|json] JSON, previews, then confirm", "Patch", "mutates" },
	{
		"U",
		"Rollout undo (deployments, statefulsets, daemonsets): diff to the target revision",
		"Undo",
		"mutates",
	},
	{ "p / P", "Rollout pause / resume (deployments)", "Pause, Resume", "mutates" },
	{ "C / u", "Cordon / uncordon the node", "Cordon, Uncordon", "mutates" },
	{
		"D",
		"Drain the node: asks for options, previews evictions and PodDisruptionBudgets",
		"Drain",
		"mutates",
	},
	{ "Y", "Copy the kubectl command of this view", "Copy command" },
	{ "m", "Open the object's manifest at its line (indexes the repository first)", "Manifest" },
	{ "=", "Diff the live object against its manifest (kubectl diff)", "Diff vs manifest" },
	{ "ctrl+g", "Drift report: choose a manifest source, compare it with the cluster", "" },
	{ "E", "Export the object (or the filtered list) as clean manifests: preview, then w writes", "Export" },
	{ "f / a / A / X", "Drift: filter, apply the selected manifest / the source, export all shown", "" },
	{ "t / w / b", "Export: change directory, write the files, branch and commit", "" },
	{ "b e p P o", "Git: branch, message, push, pull request, only exported files (enter runs)", "" },
	{ "H", "Helm releases; on an object managed by Helm: its release", "Helm release chip" },
	{
		"h / v / M / N / K / R",
		"Helm: history, values (v again: next mode), manifest, notes, hooks, resources of the release",
		"Release chips",
	},
	{ "enter", "Helm: open the release, the revision or the object", "Click a row" },
	{ "space", "Helm: mark a history revision for =", "" },
	{ "=", "Helm: diff the selected revision against the latest (or the marked one)", "Diff vs previous" },
	{
		"ctrl+r",
		"Helm: roll back to the selected revision (release: the last good one); previews in the approve block",
		"Rollback",
		"mutates",
	},
	{ "ctrl+g", "Helm: drift of the auto-detected chart directory", "" },
	{ "Y", "Helm: copy the pinned helm command of this view", "Copy command" },
	{ "?", "This help", "?" },
}

-- The view names a row's text can start with, per route kind.
local function groupsOf(kind: string): { [string]: boolean }
	if kind == "logs" then
		return { logs = true }
	elseif kind == "events" then
		return { events = true }
	elseif string.sub(kind, 1, 7) == "compare" then
		return { compare = true }
	elseif string.sub(kind, 1, 5) == "helm-" then
		return { helm = true }
	elseif kind == "drift" then
		return { drift = true }
	elseif kind == "matrix" then
		-- One drift source across contexts: [ ] and f as in compare.
		return { drift = true, compare = true }
	elseif kind == "export" or kind == "git" then
		return { export = true, git = true }
	end
	return {}
end

-- The views a row names: "Logs: …; events: …" names logs and events.
local function viewsOf(what: string): { string }
	local out: { string } = {}
	for name in string.gmatch(";" .. what, ";%s*(%a+):") do
		table.insert(out, string.lower(name))
	end
	return out
end

function M.sections(kind: string, mutations: boolean): { Section }
	local groups = groupsOf(kind)
	local here: { Entry } = {}
	local everywhere: { Entry } = {}
	local other: { Entry } = {}
	for _, k in M.KEYS do
		if k[4] == "mutates" and not mutations then
			continue
		end
		local views = viewsOf(k[2])
		local mine = false
		for _, v in views do
			mine = mine or groups[v] == true
		end
		if mine then
			table.insert(here, k)
		elseif #views == 0 then
			table.insert(everywhere, k)
		else
			table.insert(other, k)
		end
	end
	local out: { Section } = {}
	if #here > 0 then
		table.insert(out, { title = "This view", entries = here })
	end
	table.insert(out, { title = if #here > 0 then "Everywhere" else "Keys", entries = everywhere })
	if #other > 0 then
		table.insert(out, { title = "Other views", entries = other })
	end
	return out
end

-- Rows the help draws (a title per section plus its keys): the bound of
-- its scroll position.
function M.rows(kind: string, mutations: boolean): number
	local n = 0
	for _, sec in M.sections(kind, mutations) do
		n += 1 + #sec.entries
	end
	return n
end

return M
