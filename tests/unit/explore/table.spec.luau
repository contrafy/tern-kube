--!strict
-- Explore's native tables: Tern hides columns by the table's own width, lowest
-- priority first, and cuts long cells, so the builder decides what a narrow
-- pane keeps (NAME, then health), keeps pod name suffixes readable and turns
-- the grid's text/badge cells into the table's cell forms.
local Table = require("../../../plugin/lib/render/table")
local Types = require("../../../plugin/lib/model/types")
local t = require("../../lib/test")
local ui = require("../../../plugin/lib/ui")
local Values = require("../../../plugin/lib/model/values")
local describe, it, expect = t.describe, t.it, t.expect

local HEADERS = { "NAMESPACE", "NAME", "READY", "STATUS", "RESTARTS", "NODE", "CREATED", "LABELS" }
local TYPES: { Types.ColumnType } = { "text", "text", "ratio", "status", "count", "text", "timestamp", "text" }

local function rows(): { Table.Row }
	return {
		{
			key = "/Pod/a/web-1",
			cells = { "a", "web-1", "1/1", "Running", "0", "n1", "2026-11-10T10:00:00Z", "app=web" },
			action = "open=/Pod/a/web-1",
		},
		{
			key = "/Pod/a/web-2",
			cells = { "a", "web-2", "0/1", "CrashLoopBackOff", "4 (1m ago)", "n1", "2026-11-10T11:00:00Z", "app=web" },
			action = "open=/Pod/a/web-2",
		},
	}
end

local function spec(): Table.Spec
	return { key = "list", headers = HEADERS, types = TYPES, rows = rows(), selected = "/Pod/a/web-2" }
end

local function col(node: ui.Node, head: string): any
	for _, c in (node.p :: any).cols do
		if c.head == head then
			return c
		end
	end
	return nil
end

describe("native table columns", function()
	it("keeps NAME longest, then STATUS before READY, every priority distinct", function()
		-- Equal priorities hide the rightmost first: STATUS vanished before READY.
		local node = Table.table(spec())
		local seen: { [number]: boolean } = {}
		for _, c in (node.p :: any).cols do
			expect(seen[c.priority]).toBeNil()
			seen[c.priority] = true
		end
		expect(col(node, "NAME").priority > col(node, "STATUS").priority).toBe(true)
		expect(col(node, "STATUS").priority > col(node, "READY").priority).toBe(true)
		expect(col(node, "READY").priority > col(node, "NAMESPACE").priority).toBe(true)
		expect(col(node, "NAMESPACE").priority > col(node, "LABELS").priority).toBe(true)
	end)

	-- Helm history's header-less column holds the row's state (latest,
	-- running, marked): in a narrow split it hid first, before the
	-- DESCRIPTION prose, so marking a revision showed nothing in its row.
	it("keeps a header-less tag column longer than prose columns", function()
		local h = { "REV", "STATUS", "UPDATED", "CHART", "APP VERSION", "DESCRIPTION", "" }
		expect(Table.priority(h, 7) > Table.priority(h, 6)).toBe(true)
		expect(Table.priority(h, 7) > Table.priority(h, 5)).toBe(true)
		expect(Table.priority(h, 7) > Table.priority(h, 3)).toBe(true)
		expect(Table.priority(h, 2) > Table.priority(h, 7)).toBe(true)
	end)

	it("lets NAME take the spare width and cut in the middle so pod suffixes stay unique", function()
		local c = col(Table.table(spec()), "NAME")
		expect(c.grow).toBe(1)
		expect(c.truncate).toBe("middle")
	end)

	it("aligns numbers at the end in the mono face", function()
		local c = col(Table.table(spec()), "RESTARTS")
		expect(c.align).toBe("end")
		expect(c.mono).toBe(true)
		expect(col(Table.table(spec()), "NAME").align).toBeNil()
	end)

	it("shows a creation timestamp as AGE at the fetch time, not an ISO string", function()
		local s = spec()
		s.now = Values.timestamp("2026-11-10T12:00:00Z")
		local node = Table.table(s)
		expect(col(node, "CREATED")).toBeNil()
		expect(col(node, "AGE") ~= nil).toBe(true)
		local id = col(node, "AGE").id
		local first = (node.p :: any).rows[1].cells[id]
		expect(first[1].t).toBe("2h")
	end)

	it("drops hidden columns (NAMESPACE of a single-namespace scope)", function()
		local s = spec()
		s.hide = { NAMESPACE = true }
		expect(col(Table.table(s), "NAMESPACE")).toBeNil()
	end)

	it("gives every column a unique id even when headers repeat or are empty", function()
		local ids = Table.ids({ "NAME", "NAME", "", "PORT(S)" })
		expect(ids[1] ~= ids[2]).toBe(true)
		expect(ids[3] ~= "").toBe(true)
		expect(string.find(ids[4], "^[%w%-]+$") ~= nil).toBe(true)
	end)
end)

