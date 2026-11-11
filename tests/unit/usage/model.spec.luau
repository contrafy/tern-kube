--!strict
-- The usage arithmetic over the golden captures (kind, metrics-server, probe
-- pods with a sidecar, limits only and pod-level resources). The node totals
-- must equal `kubectl describe node` ("Allocated resources": 1715m / 834Mi)
-- except for pod-level resources, which the scheduler counts and kubectl 1.34
-- does not; a pod's limit share is per container, because limits are
-- enforced per container (the sidecar-init app is throttled at 101% of 20m
-- while the pod total reads a harmless 29% of 70m).
local Model = require("../../../plugin/lib/usage/model")
local Parse = require("../../../plugin/lib/usage/parse")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local MI = 1024 * 1024
local NODE = "tern-kube-dev-control-plane"

local pods = Parse.pods(fixtures.read("kubectl/usage/pods-A.tsv"))
local metrics = Parse.podMetrics(fixtures.read("kubectl/usage/podmetrics-A.tsv"))

local function pod(name: string): Parse.Pod
	for _, p in pods do
		if p.name == name then
			return p
		end
	end
	error(name)
end

local function row(rows: { Model.PodRow }, name: string): Model.PodRow
	for _, r in rows do
		if r.name == name then
			return r
		end
	end
	error(name)
end

local function near(a: number?, b: number)
	expect(a ~= nil and math.abs((a :: number) - b) < 1e-6).toBe(true)
end

describe("usage/model requests", function()
	it("a sidecar counts in the running request, a finished init does not", function()
		local r = Model.runningRequest(pod("sidecar-init"))
		near(r.cpu, 0.03)
		expect(r.mem).toBe(24 * MI)
	end)

	it("the scheduler request takes the largest init step (KEP-753)", function()
		local p = pod("sidecar-init")
		local req = Model.effective(p, "req")
		near(req.cpu, 0.5)
		expect(req.mem).toBe(256 * MI)
		local lim = Model.effective(p, "lim")
		near(lim.cpu, 0.07)
		expect(lim.mem).toBe(96 * MI)
	end)

	it("limits only: the API defaulted requests to the limits", function()
		local r = Model.runningRequest(pod("limits-only"))
		near(r.cpu, 0.1)
		near(Model.effective(pod("limits-only"), "lim").cpu, 0.1)
	end)

	it("pod-level resources override the containers", function()
		local p = pod("pod-level")
		near(Model.runningRequest(p).cpu, 0.2)
		expect(Model.effective(p, "req").mem).toBe(64 * MI)
		near(Model.effective(p, "lim").cpu, 0.4)
	end)

	it("node requested equals kubectl describe node, plus the pod-level pod kubectl leaves out", function()
		local c = Model.committed(pods)[NODE]
		near(c.cpu, 1.915)
		expect(c.mem).toBe((834 + 64) * MI)
		local withoutPodLevel: { Parse.Pod } = {}
		for _, p in pods do
			if p.podReq.cpu == nil then
				table.insert(withoutPodLevel, p)
			end
		end
		local k = Model.committed(withoutPodLevel)[NODE]
		near(k.cpu, 1.715)
		expect(k.mem).toBe(834 * MI)
		near(k.limCpu, 0.27)
		expect(k.limMem).toBe(532 * MI)
	end)

	it("terminal pods commit nothing; an unscheduled pod is on no node", function()
		local c = Model.committed(pods)[NODE]
		-- 40 pods: 3 Succeeded, 1 Failed, 1 without a node.
		expect(c.pods).toBe(35)
	end)

	it("a pod missing any request counts as without requests", function()
		expect(Model.hasRequests(pod("coredns-559f6c778d-9b6b7"))).toBe(true)
		expect(Model.hasRequests(pod("kube-apiserver-tern-kube-dev-control-plane"))).toBe(false)
		expect(Model.hasRequests(pod("pod-level"))).toBe(true)
	end)
end)

