--!strict
local Json = require("../../../plugin/lib/parse/json")
local decoder = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local decode = decoder.decode

local function column(resource: Json.Resource, header: string): string?
	for i, h in resource.summary.headers do
		if h == header then
			return resource.summary.cells[i]
		end
	end
	return nil
end

local PODS = [[
{
    "apiVersion": "v1",
    "items": [
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "api-1", "namespace": "default", "uid": "u-api"},
            "spec": {"containers": [{"name": "api"}, {"name": "sidecar"}], "nodeName": "kind-worker"},
            "status": {
                "conditions": [{"status": "True", "type": "Ready"}],
                "containerStatuses": [
                    {"name": "api", "ready": true, "restartCount": 2, "state": {"running": {"startedAt": "x"}}},
                    {"name": "sidecar", "ready": true, "restartCount": 1, "state": {"running": {"startedAt": "x"}}}
                ],
                "phase": "Running"
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "worker-1", "namespace": "default"},
            "spec": {"containers": [{"name": "worker"}], "nodeName": "kind-worker"},
            "status": {
                "containerStatuses": [
                    {"name": "worker", "ready": false, "restartCount": 14,
                     "state": {"waiting": {"reason": "CrashLoopBackOff", "message": "back-off"}}}
                ],
                "phase": "Running"
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "migrate-1", "namespace": "default"},
            "spec": {"containers": [{"name": "migrate"}], "nodeName": "kind-worker"},
            "status": {
                "containerStatuses": [
                    {"name": "migrate", "ready": false, "restartCount": 0,
                     "state": {"terminated": {"exitCode": 0, "reason": "Completed"}}}
                ],
                "phase": "Succeeded"
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "cache-1", "namespace": "default"},
            "spec": {"containers": [{"name": "cache"}]},
            "status": {"phase": "Pending"}
        },
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "deletionTimestamp": "2026-10-02T00:00:00Z",
                         "name": "old-1", "namespace": "default"},
            "spec": {"containers": [{"name": "old"}], "nodeName": "kind-worker"},
            "status": {
                "containerStatuses": [
                    {"name": "old", "ready": true, "restartCount": 0, "state": {"running": {"startedAt": "x"}}}
                ],
                "phase": "Running"
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "init-1", "namespace": "default"},
            "spec": {"containers": [{"name": "app"}], "initContainers": [{"name": "setup"}, {"name": "seed"}],
                     "nodeName": "kind-worker"},
            "status": {
                "containerStatuses": [
                    {"name": "app", "ready": false, "restartCount": 0, "state": {"waiting": {"reason": "PodInitializing"}}}
                ],
                "initContainerStatuses": [
                    {"name": "setup", "ready": true, "restartCount": 0, "state": {"terminated": {"exitCode": 0, "reason": "Completed"}}},
                    {"name": "seed", "ready": false, "restartCount": 3, "state": {"running": {"startedAt": "x"}}}
                ],
                "phase": "Pending"
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "oom-1", "namespace": "default"},
            "spec": {"containers": [{"name": "app"}], "nodeName": "kind-worker"},
            "status": {
                "containerStatuses": [
                    {"name": "app", "ready": false, "restartCount": 1,
                     "state": {"terminated": {"exitCode": 137}}}
                ],
                "phase": "Running"
            }
        }
    ],
    "kind": "List",
    "metadata": {"resourceVersion": ""}
}
]]

