--!strict
-- What the lens block shows for each kind of run: native view with a
-- snapshot header, or nil so Tern shows the raw output.
local Capture = require("../../../plugin/lib/lens/capture")
local View = require("../../../plugin/lib/lens/view")
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

local function fromLines(command: string, lines: { string }, status: number?): Capture.Capture
	return Capture.build(runs.run(command), lines, status, { decode = json.decode })
end

local function header(node: any): any
	return nodes.find(node, nodes.role("kube-lens.header"))
end

describe("lens view", function()
	it("unsupported commands render nil (raw), whatever their output", function()
		expect(View.render(fromLines("kubectl get pods -w", { "NAME   READY", "a      1/1" }, 130), vsm.default())).toBeNil()
		expect(View.render(fromLines("kubectl get pods -o jsonpath={.x}", { "a b" }, 0), vsm.default())).toBeNil()
		-- Over-claimed by `kubectl -* get *`: logs output stays raw.
		expect(View.render(fromLines("kubectl -n x logs pod get", { "hello" }, 0), vsm.default())).toBeNil()
	end)

	it("empty output renders nil", function()
		expect(View.render(fromLines("kubectl get secrets", {}, 0), vsm.default())).toBeNil()
	end)

	it("every native mode gets the snapshot header", function()
		for _, id in
			{
				"ns-apps/get_pods",
				"ns-apps/get_pods_-o_json",
				"ns-apps/get_pods_-o_name",
				"ns-apps/get_pods_-o_yaml",
				"ns-apps/describe_pod_crashloop",
				"mutate-ops/scale_deployment+api_--replicas=3",
				"cluster/top_nodes",
			}
		do
			local node = View.render(build(id), vsm.default())
			assert(node, id .. " rendered nil")
			local h = header(node)
			expect(h ~= nil).toBe(true)
			expect(nodes.text(h)).toContain("Snapshot")
		end
	end)

	it("header names the command, target and counts", function()
		local node = View.render(build("ns-apps/get_pods"), vsm.default()) :: any
		local text = nodes.text(header(node))
		expect(text).toContain("kubectl get pods")
		expect(text).toContain("ns: tern-test-apps")
		expect(text).toContain("context: current context at run time")
		expect(text).toContain("7 rows")
		local allNs = nodes.text(header(View.render(build("all-namespaces/get_pods_-A"), vsm.default())))
		expect(allNs).toContain("ns: all")
	end)

	it("header shows the explicit context and filtered counts", function()
		local c = fromLines(
			"kubectl --context prod get pods",
			{ "NAME   READY   STATUS", "a      1/1     Running", "b      0/1     Pending" },
			0
		)
		local vs = vsm.toggledFilter(vsm.sortedBy(vsm.default(), "NAME"), "STATUS", "Running")
		local text = nodes.text(header(View.render(c, vs)))
		expect(text).toContain("context: prod")
		expect(text).toContain("1 of 2 rows")
		expect(text).toContain("sorted by NAME")
	end)

	it("error-only output shows the kubectl error and exit status natively", function()
		local node = View.render(build("errors/get_foos"), vsm.default()) :: any
		expect(node ~= nil).toBe(true)
		expect(nodes.find(node, nodes.role("kube-lens.exit")) ~= nil).toBe(true)
		local diag = nodes.find(node, nodes.role("kube-lens.diagnostics")) :: any
		expect(nodes.text(diag)).toContain("the server doesn't have a resource type")
		expect(diag.p.collapsed).toBe(false)
	end)

	it("missing context error shows natively too", function()
		local node = View.render(build("errors-context/get_pods"), vsm.default()) :: any
		expect(nodes.text(node)).toContain("does-not-exist")
	end)

	it("No resources found reads as a note, not an error", function()
		local node = View.render(build("ns-empty/get_pods"), vsm.default()) :: any
		expect(nodes.text(node)).toContain("No resources found")
		expect(nodes.find(node, nodes.role("kube-lens.exit"))).toBeNil()
		expect(nodes.find(node, nodes.role("kube-lens.diagnostics"))).toBeNil()
	end)

	it("partial captures say how many lines were not understood", function()
		local c = fromLines("kubectl get pods", { "NAME   READY", "a      1/1", "   stray  text  here" }, 0)
		local node = View.render(c, vsm.default()) :: any
		expect(nodes.text(nodes.find(node, nodes.role("kube-lens.partial")) :: any)).toBe("partial: 1 unparsed line")
	end)

	it("warns when raw output holds Secret data", function()
		local text = [[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s","namespace":"n"},"data":{"k":"dg=="}}]]
		local node = View.render(fromLines("kubectl get secret s -n n -o json", { text }, 0), vsm.default()) :: any
		expect(nodes.find(node, nodes.role("kube-lens.sensitive")) ~= nil).toBe(true)
	end)

	it("the ? chip toggles the cheat sheet and keeps the rest of the state", function()
		local vs = vsm.sortedBy(vsm.default(), "AGE")
		local node = View.render(build("ns-apps/get_pods"), vs) :: any
		expect(nodes.find(node, nodes.role("kube-lens.help"))).toBeNil()
		local chip = nodes.find(node, nodes.key("help-chip")) :: any
		local next = vsm.decode(string.sub(nodes.action(chip) :: string, 3))
		expect(next.help).toBe(true)
		expect(next.sort).toBe("AGE")
		local withHelp = View.render(build("ns-apps/get_pods"), next) :: any
		expect(nodes.text(nodes.find(withHelp, nodes.role("kube-lens.help")) :: any)).toContain("Click a column header")
	end)
end)

return nil
