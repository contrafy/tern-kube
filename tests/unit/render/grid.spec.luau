--!strict
-- The clickable grid: headers sort, rows open the inspector, the inspector
-- spans the row, and narrow panes drop the columns that matter least.
local Cells = require("../../../plugin/lib/render/cells")
local Grid = require("../../../plugin/lib/render/grid")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local ui = require("../../../plugin/lib/ui")
local describe, it, expect = t.describe, t.it, t.expect

local HEADERS = { "NAME", "READY", "STATUS", "RESTARTS", "AGE", "IP", "NODE", "NOMINATED NODE", "READINESS GATES" }
local TYPES: { any } = { "text", "ratio", "status", "count", "duration", "text", "text", "text", "text" }

local function spec(open: string?): Grid.Spec
	return {
		key = "g1",
		headers = HEADERS,
		types = TYPES,
		rows = {
			{
				key = "/Pod/ns/a",
				cells = { "a", "1/1", "Running", "0", "5m", "10.0.0.1", "n1", "<none>", "<none>" },
				action = "v=open:a",
				open = open == "/Pod/ns/a",
			},
			{
				key = "/Pod/ns/b",
				cells = { "b", "0/1", "CrashLoopBackOff", "4 (1m ago)", "5m", "10.0.0.2", "n1", "<none>", "<none>" },
				action = "v=open:b",
				open = open == "/Pod/ns/b",
			},
		},
		sortCol = "AGE",
		desc = true,
		sortAction = function(col: string): string
			return "v=sort:" .. col
		end,
		inspector = function(rowKey: string): ui.Node?
			return ui.text({ "inspecting " .. rowKey })
		end,
	}
end

local function classesOf(node: any): string
	return node.p.class
end

describe("render grid", function()
	it("header cells sort by their column and mark the sorted one", function()
		local g = Grid.grid(spec())
		local heads = nodes.findAll(g, nodes.class("kl-h"))
		expect(#heads).toBe(#HEADERS)
		expect(nodes.action(heads[1])).toBe("v=sort:NAME")
		local sorted = nodes.find(g, nodes.class("kl-sorted")) :: any
		expect(nodes.text(sorted)).toBe("AGE ▼")
	end)

	it("each row is clickable with its own action and keyed by row key", function()
		local g = Grid.grid(spec())
		local rows = nodes.findAll(g, nodes.class("kl-r"))
		expect(#rows).toBe(2)
		expect(nodes.action(rows[2])).toBe("v=open:b")
		expect((rows[2].p :: any).key).toBe("/Pod/ns/b")
		expect(#nodes.findAll(rows[2], nodes.class("kl-c"))).toBe(#HEADERS)
	end)

	it("draws the inspector right after the open row only", function()
		local g = Grid.grid(spec("/Pod/ns/a"))
		local gridNode = nodes.find(g, nodes.class("kl-grid")) :: any
		local kids = gridNode.c
		local openIndex = 0
		for i, k in kids do
			if k.p.key == "/Pod/ns/a" then
				openIndex = i
			end
		end
		expect(nodes.text(kids[openIndex + 1])).toBe("inspecting /Pod/ns/a")
		expect(#nodes.findAll(g, nodes.class("kl-insp"))).toBe(1)
		expect(string.find(classesOf(kids[openIndex]), "kl-open", 1, true) ~= nil).toBe(true)
	end)

	it("never hides NAME/READY/STATUS and hides wide extras first", function()
		local g = Grid.grid(spec())
		local heads = nodes.findAll(g, nodes.class("kl-h"))
		expect(nodes.class("kl-p0")(heads[1])).toBe(true)
		expect(nodes.class("kl-p0")(heads[2])).toBe(true)
		expect(nodes.class("kl-p0")(heads[3])).toBe(true)
		expect(nodes.class("kl-p1")(heads[5])).toBe(true)
		expect(nodes.class("kl-p3")(heads[8])).toBe(true)
		expect(Grid.priority("STATUS", 4)).toBe(0)
	end)

	it("carries the visible column count of each width tier", function()
		local g = Grid.grid(spec())
		local cls = classesOf(nodes.find(g, nodes.class("kl-grid")))
		-- 9 columns: p3 = NOMINATED NODE, READINESS GATES; p2 = IP, NODE; p1 = RESTARTS, AGE.
		expect(cls).toBe("kl-grid kl-cols-9 kl-a-7 kl-b-5 kl-c-3")
	end)

	it("cell priority classes match their header's", function()
		local g = Grid.grid(spec())
		local row = nodes.findAll(g, nodes.class("kl-r"))[1]
		local cells = nodes.findAll(row, nodes.class("kl-c"))
		expect(nodes.class("kl-p3")(cells[9])).toBe(true)
		expect(nodes.class("kl-num")(cells[4])).toBe(true)
	end)
end)

describe("render cells", function()
	local function tones(col: string, ty: any, value: string): { string }
		return nodes.tones(Cells.cell(col, ty, value))
	end

	it("colors status by kubectl meaning", function()
		expect(table.find(tones("STATUS", "status", "CrashLoopBackOff"), "error") ~= nil).toBe(true)
		expect(table.find(tones("STATUS", "status", "Running"), "success") ~= nil).toBe(true)
		expect(table.find(tones("STATUS", "status", "Pending"), "warning") ~= nil).toBe(true)
	end)

	it("warns on short READY ratios and restarts", function()
		expect(table.find(tones("READY", "ratio", "0/1"), "warning") ~= nil).toBe(true)
		expect(table.find(tones("READY", "ratio", "1/1"), "success") ~= nil).toBe(true)
		expect(table.find(tones("RESTARTS", "count", "3 (2m ago)"), "warning") ~= nil).toBe(true)
		expect(table.find(tones("RESTARTS", "count", "0"), "warning")).toBeNil()
	end)

	it("mutes placeholders and marks numbers", function()
		expect(tones("NOMINATED NODE", "text", "<none>")).toEqual({ "muted" })
		expect(tones("AGE", "duration", "5m")).toEqual({ "mono" })
		expect(nodes.text(Cells.cell("NAME", "text", "db-0"))).toBe("db-0")
	end)

	-- Live Tern draws `num` in --sf-c-num (orange in the default theme), which
	-- also wins over a tone token on the same span: healthy `1/1` and every
	-- AGE looked like warnings. `mono` gives tabular figures without a color.
	it("never uses the colored num token in table cells", function()
		for _, case in { { "READY", "ratio", "1/1" }, { "RESTARTS", "count", "3" }, { "AGE", "duration", "5m" } } do
			expect(table.find(tones(case[1], case[2] :: any, case[3]), "num")).toBeNil()
		end
		expect(table.find(tones("READY", "ratio", "1/1"), "mono") ~= nil).toBe(true)
	end)
end)

return nil
