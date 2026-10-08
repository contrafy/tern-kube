--!strict
-- The table body a user clicks through: chips filter, rows open the right
-- inspector, Inspect shows everything about one row, pages cap rendering,
-- and every click carries the rest of the view state along.
local Capture = require("../../../plugin/lib/lens/capture")
local TableView = require("../../../plugin/lib/render/table_view")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function build(id: string): Capture.Capture
	local f = runs.load(id)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function render(c: Capture.Capture, vs: vsm.ViewState): (any, TableView.Counts)
	local node, counts = TableView.render(c, vs)
	assert(node, "expected a table body")
	return node, counts
end

local function rowNames(node: any): { string }
	local out: { string } = {}
	for _, r in nodes.findAll(node, nodes.class("kl-r")) do
		local first = nodes.find(r, nodes.class("kl-c")) :: any
		table.insert(out, nodes.text(first))
	end
	return out
end

local function decodeAction(a: string): vsm.ViewState?
	if string.sub(a, 1, 2) ~= "v=" then
		return nil
	end
	return vsm.decode(string.sub(a, 3))
end

local function chipAction(node: any, label: string): string
	local chip = nodes.find(node, function(n)
		return n.k == "badge" and string.find(nodes.ownText(n), label, 1, true) == 1
	end)
	assert(chip, "no chip " .. label)
	return nodes.action(chip) :: string
end