describe("json.parse pod lists", function()
	local result = Json.parse(PODS, decode)

	it("recognizes kubectl's List wrapper and yields one resource per item", function()
		expect(result.kind).toBe("list")
		expect(#result.resources).toBe(7)
		expect(result.diagnostics).toEqual({})
		expect(result.resources[1].ref).toEqual({
			kind = "Pod",
			version = "v1",
			name = "api-1",
			namespace = "default",
			uid = "u-api",
			source = "snapshot",
		})
	end)

	-- A single namespace is implied by the command; repeating it per row is noise.
	it("omits NAMESPACE and KIND when all items share them", function()
		expect(result.resources[1].summary.headers).toEqual({ "NAME", "READY", "STATUS", "RESTARTS", "NODE", "CREATED" })
	end)

	it("derives READY/STATUS/RESTARTS the way kubectl's pod printer does", function()
		local expected = {
			{ "api-1", "2/2", "Running", "3", "kind-worker" },
			{ "worker-1", "0/1", "CrashLoopBackOff", "14", "kind-worker" },
			{ "migrate-1", "0/1", "Completed", "0", "kind-worker" },
			{ "cache-1", "0/1", "Pending", "0", "" },
			{ "old-1", "1/1", "Terminating", "0", "kind-worker" },
			{ "init-1", "0/1", "Init:1/2", "3", "kind-worker" },
			{ "oom-1", "0/1", "ExitCode:137", "1", "kind-worker" },
		}
		for i, row in expected do
			local r = result.resources[i]
			expect({
				column(r, "NAME"),
				column(r, "READY"),
				column(r, "STATUS"),
				column(r, "RESTARTS"),
				column(r, "NODE"),
			}).toEqual(row)
		end
	end)

	it("shows creationTimestamp verbatim instead of computing an age from a clock", function()
		expect(column(result.resources[1], "CREATED")).toBe("2026-10-01T10:00:00Z")
	end)

	it("keeps the decoded object untouched for the inspector", function()
		local obj = result.resources[2].object
		expect(obj.status.containerStatuses[1].state.waiting.message).toBe("back-off")
	end)

	-- Without status the server has not reported anything; READY 0/N would be invented.
	it("does not derive status columns for objects that carry no status", function()
		local r = Json.parse(
			[[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"draft"},"spec":{"containers":[{"name":"a"}]}}]],
			decode
		)
		expect(r.kind).toBe("object")
		expect(r.resources[1].summary.headers).toEqual({ "NAME" })
		expect(r.resources[1].summary.cells).toEqual({ "draft" })
	end)
end)

describe("json.parse single objects", function()
	it("summarizes a Deployment with replica counts, treating omitted counters as zero", function()
		local r = Json.parse(
			[[{
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": {"creationTimestamp": "2026-10-01T10:00:00Z", "name": "web", "namespace": "shop"},
    "spec": {"replicas": 3},
    "status": {"readyReplicas": 2, "updatedReplicas": 3}
}]],
			decode
		)
		expect(r.kind).toBe("object")
		expect(#r.resources).toBe(1)
		local d = r.resources[1]
		expect(d.ref.group).toBe("apps")
		expect(d.summary.headers).toEqual({ "NAME", "READY", "UP-TO-DATE", "AVAILABLE", "CREATED" })
		expect(d.summary.cells).toEqual({ "web", "2/3", "3", "0", "2026-10-01T10:00:00Z" })
	end)

	it("reports Job completions in kubectl's succeeded/completions form", function()
		local r = Json.parse(
			[[{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"j"},
			"spec":{"completions":3,"parallelism":1},"status":{"succeeded":1}}]],
			decode
		)
		expect(r.resources[1].summary.cells).toEqual({ "j", "1/3" })
		local p = Json.parse(
			[[{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"p"},"spec":{"parallelism":4},"status":{}}]],
			decode
		)
		expect(p.resources[1].summary.cells).toEqual({ "p", "0/1 of 4" })
	end)
end)

describe("json.parse mixed lists", function()
	local result = Json.parse(
		[[{
    "apiVersion": "v1",
    "kind": "List",
    "items": [
        {"apiVersion": "v1", "kind": "Service",
         "metadata": {"name": "web", "namespace": "shop"},
         "spec": {"clusterIP": "10.96.0.10", "type": "NodePort",
                  "ports": [{"port": 80, "nodePort": 30080, "protocol": "TCP"}, {"port": 53, "protocol": "UDP"}]}},
        {"apiVersion": "apps/v1", "kind": "Deployment",
         "metadata": {"name": "web", "namespace": "shop"},
         "spec": {"replicas": 1}, "status": {"availableReplicas": 1, "readyReplicas": 1, "updatedReplicas": 1}},
        {"apiVersion": "v1", "kind": "Node",
         "metadata": {"name": "kind-control-plane",
                      "labels": {"node-role.kubernetes.io/control-plane": ""}},
         "spec": {"unschedulable": true},
         "status": {"conditions": [{"type": "MemoryPressure", "status": "False"}, {"type": "Ready", "status": "True"}],
                    "nodeInfo": {"kubeletVersion": "v1.31.0"}}},
        {"apiVersion": "v1", "kind": "Service",
         "metadata": {"name": "db", "namespace": "data"},
         "spec": {"clusterIP": "None", "type": "ClusterIP"}}
    ]
}]],
		decode
	)

	it("adds NAMESPACE and KIND when items span namespaces and kinds", function()
		expect(result.kind).toBe("list")
		local svc = result.resources[1]
		expect(svc.summary.headers).toEqual({ "NAMESPACE", "KIND", "NAME", "TYPE", "CLUSTER-IP", "PORTS" })
		expect(svc.summary.cells).toEqual({ "shop", "Service", "web", "NodePort", "10.96.0.10", "80:30080/TCP,53/UDP" })
	end)

	it("keeps kind-specific columns per kind", function()
		expect(result.resources[2].summary.cells).toEqual({ "shop", "Deployment", "web", "1/1", "1", "1" })
		expect(result.resources[3].summary.headers).toEqual({
			"NAMESPACE",
			"KIND",
			"NAME",
			"STATUS",
			"ROLES",
			"VERSION",
		})
		expect(result.resources[3].summary.cells).toEqual({
			"",
			"Node",
			"kind-control-plane",
			"Ready,SchedulingDisabled",
			"control-plane",
			"v1.31.0",
		})
		expect(result.resources[4].summary.cells).toEqual({ "data", "Service", "db", "ClusterIP", "None", "<none>" })
	end)
end)

