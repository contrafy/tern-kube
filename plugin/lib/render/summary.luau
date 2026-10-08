--!strict
-- Summary badges for one snapshot table. Every count is derived from a column
-- the table shows; a kind whose telling column is absent (custom columns,
-- `top`) gets only the row count.

local Types = require("../model/types")
local Values = require("../model/values")
local ui = require("../ui")

type Node = ui.Node
type SnapshotTable = Types.SnapshotTable

local M = {}

local SEVERITY: { [string]: number } = { error = 1, warning = 2, success = 3, neutral = 4, muted = 5 }

local function columnOf(t: SnapshotTable, header: string): number?
	return table.find(t.headers, header)
end

local function plural(n: number, singular: string, pluralForm: string?): string
	if n == 1 then
		return "1 " .. singular
	end
	return string.format("%d %s", n, pluralForm or (singular .. "s"))
end

-- One badge per distinct value, problems first, then most frequent.
local function valueCounts(t: SnapshotTable, col: number, header: string): { Node }
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, row in t.rows do
		local value = row.cells[col] or ""
		if Values.isPlaceholder(value) then
			continue
		end
		if counts[value] == nil then
			counts[value] = 0
			table.insert(order, value)
		end
		counts[value] += 1
	end
	local tones: { [string]: string } = {}
	for _, value in order do
		tones[value] = Values.statusTone(header, value)
	end
	table.sort(order, function(a: string, b: string): boolean
		local sa, sb = SEVERITY[tones[a]] or 4, SEVERITY[tones[b]] or 4
		if sa ~= sb then
			return sa < sb
		end
		if counts[a] ~= counts[b] then
			return counts[a] > counts[b]
		end
		return a < b
	end)
	local out: { Node } = table.create(#order)
	for i, value in order do
		out[i] = ui.badge(string.format("%d %s", counts[value], value), tones[value])
	end
	return out
end

local function append(out: { Node }, nodes: { Node })
	for _, n in nodes do
		table.insert(out, n)
	end
end

local function statusBadges(t: SnapshotTable): { Node }
	local col = columnOf(t, "STATUS")
	return if col then valueCounts(t, col, "STATUS") else {}
end

local function pods(t: SnapshotTable): { Node }
	local out = statusBadges(t)
	local col = columnOf(t, "RESTARTS")
	if col then
		local total = 0
		for _, row in t.rows do
			total += Values.count(row.cells[col] or "") or 0
		end
		table.insert(out, ui.badge(plural(total, "restart"), if total > 0 then "warning" else "muted"))
	end
	return out
end

local function deployments(t: SnapshotTable): { Node }
	local col = columnOf(t, "READY")
	if col == nil then
		return {}
	end
	local ready, desired, unavailable, seen = 0, 0, 0, false
	for _, row in t.rows do
		local num, den = Values.ratio(row.cells[col] or "")
		if num and den then
			seen = true
			ready += num
			desired += den
			if num < den then
				unavailable += 1
			end
		end
	end
	if not seen then
		return {}
	end
	local out = {
		ui.badge(
			string.format("%d/%d replicas ready", ready, desired),
			if ready < desired then "warning" else "success"
		),
	}
	if unavailable > 0 then
		table.insert(out, ui.badge(string.format("%d not fully available", unavailable), "warning"))
	end
	return out
end

local function jobs(t: SnapshotTable): { Node }
	local status = statusBadges(t)
	if #status > 0 then
		return status
	end
	local col = columnOf(t, "COMPLETIONS")
	if col == nil then
		return {}
	end
	local complete = 0
	for _, row in t.rows do
		local num, den = Values.ratio(row.cells[col] or "")
		if num and den and den > 0 and num >= den then
			complete += 1
		end
	end
	return { ui.badge(string.format("%d complete", complete), if complete > 0 then "success" else "muted") }
end

local function events(t: SnapshotTable): { Node }
	local col = columnOf(t, "TYPE")
	if col == nil then
		return {}
	end
	local warnings = 0
	for _, row in t.rows do
		if row.cells[col] == "Warning" then
			warnings += 1
		end
	end
	return { ui.badge(plural(warnings, "warning"), if warnings > 0 then "warning" else "muted") }
end

local function cronjobs(t: SnapshotTable): { Node }
	local col = columnOf(t, "SUSPEND")
	if col == nil then
		return {}
	end
	local suspended = 0
	for _, row in t.rows do
		if row.cells[col] == "True" then
			suspended += 1
		end
	end
	return { ui.badge(string.format("%d suspended", suspended), if suspended > 0 then "warning" else "muted") }
end

local function services(t: SnapshotTable): { Node }
	local col = columnOf(t, "TYPE")
	if col == nil then
		return {}
	end
	local out = valueCounts(t, col, "TYPE")
	for _, badge in out do
		(badge.p :: { [string]: any }).tone = "neutral"
	end
	return out
end

local BY_KIND: { [string]: (SnapshotTable) -> { Node } } = {
	pod = pods,
	deployment = deployments,
	node = statusBadges,
	job = jobs,
	event = events,
	cronjob = cronjobs,
	service = services,
}

function M.summarize(t: SnapshotTable): { Node }
	local out: { Node } = {}
	local kind = t.kind
	local handler = if kind then BY_KIND[string.lower(kind)] else nil
	if handler then
		append(out, handler(t))
	end
	if #out == 0 then
		table.insert(out, ui.badge(plural(#t.rows, "row"), "muted"))
	end
	return out
end

return M
