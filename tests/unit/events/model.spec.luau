--!strict
-- Events arrive in two JSON generations (legacy counts vs series) and four
-- table layouts; the timeline and the lens must see one shape regardless, so
-- every normalisation rule is pinned here with the exact kubectl spellings.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Model = require("../../../plugin/lib/events/model")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local LEGACY = [[{
  "apiVersion": "v1", "kind": "EventList", "items": [{
    "kind": "Event", "apiVersion": "v1",
    "metadata": {"name": "crashloop.18e3", "namespace": "tern-test-apps", "uid": "u-legacy", "creationTimestamp": "2026-10-30T22:40:00Z"},
    "involvedObject": {"kind": "Pod", "namespace": "tern-test-apps", "name": "crashloop", "uid": "pod-uid", "apiVersion": "v1", "fieldPath": "spec.containers{app}"},
    "reason": "BackOff", "message": "Back-off restarting failed container",
    "source": {"component": "kubelet", "host": "node-1"},
    "firstTimestamp": "2026-10-30T22:41:00Z", "lastTimestamp": "2026-11-02T02:00:00Z",
    "count": 115, "type": "Warning", "eventTime": null, "reportingComponent": "kubelet"
  }]
}]]

local SERIES = [[{
  "apiVersion": "v1", "kind": "List", "items": [{
    "kind": "Event", "apiVersion": "v1",
    "metadata": {"name": "pending.18e3", "namespace": "tern-test-apps", "uid": "u-series", "creationTimestamp": "2026-10-30T22:41:32Z"},
    "involvedObject": {"kind": "Pod", "namespace": "tern-test-apps", "name": "pending", "uid": "p2", "apiVersion": "v1"},
    "reason": "FailedScheduling", "message": "0/1 nodes are available",
    "source": {}, "firstTimestamp": null, "lastTimestamp": null, "count": null, "type": "Warning",
    "eventTime": "2026-10-30T22:41:32.260930Z",
    "series": {"count": 6, "lastObservedTime": "2026-11-02T02:22:32.241787Z"},
    "reportingComponent": "default-scheduler"
  }, {
    "kind": "Event", "apiVersion": "v1",
    "metadata": {"name": "job.1", "namespace": "tern-test-batch", "uid": "u-once", "creationTimestamp": "2026-11-02T16:14:08Z"},
    "involvedObject": {"kind": "Pod", "namespace": "tern-test-batch", "name": "job-pod", "apiVersion": "v1"},
    "reason": "Scheduled", "message": "Successfully assigned", "source": {}, "type": "Normal",
    "eventTime": "2026-11-02T16:14:08.090640Z", "reportingComponent": "default-scheduler"
  }]
}]]

local K8S_IO = [[{
  "apiVersion": "events.k8s.io/v1", "kind": "EventList", "items": [{
    "metadata": {"name": "web.1", "namespace": "tern-test-apps", "uid": "u-new"},
    "regarding": {"kind": "Deployment", "namespace": "tern-test-apps", "name": "web", "uid": "d1", "apiVersion": "apps/v1"},
    "related": {"kind": "ReplicaSet", "namespace": "tern-test-apps", "name": "web-abc", "apiVersion": "apps/v1"},
    "note": "Scaled up replica set web-abc from 0 to 2", "reason": "ScalingReplicaSet", "type": "Normal",
    "deprecatedCount": 3, "deprecatedFirstTimestamp": "2026-11-01T10:00:00Z", "deprecatedLastTimestamp": "2026-11-01T11:00:00Z",
    "deprecatedSource": {"component": "deployment-controller"},
    "reportingController": "deployment-controller"
  }, {
    "metadata": {"name": "web.2", "namespace": "tern-test-apps"},
    "regarding": {"kind": "Deployment", "namespace": "tern-test-apps", "name": "web", "apiVersion": "apps/v1"},
    "note": "series", "reason": "ScalingReplicaSet", "type": "Normal",
    "eventTime": "2026-11-01T12:00:00.000001Z",
    "series": {"count": 4, "lastObservedTime": "2026-11-01T12:30:00Z"},
    "reportingController": "deployment-controller"
  }]
}]]

local function inv(line: string): any
	local words = string.split(line, " ")
	local program = table.remove(words, 1) :: string
	return Argv.parse(program, words)
end

