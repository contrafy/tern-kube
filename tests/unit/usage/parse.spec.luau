--!strict
-- The usage views read four constant jsonpath templates (golden captures from
-- the kind cluster with metrics-server). The parsers must keep "not set" apart
-- from zero (a missing request is `<none>`, never 0m), accept the metrics
-- API's bare `0` CPU, and not care about container order, which changes
-- between reads.
local Parse = require("../../../plugin/lib/usage/parse")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function find<T>(list: { T }, ns: string?, name: string): T
	for _, x in list do
		local r = x :: any
		if r.name == name and (ns == nil or r.namespace == ns) then
			return x
		end
	end
	error("not found: " .. name)
end

describe("usage/parse templates", function()
	it("are the jsonpath captured against the kind cluster, with no place for user text", function()
		local golden: { [string]: string } =
			{ POD_JP = Parse.POD_JP, PODM_JP = Parse.PODM_JP, NODE_JP = Parse.NODE_JP, NODEM_JP = Parse.NODEM_JP }
		for name, tpl in golden do
			local want = (string.gsub(fixtures.read("kubectl/usage/" .. name .. ".txt"), "\n$", ""))
			expect(tpl).toBe(want)
		end
	end)
end)

describe("usage/parse pods", function()
	local pods = Parse.pods(fixtures.read("kubectl/usage/pods-A.tsv"))

	it("reads every pod line", function()
		expect(#pods).toBe(40)
	end)

	it("keeps missing requests nil, not zero", function()
		local p = find(pods, "kube-system", "kube-proxy-8mdp2")
		expect(p.containers[1].name).toBe("kube-proxy")
		expect(p.containers[1].req.cpu).toBeNil()
		expect(p.containers[1].lim.mem).toBeNil()
	end)

	it("reads container requests and limits in base units", function()
		local p = find(pods, "kube-system", "coredns-559f6c778d-9b6b7")
		expect(p.node).toBe("tern-kube-dev-control-plane")
		expect(p.phase).toBe("Running")
		expect(p.containers[1].req.cpu).toBe(0.1)
		expect(p.containers[1].req.mem).toBe(70 * 1024 * 1024)
		expect(p.containers[1].lim.mem).toBe(170 * 1024 * 1024)
	end)

	it("reads pod-level resources and init containers with their restart policy", function()
		local pl = find(pods, nil, "pod-level")
		expect(pl.podReq.cpu).toBe(0.2)
		expect(pl.podLim.mem).toBe(128 * 1024 * 1024)
		local si = find(pods, nil, "sidecar-init")
		expect(#si.inits).toBe(2)
		expect(si.inits[1].name).toBe("setup")
		expect(si.inits[1].sidecar).toBe(false)
		expect(si.inits[2].name).toBe("proxy")
		expect(si.inits[2].sidecar).toBe(true)
		expect(si.inits[2].lim.cpu).toBe(0.05)
	end)

	it("an unscheduled pod has no node", function()
		expect(find(pods, nil, "pending").node).toBeNil()
	end)

	it("empty output is no pods", function()
		expect(#Parse.pods("")).toBe(0)
		expect(#Parse.pods("\n")).toBe(0)
	end)
end)

describe("usage/parse pod metrics", function()
	local m = Parse.podMetrics(fixtures.read("kubectl/usage/podmetrics-A.tsv"))

	it("sums containers and keeps the window time", function()
		local si = find(m, nil, "sidecar-init")
		expect(si.cpu).toBe(20137840 / 1e9)
		expect(si.mem).toBe(632 * 1024)
		expect(si.t).toBe(Parse.time("2026-11-11T16:13:35Z"))
		expect(si.window).toBe("19.762s")
	end)

	it("accepts a bare 0 CPU", function()
		local db = find(m, nil, "db-0")
		expect(db.cpu).toBe(0)
		expect(db.containers[1].cpu).toBe(0)
	end)

	it("container order does not change the totals", function()
		local a = Parse.podMetrics("ns\tp\t2026-11-11T16:06:08Z\t14s\tapp=20041204n,316Ki;proxy=0,312Ki;\n")[1]
		local b = Parse.podMetrics("ns\tp\t2026-11-11T16:06:08Z\t14s\tproxy=0,312Ki;app=20041204n,316Ki;\n")[1]
		expect(a.cpu).toBe(b.cpu)
		expect(a.mem).toBe(b.mem)
		expect((Parse.container(a, "app") :: Parse.Usage).cpu).toBe((Parse.container(b, "app") :: Parse.Usage).cpu)
	end)

	it("a malformed usage value is nil, not 0", function()
		local p = Parse.podMetrics("ns\tp\t\t\tapp=,;\n")[1]
		expect(p.t).toBeNil()
		expect(p.containers[1].cpu).toBeNil()
		expect(p.cpu).toBeNil()
	end)
end)

describe("usage/parse nodes", function()
	it("reads allocatable, capacity, schedulability and Ready", function()
		local n = Parse.nodes(fixtures.read("kubectl/usage/nodes.tsv"))[1]
		expect(n.name).toBe("tern-kube-dev-control-plane")
		expect(n.alloc.cpu).toBe(10)
		expect(n.alloc.mem).toBe(8126480 * 1024)
		expect(n.alloc.pods).toBe(110)
		expect(n.unschedulable).toBe(false)
		expect(n.ready).toBe("True")
	end)

	it("reads a cordoned NotReady node", function()
		local n = Parse.nodes("n1\t4,16Gi,110\t4,16Gi\ttrue\tFalse\n")[1]
		expect(n.unschedulable).toBe(true)
		expect(n.ready).toBe("False")
	end)

	it("reads node metrics", function()
		local m = Parse.nodeMetrics(fixtures.read("kubectl/usage/nodemetrics.tsv"))[1]
		expect(m.cpu).toBe(243265703 / 1e9)
		expect(m.mem).toBe(1752628 * 1024)
		expect(m.t).toBe(Parse.time("2026-11-11T16:13:40Z"))
	end)
end)

return nil
