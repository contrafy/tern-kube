--!strict
-- Risk tiers. Ordinary apply/scale/restart get a one-click confirm; anything
-- that is hard to undo or wider than it looks (deletes, selectors, --all,
-- namespaces, CRDs, cluster-scoped objects, prune, force) needs the target
-- typed; an unfinished or failed preview blocks. Manifest scans are text
-- heuristics and must say so: kube-lens never claims policy conformance.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Plan = require("../../../plugin/lib/mutation/plan")
local Risk = require("../../../plugin/lib/mutation/risk")
local T = require("../../../plugin/lib/mutation/types")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV: T.Env = { context = "kind-dev", contextSource = "chosen", namespace = "apps", cwd = "/w" }

local function plan(line: string, env: T.Env?): T.Plan
	local p, diags = Plan.fromArgv(string.split(line, " "), env or ENV)
	expect(diags).toEqual({})
	return p :: T.Plan
end

local function ref(kind: string, name: string, namespace: string?): any
	return { kind = kind, name = name, namespace = namespace, source = "live" }
end

local function ids(a: T.Assessment): { string }
	local out = {}
	for _, r in a.reasons do
		table.insert(out, r.id)
	end
	table.sort(out)
	return out
end

local function reason(a: T.Assessment, id: string): T.Reason
	for _, r in a.reasons do
		if r.id == id then
			return r
		end
	end
	error("no reason " .. id)
end

local OK = { previewOk = true }

local function facts(over: { [string]: any }): Risk.Facts
	local f: any = { previewOk = true }
	for k, v in over do
		f[k] = v
	end
	return f
end

local LIMITED = [[
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: web
          image: nginx
          resources:
            limits:
              cpu: 100m
]]

describe("risk tiers: simple", function()
	it("ordinary apply is a one-click confirm", function()
		local diff = Diffseg.parse(fixtures.read("real/mutate-configured/diff_-f_mutate+app-v2.yaml.txt"))
		local a = Risk.assess(
			plan("kubectl apply -f app.yaml"),
			facts({ diff = diff, manifests = { { path = "/w/app.yaml", text = LIMITED } } })
		)
		expect(a.tier).toBe("simple")
		expect(ids(a)).toEqual({})
		expect(a.token).toBe("apply 2 resources")
	end)

	it("scale and restart of one named workload are simple", function()
		local scale = Risk.assess(
			plan("kubectl scale deploy/web --replicas=3"),
			facts({ targets = { ref("Deployment", "web", "apps") } })
		)
		expect(scale.tier).toBe("simple")
		expect(scale.token).toBe("web")
		expect(Risk.assess(plan("kubectl rollout restart deploy/web"), OK).tier).toBe("simple")
	end)

	it("quick-action debug pod and cronjob run are simple", function()
		expect(Risk.assess(plan("kubectl debug -it web --image=busybox"), OK).tier).toBe("simple")
		expect(Risk.assess(plan("kubectl create job j --from=cronjob/c"), OK).tier).toBe("simple")
	end)

	it("flags scale to zero without escalating", function()
		local a = Risk.assess(plan("kubectl scale deploy/web --replicas=0"), OK)
		expect(a.tier).toBe("simple")
		expect(reason(a, "scale-zero").severity).toBe("medium")
	end)
end)