describe("native table rows", function()
	it("keys rows by their item key and draws the selection", function()
		local node = Table.table(spec())
		local p = node.p :: any
		expect(p.rows[1].id).toBe("/Pod/a/web-1")
		expect(p.selected).toBe("/Pod/a/web-2")
		expect(p.selectable).toBe(true)
		expect(node.k).toBe("table")
	end)

	it("tones cells like the grid did (status, short ready, restarts)", function()
		local node = Table.table(spec())
		local p = node.p :: any
		local status = p.rows[2].cells[col(node, "STATUS").id]
		expect(status[1].s).toBe("error strong")
		expect(p.rows[2].cells[col(node, "RESTARTS").id][1].s).toBe("warning mono")
	end)

	it("turns text and badge nodes from a cell function into table cells", function()
		local s = spec()
		s.cell = function(c: string, _t: Types.ColumnType, value: string): ui.Node
			if c == "STATUS" then
				return ui.badge(value, "warning", { title = "why" })
			end
			return ui.text({ ui.span(value, "muted") }, { title = "full " .. value })
		end
		local node = Table.table(s)
		local p = node.p :: any
		expect(p.rows[1].cells[col(node, "STATUS").id].badge.text).toBe("Running")
		expect(p.rows[1].cells[col(node, "STATUS").id].badge.tone).toBe("warning")
		local name = p.rows[1].cells[col(node, "NAME").id]
		expect(name.text[1].t).toBe("web-1")
		expect(name.title).toBe("full web-1")
	end)

	it("appends a row's notes muted", function()
		local s = spec()
		s.rows[1].notes = { [2] = "(other ns)" }
		local node = Table.table(s)
		local cell = (node.p :: any).rows[1].cells[col(node, "NAME").id].text
		expect(cell[#cell].t).toBe(" (other ns)")
		expect(cell[#cell].s).toBe("muted")
	end)

	-- Tern cuts the text itself (the DOM holds "charts/shop as tern-tes…"):
	-- rows that differ only in the cut part look the same, and the title is
	-- the only place the whole value is left to read.
	it("gives middle-cut cells their whole value as title", function()
		local node = Table.table(spec())
		local p = node.p :: any
		local name = p.rows[1].cells[col(node, "NAME").id]
		expect(name.text[1].t).toBe("web-1")
		expect(name.title).toBe("web-1")
		expect(p.rows[1].cells[col(node, "NODE").id].title).toBeNil()
	end)

	it("keeps a cell function's own title on a middle-cut cell", function()
		local s = spec()
		s.cell = function(_c: string, _t: Types.ColumnType, value: string): ui.Node
			return ui.text({ ui.span(value) }, { title = "full " .. value })
		end
		local node = Table.table(s)
		expect((node.p :: any).rows[1].cells[col(node, "NAME").id].title).toBe("full web-1")
	end)
end)

describe("native table sort", function()
	it("marks sortable columns and echoes the sort by column id", function()
		local s = spec()
		s.sortable = true
		s.sort = { col = "RESTARTS", dir = "desc" }
		local node = Table.table(s)
		local p = node.p :: any
		expect(col(node, "RESTARTS").sortable).toBe(true)
		expect(p.sort.col).toBe(col(node, "RESTARTS").id)
		expect(p.sort.dir).toBe("desc")
	end)

	it("leaves headers inert when the order is fixed", function()
		local node = Table.table(spec())
		expect(col(node, "NAME").sortable).toBeNil()
		expect((node.p :: any).sort).toBeNil()
	end)

	it("starts counts descending, names ascending", function()
		expect(Table.firstDir("count")).toBe("desc")
		expect(Table.firstDir("quantity")).toBe("desc")
		expect(Table.firstDir("text")).toBe("asc")
		expect(Table.firstDir("timestamp")).toBe("asc")
	end)

	it("sorts typed: counts numerically, AGE youngest first, blanks last", function()
		local list = {
			{ "b", "10", "2026-11-10T10:00:00Z" },
			{ "a", "9", "2026-11-10T11:00:00Z" },
			{ "c", "<none>", "" },
		}
		local types: { Types.ColumnType } = { "text", "count", "timestamp" }
		local function order(i: number, dir: string): string
			local sorted = Table.sorted(list, function(r)
				return r
			end, types, i, dir)
			local out = {}
			for _, r in sorted do
				table.insert(out, r[1])
			end
			return table.concat(out)
		end
		expect(order(2, "desc")).toBe("bac")
		expect(order(2, "asc")).toBe("abc")
		-- AGE ascending: the youngest (latest timestamp) first.
		expect(order(3, "asc")).toBe("abc")
		expect(order(1, "desc")).toBe("cba")
	end)
end)

return nil
