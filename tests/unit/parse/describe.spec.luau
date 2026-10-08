--!strict
local Types = require("../../../plugin/lib/model/types")
local describeParser = require("../../../plugin/lib/parse/describe")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type DescribeField = Types.DescribeField

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

local CRASHLOOP_POD = {
	"Name:             crashy-7c9d8f6b5-x2x9q",
	"Namespace:        demo",
	"Priority:         0",
	"Service Account:  default",
	"Node:             kind-control-plane/172.18.0.2",
	"Start Time:       Thu, 08 Oct 2026 10:00:00 +0000",
	"Labels:           app=crashy",
	"                  pod-template-hash=7c9d8f6b5",
	"Annotations:      <none>",
	"Status:           Running",
	"IP:               10.244.0.7",
	"IPs:",
	"  IP:           10.244.0.7",
	"Controlled By:  ReplicaSet/crashy-7c9d8f6b5",
	"Containers:",
	"  app:",
	"    Container ID:  containerd://0123abcd",
	"    Image:         busybox:1.36",
	"    Port:          <none>",
	"    Command:",
	"      sh",
	"      -c",
	"      exit 1",
	"    State:          Waiting",
	"      Reason:       CrashLoopBackOff",
	"    Last State:     Terminated",
	"      Reason:       Error",
	"      Exit Code:    1",
	"    Ready:          False",
	"    Restart Count:  4",
	"    Environment:    <none>",
	"    Mounts:",
	"      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-abcde (ro)",
	"Conditions:",
	"  Type                        Status",
	"  PodReadyToStartContainers   True ",
	"  Initialized                 True ",
	"  Ready                       False ",
	"  ContainersReady             False ",
	"  PodScheduled                True ",
	"Volumes:",
	"  kube-api-access-abcde:",
	"    Type:                    Projected (a volume that contains injected data from multiple sources)",
	"    TokenExpirationSeconds:  3607",
	"QoS Class:                   BestEffort",
	"Node-Selectors:              <none>",
	"Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s",
	"                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s",
	"Events:",
	"  Type     Reason     Age                From               Message",
	"  ----     ------     ----               ----               -------",
	"  Normal   Scheduled  2m                 default-scheduler  Successfully assigned demo/crashy-7c9d8f6b5-x2x9q to kind-control-plane",
	'  Normal   Pulled     90s (x5 over 2m)   kubelet            Container image "busybox:1.36" already present on machine',
	"  Warning  BackOff    5s (x10 over 2m)   kubelet            Back-off restarting failed container app in pod crashy-7c9d8f6b5-x2x9q_demo(1234)",
}

