--!strict
local Summary = require("../../../plugin/lib/render/summary")
local TableParser = require("../../../plugin/lib/parse/table")
local Types = require("../../../plugin/lib/model/types")
local Values = require("../../../plugin/lib/model/values")
local fixtures = require("../../lib/fixtures")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function snapshotTable(path: string, kind: string?): Types.SnapshotTable
	local parsed = TableParser.parse(fixtures.lines(path)).tables[1]
	local headers: { string } = {}
	local types: { Types.ColumnType } = {}
	for i, column in parsed.columns do
		headers[i] = column.name
		local samples = {}
		for _, row in parsed.rows do
			table.insert(samples, row.cells[i] or "")
		end
		types[i] = Values.columnType(column.name, samples)
	end
	local rows: { Types.ResourceRow } = {}
	for i, row in parsed.rows do
		rows[i] = { key = "r" .. i, cells = row.cells, rawLines = { row.line }, warnings = {} }
	end
	return { kind = kind, headers = headers, types = types, rows = rows }
end

type Badge = { text: string, tone: string }

local function badges(list: { nodes.Node }): { Badge }
	local out: { Badge } = {}
	for _, n in list do
		expect(n.k).toBe("badge")
		local p = n.p :: { [string]: any }
		table.insert(out, { text = p.text, tone = p.tone })
	end
	return out
end

-- The facet chips above the table already count STATUS, TYPE and the rows
-- (header); the summary only adds what no chip says (LENS-L11: `1 Error`,
-- `4 Running`, `N rows` and `N warnings` repeated a chip one line below).
describe("summary badges", function()
	-- Fixtures are recaptured from a live cluster; restart counts vary, so
	-- expectations are derived from the fixture's own cells.
	it("pods: totals restarts only, toned by whether any restart is recent", function()
		local tbl = snapshotTable("real/ns-apps/get_pods.txt", "Pod")
		local restarts = 0
		for _, row in tbl.rows do
			restarts += tonumber(string.match(row.cells[4], "^%d+")) or 0
		end
		local out = badges(Summary.summarize(tbl))
		-- "4 (80s ago)" counts as 4, not as unparseable text.
		expect(restarts > 0).toBe(true)
		expect(#out).toBe(1)
		expect(out[1].text).toBe(string.format("%d restarts", restarts))
		local old = snapshotTable("real/ns-apps/get_pods.txt", "Pod")
		for _, row in old.rows do
			row.cells[4] = "2 (25h ago)"
		end
		expect(badges(Summary.summarize(old))[1].tone).toBe("muted")
		old.rows[1].cells[4] = "3 (2m ago)"
		expect(badges(Summary.summarize(old))[1].tone).toBe("warning")
	end)

	it("does not invent restart counts when RESTARTS is not shown", function()
		expect(Summary.summarize(snapshotTable("real/ns-apps/top_pods.txt", "Pod"))).toEqual({})
	end)

	it("sums ready/desired replicas and counts deployments that are not fully available", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-apps/get_deployments.txt", "Deployment")))
		expect(out).toEqual({
			{ text = "2/3 replicas ready", tone = "warning" },
			{ text = "1 not fully available", tone = "warning" },
		})
	end)

	it("leaves node, job, event and service status counts to the facet chips", function()
		for _, case in
			{
				{ "real/cluster/get_nodes.txt", "Node" },
				{ "real/ns-batch/get_jobs.txt", "Job" },
				{ "real/ns-apps/get_events.txt", "Event" },
				{ "real/ns-apps/get_services.txt", "Service" },
				{ "real/ns-crd/get_widgets.txt", "Widget" },
			}
		do
			expect(Summary.summarize(snapshotTable(case[1], case[2]))).toEqual({})
		end
	end)

	it("counts complete jobs from COMPLETIONS when there is no STATUS column", function()
		local tbl = snapshotTable("real/ns-batch/get_jobs.txt", "Job")
		local status = table.find(tbl.headers, "STATUS") :: number
		table.remove(tbl.headers, status)
		table.remove(tbl.types, status)
		for _, row in tbl.rows do
			table.remove(row.cells, status)
		end
		expect(badges(Summary.summarize(tbl))).toEqual({ { text = "1 complete", tone = "success" } })
	end)

	it("counts suspended cronjobs", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-batch/get_cronjobs.txt", "CronJob")))
		expect(out).toEqual({ { text = "1 suspended", tone = "warning" } })
	end)
end)

return nil
