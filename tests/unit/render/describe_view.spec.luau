--!strict
local DescribeView = require("../../../plugin/lib/render/describe_view")
local Viewstate = require("../../../plugin/lib/lens/viewstate")
local captures = require("../../lib/captures")
local fixtures = require("../../lib/fixtures")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Node = nodes.Node

local function render(path: string, command: string): Node
	return DescribeView.render(captures.build(path, command), Viewstate.default(), Viewstate)
end

local function section(root: Node, head: string): Node
	local found = nodes.find(root, function(n)
		return n.k == "section" and string.sub(nodes.ownText(n), 1, #head) == head
	end)
	assert(found, "no section headed " .. head)
	return found
end

local function cards(root: Node): { Node }
	return nodes.findAll(root, nodes.kind("card"))
end

-- Cell spans of a `table` node, keyed by header text.
local function tableRows(tbl: Node): { { [string]: { t: string, s: string? } } }
	local p = tbl.p :: { [string]: any }
	local heads: { [string]: string } = {}
	for _, col in p.cols do
		heads[col.id] = col.head
	end
	local out = {}
	for _, row in p.rows do
		local cells = {}
		for id, spans in row.cells do
			cells[heads[id]] = spans[1]
		end
		table.insert(out, cells)
	end
	return out
end

local function firstTable(root: Node): Node
	return nodes.find(root, nodes.kind("table")) :: Node
end

describe("describe view: crashloop pod", function()
	local view = render("real/ns-apps/describe_pod_crashloop", "kubectl describe pod crashloop -n tern-test-apps")

	it("shows one card titled with kind, name and namespace", function()
		local list = cards(view)
		expect(#list).toBe(1)
		local head = nodes.spansText((list[1].p :: any).head)
		expect(head).toContain("Pod")
		expect(head).toContain("crashloop")
		expect(head).toContain("tern-test-apps")
	end)

	it("keeps containers expanded but folds deeper detail like the command line", function()
		expect((section(view, "Containers").p :: any).collapsed).toBe(false)
		-- The container itself sits under Containers and stays open.
		expect((section(view, "app").p :: any).collapsed).toBe(false)
		expect((section(view, "Command").p :: any).collapsed).toBe(true)
		-- A collapsed block with a value still shows that value in its head.
		local state = section(view, "Last State")
		expect(nodes.ownText(state)).toContain("Terminated")
	end)

	it("flags restarts and a failed last state", function()
		local found = false
		for _, kv in nodes.findAll(view, nodes.kind("kv")) do
			for _, item in (kv.p :: any).items do
				if item.k[1].t == "Restart Count" then
					found = true
					expect(tonumber(item.v[1].t) > 0).toBe(true)
					expect(item.v[1].s).toContain("warning")
				end
				if item.k[1].t == "Reason" and item.v[1].t == "Error" then
					expect(item.v[1].s).toContain("error")
				end
			end
		end
		expect(found).toBe(true)
	end)

	it("renders Events as a timeline with Warning rows toned and Normal rows plain", function()
		local events = section(view, "Events")
		expect(nodes.ownText(events)).toContain("Warning")
		local rows = tableRows(firstTable(events))
		local sawWarning, sawNormal = false, false
		for _, row in rows do
			if row.Type.t == "Warning" then
				sawWarning = true
				expect(row.Reason.s).toBe("warning")
				expect(row.Message.s).toBe("warning")
			else
				sawNormal = true
				expect(row.Reason.s).toBeNil()
			end
		end
		expect(sawWarning and sawNormal).toBe(true)
	end)

	it("colours pod conditions by meaning", function()
		local rows = tableRows(firstTable(section(view, "Conditions")))
		expect(#rows > 0).toBe(true)
		for _, row in rows do
			if row.Status.t == "True" then
				expect(row.Status.s).toContain("success")
			end
		end
	end)
end)

describe("describe view: other kinds", function()
	it("shows `Events: <none>` as muted text rather than an empty table", function()
		local view = render("real/ns-apps/describe_svc_web", "kubectl describe svc web -n tern-test-apps")
		local events = nodes.find(view, nodes.hasText("Events:")) :: Node
		expect(events.k).toBe("text")
		expect(nodes.tones(events)).toContain("muted")
		expect(nodes.ownText(events)).toContain("<none>")
		expect(nodes.find(view, nodes.kind("table"))).toBeNil()
		expect(nodes.text(view)).toContain("Session Affinity")
	end)

	it("shows a deployment's pod template with its containers open and its conditions", function()
		local view = render("real/ns-apps/describe_deployment_web", "kubectl describe deployment web -n tern-test-apps")
		expect(nodes.spansText((cards(view)[1].p :: any).head)).toContain("Deployment")
		local template = section(view, "Pod Template")
		expect((template.p :: any).collapsed).toBe(false)
		expect((section(template, "Containers").p :: any).collapsed).toBe(false)
		local rows = tableRows(firstTable(section(view, "Conditions")))
		expect(rows[1].Type.t).toBe("Available")
		expect(rows[1].Status.s).toContain("success")
		expect(nodes.text(view)).toContain("2 desired")
	end)

	it("reads node pressure conditions the right way round", function()
		local view = render("real/cluster/describe_node", "kubectl describe node")
		local rows = tableRows(firstTable(section(view, "Conditions")))
		local byType = {}
		for _, row in rows do
			byType[row.Type.t] = row.Status
		end
		-- MemoryPressure=False is healthy; Ready=True is healthy.
		expect(byType.MemoryPressure.t).toBe("False")
		expect(byType.MemoryPressure.s).toContain("success")
		expect(byType.Ready.s).toContain("success")
	end)

	it("lists every non-terminated pod of a node in a table", function()
		local view = render("real/cluster/describe_node", "kubectl describe node")
		local pods = section(view, "Non-terminated Pods")
		local expected = string.match(nodes.ownText(pods), "%((%d+) in total%)")
		expect(#tableRows(firstTable(pods))).toBe(tonumber(expected))
	end)

	it("renders a node in under 20 ms", function()
		local capture = captures.build("real/cluster/describe_node", "kubectl describe node")
		local runs = 20
		local start = os.clock()
		for _ = 1, runs do
			DescribeView.render(capture, Viewstate.default(), Viewstate)
		end
		local ms = (os.clock() - start) * 1000 / runs
		expect(ms < 20).toBe(true)
	end)
end)

describe("describe view: several objects and errors", function()
	it("gives each object its own card and folds all but the first when there are many", function()
		local view = render("real/ns-apps/describe_pods", "kubectl describe pods -n tern-test-apps")
		local objects = 0
		for _, line in fixtures.lines("real/ns-apps/describe_pods.txt") do
			if string.sub(line, 1, 5) == "Name:" then
				objects += 1
			end
		end
		local list = cards(view)
		expect(#list).toBe(objects)
		expect(objects > DescribeView.EXPANDED_OBJECTS).toBe(true)
		expect((list[1].p :: any).collapsed).toBe(false)
		for i = 2, #list do
			expect((list[i].p :: any).collapsed).toBe(true)
		end
		-- Tern keeps toggle state by key, so keys must be unique per view.
		local seen: { [string]: boolean } = {}
		nodes.walk(view, function(n)
			local key = n.p and n.p.key
			if key then
				expect(seen[key]).toBeNil()
				seen[key] = true
			end
		end)
	end)

	it("puts kubectl's NotFound error up front instead of an empty view", function()
		local view =
			render("real/errors/describe_pod_does-not-exist", "kubectl describe pod does-not-exist -n tern-test-apps")
		local err = nodes.find(view, nodes.role("kube-lens.error")) :: Node
		expect((err.p :: any).tone).toBe("error")
		expect(nodes.text(err)).toContain('pods "does-not-exist" not found')
		expect(#cards(view)).toBe(1)
	end)
end)

return nil