describe("json.parse custom resources", function()
	it("summarizes status conditions generically and only when present", function()
		local r = Json.parse(
			[[{"apiVersion": "v1", "kind": "List", "items": [
  {"apiVersion": "acme.example.com/v1alpha1", "kind": "Widget",
   "metadata": {"name": "a", "namespace": "ns", "creationTimestamp": "2026-10-01T10:00:00Z"},
   "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Synced", "status": "False"}]}},
  {"apiVersion": "acme.example.com/v1alpha1", "kind": "Widget",
   "metadata": {"name": "b", "namespace": "ns", "creationTimestamp": "2026-10-01T10:00:00Z"},
   "spec": {"size": 3}}
]}]],
			decode
		)
		expect(r.resources[1].ref.group).toBe("acme.example.com")
		expect(r.resources[1].summary.headers).toEqual({ "NAME", "CONDITIONS", "CREATED" })
		expect(r.resources[1].summary.cells).toEqual({ "a", "Ready=True,Synced=False", "2026-10-01T10:00:00Z" })
		expect(r.resources[2].summary.cells).toEqual({ "b", "", "2026-10-01T10:00:00Z" })
	end)

	it("never adds columns no object can fill", function()
		local r = Json.parse(
			[[{"apiVersion":"acme.example.com/v1","kind":"Gadget","metadata":{"name":"g"},"spec":{"x":1}}]],
			decode
		)
		expect(r.resources[1].summary.headers).toEqual({ "NAME" })
	end)

	it("skips items without identity and says so", function()
		local r = Json.parse(
			[[{"kind":"List","items":[{"kind":"Pod","metadata":{"generateName":"x-"}},{"kind":"Pod","metadata":{"name":"ok"}}]}]],
			decode
		)
		expect(#r.resources).toBe(1)
		expect(r.resources[1].ref.name).toBe("ok")
		expect(#r.diagnostics).toBe(1)
		expect(r.diagnostics[1].severity).toBe("warning")
	end)
end)

describe("json.parse empty and broken input", function()
	it("treats an empty List as a valid, empty result", function()
		local r = Json.parse('{\n    "apiVersion": "v1",\n    "items": [],\n    "kind": "List"\n}', decode)
		expect(r.kind).toBe("list")
		expect(r.resources).toEqual({})
		expect(r.diagnostics).toEqual({})
	end)

	-- stderr is interleaved with stdout in the capture, so deprecation warnings
	-- precede the JSON and errors for missing names follow it.
	it("strips leading Warning lines and trailing error lines into diagnostics", function()
		local text = table.concat({
			"Warning: v1 ComponentStatus is deprecated in v1.19+",
			"{",
			'    "apiVersion": "v1",',
			'    "kind": "Pod",',
			'    "metadata": {"name": "p"}',
			"}",
			'Error from server (NotFound): pods "missing" not found',
		}, "\n")
		local r = Json.parse(text, decode)
		expect(r.kind).toBe("object")
		expect(r.resources[1].ref.name).toBe("p")
		expect(r.diagnostics).toEqual({
			{ line = 1, severity = "warning", text = "Warning: v1 ComponentStatus is deprecated in v1.19+" },
			{ line = 7, severity = "error", text = 'Error from server (NotFound): pods "missing" not found' },
		})
	end)

	it("reports truncated output as invalid without raising", function()
		local r = Json.parse('{\n    "apiVersion": "v1",\n    "items": [\n        {"kind": "Pod",', decode)
		expect(r.kind).toBe("invalid")
		expect(r.resources).toEqual({})
		expect(#r.diagnostics).toBe(1)
		expect(r.diagnostics[1].severity).toBe("error")
	end)

	it("reports non-JSON and non-Kubernetes JSON as invalid", function()
		expect(Json.parse('error: the server doesn\'t have a resource type "pdos"', decode).kind).toBe("invalid")
		expect(Json.parse("", decode).kind).toBe("invalid")
		expect(Json.parse('{"clientVersion": {"major": "1"}}', decode).kind).toBe("invalid")
		expect(Json.parse("[1, 2]", decode).kind).toBe("invalid")
	end)

	it("survives a decoder that raises non-string errors", function()
		local r = Json.parse("{", function(_: string): any
			error({ code = 1 })
		end)
		expect(r.kind).toBe("invalid")
	end)
end)

describe("json.redactSecrets", function()
	local secretJson = [[{
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "db",
        "annotations": {
            "kubectl.kubernetes.io/last-applied-configuration": "{\"data\":{\"password\":\"aHVudGVyMg==\"}}",
            "team": "data"
        }
    },
    "data": {"password": "aHVudGVyMg==", "user": "YWRtaW4="},
    "stringData": {"token": "abc"},
    "type": "Opaque"
}]]

	it("masks Secret data, stringData and the last-applied copy for native display", function()
		local r = Json.parse(secretJson, decode)
		local masked = Json.redactSecrets(r.resources[1])
		expect(masked.data).toEqual({
			password = "<redacted: 12 bytes base64>",
			user = "<redacted: 8 bytes base64>",
		})
		expect(masked.stringData).toEqual({ token = "<redacted: 3 bytes>" })
		expect(masked.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]).toBe(
			"<redacted: 36 bytes>"
		)
		expect(masked.metadata.annotations.team).toBe("data")
		expect(masked.metadata.name).toBe("db")
		expect(masked.type).toBe("Opaque")
	end)

	-- Raw view keeps the original; redaction must not leak back into it.
	it("leaves the original decoded object untouched", function()
		local r = Json.parse(secretJson, decode)
		Json.redactSecrets(r.resources[1])
		expect(r.resources[1].object.data.password).toBe("aHVudGVyMg==")
		expect(r.resources[1].object.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]).toContain(
			"aHVudGVyMg=="
		)
	end)

	it("never masks ConfigMap data", function()
		local r = Json.parse(
			[[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"c"},"data":{"password":"plain"}}]],
			decode
		)
		local shown = Json.redactSecrets(r.resources[1])
		expect(shown.data.password).toBe("plain")
	end)