describe("events model fromList", function()
	it("keeps legacy count and first/last timestamps, because kubectl events shows them as x115 over 2d", function()
		local e = Model.fromList(json.decode(LEGACY))[1]
		expect(e.key).toBe("u-legacy")
		expect(e.count).toBe(115)
		expect(e.first).toBe("2026-10-30T22:41:00Z")
		expect(e.last).toBe("2026-11-02T02:00:00Z")
		expect(e.series).toBe(false)
		expect(e.type).toBe("Warning")
		expect(e.reason).toBe("BackOff")
		expect(e.namespace).toBe("tern-test-apps")
	end)

	it("joins source component and host like `get events -o wide` SOURCE", function()
		expect(Model.fromList(json.decode(LEGACY))[1].source).toBe("kubelet, node-1")
	end)

	it("turns involvedObject into a live ref with uid and fieldPath, so Explore can open the exact object", function()
		local e = Model.fromList(json.decode(LEGACY))[1]
		expect(e.object).toEqual({
			namespace = "tern-test-apps",
			version = "v1",
			kind = "Pod",
			name = "crashloop",
			uid = "pod-uid",
			source = "live",
		})
		expect(e.fieldPath).toBe("spec.containers{app}")
		expect(e.related).toBeNil()
	end)

	it("reads series count and lastObservedTime, because series events carry count=null", function()
		local e = Model.fromList(json.decode(SERIES))[1]
		expect(e.series).toBe(true)
		expect(e.count).toBe(6)
		expect(e.first).toBe("2026-10-30T22:41:32.260930Z")
		expect(e.last).toBe("2026-11-02T02:22:32.241787Z")
	end)

	it("falls back to reportingComponent when source is empty, as for every series event", function()
		expect(Model.fromList(json.decode(SERIES))[1].source).toBe("default-scheduler")
	end)

	it("counts a one-off event (no count, no series) once and dates it by eventTime", function()
		local e = Model.fromList(json.decode(SERIES))[2]
		expect(e.count).toBe(1)
		expect(e.series).toBe(false)
		expect(e.first).toBe("2026-11-02T16:14:08.090640Z")
		expect(e.last).toBe("2026-11-02T16:14:08.090640Z")
	end)

	it("dates an event with no timestamps at all by metadata.creationTimestamp rather than dropping it", function()
		local list = { items = { { metadata = { name = "x", creationTimestamp = "2026-11-02T00:00:00Z" } } } }
		local e = Model.fromList(list)[1]
		expect(e.first).toBe("2026-11-02T00:00:00Z")
		expect(e.last).toBe("2026-11-02T00:00:00Z")
		expect(e.object).toBeNil()
		expect(e.key).toBe("/x")
	end)

	it("maps the events.k8s.io/v1 shape (regarding, note, deprecated*) onto the same fields", function()
		local events = Model.fromList(json.decode(K8S_IO))
		local legacy, series = events[1], events[2]
		expect(legacy.message).toBe("Scaled up replica set web-abc from 0 to 2")
		expect(legacy.count).toBe(3)
		expect(legacy.first).toBe("2026-11-01T10:00:00Z")
		expect(legacy.last).toBe("2026-11-01T11:00:00Z")
		expect(legacy.source).toBe("deployment-controller")
		expect(legacy.object and legacy.object.kind).toBe("Deployment")
		expect(legacy.object and legacy.object.group).toBe("apps")
		expect(legacy.related and legacy.related.name).toBe("web-abc")
		expect(series.count).toBe(4)
		expect(series.last).toBe("2026-11-01T12:30:00Z")
		expect(series.source).toBe("deployment-controller")
	end)

	it("keys an event without uid by namespace/name, so refetches keep a stable selection", function()
		expect(Model.fromList(json.decode(K8S_IO))[2].key).toBe("tern-test-apps/web.2")
	end)

	it("accepts a single Event object and ignores non-lists and non-table items instead of crashing", function()
		local single = json.decode(LEGACY).items[1]
		expect(#Model.fromList(single)).toBe(1)
		expect(#Model.fromList(nil)).toBe(0)
		expect(#Model.fromList("text")).toBe(0)
		expect(#Model.fromList({ kind = "PodList" })).toBe(0)
		local mixed = { items = { 1 :: any, json.null, "x", { metadata = { uid = "a" } } } }
		expect(#Model.fromList(mixed)).toBe(1)
	end)

	it("keys an item with no metadata by its list position so keys stay unique", function()
		local list = { items = { "skip" :: any, { reason = "X" } } }
		local events = Model.fromList(list)
		expect(events[1].key).toBe("#2")
	end)
end)

describe("events model lastSeenCell", function()
	it("splits `kubectl events` LAST SEEN into age, count and the first-seen age", function()
		expect(Model.lastSeenCell("7d6h (x534 over 11d)")).toEqual({ age = "7d6h", count = 534, over = "11d" })
	end)

	it("keeps a plain age as is", function()
		expect(Model.lastSeenCell("0s")).toEqual({ age = "0s" })
		expect(Model.lastSeenCell("  5m  ")).toEqual({ age = "5m" })
	end)

	it("keeps <unknown> as the age so callers can tell it from a real one", function()
		expect(Model.lastSeenCell("<unknown>")).toEqual({ age = "<unknown>" })
	end)
end)

describe("events model objectRef", function()
	it("canonicalises `Pod/x` from kubectl events", function()
		expect(Model.objectRef("Pod/crashloop", "ns")).toEqual({
			namespace = "ns",
			kind = "Pod",
			name = "crashloop",
			source = "snapshot",
		})
	end)

	it("canonicalises lowercase `pod/x` from get events to the same Kind", function()
		local ref = Model.objectRef("pod/crashloop", "ns")
		expect(ref and ref.kind).toBe("Pod")
		expect(ref and ref.group).toBeNil()
	end)

	it("resolves group-qualified `deployment.apps/x` and `Deployment.apps/x`", function()
		for _, text in { "deployment.apps/web", "Deployment.apps/web", "Deployment/web" } do
			local ref = Model.objectRef(text, "ns")
			expect(ref and ref.kind).toBe("Deployment")
			expect(ref and ref.group).toBe("apps")
			expect(ref and ref.namespace).toBe("ns")
		end
	end)

	it("drops the namespace for cluster-scoped kinds, because `node/x -n ns` would not resolve", function()
		local ref = Model.objectRef("Node/tern-kube-dev-control-plane", "tern-test-apps")
		expect(ref and ref.kind).toBe("Node")
		expect(ref and ref.namespace).toBeNil()
	end)

	it("keeps unknown kinds as written with their namespace (CRDs)", function()
		local ref = Model.objectRef("Widget.example.com/w1", "ns")
		expect(ref and ref.kind).toBe("Widget")
		expect(ref and ref.group).toBe("example.com")
		expect(ref and ref.namespace).toBe("ns")
	end)

	it("returns nil for malformed text instead of inventing a ref", function()
		for _, text in { "", "crashloop", "Pod/", "/x", "a/b/c", "Pod/a b" } do
			expect(Model.objectRef(text, "ns")).toBeNil()
		end
	end)
end)

describe("events model fromRow", function()
	it("reads `kubectl events` rows: LAST SEEN with count, capitalised OBJECT, namespace from -n", function()
		local headers = { "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" }
		local e = Model.fromRow(
			headers,
			{ "4m13s (x570 over 2d19h)", "Warning", "Failed", "Pod/broken", "Error: ImagePullBackOff" },
			inv("kubectl events -n tern-test-apps")
		)
		expect(e.type).toBe("Warning")
		expect(e.reason).toBe("Failed")
		expect(e.message).toBe("Error: ImagePullBackOff")
		expect(e.lastSeen).toBe("4m13s")
		expect(e.count).toBe(570)
		expect(e.over).toBe("2d19h")
		expect(e.namespace).toBe("tern-test-apps")
		expect(e.object and e.object.kind).toBe("Pod")
		expect(e.object and e.object.namespace).toBe("tern-test-apps")
		expect(e.series).toBe(false)
		expect(e.first).toBeNil()
	end)

	it("takes the namespace from the -A NAMESPACE column, not the invocation", function()
		local headers = { "NAMESPACE", "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" }
		local e = Model.fromRow(
			headers,
			{ "kube-system", "42m", "Warning", "Unhealthy", "Pod/ms", "probe" },
			inv("kubectl events -A")
		)
		expect(e.namespace).toBe("kube-system")
		expect(e.object and e.object.namespace).toBe("kube-system")
		expect(e.count).toBe(1)
		expect(e.lastSeen).toBe("42m")
	end)

	it("reads `get events` rows with lowercase OBJECT and a plain age", function()
		local headers = { "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" }
		local e = Model.fromRow(
			headers,
			{ "5m16s", "Normal", "Scheduled", "pod/web-1", "Successfully assigned" },
			inv("kubectl get events -n tern-test-apps")
		)
		expect(e.object and e.object.kind).toBe("Pod")
		expect(e.object and e.object.name).toBe("web-1")
		expect(e.lastSeen).toBe("5m16s")
		expect(e.over).toBeNil()
	end)

	it("reads -o wide SUBOBJECT, SOURCE, FIRST SEEN, numeric COUNT and keys by the Event NAME", function()
		local headers =
			{ "LAST SEEN", "TYPE", "REASON", "OBJECT", "SUBOBJECT", "SOURCE", "MESSAGE", "FIRST SEEN", "COUNT", "NAME" }
		local e = Model.fromRow(headers, {
			"4m14s",
			"Normal",
			"BackOff",
			"pod/broken",
			"spec.containers{app}",
			"kubelet, node-1",
			"Back-off pulling image",
			"2d19h",
			"570",
			"broken.18e36b5e183401fb",
		}, inv("kubectl get events -n tern-test-apps -o wide"))
		expect(e.fieldPath).toBe("spec.containers{app}")
		expect(e.source).toBe("kubelet, node-1")
		expect(e.over).toBe("2d19h")
		expect(e.count).toBe(570)
		expect(e.key).toBe("tern-test-apps/broken.18e36b5e183401fb")
	end)

	it("ignores the leading EVENT column of --output-watch-events", function()
		local headers = { "EVENT", "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" }
		local e = Model.fromRow(
			headers,
			{ "MODIFIED", "3m11s", "Normal", "Pulled", "pod/x", "Container image present" },
			inv("kubectl get events -n tern-test-logs -w --output-watch-events")
		)
		expect(e.reason).toBe("Pulled")
		expect(e.object and e.object.name).toBe("x")
		expect(e.namespace).toBe("tern-test-logs")
	end)

	it("keeps two rows for one object and reason apart when their LAST SEEN differs", function()
		local headers = { "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" }
		local i = inv("kubectl events -n ns")
		local a = Model.fromRow(headers, { "14h (x6 over 2d17h)", "Warning", "FailedScheduling", "Pod/p", "m" }, i)
		local b = Model.fromRow(headers, { "19m (x6 over 4h7m)", "Warning", "FailedScheduling", "Pod/p", "m" }, i)
		expect(a.key == b.key).toBe(false)
		expect(Model.fromRow(headers, { "14h (x6 over 2d17h)", "Warning", "FailedScheduling", "Pod/p", "m" }, i).key).toBe(
			a.key
		)
	end)

	it("leaves lastSeen nil for <unknown> and the object nil for a malformed OBJECT cell", function()
		local headers = { "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" }
		local e = Model.fromRow(headers, { "<unknown>", "Normal", "X", "weird", "m" }, inv("kubectl get events"))
		expect(e.lastSeen).toBeNil()
		expect(e.object).toBeNil()
	end)
end)

describe("events model reasonTone", function()
	it("maps the plan's reason table, Failed* prefix included", function()
		local cases: { { string } } = {
			{ "FailedScheduling", "Warning", "error" },
			{ "FailedMount", "Warning", "error" },
			{ "FailedCreatePodSandBox", "Warning", "error" },
			{ "Failed", "Warning", "error" },
			{ "BackOff", "Normal", "error" },
			{ "Unhealthy", "Warning", "error" },
			{ "Evicted", "Warning", "error" },
			{ "OOMKilling", "Warning", "error" },
			{ "NodeNotReady", "Normal", "error" },
			{ "Killing", "Normal", "warning" },
			{ "Preempting", "Normal", "warning" },
			{ "Rebooted", "Warning", "warning" },
			{ "ProbeWarning", "Warning", "warning" },
			{ "Scheduled", "Normal", "success" },
			{ "Pulled", "Normal", "success" },
			{ "Created", "Normal", "success" },
			{ "Started", "Normal", "success" },
			{ "SuccessfulCreate", "Normal", "success" },
			{ "ScalingReplicaSet", "Normal", "success" },
			{ "Completed", "Normal", "success" },
			{ "Pulling", "Normal", "neutral" },
		}
		for _, c in cases do
			expect(c[1] .. ":" .. Model.reasonTone(c[1], c[2])).toBe(c[1] .. ":" .. c[3])
		end
	end)

	it("tones an unknown reason on a Warning event as warning, so no Warning row looks harmless", function()
		expect(Model.reasonTone("SomethingOdd", "Warning")).toBe("warning")
		expect(Model.reasonTone("SomethingOdd", "Normal")).toBe("neutral")
	end)
end)

return nil