describe("table view", function()
	it("renders one grid with every pod and counts", function()
		local node, counts = render(build("ns-apps/get_pods"), vsm.default())
		expect(#nodes.findAll(node, nodes.class("kl-grid"))).toBe(1)
		expect(#rowNames(node)).toBe(7)
		expect(counts).toEqual({ shown = 7, matched = 7, total = 7 })
	end)

	it("get all stacks one grid per kind under kind headings", function()
		local node = render(build("ns-apps/get_all"), vsm.default())
		expect(#nodes.findAll(node, nodes.class("kl-grid"))).toBe(6)
		local headings = nodes.findAll(node, nodes.role("kube-lens.kind"))
		expect(#headings).toBe(6)
		expect(string.find(nodes.text(headings[4]), "Deployment", 1, true) ~= nil).toBe(true)
	end)

	it("offers STATUS chips with counts and a Problems chip", function()
		local node = render(build("ns-apps/get_pods"), vsm.default())
		local action = chipAction(node, "Running ")
		local vs = decodeAction(action) :: vsm.ViewState
		expect(vs.filters).toEqual({ "STATUS=Running" })
		local problems = decodeAction(chipAction(node, "Problems 3")) :: vsm.ViewState
		expect(problems.problems).toBe(true)
	end)

	it("offers KIND chips only when several kinds are shown, NAMESPACE only when several", function()
		local all = render(build("ns-apps/get_all"), vsm.default())
		expect(nodes.find(all, nodes.key("facet-KIND")) ~= nil).toBe(true)
		expect(nodes.find(all, nodes.key("facet-NAMESPACE"))).toBeNil()
		local pods = render(build("ns-apps/get_pods"), vsm.default())
		expect(nodes.find(pods, nodes.key("facet-KIND"))).toBeNil()
		local allNs = render(build("all-namespaces/get_pods_-A"), vsm.default())
		expect(nodes.find(allNs, nodes.key("facet-NAMESPACE")) ~= nil).toBe(true)
	end)

	it("filtering keeps only matching rows and keeps the open row open", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.toggledFilter(vsm.opened(vsm.default(), "/Pod/tern-test-apps/db-0"), "STATUS", "Running")
		local node, counts = render(c, vs)
		for _, n in rowNames(node) do
			expect(n == "pending" or n == "crashloop").toBe(false)
		end
		expect(counts.matched < counts.total).toBe(true)
		expect(nodes.text(nodes.find(node, nodes.class("kl-open")) :: any)).toContain("db-0")
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
		expect(nodes.text(insp)).toContain("db-0")
	end)

	it("a filtered-out open row shows no inspector rather than another row's", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.toggledFilter(vsm.opened(vsm.default(), "/Pod/tern-test-apps/pending"), "STATUS", "Running")
		local node = render(c, vs)
		expect(nodes.find(node, nodes.role("kube-lens.inspector"))).toBeNil()
	end)

	it("the inspector shows the clicked row's cells and target-aware actions", function()
		local c = build("ns-apps/get_pods")
		local node = render(c, vsm.opened(vsm.default(), "/Pod/tern-test-apps/crashloop"))
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
		local text = nodes.text(insp)
		expect(text).toContain("crashloop")
		expect(text).toContain("RESTARTS")
		local actions = nodes.actions(insp)
		expect(table.find(actions, "explore=/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
		expect(table.find(actions, "copy=logs|/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
		expect(table.find(actions, "copy=describe|/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
	end)

	it("non-pod rows offer no logs copy", function()
		local c = build("ns-apps/get_deployments")
		local node = render(c, vsm.opened(vsm.default(), "apps/Deployment/tern-test-apps/web"))
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
		expect(table.find(nodes.actions(insp), "copy=logs|apps/Deployment/tern-test-apps/web")).toBeNil()
	end)

	it("every grid and inspector action carries sort, filters and selection along", function()
		local c = build("ns-apps/get_pods")
		local base = vsm.toggledFilter(vsm.sortedBy(vsm.default(), "AGE"), "STATUS", "Running")
		base = vsm.opened(base, "/Pod/tern-test-apps/db-0")
		local node = render(c, base)
		local checked = 0
		for _, region in nodes.findAll(node, nodes.class("kl-grid")) do
			for _, a in nodes.actions(region) do
				local vs = decodeAction(a)
				if vs then
					checked += 1
					expect(vs.filters).toEqual({ "STATUS=Running" })
					expect(vs.sort ~= nil).toBe(true)
				end
			end
		end
		expect(checked > 10).toBe(true)
		local rowVs = decodeAction(nodes.action(nodes.findAll(node, nodes.class("kl-r"))[1]) :: string) :: vsm.ViewState
		expect(rowVs.sort).toBe("AGE")
		local closeVs = decodeAction(chipAction(node, "Close")) :: vsm.ViewState
		expect(closeVs.open).toBeNil()
		expect(closeVs.sort).toBe("AGE")
		expect(closeVs.filters).toEqual({ "STATUS=Running" })
	end)

	it("Inspect opens a full view with breadcrumb, all cells, source line and Back", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.inspect(vsm.default(), "/Pod/tern-test-apps/db-0")
		local node = render(c, vs)
		expect(nodes.find(node, nodes.class("kl-grid"))).toBeNil()
		local crumbs = nodes.text(nodes.find(node, nodes.role("kube-lens.breadcrumb")) :: any)
		expect(crumbs).toBe("Snapshot › Pod › db-0")
		local code = nodes.find(node, nodes.kind("code")) :: any
		expect(string.sub(code.p.text, 1, 4)).toBe("db-0")
		local back = decodeAction(chipAction(node, "Back")) :: vsm.ViewState
		expect(back.full).toBe(false)
		expect(back.open).toBe("/Pod/tern-test-apps/db-0")
	end)

	it("Inspect of a -o json row shows the object tree", function()
		local c = build("ns-apps/get_pods_-o_json")
		local node = render(c, vsm.inspect(vsm.default(), "/Pod/tern-test-apps/db-0"))
		expect(nodes.find(node, nodes.kind("tree")) ~= nil).toBe(true)
	end)

	it("pages 1000 rows by 500 with page chips", function()
		local c = build("synthetic/rows-1000/get_pods")
		local node, counts = render(c, vsm.default())
		expect(counts).toEqual({ shown = 500, matched = 1000, total = 1000 })
		expect(#nodes.findAll(node, nodes.class("kl-r"))).toBe(500)
		local second = decodeAction(chipAction(node, "501-1000")) :: vsm.ViewState
		expect(second.page).toBe(1)
		local node2, counts2 = render(c, second)
		expect(counts2.shown).toBe(500)
		local page1: { [string]: boolean } = {}
		for _, n in rowNames(node) do
			page1[n] = true
		end
		for _, n in rowNames(node2) do
			expect(page1[n]).toBeNil()
		end
		expect(nodes.text(nodes.find(node2, nodes.role("kube-lens.pages")) :: any)).toContain("Rows 501-1000 of 1000")
	end)

	it("a page past the end shows the last page", function()
		local c = build("synthetic/rows-1000/get_pods")
		local _, counts = render(c, vsm.paged(vsm.default(), 9))
		expect(counts.shown).toBe(500)
	end)

	it("returns nil when there is no table (error-only output)", function()
		local node = TableView.render(build("errors/get_foos"), vsm.default())
		expect(node).toBeNil()
	end)
end)

return nil
