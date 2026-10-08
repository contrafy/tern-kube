--!strict
-- Relations over the real JSON world captured from the kind cluster
-- (tests/fixtures/real/json-world, scripts/fixtures/capture-json.sh). A fake
-- kubectl answers each RelQuery from those fixtures with kubectl's own
-- semantics (name, -l selector, -o name), so the specs exercise the real
-- query strings the host will run.
local Relations = require("../../../plugin/lib/explore/relations")
local Selector = require("../../../plugin/lib/explore/selector")
local fixtures = require("../../lib/fixtures")
local decoder = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local WORLD = "real/json-world/"
local APPS, BATCH, CRD = "tern-test-apps", "tern-test-batch", "tern-test-crd"
local NODE = "kube-lens-dev-control-plane"

local cache: { [string]: { any } } = {}

local function scenario(ns: string?): string
	return if ns then "ns-" .. string.gsub(ns, "^tern%-test%-", "") else "cluster"
end

local function fixtureItems(path: string): { any }
	local hit = cache[path]
	if hit then
		return hit
	end
	local items: { any } = if fixtures.has(path) then decoder.decode(fixtures.read(path)).items else {}
	cache[path] = items
	return items
end

local function names(path: string): { string }
	local out: { string } = {}
	if fixtures.has(path) then
		for _, line in fixtures.lines(path) do
			table.insert(out, (string.gsub(line, "^[^/]+/", "")))
		end
	end
	return out
end

local function world(plural: string, ns: string?): { any }?
	local dir = WORLD .. scenario(ns) .. "/"
	if plural == "configmaps" then
		-- kube-root-ca.crt holds the cluster CA, so it is captured by name only.
		local items = table.clone(
			fixtureItems(dir .. "get_configmaps_--field-selector=metadata.name!=kube-root-ca.crt_-o_json.txt")
		)
		for _, name in names(dir .. "get_configmaps_-o_name.txt") do
			if name == "kube-root-ca.crt" then
				table.insert(
					items,
					{ apiVersion = "v1", kind = "ConfigMap", metadata = { name = name, namespace = ns } }
				)
			end
		end
		return items
	end
	local path = dir .. "get_" .. plural .. "_-o_json.txt"
	if not fixtures.has(path) then
		return nil
	end
	return fixtureItems(path)
end

local function objectNamed(plural: string, ns: string?, name: string): any
	for _, item in (world(plural, ns) or {}) :: { any } do
		if item.metadata.name == name then
			return item
		end
	end
	error(string.format("fixture has no %s %s", plural, name))
end

type Extra = { [string]: { any } }

local seenQueries: { Relations.RelQuery } = {}

-- Answers one query like `kubectl get <kind> [name] [-n ns] [-l sel] -o json|name`.
local function fakeKubectl(q: Relations.RelQuery, extra: Extra?): Relations.QueryResult?
	table.insert(seenQueries, q)
	local plural = string.match(q.kind, "^[^.]+") :: string
	local source: { any }
	if plural == "secrets" then
		if not q.nameOnly then
			error("secret queried without -o name: " .. q.key)
		end
		local lines: { string } = {}
		for _, name in names(WORLD .. scenario(q.namespace) .. "/get_secrets_-o_name.txt") do
			if q.name == nil or q.name == name then
				table.insert(lines, "secret/" .. name)
			end
		end
		return Relations.itemsFromNames(q, table.concat(lines, "\n"))
	end
	local base = world(plural, q.namespace)
	local added = extra and extra[plural]
	if base == nil and added == nil then
		return nil
	end
	source = table.clone(base or {})
	for _, item in (added or {}) :: { any } do
		table.insert(source, item)
	end
	local sel: Selector.Selector? = nil
	if q.selector then
		local parsed, err = Selector.parse(q.selector)
		if parsed == nil then
			error("query selector does not parse: " .. tostring(err))
		end
		sel = parsed
	end
	local items: { any } = {}
	for _, item in source do
		local m = item.metadata
		if
			(q.name == nil or m.name == q.name)
			and (q.namespace == nil or m.namespace == nil or m.namespace == q.namespace)
			and (sel == nil or Selector.matches(sel, m.labels))
		then
			table.insert(items, item)
		end
	end
	return { items = items }
