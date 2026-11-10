--!strict
-- Summary badges for one snapshot table: only what the facet chips above
-- the table and the header's row count do not already say. Every count is
-- derived from a column the table shows.

local Query = require("../lens/query")
local Types = require("../model/types")
local Values = require("../model/values")
local ui = require("../ui")

type Node = ui.Node
type SnapshotTable = Types.SnapshotTable

local M = {}

local function columnOf(t: SnapshotTable, header: string): number?
	return table.find(t.headers, header)
end

local function plural(n: number, singular: string): string
	return if n == 1 then "1 " .. singular else string.format("%d %ss", n, singular)
end

-- The muted tone says the restarts are old news (Problems ignores them too).
local function pods(t: SnapshotTable): { Node }
	local col = columnOf(t, "RESTARTS")
	if col == nil then
		return {}
	end
	local total = 0
	local recent = false
	for _, row in t.rows do
		local cell = row.cells[col] or ""
		total += Values.count(cell) or 0
		recent = recent or Query.recentRestart(cell)
	end
	return { ui.badge(plural(total, "restart"), if recent then "warning" else "muted") }
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

-- Jobs with a STATUS column are counted by its facet chips.
local function jobs(t: SnapshotTable): { Node }
	local col = columnOf(t, "COMPLETIONS")
	if col == nil or columnOf(t, "STATUS") then
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

local BY_KIND: { [string]: (SnapshotTable) -> { Node } } = {
	pod = pods,
	deployment = deployments,
	job = jobs,
	cronjob = cronjobs,
}

function M.summarize(t: SnapshotTable): { Node }
	local kind = t.kind
	local handler = if kind then BY_KIND[string.lower(kind)] else nil
	return if handler then handler(t) else {}
end

return M
