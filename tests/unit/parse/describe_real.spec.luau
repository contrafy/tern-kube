--!strict
-- Real `kubectl describe` output (kubectl v1.34 against a kind v1.37 cluster).
-- Ages, restart counts and hashes change between captures, so assertions
-- check structure and stable values only.
local Types = require("../../../plugin/lib/model/types")
local describeParser = require("../../../plugin/lib/parse/describe")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type DescribeField = Types.DescribeField
type DescribeObject = Types.DescribeObject
type DescribeEvent = Types.DescribeEvent

local function field(fields: { DescribeField }, ...: string): DescribeField
	local current: DescribeField? = nil
	local list = fields
	for _, key in { ... } do
		current = nil
		for _, candidate in list do
			if candidate.key == key then
				current = candidate
				break
			end
		end
		assert(current, "missing field " .. key)
		list = current.children
	end
	assert(current, "no keys given")
	return current
end

local function parseOne(path: string): DescribeObject
	local out = describeParser.parse(fixtures.lines(path))
	expect(out.diagnostics).toEqual({})
	expect(#out.objects).toBe(1)
	return out.objects[1]
end

local function eventsOf(object: DescribeObject): { DescribeEvent }
	local events = object.events
	assert(events, "events missing for " .. object.name)
	return events
end

describe("describe.parse real pod", function()
	it("reads a crash-looping pod's identity, crash details and backoff events", function()
		local pod = parseOne("real/ns-apps/describe_pod_crashloop.txt")
		expect(pod.name).toBe("crashloop")
		expect(pod.namespace).toBe("tern-test-apps")
		expect(pod.kind).toBe("Pod")
		local container = field(pod.fields, "Containers", "app")
		expect(field(container.children, "Last State").value).toBe("Terminated")
		expect(field(container.children, "Last State", "Reason").value).toBe("Error")
		expect(field(container.children, "Last State", "Exit Code").value).toBe("1")
		expect(string.match(field(container.children, "Restart Count").value, "^%d+$") ~= nil).toBe(true)
		local command = field(container.children, "Command")
		expect(command.children[3].value).toContain("fatal: config file /etc/app/config.yaml not found")

		local conditions = field(pod.fields, "Conditions").table
		assert(conditions, "conditions")
		expect(#conditions.rows).toBe(5)
		expect(conditions.rows[5].cells).toEqual({ "PodScheduled", "True" })

		local backoff: DescribeEvent? = nil
		for _, event in eventsOf(pod) do
			if event.reason == "BackOff" then
				backoff = event
			end
		end
		assert(backoff, "BackOff event")
		expect(backoff.type).toBe("Warning")
		expect(backoff.from).toBe("kubelet")
		expect(string.match(backoff.age, "^%S+ %(x%d+ over %S+%)$") ~= nil).toBe(true)
		expect(backoff.message).toContain("Back-off restarting failed container app in pod crashloop_tern-test-apps")
	end)

	-- Odd label keys, empty label values and multi-line unicode annotations
	-- must neither break nesting nor leak into neighbouring fields.
	it("keeps odd labels and multi-line unicode annotations as value lists", function()
		local pod = parseOne("real/ns-edge/describe_pod_labels-odd.txt")
		local labels = field(pod.fields, "Labels").values
		expect(#labels).toBe(7)
		expect(labels[1]).toBe("UPPER_case.Key=Mixed_Case.Value")
		expect(labels).toContain("lens.example.com/empty=")
		local annotations = field(pod.fields, "Annotations").values
		expect(annotations[1]).toContain("日本語のテキスト")
		expect(annotations).toEqual({
			annotations[1],
			"lens.example.com/multiline:",
			"  first line",
			"  second line with  tab",
		})
		expect(field(pod.fields, "Status").value).toBe("Running")
		expect(#eventsOf(pod) > 0).toBe(true)
	end)
end)

describe("describe.parse real workloads", function()
	it("reads a deployment's pod template, conditions and scaling events", function()
		local deploy = parseOne("real/ns-apps/describe_deployment_web.txt")
		expect(deploy.kind).toBe("Deployment")
		expect(field(deploy.fields, "Labels").values).toEqual({ "app=web", "tier=frontend" })
		expect(field(deploy.fields, "Pod Template", "Labels").values).toEqual({ "app=web", "tier=frontend" })
		local web = field(deploy.fields, "Pod Template", "Containers", "web")
		expect(field(web.children, "Image").value).toBe("registry.k8s.io/pause:3.10")
		expect(field(web.children, "Requests", "cpu").value).toBe("5m")
		expect(field(deploy.fields, "Pod Template", "Volumes").value).toBe("<none>")
		local conditions = field(deploy.fields, "Conditions").table
		assert(conditions, "conditions")
		expect(conditions.rows[1].cells).toEqual({ "Available", "True", "MinimumReplicasAvailable" })
		expect(eventsOf(deploy)[1].reason).toBe("ScalingReplicaSet")
		expect(eventsOf(deploy)[1].from).toBe("deployment-controller")
	end)

	it("infers Job and CronJob from their distinctive fields", function()
		expect(parseOne("real/ns-batch/describe_job_fail-job.txt").kind).toBe("Job")
		expect(parseOne("real/ns-batch/describe_cronjob_nightly-report.txt").kind).toBe("CronJob")
	end)

	-- CRDs use the generic describer, which states the kind and nests the spec.
	it("reads a custom resource with its declared kind", function()
		local widget = parseOne("real/ns-crd/describe_widget_gizmo.txt")
		expect(widget.kind).toBe("Widget")
		expect(widget.namespace).toBe("tern-test-crd")
		expect(field(widget.fields, "Spec", "Size").value).toBe("3")
		expect(field(widget.fields, "Metadata", "Generation").value).toBe("1")
		expect(widget.events).toEqual({})
	end)
end)

describe("describe.parse real networking", function()
	it("reads a service", function()
		local svc = parseOne("real/ns-apps/describe_svc_web.txt")
		expect(svc.kind).toBe("Service")
		expect(field(svc.fields, "Port").value).toBe("http  80/TCP")
		expect(string.match(field(svc.fields, "Endpoints").value, "^[%d%.]+:8080,[%d%.]+:8080$") ~= nil).toBe(true)
		expect(svc.events).toEqual({})
	end)

	-- The ingress printer indents path rows independently of the header, so
	-- their columns cannot be trusted; they are kept raw rather than mis-split.
	it("reads an ingress and keeps misaligned rule rows raw", function()
		local ing = parseOne("real/ns-apps/describe_ingress_web.txt")
		expect(ing.kind).toBe("Ingress")
		expect(field(ing.fields, "Address").value).toBe("")
		expect(field(ing.fields, "TLS").children[1].value).toBe("web-tls terminates app.example.com,api.example.com")
		local rules = field(ing.fields, "Rules").table
		assert(rules, "rules")
		expect(#rules.columns).toBe(3)
		expect(rules.rows[1].cells).toEqual({ "app.example.com", "", "" })
		local pathRow = rules.unparsed[1]
		expect(pathRow.line).toBe(13)
		expect(string.match(pathRow.text, "^/   web:http %([%d%.:,]+%)$") ~= nil).toBe(true)
		expect(#rules.rows + #rules.unparsed).toBe(4)
	end)
end)

describe("describe.parse real node", function()
	it("reads node conditions, allocations and the per-pod resource table", function()
		local node = parseOne("real/cluster/describe_node_tern-kube-dev-control-plane.txt")
		expect(node.kind).toBe("Node")
		expect(node.namespace).toBeNil()
		expect(field(node.fields, "Labels").values).toContain("node-role.kubernetes.io/control-plane=")
		expect(field(node.fields, "System Info", "Kube-Proxy Version").value).toBe("")
		expect(field(node.fields, "Capacity", "pods").value).toBe("110")

		local conditions = field(node.fields, "Conditions").table
		assert(conditions, "conditions")
		expect(#conditions.rows).toBe(4)
		expect(conditions.rows[4].cells[1]).toBe("Ready")
		expect(conditions.rows[4].cells[6]).toBe("kubelet is posting ready status")

		local podsField = field(node.fields, "Non-terminated Pods")
		local total = tonumber(string.match(podsField.value, "^%((%d+) in total%)$"))
		local pods = podsField.table
		assert(pods, "pods table")
		local names = {}
		for _, column in pods.columns do
			table.insert(names, column.name)
		end
		expect(names).toEqual({
			"Namespace",
			"Name",
			"CPU Requests",
			"CPU Limits",
			"Memory Requests",
			"Memory Limits",
			"Age",
		})
		expect(#pods.rows).toBe(total)
		local podNames = {}
		for _, row in pods.rows do
			for _, cell in row.cells do
				expect(cell ~= "").toBe(true)
			end
			table.insert(podNames, row.cells[2])
		end
		expect(podNames).toContain("a-pod-with-a-deliberately-long-name-to-stress-column-widths-in-the-lens")

		local allocated = field(node.fields, "Allocated resources").table
		assert(allocated, "allocated")
		expect(allocated.rows[1].cells[1]).toBe("cpu")
		expect(string.match(allocated.rows[1].cells[2], "^%d+m %(%d+%%%)$") ~= nil).toBe(true)
		expect(#eventsOf(node) > 0).toBe(true)
	end)

	it("reads the all-nodes describe", function()
		local out = describeParser.parse(fixtures.lines("real/cluster/describe_node.txt"))
		expect(#out.objects).toBe(1)
		expect(out.objects[1].name).toBe("tern-kube-dev-control-plane")
	end)
end)

describe("describe.parse real multi-object and errors", function()
	-- `kubectl describe pods` separates objects with two blank lines; each pod
	-- must keep its own fields and events.
	it("splits every pod of a namespace-wide describe", function()
		local lines = fixtures.lines("real/ns-apps/describe_pods.txt")
		local out = describeParser.parse(lines)
		expect(out.diagnostics).toEqual({})
		local starts = 0
		for _, line in lines do
			if string.sub(line, 1, 5) == "Name:" then
				starts += 1
			end
		end
		expect(#out.objects).toBe(starts)
		local byName: { [string]: DescribeObject } = {}
		for _, object in out.objects do
			expect(object.kind).toBe("Pod")
			expect(object.namespace).toBe("tern-test-apps")
			expect(#eventsOf(object) > 0).toBe(true)
			expect(byName[object.name]).toBeNil()
			byName[object.name] = object
		end
		expect(byName["crashloop"].name).toBe("crashloop")
		local pending = eventsOf(byName["pending"])
		expect(pending[1].reason).toBe("FailedScheduling")
		expect(pending[1].message).toContain("didn't match Pod's node affinity/selector")
		local broken = eventsOf(out.objects[1])
		local messages = {}
		for _, event in broken do
			table.insert(messages, event.message)
		end
		expect(out.objects[1].name).toContain("broken-image-")
		expect(messages).toContain("Error: ImagePullBackOff")
	end)

	it("surfaces a describe of a missing object as an error", function()
		local out = describeParser.parse(fixtures.lines("real/errors/describe_pod_does-not-exist.stderr"))
		expect(out.objects).toEqual({})
		expect(out.diagnostics).toEqual({
			{ line = 1, severity = "error", text = 'Error from server (NotFound): pods "does-not-exist" not found' },
		})
	end)
end)

return nil