end

-- The host loop: run pending queries until none remain, then build.
local function explore(root: any, opts: Relations.Options?, extra: Extra?): (Relations.Graph, Relations.Results)
	local results: Relations.Results = {}
	for _ = 1, 10 do
		local wanted = Relations.pending(root, results, opts)
		if #wanted == 0 then
			break
		end
		for _, q in wanted do
			local r = fakeKubectl(q, extra)
			if r then
				results[q.key] = r
			else
				results[q.key] = { items = {}, error = "not captured" }
			end
		end
	end
	return Relations.build(root, results, opts), results
end

local function node(g: Relations.Graph, kind: string, name: string): Relations.GraphNode
	for _, n in g.nodes do
		if n.ref.kind == kind and n.ref.name == name then
			return n
		end
	end
	error(string.format("graph has no %s/%s", kind, name))
end

local function hasNode(g: Relations.Graph, kind: string, name: string): boolean
	for _, n in g.nodes do
		if n.ref.kind == kind and n.ref.name == name then
			return true
		end
	end
	return false
end

local function edge(
	g: Relations.Graph,
	from: Relations.GraphNode,
	to: Relations.GraphNode,
	relation: string
): Relations.GraphEdge?
	for _, e in g.edges do
		if e.from == from.key and e.to == to.key and e.relation == relation then
			return e
		end
	end
	return nil
end

local function count(g: Relations.Graph, kind: string): number
	local n = 0
	for _, x in g.nodes do
		if x.ref.kind == kind then
			n += 1
		end
	end
	return n
end

local function hasNote(g: Relations.Graph, pattern: string): boolean
	for _, n in g.notes do
		if string.find(n, pattern) then
			return true
		end
	end
	return false
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function webPods(): { any }
	local out: { any } = {}
	for _, pod in world("pods", APPS) :: { any } do
		if pod.metadata.labels.app == "web" then
			table.insert(out, pod)
		end
	end
	return out
end

-- Generated names (pod/ReplicaSet/slice hashes) change on every world rebuild.
local function nameWithLabel(plural: string, ns: string, key: string, value: string): string
	for _, item in world(plural, ns) :: { any } do
		local labels = item.metadata.labels
		if labels and labels[key] == value then
			return item.metadata.name
		end
	end
	error(string.format("fixture has no %s with %s=%s", plural, key, value))
end

local WEB_RS = nameWithLabel("replicasets", APPS, "app", "web")
local WEB_SLICE = nameWithLabel("endpointslices", APPS, "kubernetes.io/service-name", "web")
local DONE_POD = nameWithLabel("pods", BATCH, "batch.kubernetes.io/job-name", "done-job")
local FAIL_POD = nameWithLabel("pods", BATCH, "batch.kubernetes.io/job-name", "fail-job")
local WEB_PODS: { string } = {}
for _, pod in webPods() do
	table.insert(WEB_PODS, pod.metadata.name)
end
table.sort(WEB_PODS)