describe("describe.parse pod", function()
	local out = describeParser.parse(CRASHLOOP_POD)
	local pod = out.objects[1]

	it("identifies the object so the lens can link it", function()
		expect(#out.objects).toBe(1)
		expect(pod.name).toBe("crashy-7c9d8f6b5-x2x9q")
		expect(pod.namespace).toBe("demo")
		expect(pod.kind).toBe("Pod")
		expect(pod.line).toBe(1)
		expect(out.diagnostics).toEqual({})
	end)

	-- Values containing colons (timestamps, URIs) must stay whole.
	it("splits keys only at the first colon-space", function()
		expect(field(pod.fields, "Start Time").value).toBe("Thu, 08 Oct 2026 10:00:00 +0000")
		expect(field(pod.fields, "Containers", "app", "Container ID").value).toBe("containerd://0123abcd")
	end)

	-- Labels and tolerations continue on lines aligned to the value column;
	-- treating them as separate fields would drop all but the first label.
	it("collects value continuation lines into lists", function()
		expect(field(pod.fields, "Labels").values).toEqual({ "app=crashy", "pod-template-hash=7c9d8f6b5" })
		expect(field(pod.fields, "Tolerations").values).toEqual({
			"node.kubernetes.io/not-ready:NoExecute op=Exists for 300s",
			"node.kubernetes.io/unreachable:NoExecute op=Exists for 300s",
		})
		expect(field(pod.fields, "Annotations").values).toEqual({ "<none>" })
	end)

	-- The crash reason lives three levels deep; nesting must follow indentation.
	it("nests container state details under their container", function()
		local state = field(pod.fields, "Containers", "app", "State")
		expect(state.value).toBe("Waiting")
		expect(field(state.children, "Reason").value).toBe("CrashLoopBackOff")
		expect(field(pod.fields, "Containers", "app", "Last State", "Exit Code").value).toBe("1")
		expect(field(pod.fields, "Containers", "app", "Restart Count").value).toBe("4")
		local command = field(pod.fields, "Containers", "app", "Command")
		expect(#command.children).toBe(3)
		expect(command.children[3]).toEqual({
			key = "",
			value = "exit 1",
			values = { "exit 1" },
			line = 23,
			children = {},
		})
	end)

	it("reads the pod Conditions table without an underline", function()
		local conditions = field(pod.fields, "Conditions").table
		assert(conditions, "conditions table")
		expect(conditions.headerLine).toBe(35)
		expect(#conditions.columns).toBe(2)
		expect(conditions.columns[2].name).toBe("Status")
		expect(#conditions.rows).toBe(5)
		expect(conditions.rows[3].cells).toEqual({ "Ready", "False" })
		expect(field(pod.fields, "Volumes", "kube-api-access-abcde", "TokenExpirationSeconds").value).toBe("3607")
	end)

	-- Ages such as "5s (x10 over 2m)" contain spaces, so events are cut at the
	-- header-derived column spans rather than split on whitespace.
	it("exposes events with multi-word ages and messages", function()
		local events = pod.events
		assert(events, "events")
		expect(#events).toBe(3)
		expect(events[3]).toEqual({
			type = "Warning",
			reason = "BackOff",
			age = "5s (x10 over 2m)",
			from = "kubelet",
			message = "Back-off restarting failed container app in pod crashy-7c9d8f6b5-x2x9q_demo(1234)",
			line = 54,
		})
	end)
end)

describe("describe.parse other kinds", function()
	it("reads a deployment with nested pod template and underlined conditions", function()
		local out = describeParser.parse({
			"Name:                   web",
			"Namespace:              default",
			"CreationTimestamp:      Thu, 08 Oct 2026 10:00:00 +0000",
			"Labels:                 app=web",
			"Annotations:            deployment.kubernetes.io/revision: 2",
			"Selector:               app=web",
			"Replicas:               3 desired | 3 updated | 3 total | 3 available | 0 unavailable",
			"StrategyType:           RollingUpdate",
			"MinReadySeconds:        0",
			"RollingUpdateStrategy:  25% max unavailable, 25% max surge",
			"Pod Template:",
			"  Labels:  app=web",
			"  Containers:",
			"   nginx:",
			"    Image:         nginx:1.27",
			"    Port:          80/TCP",
			"    Host Port:     0/TCP",
			"    Environment:   <none>",
			"    Mounts:        <none>",
			"  Volumes:         <none>",
			"  Node-Selectors:  <none>",
			"  Tolerations:     <none>",
			"Conditions:",
			"  Type           Status  Reason",
			"  ----           ------  ------",
			"  Available      True    MinimumReplicasAvailable",
			"  Progressing    True    NewReplicaSetAvailable",
			"OldReplicaSets:  web-5d4f8c7b9 (0/0 replicas created)",
			"NewReplicaSet:   web-6c8d9f7b4 (3/3 replicas created)",
			"Events:          <none>",
		})
		local deploy = out.objects[1]
		expect(deploy.kind).toBe("Deployment")
		expect(field(deploy.fields, "Annotations").value).toBe("deployment.kubernetes.io/revision: 2")
		expect(field(deploy.fields, "Pod Template", "Containers", "nginx", "Image").value).toBe("nginx:1.27")
		expect(field(deploy.fields, "Pod Template", "Volumes").value).toBe("<none>")
		local conditions = field(deploy.fields, "Conditions").table
		assert(conditions, "conditions")
		expect(conditions.rows[2].cells).toEqual({ "Progressing", "True", "NewReplicaSetAvailable" })
		-- "<none>" means kubectl found no events: an empty list, not unknown.
		expect(deploy.events).toEqual({})
	end)

	-- Node tables have multi-word headers ("CPU Requests") and a free-text
	-- note before the allocation table; both must survive.
	it("reads node tables with multi-word headers", function()
		local out = describeParser.parse({
			"Name:               kind-control-plane",
			"Roles:              control-plane",
			"Labels:             kubernetes.io/hostname=kind-control-plane",
			"                    node-role.kubernetes.io/control-plane=",
			"Taints:             <none>",
			"Unschedulable:      false",
			"Conditions:",
			"  Type             Status  LastHeartbeatTime                 LastTransitionTime                Reason                       Message",
			"  ----             ------  -----------------                 ------------------                ------                       -------",
			"  Ready            True    Thu, 08 Oct 2026 10:05:00 +0000   Thu, 08 Oct 2026 10:00:30 +0000   KubeletReady                 kubelet is posting ready status",
			"Capacity:",
			"  cpu:     8",
			"  memory:  8025424Ki",
			"System Info:",
			"  Kernel Version:             6.10.14-linuxkit",
			"Non-terminated Pods:          (2 in total)",
			"  Namespace                   Name                     CPU Requests  CPU Limits  Memory Requests  Memory Limits  Age",
			"  ---------                   ----                     ------------  ----------  ---------------  -------------  ---",
			"  kube-system                 coredns-668d6bf9bc-7m2kx 100m (1%)     0 (0%)      70Mi (0%)        170Mi (2%)     5m",
			"  kube-system                 etcd-kind-control-plane  100m (1%)     0 (0%)      100Mi (1%)       0 (0%)         5m",
			"Allocated resources:",
			"  (Total limits may be over 100 percent, i.e., overcommitted.)",
			"  Resource           Requests    Limits",
			"  --------           --------    ------",
			"  cpu                200m (2%)   0 (0%)",
			"Events:",
			"  Type    Reason                   Age   From     Message",
			"  ----    ------                   ----  ----     -------",
			"  Normal  NodeHasSufficientMemory  5m    kubelet  Node kind-control-plane status is now: NodeHasSufficientMemory",
		})
		local node = out.objects[1]
		expect(node.kind).toBe("Node")
		expect(node.namespace).toBeNil()
		expect(field(node.fields, "Labels").values[2]).toBe("node-role.kubernetes.io/control-plane=")
		local conditions = field(node.fields, "Conditions").table
		assert(conditions, "conditions")
		expect(conditions.rows[1].cells[3]).toBe("Thu, 08 Oct 2026 10:05:00 +0000")
		expect(conditions.rows[1].cells[6]).toBe("kubelet is posting ready status")
		local podsField = field(node.fields, "Non-terminated Pods")
		expect(podsField.value).toBe("(2 in total)")
		local pods = podsField.table
		assert(pods, "pods table")
		expect(pods.columns[3]).toEqual({ name = "CPU Requests", start = 56, stop = 69 })
		expect(pods.rows[1].cells).toEqual({
			"kube-system",
			"coredns-668d6bf9bc-7m2kx",
			"100m (1%)",
			"0 (0%)",
			"70Mi (0%)",
			"170Mi (2%)",
			"5m",
		})
		local allocated = field(node.fields, "Allocated resources")
		expect(allocated.children[1].value).toBe("(Total limits may be over 100 percent, i.e., overcommitted.)")
		local alloc = allocated.table
		assert(alloc, "allocation table")
		expect(alloc.rows[1].cells).toEqual({ "cpu", "200m (2%)", "0 (0%)" })
		local events = node.events
		assert(events, "events")
		expect(events[1].message).toBe("Node kind-control-plane status is now: NodeHasSufficientMemory")
	end)

	it("reads a service and its single-line fields", function()
		local out = describeParser.parse({
			"Name:                     web",
			"Namespace:                default",
			"Labels:                   app=web",
			"Selector:                 app=web",
			"Type:                     ClusterIP",
			"IP:                       10.96.12.34",
			"Port:                     <unset>  80/TCP",
			"TargetPort:               80/TCP",
			"Endpoints:                10.244.0.5:80,10.244.0.6:80",
			"Session Affinity:         None",
			"Events:                   <none>",
		})
		local svc = out.objects[1]
		expect(svc.kind).toBe("Service")
		expect(field(svc.fields, "Port").value).toBe("<unset>  80/TCP")
		expect(field(svc.fields, "Endpoints").value).toBe("10.244.0.5:80,10.244.0.6:80")
	end)

	-- Generic (CRD) describers print the kind explicitly; trust it.
	it("uses an explicit Kind field and leaves unknown shapes kind-less", function()
		local out = describeParser.parse({
			"Name:         w1",
			"Namespace:    default",
			"API Version:  example.com/v1",
			"Kind:         Widget",
			"Spec:",
			"  Size:  3",
			"",
			"Name:         mystery",
			"Labels:       <none>",
		})
		expect(out.objects[1].kind).toBe("Widget")
		expect(field(out.objects[1].fields, "Spec", "Size").value).toBe("3")
		expect(out.objects[2].kind).toBeNil()
		expect(out.objects[2].events).toBeNil()
	end)
end)

describe("describe.parse multiple objects and noise", function()
	-- `kubectl describe pods` prints every match; each needs its own identity.
	it("splits objects at column-0 Name lines and tolerates inner blank lines", function()
		local out = describeParser.parse({
			"Name:         cfg",
			"Namespace:    default",
			"Labels:       <none>",
			"Annotations:  <none>",
			"",
			"Data",
			"====",
			"key:",
			"----",
			"value",
			"",
			"BinaryData",
			"====",
			"",
			"Events:  <none>",
			"",
			"",
			"Name:         token",
			"Namespace:    kube-system",
			"Labels:       <none>",
			"",
			"Type:  Opaque",
			"",
			"Data",
			"====",
			"password:  6 bytes",
		})
		expect(#out.objects).toBe(2)
		expect(out.objects[1].kind).toBe("ConfigMap")
		expect(out.objects[1].events).toEqual({})
		expect(out.objects[2].name).toBe("token")
		expect(out.objects[2].namespace).toBe("kube-system")
		expect(out.objects[2].line).toBe(18)
		expect(out.objects[2].kind).toBe("Secret")
	end)

	-- stderr is interleaved: a missing name must surface as an error without
	-- being swallowed into the previous object's fields.
	it("reports interleaved errors and stray text as diagnostics", function()
		local out = describeParser.parse({
			"stray preamble",
			"Name:  a",
			'Error from server (NotFound): pods "b" not found',
			"Labels:  <none>",
		})
		expect(#out.objects).toBe(1)
		expect(out.diagnostics).toEqual({
			{ line = 1, severity = "info", text = "stray preamble" },
			{ line = 3, severity = "error", text = 'Error from server (NotFound): pods "b" not found' },
		})
		expect(#out.objects[1].fields).toBe(2)
	end)

	it("never raises on empty or odd input", function()
		expect(describeParser.parse({}).objects).toEqual({})
		local out =
			describeParser.parse({ "Name:", "  ----", "      :::", "Events:", "  Type  Reason", "  ----  ------" })
		expect(#out.objects).toBe(1)
		expect(out.objects[1].events).toEqual({})
	end)

	it("keeps multi-byte text aligned to rune columns", function()
		local out = describeParser.parse({
			"Name:  a",
			"Events:",
			"  Type    Reason  Age   From     Message",
			"  ----    ------  ----  ----     -------",
			"  Normal  Héllo   1m    kübelet  ünïcode message",
		})
		local events = out.objects[1].events
		assert(events, "events")
		expect(events[1]).toEqual({
			type = "Normal",
			reason = "Héllo",
			age = "1m",
			from = "kübelet",
			message = "ünïcode message",
			line = 5,
		})
	end)

	it("parses 1000 event rows well within the lens budget", function()
		local lines = { "Name:  big", "Events:" }
		table.insert(lines, "  Type     Reason     Age                From               Message")
		table.insert(lines, "  ----     ------     ----               ----               -------")
		for i = 1, 1000 do
			table.insert(
				lines,
				string.format(
					"  Warning  BackOff    %-18s kubelet            Back-off restarting failed container %d",
					i .. "s (x2 over 3m)",
					i
				)
			)
		end
		local started = os.clock()
		local out = describeParser.parse(lines)
		local elapsed = os.clock() - started
		local events = out.objects[1].events
		assert(events, "events")
		expect(#events).toBe(1000)
		expect(events[1000].age).toBe("1000s (x2 over 3m)")
		expect(elapsed < 0.2).toBe(true)
	end)
end)

return nil
