--!strict
-- The usage tables are built once per load: cells stay text so the list
-- machinery sorts and filters them, tones and titles ride along as prebuilt
-- Tern cells, and the trend cells are added only for rows on screen. A row
-- without metrics must say why rather than show 0.
local Model = require("../../../plugin/lib/usage/model")
local Parse = require("../../../plugin/lib/usage/parse")
local Series = require("../../../plugin/lib/usage/series")
local View = require("../../../plugin/lib/usage/view")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local pods = Parse.pods(fixtures.read("kubectl/usage/pods-A.tsv"))
local metrics = Parse.podMetrics(fixtures.read("kubectl/usage/podmetrics-A.tsv"))
local rows = Model.podRows(pods, metrics, nil)

local function urow(b: View.Built, key: string): View.URow
	for _, r in b.rows do
		if r.key == key then
			return r
		end
	end
	error(key)
end

local function tileValue(b: View.Built, label: string): string
	for _, tl in b.tiles do
		if tl.label[1].t == label then
			return tl.value[1].t
		end
	end
	error(label)
end

describe("usage/view pods", function()
	local b = View.pods(rows, { context = "kind-tern-kube-dev", metricsError = nil, metricsRead = true })

	it("lists the columns in priority order, trends unsortable", function()
		expect(b.headers).toEqual({
			"NAMESPACE",
			"NAME",
			"CPU",
			"MEM",
			"%CPU/L",
			"%MEM/L",
			"%CPU/R",
			"%MEM/R",
			"CPU~",
			"MEM~",
			"NODE",
		})
		expect(b.unsortable["CPU~"]).toBe(true)
		expect(b.unsortable.CPU).toBeNil()
	end)

	it("a hot pod's limit share is error-toned with its container named", function()
		local r = urow(b, "tern-test-x-d12usage/sidecar-init")
		expect(r.cells[3]).toBe("21m")
		expect(r.cells[5]).toBe("101%")
		expect(r.raw[5].text[1].s).toBe("error mono")
		expect(string.find(r.raw[5].title, "app at 101% of 20m", 1, true) ~= nil).toBe(true)
		expect(r.ref and r.ref.kind).toBe("Pod")
		expect(r.ref and r.ref.namespace).toBe("tern-test-x-d12usage")
	end)

	it("a pod without a metrics window says so instead of 0", function()
		local r = urow(b, "tern-test-apps/crashloop")
		expect(r.cells[3]).toBe(View.NO_METRICS)
		expect(r.raw[3].title).toBe(View.NO_METRICS_TITLE)
	end)

	it("no request or limit is <none>", function()
		local r = urow(b, "tern-test-apps/db-0")
		expect(r.cells[5]).toBe(View.NONE)
		expect(r.cells[7]).toBe(View.NONE)
	end)

	it("tiles count pods with metrics and pods near their limits", function()
		expect(tileValue(b, "Pods")).toBe("33 / 40")
		expect(tileValue(b, "Near limits")).toBe("1")
	end)

	it("a metrics error is a note, the rows stay", function()
		local e = View.pods(
			Model.podRows(pods, {}, nil),
			{ context = nil, metricsError = Model.METRICS_MISSING, metricsRead = false }
		)
		expect(e.notes).toEqual({ Model.METRICS_MISSING })
		expect(#e.rows).toBe(40)
		local empty = View.pods(Model.podRows(pods, {}, nil), { context = nil, metricsError = nil, metricsRead = true })
		expect(empty.notes).toEqual({ Model.NO_WINDOW })
	end)
end)

describe("usage/view trends", function()
	local b = View.pods(rows, { context = nil, metricsError = nil, metricsRead = true })
	local r = urow(b, "tern-test-x-d12usage/sidecar-init")
	local clock = function(at: number): string
		return tostring(at)
	end

	it("one sample is a muted dot that says how to get more", function()
		local store = (Series.add(Series.new(), View.podSamples(metrics)))
		local raw = View.withTrends(b, r, { store = store, clock = clock, off = false })
		expect(raw[9].text[1].t).toBe(View.ONE_SAMPLE)
		expect(raw[9].title).toBe(Series.ONE_SAMPLE)
	end)

	it("two samples draw a spark against the pod's limit", function()
		local later = Parse.podMetrics(
			"tern-test-x-d12usage\tsidecar-init\t2026-11-11T16:13:50Z\t15s\tapp=19000000n,316Ki;proxy=0,316Ki;\n"
		)
		local store = (Series.add(Series.new(), View.podSamples(metrics)))
		store = (Series.add(store, View.podSamples(later)))
		local raw = View.withTrends(b, r, { store = store, clock = clock, off = false })
		expect(#raw[9].spark.values).toBe(2)
		expect(raw[9].spark.max).toBe(0.07)
		expect(raw[10].spark ~= nil).toBe(true)
		expect(r.raw[9]).toBeNil()
	end)

	it("trends off adds no cells", function()
		local raw = View.withTrends(b, r, { store = Series.new(), clock = clock, off = true })
		expect(raw[9]).toBeNil()
	end)
end)

describe("usage/view containers and nodes", function()
	it("names sidecars and finished init containers", function()
		local si: Model.PodRow? = nil
		for _, x in rows do
			if x.name == "sidecar-init" then
				si = x
			end
		end
		local b = View.containers(si :: Model.PodRow, nil, nil)
		local kinds: { string } = {}
		for _, x in b.rows do
			table.insert(kinds, x.cells[1] .. ":" .. x.cells[2])
		end
		expect(kinds).toEqual({ "app:container", "setup:init (done)", "proxy:sidecar" })
		expect(b.headers[1]).toBe("CONTAINER")
	end)

	it("pod-level resources are a note on the pod", function()
		local pl: Model.PodRow? = nil
		for _, x in rows do
			if x.name == "pod-level" then
				pl = x
			end
		end
		local b = View.containers(pl :: Model.PodRow, nil, nil)
		expect(b.notes[1]).toBe("pod-level requests 200m / 64Mi, limits 400m / 128Mi apply to the pod as a whole")
	end)

	it("nodes show requested of allocatable, <forbidden> when pods cannot be read", function()
		local nodes = Parse.nodes(fixtures.read("kubectl/usage/nodes.tsv"))
		local nm = Parse.nodeMetrics(fixtures.read("kubectl/usage/nodemetrics.tsv"))
		local b = View.nodes(
			Model.nodeRows(nodes, nm, pods),
			nil,
			{ metricsError = nil, podsError = nil, podsForbidden = false }
		)
		local r = b.rows[1]
		expect(r.cells[5]).toBe("19%")
		expect(r.cells[9]).toBe("35/110")
		expect(tileValue(b, "Nodes")).toBe("1 / 1")
		expect(tileValue(b, "Pods")).toBe("35 / 110")
		local f = View.nodes(
			Model.nodeRows(nodes, nm, nil),
			nil,
			{ metricsError = nil, podsError = "denied", podsForbidden = true }
		)
		expect(f.rows[1].cells[5]).toBe(View.FORBIDDEN)
		expect(f.notes).toEqual({ "denied" })
	end)
end)

return nil
