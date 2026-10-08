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

describe("summary badges", function()
	-- Fixtures are recaptured from a live cluster; restart counts and pod
	-- names vary, so expectations are derived from the fixture's own cells.
	it("counts pod statuses with problems first and totals restarts from the RESTARTS column", function()
		local tbl = snapshotTable("real/ns-apps/get_pods.txt", "Pod")
		local running, restarts = 0, 0
		for _, row in tbl.rows do
			running += if row.cells[3] == "Running" then 1 else 0
			restarts += tonumber(string.match(row.cells[4], "^%d+")) or 0
		end
		local out = badges(Summary.summarize(tbl))
		-- Problems lead so a user sees what is broken before what is fine.
		expect(out[1].tone).toBe("error")
		expect(out).toContain({ text = string.format("%d Running", running), tone = "success" })
		expect(out).toContain({ text = "1 CrashLoopBackOff", tone = "error" })
		expect(out).toContain({ text = "1 ImagePullBackOff", tone = "error" })
		expect(out).toContain({ text = "1 Pending", tone = "warning" })
		-- "4 (80s ago)" counts as 4, not as unparseable text.
		expect(restarts > 0).toBe(true)
		expect(out[#out]).toEqual({ text = string.format("%d restarts", restarts), tone = "warning" })
	end)

	it("does not invent restart counts when RESTARTS is not shown", function()
		local tbl = snapshotTable("real/ns-apps/top_pods.txt", "Pod")
		local out = badges(Summary.summarize(tbl))
		expect(out).toEqual({ { text = string.format("%d rows", #tbl.rows), tone = "muted" } })
	end)

	it("sums ready/desired replicas and counts deployments that are not fully available", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-apps/get_deployments.txt", "Deployment")))
		expect(out).toEqual({
			{ text = "2/3 replicas ready", tone = "warning" },
			{ text = "1 not fully available", tone = "warning" },
		})
	end)

	it("counts node readiness", function()
		local out = badges(Summary.summarize(snapshotTable("real/cluster/get_nodes.txt", "Node")))
		expect(out).toEqual({ { text = "1 Ready", tone = "success" } })
	end)

	it("counts complete and failed jobs", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-batch/get_jobs.txt", "Job")))
		expect(out).toEqual({ { text = "1 Failed", tone = "error" }, { text = "1 Complete", tone = "success" } })
	end)

	it("counts Warning events", function()
		local tbl = snapshotTable("real/ns-apps/get_events.txt", "Event")
		local expected = 0
		for _, row in tbl.rows do
			if row.cells[2] == "Warning" then
				expected += 1
			end
		end
		expect(expected > 0).toBe(true)
		local out = badges(Summary.summarize(tbl))
		expect(out).toEqual({ { text = string.format("%d warnings", expected), tone = "warning" } })
	end)

	it("counts suspended cronjobs", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-batch/get_cronjobs.txt", "CronJob")))
		expect(out).toEqual({ { text = "1 suspended", tone = "warning" } })
	end)

	it("groups services by TYPE without status colouring", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-apps/get_services.txt", "Service")))
		expect(#out > 1).toBe(true)
		for _, b in out do
			expect(b.tone).toBe("neutral")
		end
		expect(
			nodes.text({ k = "row", c = Summary.summarize(snapshotTable("real/ns-apps/get_services.txt", "Service")) })
		).toContain("ClusterIP")
	end)

	it("shows only the row count for kinds it knows nothing about", function()
		local out = badges(Summary.summarize(snapshotTable("real/ns-crd/get_widgets.txt", "Widget")))
		expect(#out).toBe(1)
		expect(out[1].tone).toBe("muted")
		expect(out[1].text).toContain("rows")
	end)
end)

return nil