describe("risk tiers: typed", function()
	it("every delete is typed, with the object name as the token", function()
		local a = Risk.assess(plan("kubectl delete pod web"), facts({ targets = { ref("Pod", "web", "apps") } }))
		expect(a.tier).toBe("typed")
		expect(a.token).toBe("web")
		expect(ids(a)).toEqual({ "delete" })
	end)

	it("multi-object deletes ask for the `delete N resources` phrase", function()
		local a = Risk.assess(
			plan("kubectl delete pods -l app=web"),
			facts({ targets = { ref("Pod", "a", "apps"), ref("Pod", "b", "apps"), ref("Pod", "c", "apps") } })
		)
		expect(a.token).toBe("delete 3 resources")
		expect(ids(a)).toEqual({ "broad-selector", "delete" })
		expect(reason(a, "broad-selector").severity).toBe("high")
	end)

	it("flags --all, the `all` type and -A as broad deletes", function()
		expect(ids(Risk.assess(plan("kubectl delete pods --all"), OK))).toContain("delete-all")
		expect(ids(Risk.assess(plan("kubectl delete all -l app=web"), OK))).toContain("all-type")
		expect(ids(Risk.assess(plan("kubectl delete pods -l app=web -A"), OK))).toContain("all-namespaces")
	end)

	it("flags deletes that span several namespaces", function()
		local a = Risk.assess(
			plan("kubectl delete -f app.yaml"),
			facts({ targets = { ref("Pod", "a", "x"), ref("Pod", "b", "y") } })
		)
		expect(reason(a, "multiple-namespaces").tier).toBe("typed")
	end)

	it("flags namespace, CRD and cluster-scoped deletions", function()
		local ns = Risk.assess(
			plan("kubectl delete namespace tern-test-x"),
			facts({ targets = { ref("Namespace", "tern-test-x") } })
		)
		expect(ids(ns)).toEqual({ "delete", "namespace-delete" })
		expect(ns.token).toBe("tern-test-x")
		expect(ids(Risk.assess(plan("kubectl delete crd widgets.lens.example.com"), OK))).toContain("crd-delete")
		expect(ids(Risk.assess(plan("kubectl delete clusterrole view-all"), OK))).toContain("cluster-scoped-delete")
		expect(ids(Risk.assess(plan("kubectl delete node worker"), OK))).toContain("cluster-scoped-delete")
	end)

	it("finds a namespace hidden in a `delete -f` manifest", function()
		local a = Risk.assess(
			plan("kubectl delete -f ns.yaml"),
			facts({
				manifests = {
					{ path = "/w/ns.yaml", text = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: x\n" },
				},
			})
		)
		expect(ids(a)).toContain("namespace-delete")
	end)

	it("flags force and zero grace period", function()
		local a = Risk.assess(plan("kubectl delete pod web --force --grace-period=0"), OK)
		expect(ids(a)).toEqual({ "delete", "force", "grace-period-zero" })
		expect(reason(Risk.assess(plan("kubectl apply -f a.yaml --force"), OK), "force").tier).toBe("typed")
	end)

	it("prune is typed, and the deletions the diff shows are counted", function()
		local diff = Diffseg.parse(
			fixtures.read(
				"real/mutate-preview/diff_-f_preview+widgets.yaml_--prune_-l_app=widgets_--prune-allowlist=lens.example.com+v1alpha1+Widget.txt"
			)
		)
		local a = Risk.assess(plan("kubectl apply -f widgets.yaml --prune -l app=widgets"), facts({ diff = diff }))
		expect(a.tier).toBe("typed")
		expect(ids(a)).toEqual({ "prune", "prune-deletes" })
		expect(reason(a, "prune-deletes").text).toBe("1 object(s) would be deleted")
		expect(a.token).toBe("apply 3 resources")
		expect(reason(Risk.assess(plan("kubectl apply -f dir --prune --all"), OK), "prune").text).toContain("--all")
	end)

	it("flags namespace deletion through prune", function()
		local diff = Diffseg.parse(table.concat({
			"diff -u -N /tmp/L/v1.Namespace..old /tmp/M/v1.Namespace..old",
			"--- /tmp/L/v1.Namespace..old\t2026",
			"+++ /tmp/M/v1.Namespace..old\t1970",
			"@@ -1 +0,0 @@",
			"-apiVersion: v1",
		}, "\n"))
		expect(ids(Risk.assess(plan("kubectl apply -f d --prune --all"), facts({ diff = diff })))).toContain(
			"prune-namespace"
		)
	end)

	it("broad scale and restart are typed", function()
		expect(Risk.assess(plan("kubectl scale deploy --all --replicas=1"), OK).tier).toBe("typed")
		expect(Risk.assess(plan("kubectl rollout restart deploy -l app=web"), OK).tier).toBe("typed")
		expect(Risk.assess(plan("kubectl rollout restart deployment"), OK).tier).toBe("typed")
	end)

	it("debug node is typed with the node name (privileged pod in host namespaces)", function()
		local a = Risk.assess(plan("kubectl debug node/worker -it --image=busybox"), OK)
		expect(a.tier).toBe("typed")
		expect(a.token).toBe("worker")
	end)

	it("--server/--cluster make the shown context untrustworthy", function()
		expect(
			reason(Risk.assess(plan("kubectl scale deploy/web --replicas=1 --server=https://x"), OK), "target-override").tier
		).toBe("typed")
	end)

	it("falls back to the context name when the affected objects are unknown", function()
		expect(Risk.assess(plan("kubectl delete pods -l app=web"), OK).token).toBe("kind-dev")
	end)
end)

describe("risk tiers: blocked", function()
	it("a failed preview blocks, overridable only through confirm's config gate", function()
		local a = Risk.assess(plan("kubectl delete pod web"), { previewOk = false, failure = "Forbidden" })
		expect(a.tier).toBe("blocked")
		local r = reason(a, "preview-failed")
		expect(r.overridable).toBe(true)
		expect(r.text).toBe("The preview failed: Forbidden")
	end)

	it("an unfinished preview blocks and cannot be overridden", function()
		local a = Risk.assess(plan("kubectl scale deploy/web --replicas=1"), {})
		expect(a.tier).toBe("blocked")
		expect(reason(a, "preview-pending").overridable).toBe(false)
	end)
end)

describe("risk manifest heuristics (advisory)", function()
	local function scan(text: string): T.Assessment
		return Risk.assess(
			plan("kubectl apply -f m.yaml"),
			facts({ manifests = { { path = "/w/m.yaml", text = text } } })
		)
	end

	it("flags privileged pods, hostPath and host namespaces as typed, labelled advisory", function()
		local a = scan([[
apiVersion: v1
kind: Pod
metadata:
  name: root
spec:
  hostNetwork: true
  hostPID: true
  containers:
    - name: c
      securityContext:
        privileged: true
      resources:
        limits:
          cpu: 1
  volumes:
    - name: h
      hostPath:
        path: /
]])
		expect(ids(a)).toEqual({ "host-namespaces", "host-path", "privileged" })
		expect(a.tier).toBe("typed")
		local p = reason(a, "privileged")
		expect(p.advisory).toBe(true)
		expect(p.text).toBe("Privileged container: Pod root (advisory heuristic)")
	end)

	it("flags wildcard RBAC and cluster-admin bindings (real preview input)", function()
		local a = scan(
			'apiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: w\nrules:\n  - apiGroups: ["*"]\n    resources: ["*"]\n    verbs: ["*"]\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata:\n  name: b\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: cluster-admin\n'
		)
		expect(ids(a)).toEqual({ "cluster-admin", "rbac-wildcard" })
	end)

	it("flags public services and ingresses without escalating", function()
		local a = scan(
			"apiVersion: v1\nkind: Service\nmetadata:\n  name: lb\nspec:\n  type: LoadBalancer\n---\napiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: web\n"
		)
		expect(ids(a)).toEqual({ "ingress", "public-service" })
		expect(a.tier).toBe("simple")
		expect(reason(a, "public-service").text).toBe(
			"Service exposed outside the cluster (LoadBalancer/NodePort): Service lb (advisory heuristic)"
		)
	end)

	it("flags workloads without limits at low severity", function()
		local a = scan("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: apps\nspec: {}\n")
		expect(reason(a, "missing-limits").severity).toBe("low")
		expect(reason(a, "missing-limits").text).toContain("Deployment apps/web")
	end)

	it("ignores commented-out settings", function()
		expect(ids(scan(LIMITED .. "#      privileged: true\n"))).toEqual({})
	end)

	it("orders reasons by severity so the worst comes first", function()
		local a = scan(
			"apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  hostNetwork: true\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: s\nspec:\n  type: NodePort\n"
		)
		expect(a.reasons[1].severity).toBe("high")
		expect(a.reasons[#a.reasons].severity).toBe("low")
	end)
end)

return nil