describe("relations.queriesFor", function()
	it("narrows workload children with the workload selector and pins the namespace", function()
		local qs = Relations.queriesFor(objectNamed("deployments", APPS, "web"))
		expect(#qs).toBe(1)
		expect(qs[1].kind).toBe("replicasets.apps")
		expect(qs[1].namespace).toBe(APPS)
		expect(qs[1].selector).toBe("app=web")
		expect(qs[1].provenance).toBe("ownerReference")
	end)

	it("asks for nodes cluster-scoped (no namespace, never all namespaces)", function()
		local pod = webPods()[1]
		local nodeQuery: Relations.RelQuery? = nil
		for _, q in Relations.queriesFor(pod) do
			if q.kind == "nodes" then
				nodeQuery = q
			end
		end
		expect(nodeQuery and nodeQuery.name).toBe(NODE)
		expect(nodeQuery and nodeQuery.namespace).toBeNil()
		expect(nodeQuery and nodeQuery.provenance).toBe("node binding")
	end)

	it("lists EndpointSlices by the service-name label", function()
		local qs = Relations.queriesFor(objectNamed("services", APPS, "web"))
		local selectors: { string } = {}
		for _, q in qs do
			table.insert(selectors, q.kind .. " " .. tostring(q.selector))
		end
		expect(selectors).toEqual({ "pods app=web", "endpointslices.discovery.k8s.io kubernetes.io/service-name=web" })
	end)

	it("dedupes queries by key", function()
		local ing = objectNamed("ingresses", APPS, "web")
		local qs = Relations.queriesFor(ing)
		local keys: { [string]: boolean } = {}
		for _, q in qs do
			expect(keys[q.key]).toBeNil()
			keys[q.key] = true
		end
		expect(#qs).toBe(2)
	end)
end)

describe("relations.build over the real world", function()
	it("walks Deployment -> ReplicaSet -> Pods by owner uid", function()
		local g = explore(objectNamed("deployments", APPS, "web"))
		local deploy = node(g, "Deployment", "web")
		local rs = node(g, "ReplicaSet", WEB_RS)
		expect(deploy.depth).toBe(0)
		expect(deploy.provenance).toBe("root")
		expect(rs.depth).toBe(1)
		expect(rs.provenance).toBe("ownerReference")
		expect(rs.parent).toBe(deploy.key)
		expect(edge(g, deploy, rs, "owns") ~= nil).toBe(true)
		for _, name in WEB_PODS do
			local pod = node(g, "Pod", name)
			expect(pod.depth).toBe(2)
			expect(pod.provenance).toBe("ownerReference")
			expect(pod.summary).toBe("Running 1/1")
			expect(edge(g, rs, pod, "owns") ~= nil).toBe(true)
		end
		expect(count(g, "ReplicaSet")).toBe(1)
		expect(count(g, "Pod")).toBe(2)
		expect(g.truncated).toBe(false)
	end)

	it("walks a Pod up to its owners without fanning out to siblings", function()
		local pod = objectNamed("pods", APPS, WEB_PODS[1])
		local g = explore(pod)
		local root = node(g, "Pod", WEB_PODS[1])
		local rs = node(g, "ReplicaSet", WEB_RS)
		local deploy = node(g, "Deployment", "web")
		expect(rs.depth).toBe(1)
		expect(deploy.depth).toBe(2)
		expect(edge(g, rs, root, "owns") ~= nil).toBe(true)
		expect(edge(g, deploy, rs, "owns") ~= nil).toBe(true)
		expect(hasNode(g, "Pod", WEB_PODS[2])).toBe(false)
	end)

	it("links a Pod to its Node, ConfigMaps and ServiceAccount from the spec", function()
		local pod = objectNamed("pods", APPS, "db-0")
		local g = explore(pod)
		local root = node(g, "Pod", "db-0")
		local n = node(g, "Node", NODE)
		expect(n.provenance).toBe("node binding")
		expect(n.summary).toBe("Ready")
		expect(n.ref.namespace).toBeNil()
		expect(edge(g, root, n, "runs on") ~= nil).toBe(true)
		local ca = node(g, "ConfigMap", "kube-root-ca.crt")
		expect(ca.provenance).toBe("spec reference")
		expect(ca.missing).toBe(false)
		expect(edge(g, root, ca, "uses config") ~= nil).toBe(true)
		-- ServiceAccounts are not in the fixture world: shown, flagged, not invented.
		local sa = node(g, "ServiceAccount", "default")
		expect(sa.missing).toBe(true)
		expect(sa.summary).toBe("fetch failed")
		expect(node(g, "StatefulSet", "db").depth).toBe(1)
	end)

	it("links Secrets by reference only, never fetching values", function()
		local pod = deepCopy(objectNamed("pods", APPS, "crashloop"))
		pod.spec.containers[1].env = {
			{ name = "PASSWORD", valueFrom = { secretKeyRef = { name = "app-secret", key = "password" } } },
		}
		pod.spec.imagePullSecrets = { { name = "registry-creds" } }
		table.clear(seenQueries)
		local g = explore(pod)
		local secret = node(g, "Secret", "app-secret")
		expect(secret.summary).toBe("reference only")
		expect(secret.missing).toBe(false)
		expect(secret.provenance).toBe("spec reference")
		local creds = node(g, "Secret", "registry-creds")
		expect(creds.missing).toBe(true)
		expect(creds.summary).toBe("not found")
		local secretQueries = 0
		for _, q in seenQueries do
			if string.match(q.kind, "^secrets") then
				secretQueries += 1
				expect(q.nameOnly).toBe(true)
			end
		end
		expect(secretQueries).toBe(2)
	end)

	it("relates a Service to EndpointSlices and to Pods via targetRef and selector", function()
		local g = explore(objectNamed("services", APPS, "web"))
		local svc = node(g, "Service", "web")
		expect(svc.summary).toBe("ClusterIP " .. objectNamed("services", APPS, "web").spec.clusterIP)
		local slice = node(g, "EndpointSlice", WEB_SLICE)
		expect(slice.provenance).toBe("endpointslice")
		expect(slice.summary).toBe("2/2 ready")
		expect(edge(g, svc, slice, "endpoints") ~= nil).toBe(true)
		for _, name in WEB_PODS do
			local pod = node(g, "Pod", name)
			local selects = edge(g, svc, pod, "selects")
			local targets = edge(g, slice, pod, "targets")
			expect(selects and selects.provenance).toBe("selector (heuristic)")
			expect(targets and targets.provenance).toBe("endpoint targetRef")
			-- The strongest evidence wins for the node.
			expect(pod.provenance).toBe("endpoint targetRef")
		end
		expect(count(g, "EndpointSlice")).toBe(1)
	end)

	it("keeps selector-only Pods marked heuristic", function()
		local g = explore(objectNamed("services", APPS, "web"), { maxDepth = 1 })
		expect(node(g, "Pod", WEB_PODS[1]).provenance).toBe("selector (heuristic)")
	end)

	it("never selects Pods for an ExternalName Service", function()
		local g = explore(objectNamed("services", APPS, "external-docs"))
		expect(count(g, "Pod")).toBe(0)
	end)

	it("follows Ingress backends to Services and TLS to a Secret reference", function()
		local g = explore(objectNamed("ingresses", APPS, "web"))
		local ing = node(g, "Ingress", "web")
		expect(ing.summary).toBe("app.example.com, api.example.com")
		local svc = node(g, "Service", "web")
		expect(svc.provenance).toBe("spec reference")
		expect(edge(g, ing, svc, "routes to") ~= nil).toBe(true)
		expect(count(g, "Service")).toBe(1)
		local tls = node(g, "Secret", "web-tls")
		expect(tls.missing).toBe(true)
		expect(tls.summary).toBe("not found")
		expect(edge(g, ing, tls, "tls") ~= nil).toBe(true)
		-- Depth 2 reaches the Service's endpoint slice and selected pods.
		expect(node(g, "Pod", WEB_PODS[1]).depth).toBe(2)
		expect(node(g, "EndpointSlice", WEB_SLICE).depth).toBe(2)
	end)

	it("relates Jobs to their Pods and Pods back to Jobs", function()
		local g = explore(objectNamed("jobs", BATCH, "done-job"))
		local job = node(g, "Job", "done-job")
		expect(job.summary).toBe("Complete")
		local pod = node(g, "Pod", DONE_POD)
		expect(edge(g, job, pod, "owns") ~= nil).toBe(true)
		expect(count(g, "Pod")).toBe(1)

		local up = explore(objectNamed("pods", BATCH, FAIL_POD))
		local failed = node(up, "Job", "fail-job")
		expect(failed.summary).toBe("Failed")
		expect(edge(up, failed, node(up, "Pod", FAIL_POD), "owns") ~= nil).toBe(true)
	end)

	it("walks CronJob -> Job -> Pod", function()
		-- The real world has never run nightly-report: derive its Job and Pod
		-- from done-job so the chain carries real shapes with the CronJob's uid.
		local cron = objectNamed("cronjobs", BATCH, "nightly-report")
		local job = deepCopy(objectNamed("jobs", BATCH, "done-job"))
		job.metadata.name = "nightly-report-29000000"
		job.metadata.uid = "synthetic-job-uid"
		job.metadata.ownerReferences = {
			{
				apiVersion = "batch/v1",
				kind = "CronJob",
				name = "nightly-report",
				uid = cron.metadata.uid,
				controller = true,
			},
		}
		job.spec.selector = { matchLabels = { ["batch.kubernetes.io/controller-uid"] = "synthetic-job-uid" } }
		local pod = deepCopy(objectNamed("pods", BATCH, DONE_POD))
		pod.metadata.name = "nightly-report-29000000-abcde"
		pod.metadata.uid = "synthetic-pod-uid"
		pod.metadata.labels = { ["batch.kubernetes.io/controller-uid"] = "synthetic-job-uid" }
		pod.metadata.ownerReferences = {
			{
				apiVersion = "batch/v1",
				kind = "Job",
				name = job.metadata.name,
				uid = "synthetic-job-uid",
				controller = true,
			},
		}
		local extra = { jobs = { job }, pods = { pod } }
		local g = explore(cron, nil, extra)
		local cronNode = node(g, "CronJob", "nightly-report")
		expect(cronNode.summary).toBe("schedule 0 3 * * *")
		local jobNode = node(g, "Job", job.metadata.name)
		local podNode = node(g, "Pod", pod.metadata.name)
		expect(edge(g, cronNode, jobNode, "owns") ~= nil).toBe(true)
		expect(edge(g, jobNode, podNode, "owns") ~= nil).toBe(true)
		expect(count(g, "Job")).toBe(1)

		local paused = explore(objectNamed("cronjobs", BATCH, "paused-cleanup"))
		expect(node(paused, "CronJob", "paused-cleanup").summary).toBe("schedule */15 * * * *, suspended")
		expect(count(paused, "Job")).toBe(0)
	end)

	it("relates custom resources only through ownerReferences and configured child kinds", function()
		local gizmo = objectNamed("widgets", CRD, "gizmo")
		expect(#Relations.queriesFor(gizmo)).toBe(0)
		local cm = {
			apiVersion = "v1",
			kind = "ConfigMap",
			metadata = {
				name = "gizmo-config",
				namespace = CRD,
				uid = "synthetic-cm-uid",
				ownerReferences = {
					{
						apiVersion = "lens.example.com/v1alpha1",
						kind = "Widget",
						name = "gizmo",
						uid = gizmo.metadata.uid,
					},
				},
			},
			data = { a = "1" },
		}
		local g = explore(gizmo, { childKinds = { "configmaps" } }, { configmaps = { cm } })
		local child = node(g, "ConfigMap", "gizmo-config")
		expect(child.summary).toBe("1 keys")
		expect(edge(g, node(g, "Widget", "gizmo"), child, "owns") ~= nil).toBe(true)

		local up = explore(cm, nil, { configmaps = { cm } })
		local owner = node(up, "Widget", "gizmo")
		expect(owner.ref.group).toBe("lens.example.com")
		expect(owner.provenance).toBe("ownerReference")
	end)
end)

describe("relations guards", function()
	it("stops at a synthetic self-owner and reports the cycle", function()
		local pod = deepCopy(objectNamed("pods", APPS, "crashloop"))
		pod.metadata.ownerReferences = {
			{ apiVersion = "v1", kind = "Pod", name = "crashloop", uid = pod.metadata.uid },
		}
		local g = explore(pod)
		expect(count(g, "Pod")).toBe(1)
		for _, e in g.edges do
			expect(e.from == e.to).toBe(false)
		end
		expect(hasNote(g, "cycle")).toBe(true)
	end)

	it("terminates on an ownership loop between two objects", function()
		local a = deepCopy(objectNamed("widgets", CRD, "gizmo"))
		local b = deepCopy(objectNamed("widgets", CRD, "sprocket"))
		a.metadata.ownerReferences =
			{ { apiVersion = "lens.example.com/v1alpha1", kind = "Widget", name = "sprocket", uid = b.metadata.uid } }
		b.metadata.ownerReferences =
			{ { apiVersion = "lens.example.com/v1alpha1", kind = "Widget", name = "gizmo", uid = a.metadata.uid } }
		local results: Relations.Results = {}
		for _, q in Relations.queriesFor(a) do
			results[q.key] = { items = { a, b } }
		end
		for _, q in Relations.queriesFor(b) do
			results[q.key] = { items = { a, b } }
		end
		local g = Relations.build(a, results, { maxDepth = 10 })
		expect(#g.nodes).toBe(2)
		expect(hasNote(g, "cycle")).toBe(true)
	end)

	local function syntheticPods(rs: any, n: number): { any }
		local template = webPods()[1]
		local pods: { any } = table.create(n)
		for i = 1, n do
			local pod = deepCopy(template)
			pod.metadata.name = string.format("synthetic-%04d", i)
			pod.metadata.uid = "synthetic-pod-" .. i
			pod.metadata.ownerReferences =
				{ { apiVersion = "apps/v1", kind = "ReplicaSet", name = rs.metadata.name, uid = rs.metadata.uid } }
			pods[i] = pod
		end
		return pods
	end

	local function rsResults(rs: any, pods: { any }): Relations.Results
		local results: Relations.Results = {}
		for _, q in Relations.queriesFor(rs) do
			results[q.key] = { items = if q.kind == "pods" then pods else {} }
		end
		return results
	end

	it("caps fan-out per relation with a +N more note", function()
		local rs = objectNamed("replicasets", APPS, WEB_RS)
		local g = Relations.build(rs, rsResults(rs, syntheticPods(rs, 120)), { maxDepth = 1 })
		expect(count(g, "Pod")).toBe(Relations.DEFAULT_FAN_OUT)
		expect(g.truncated).toBe(true)
		expect(hasNote(g, "^%+70 more pods")).toBe(true)
	end)

	it("honours the maxNodes budget", function()
		local rs = objectNamed("replicasets", APPS, WEB_RS)
		local g = Relations.build(rs, rsResults(rs, syntheticPods(rs, 30)), { maxDepth = 1, maxNodes = 10 })
		expect(#g.nodes).toBe(10)
		expect(g.truncated).toBe(true)
		expect(hasNote(g, "budget")).toBe(true)
	end)

	it("builds a graph over 1000 synthetic pods in under 50 ms", function()
		local svc = objectNamed("services", APPS, "web")
		local rs = objectNamed("replicasets", APPS, WEB_RS)
		local pods = syntheticPods(rs, 1000)
		local endpoints: { any } = table.create(#pods)
		for i, pod in pods do
			endpoints[i] = {
				addresses = { "10.0.0." .. i },
				conditions = { ready = true },
				targetRef = { kind = "Pod", name = pod.metadata.name, namespace = APPS, uid = pod.metadata.uid },
			}
		end
		local slice = deepCopy(objectNamed("endpointslices", APPS, WEB_SLICE))
		slice.endpoints = endpoints
		local nodes = world("nodes", nil) :: { any }
		local results: Relations.Results = {}
		local opts: Relations.Options = { maxNodes = 5000, fanOut = 1000 }
		for _ = 1, 3 do
			for _, q in Relations.pending(svc, results, opts) do
				local plural = string.match(q.kind, "^[^.]+")
				local items: { any } = if plural == "pods"
					then pods
					elseif plural == "endpointslices" then { slice }
					elseif plural == "nodes" then nodes
					else {}
				results[q.key] = { items = items }
			end
		end
		local start = os.clock()
		local g = Relations.build(svc, results, opts)
		local elapsed = (os.clock() - start) * 1000
		expect(count(g, "Pod")).toBe(1000)
		expect(node(g, "Pod", "synthetic-0500").provenance).toBe("endpoint targetRef")
		expect(g.truncated).toBe(false)
		if elapsed >= 50 then
			error(string.format("build took %.1f ms (budget 50 ms)", elapsed))
		end
	end)
end)

describe("relations.itemsFromNames", function()
	it("keeps only kind, name and namespace from -o name output", function()
		local q = Relations.queriesFor(objectNamed("ingresses", APPS, "web"))[2]
		expect(q.nameOnly).toBe(true)
		local r = Relations.itemsFromNames(q, "secret/web-tls\n")
		expect(r.items).toEqual({
			{ apiVersion = "v1", kind = "Secret", metadata = { name = "web-tls", namespace = APPS } },
		})
	end)
end)

return nil