end)

describe("json.parse performance", function()
	it("summarizes 1000 pods well inside the lens callback budget", function()
		local items: { any } = {}
		for i = 1, 1000 do
			items[i] = {
				apiVersion = "v1",
				kind = "Pod",
				metadata = {
					name = "pod-" .. i,
					namespace = "ns-" .. (i % 7),
					creationTimestamp = "2026-10-01T10:00:00Z",
				},
				spec = { containers = { { name = "a" }, { name = "b" } }, nodeName = "node-" .. (i % 3) },
				status = {
					phase = "Running",
					conditions = { { type = "Ready", status = "True" } },
					containerStatuses = {
						{ name = "a", ready = true, restartCount = 1, state = { running = {} } } :: any,
						{
							name = "b",
							ready = false,
							restartCount = 0,
							state = { waiting = { reason = "CrashLoopBackOff" } },
						},
					},
				},
			}
		end
		local decoded = { apiVersion = "v1", kind = "List", items = items }
		local started = os.clock()
		local r = Json.parse("{}", function(_: string): any
			return decoded
		end)
		local elapsed = os.clock() - started
		expect(#r.resources).toBe(1000)
		expect(column(r.resources[1000], "STATUS")).toBe("CrashLoopBackOff")
		expect(elapsed < 0.2).toBe(true)
	end)
end)

return nil