describe("usage/model limit share", function()
	local rows = Model.podRows(pods, metrics, nil)

	it("is the highest container share of its own limit", function()
		local r = row(rows, "sidecar-init")
		near(r.limCpu.pct, 20137840 / 1e9 / 0.02 * 100)
		expect(Model.tone("limit", r.limCpu.pct)).toBe("error")
		expect(r.limCpu.title).toBe("app at 101% of 20m")
	end)

	it("names the containers without a limit", function()
		local p = pod("tk-fin-web-76f8c4fd78-ntscm")
		local withSidecar = table.clone(p)
		withSidecar.containers = table.clone(p.containers)
		table.insert(withSidecar.containers, { name = "proxy", req = {}, lim = {} })
		local m = Model.metricsByKey(metrics)[Model.podKey(p.namespace, p.name)]
		local share = Model.limitShare(withSidecar, m, "mem")
		expect(share.title).toBe("web at 0.6% of 32Mi; proxy has no limit")
	end)

	it("is nil when no container has a limit", function()
		expect(row(rows, "db-0").limCpu.pct).toBeNil()
	end)

	it("uses the pod-level limit when set", function()
		local r = row(rows, "pod-level")
		expect(r.limMem.pct ~= nil).toBe(true)
		expect(string.find(r.limMem.title or "", "pod-level limit 128Mi", 1, true) ~= nil).toBe(true)
	end)

	it("pods without a metrics window keep nil usage", function()
		local r = row(rows, "crashloop")
		expect(r.metric).toBeNil()
		expect(r.cpu).toBeNil()
		expect(r.reqCpuPct).toBeNil()
	end)

	it("`node` keeps only that node's pods", function()
		expect(#Model.podRows(pods, metrics, NODE)).toBe(39)
		expect(#Model.podRows(pods, metrics, "elsewhere")).toBe(0)
	end)
end)

describe("usage/model totals", function()
	it("counts metrics, near limits and missing requests", function()
		local totals = Model.podTotals(Model.podRows(pods, metrics, nil))
		expect(totals.listed).toBe(40)
		expect(totals.withMetrics).toBe(33)
		expect(totals.nearLimits).toBe(1)
		-- Running pods with some container lacking a CPU or memory request.
		expect(totals.noRequests > 0).toBe(true)
	end)

	it("node rows carry usage of allocatable and committed requests", function()
		local nodes = Parse.nodes(fixtures.read("kubectl/usage/nodes.tsv"))
		local nm = Parse.nodeMetrics(fixtures.read("kubectl/usage/nodemetrics.tsv"))
		local r = Model.nodeRows(nodes, nm, pods)[1]
		near(r.cpuPct, 243265703 / 1e9 / 10 * 100)
		near(r.reqCpu, 1.915)
		expect(r.status).toBe("Ready")
		local without = Model.nodeRows(nodes, nm, nil)[1]
		expect(without.reqCpu).toBeNil()
		local totals = Model.nodeTotals({ r })
		expect(totals.ready).toBe(1)
		expect(totals.allocPods).toBe(110)
		expect(totals.pods).toBe(35)
	end)
end)

describe("usage/model formatting and tones", function()
	it("formats like kubectl top", function()
		expect(Model.cpu(20137840 / 1e9)).toBe("21m")
		expect(Model.cpu(0)).toBe("0m")
		expect(Model.mem(1752628 * 1024)).toBe("1711Mi")
		expect(Model.mem(316 * 1024)).toBe("316Ki")
		expect(Model.cores(10)).toBe("10 cores")
		expect(Model.bytes(8126480 * 1024)).toBe("7.8Gi")
		expect(Model.pct(100.69)).toBe("101%")
		expect(Model.pct(2.43)).toBe("2.4%")
	end)

	it("thresholds: limits 80/95, requests 100, node requested 90/100, limits over 100", function()
		expect(Model.tone("limit", 79)).toBeNil()
		expect(Model.tone("limit", 80)).toBe("warning")
		expect(Model.tone("limit", 95)).toBe("error")
		expect(Model.tone("request", 100)).toBe("warning")
		expect(Model.tone("nodeReq", 90)).toBe("warning")
		expect(Model.tone("nodeReq", 100)).toBe("error")
		expect(Model.tone("nodeLim", 100)).toBeNil()
		expect(Model.tone("nodeLim", 101)).toBe("warning")
		expect(Model.tone("node", nil)).toBeNil()
	end)
end)

describe("usage/model errors", function()
	it("maps a missing metrics API like kubectl top does", function()
		local text, kind =
			Model.metricsError('error: the server doesn\'t have a resource type "pods"', "pods.metrics.k8s.io")
		expect(text).toBe(Model.METRICS_MISSING)
		expect(kind).toBe("metrics")
		expect(
			(
				Model.metricsError(
					"Error from server (ServiceUnavailable): the server is currently unable",
					"nodes.metrics.k8s.io"
				)
			)
		).toBe(Model.METRICS_MISSING)
	end)

	it("keeps kubectl's Forbidden line and names the permission", function()
		local text, kind = Model.metricsError(
			'Error from server (Forbidden): pods.metrics.k8s.io is forbidden: User "u" cannot list resource "pods"\nmore',
			"pods.metrics.k8s.io"
		)
		expect(kind).toBe("forbidden")
		expect(text).toBe(
			'Error from server (Forbidden): pods.metrics.k8s.io is forbidden: User "u" cannot list resource "pods" (needs list on pods.metrics.k8s.io)'
		)
	end)

	it("leaves other failures to the generic message", function()
		expect((Model.metricsError("Unable to connect to the server", "pods.metrics.k8s.io"))).toBeNil()
		expect((Model.metricsError('error: the server doesn\'t have a resource type "pods"', "pods"))).toBeNil()
	end)
end)

return nil
