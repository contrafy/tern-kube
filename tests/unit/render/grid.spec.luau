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
		local heads = nodes.findAll(g, nodes.class("tk-h"))
		expect(#heads).toBe(#HEADERS)
		expect(nodes.action(heads[1])).toBe("v=sort:NAME")
		local sorted = nodes.find(g, nodes.class("tk-sorted")) :: any
		expect(nodes.text(sorted)).toBe("AGE ▼")
	end)

	it("each row is clickable with its own action and keyed by row key", function()
		local g = Grid.grid(spec())
		local rows = nodes.findAll(g, nodes.class("tk-r"))
		expect(#rows).toBe(2)
		expect(nodes.action(rows[2])).toBe("v=open:b")
		expect((rows[2].p :: any).key).toBe("/Pod/ns/b")
		expect(#nodes.findAll(rows[2], nodes.class("tk-c"))).toBe(#HEADERS)
	end)

	it("draws the inspector right after the open row only", function()
		local g = Grid.grid(spec("/Pod/ns/a"))
		local gridNode = nodes.find(g, nodes.class("tk-grid")) :: any
		local kids = gridNode.c
		local openIndex = 0
		for i, k in kids do
			if k.p.key == "/Pod/ns/a" then
				openIndex = i
			end
		end
		expect(nodes.text(kids[openIndex + 1])).toBe("inspecting /Pod/ns/a")
		expect(#nodes.findAll(g, nodes.class("tk-insp"))).toBe(1)
		expect(string.find(classesOf(kids[openIndex]), "tk-open", 1, true) ~= nil).toBe(true)
	end)

	it("never hides NAME/READY/STATUS and hides wide extras first", function()
		local g = Grid.grid(spec())
		local heads = nodes.findAll(g, nodes.class("tk-h"))
		expect(nodes.class("tk-p0")(heads[1])).toBe(true)
		expect(nodes.class("tk-p0")(heads[2])).toBe(true)
		expect(nodes.class("tk-p0")(heads[3])).toBe(true)
		expect(nodes.class("tk-p1")(heads[5])).toBe(true)
		expect(nodes.class("tk-p3")(heads[8])).toBe(true)
		expect(Grid.priority("STATUS", 4)).toBe(0)
	end)

	it("carries the visible column count of each width tier", function()
		local g = Grid.grid(spec())
		local cls = classesOf(nodes.find(g, nodes.class("tk-grid")))
		-- 9 columns: p3 = NOMINATED NODE, READINESS GATES; p2 = IP, NODE; p1 = RESTARTS, AGE.
		expect(cls).toBe("tk-grid tk-cols-9 tk-a-7 tk-b-5 tk-c-3")
	end)

	it("cell priority classes match their header's", function()
		local g = Grid.grid(spec())
		local row = nodes.findAll(g, nodes.class("tk-r"))[1]
		local cells = nodes.findAll(row, nodes.class("tk-c"))
		expect(nodes.class("tk-p3")(cells[9])).toBe(true)
		expect(nodes.class("tk-num")(cells[4])).toBe(true)
	end)

	-- A Job's pod that finished shows READY 0/1 by design; drawing it in the
	-- warning tone sent people hunting for a problem that is not there.
	it("mutes the short READY of Completed/Succeeded rows only", function()
		local s = spec()
		s.rows[1].cells = { "job-x", "0/1", "Completed", "0", "5m", "10.0.0.1", "n1", "<none>", "<none>" }
		local g = Grid.grid(s)
		local rows = nodes.findAll(g, nodes.class("tk-r"))
		local done = nodes.tones((nodes.findAll(rows[1], nodes.class("tk-c"))[2] :: any).c[1])
		expect(table.find(done, "warning")).toBeNil()
		expect(table.find(done, "muted") ~= nil).toBe(true)
		local crash = nodes.tones((nodes.findAll(rows[2], nodes.class("tk-c"))[2] :: any).c[1])
		expect(table.find(crash, "warning") ~= nil).toBe(true)
	end)

	-- A log keeps arrival order: its headers are labels, not sort buttons.
	it("unsortable grids draw plain headers", function()
		local s = spec()
		s.sortable = false
		local heads = nodes.findAll(Grid.grid(s), nodes.class("tk-h"))
		expect(nodes.action(heads[1])).toBeNil()
		expect(nodes.find(Grid.grid(s), nodes.class("tk-sorted"))).toBeNil()
		expect(nodes.text(heads[5])).toBe("AGE")
	end)

	it("rows carry extra classes, prebuilt cells, muted notes and dividers", function()
		local s = spec()
		s.class = "tk-logs"
		s.rows[1].class = "tk-lvl-warn"
		s.rows[1].notes = { [5] = "×3 over 1h" }
		s.rows[2].nodes = { [3] = ui.badge("ERROR", "error") }
		s.rows[2].divider = "2026-11-02"
		local g = Grid.grid(s)
		expect(classesOf(nodes.find(g, nodes.class("tk-grid")))).toContain("tk-logs")
		local rows = nodes.findAll(g, nodes.class("tk-r"))
		expect(classesOf(rows[1])).toBe("tk-r tk-lvl-warn")
		local age = nodes.findAll(rows[1], nodes.class("tk-c"))[5]
		expect(nodes.text(age)).toBe("5m ×3 over 1h")
		expect(table.find(nodes.tones((age :: any).c[1]), "muted") ~= nil).toBe(true)
		local status = nodes.findAll(rows[2], nodes.class("tk-c"))[3] :: any
		expect(status.c[1].k).toBe("badge")
		local divider = nodes.find(g, nodes.class("tk-divider")) :: any
		expect(divider.p.text).toBe("2026-11-02")
	end)

	it("kept columns never hide, whatever their priority", function()
		local s = spec()
		s.keep = { IP = true }
		local heads = nodes.findAll(Grid.grid(s), nodes.class("tk-h"))
		expect(nodes.class("tk-p0")(heads[6])).toBe(true)
		expect(classesOf(nodes.find(Grid.grid(s), nodes.class("tk-grid")))).toBe(
			"tk-grid tk-cols-9 tk-a-7 tk-b-6 tk-c-4"
		)
	end)

	-- Pods of one ReplicaSet differ only in their last segment; an end
	-- ellipsis made `web-65d7d99975-6j…` and `web-65d7d99975-mt…` identical.
	it("splits long names so the unique end stays visible", function()
		expect({ Grid.splitMiddle("web-65d7d99975-6jsgc") }).toEqual({ "web-65d7d99975", "-6jsgc" })
		expect({ Grid.splitMiddle("kube-apiserver-tern-kube-dev-control-plane") }).toEqual({
			"kube-apiserver-tern-kube-dev-control",
			"-plane",
		})
		expect({ Grid.splitMiddle("statefulset-x-0") }).toEqual({ "statefulset", "-x-0" })
		expect({ Grid.splitMiddle("db-0") }).toEqual({ "db-0", "" })
		expect({ Grid.splitMiddle("abcdefghijklmnopqrstuvwxyz") }).toEqual({ "abcdefghijklmnopqr", "stuvwxyz" })
	end)

	it("middle columns draw a shrinking head and a fixed tail, titled with the whole value", function()
		local s = spec()
		s.rows[1].cells[1] = "web-65d7d99975-6jsgc"
		s.middle = { NAME = true }
		local row = nodes.findAll(Grid.grid(s), nodes.class("tk-r"))[1]
		local cell = nodes.findAll(row, nodes.class("tk-c"))[1] :: any
		expect(classesOf(cell)).toContain("tk-midc")
		expect(cell.p.title).toBe("web-65d7d99975-6jsgc")
		expect(nodes.text(nodes.find(cell, nodes.class("tk-mid-h")) :: any)).toBe("web-65d7d99975")
		expect(nodes.text(nodes.find(cell, nodes.class("tk-mid-t")) :: any)).toBe("-6jsgc")
		-- Short names and grids without `middle` keep the plain text cell.
		local plain = nodes.findAll(Grid.grid(spec()), nodes.class("tk-r"))[1]
		expect(nodes.find(plain, nodes.class("tk-mid-h"))).toBeNil()
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

	-- Every pod restarted by a Docker restart a day ago glowed yellow, the
	-- same as a pod crashing now; the tone follows the Problems rule.
	it("tones only recent restarts as warnings", function()
		expect(table.find(tones("RESTARTS", "count", "2 (25h ago)"), "warning")).toBeNil()
		expect(table.find(tones("RESTARTS", "count", "4"), "warning")).toBeNil()
		expect(table.find(tones("RESTARTS", "count", "1 (40s ago)"), "warning") ~= nil).toBe(true)
	end)

	it("mutes a short ratio on a finished row, keeps a full one green", function()
		expect(nodes.tones(Cells.cell("READY", "ratio", "0/1", true))).toEqual({ "muted", "mono" })
		expect(table.find(nodes.tones(Cells.cell("READY", "ratio", "1/1", true)), "success") ~= nil).toBe(true)
		expect(Cells.rowFinished({ "text", "status" } :: any, { "a", "Succeeded" })).toBe(true)
		expect(Cells.rowFinished({ "text", "status" } :: any, { "a", "Running" })).toBe(false)
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
