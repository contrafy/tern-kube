--!strict
-- Risk tiers. Ordinary apply/scale/restart get a one-click confirm; anything
-- that is hard to undo or wider than it looks (deletes, selectors, --all,
-- namespaces, CRDs, cluster-scoped objects, prune, force) needs the target
-- typed; an unfinished or failed preview blocks. Manifest scans are text
-- heuristics and must say so: tern-kube never claims policy conformance.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Drain = require("../../../plugin/lib/mutation/drain")
local Objdiff = require("../../../plugin/lib/mutation/objdiff")
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

	-- GIT-F1: export writes REPLACE_ME for Secret values and kubectl diff
	-- masks both sides, so applying an export as is looks like any change
	-- while it overwrites the live values. Not a heuristic: typed, not advisory.
	it("a Secret with export placeholders is typed, naming the keys", function()
		local a = scan([[
apiVersion: v1
kind: Secret
metadata:
  name: db
  namespace: apps
stringData:
  password: REPLACE_ME
  user: admin
data:
  token: UkVQTEFDRV9NRQ==
---
apiVersion: v1
kind: Secret
metadata:
  name: ok
stringData:
  a: b
]])
		local r = reason(a, "secret-placeholder")
		expect(r.severity).toBe("high")
		expect(r.tier).toBe("typed")
		expect(r.advisory).toBe(false)
		expect(r.text).toBe(
			"Secret apps/db sets placeholder values (password, token): REPLACE_ME from a tern-kube export would replace the live values"
		)
		expect(a.tier).toBe("typed")
	end)
end)

local function cm(name: string, labels: { [string]: string }?, extra: { [string]: any }?): any
	local o: any = {
		apiVersion = "v1",
		kind = "ConfigMap",
		metadata = { name = name, namespace = "apps", labels = labels },
	}
	local fields: { [string]: any } = extra or {}
	for k, v in fields do
		o.metadata[k] = v
	end
	return o
end

local function diffOf(before: { any }, after: { any }): any
	return Objdiff.compute(Objdiff.pair(before, after), { showSecretValues = false })
end

local function tiers(a: T.Assessment): { string }
	local out = {}
	for _, r in a.reasons do
		table.insert(out, r.tier .. ":" .. r.id)
	end
	table.sort(out)
	return out
end

describe("risk: label and annotate", function()
	it("one labelled object is a simple confirm", function()
		local a = Risk.assess(
			plan("kubectl label configmap/cm a=b"),
			facts({
				targets = { ref("ConfigMap", "cm", "apps") },
				objects = diffOf({ cm("cm") }, { cm("cm", { a = "b" }) }),
			})
		)
		expect(a.tier).toBe("simple")
	end)

	it("a selector needs the typed `label N resources`", function()
		local p = plan("kubectl label configmap -l app=x a=b")
		local a = Risk.assess(p, facts({ targets = { ref("ConfigMap", "a", "apps"), ref("ConfigMap", "b", "apps") } }))
		expect(a.tier).toBe("typed")
		expect(reason(a, "broad-selector").tier).toBe("typed")
		expect(a.token).toBe("label 2 resources")
	end)

	it("several named objects are typed too", function()
		local p = plan("kubectl annotate configmap a b note=x")
		local a = Risk.assess(p, facts({ targets = { ref("ConfigMap", "a", "apps"), ref("ConfigMap", "b", "apps") } }))
		expect(reason(a, "multiple-objects").tier).toBe("typed")
		expect(a.token).toBe("annotate 2 resources")
	end)

	it("node and namespace labels are typed: they steer scheduling and policies", function()
		local a = Risk.assess(plan("kubectl label node n1 pool=a"), facts({ targets = { ref("Node", "n1") } }))
		expect(reason(a, "cluster-scoped").text).toContain("scheduling")
		local b = Risk.assess(
			plan("kubectl label namespace apps pod-security.kubernetes.io/enforce=privileged --overwrite"),
			facts({ targets = { ref("Namespace", "apps") } })
		)
		expect(reason(b, "pod-security").severity).toBe("high")
		expect(b.tier).toBe("typed")
	end)

	it("rewriting last-applied is typed; system keys and overwrites are flagged", function()
		local a = Risk.assess(
			plan("kubectl annotate configmap/cm kubectl.kubernetes.io/last-applied-configuration=x --overwrite"),
			OK
		)
		expect(reason(a, "last-applied").tier).toBe("typed")
		expect(reason(a, "system-keys").severity).toBe("medium")
		local o = Risk.assess(
			plan("kubectl label configmap/cm a=c --overwrite"),
			facts({ objects = diffOf({ cm("cm", { a = "b" }) }, { cm("cm", { a = "c" }) }) })
		)
		expect(reason(o, "overwrites").text).toContain("1 existing value")
	end)

	it("warns that relabelling an owned pod may detach it, and lists removals", function()
		local owned = { { kind = "ReplicaSet", name = "rs" } }
		local before: any = cm("p", { app = "web" }, { ownerReferences = owned })
		before.kind = "Pod"
		local after: any = cm("p", nil, { ownerReferences = owned })
		after.kind = "Pod"
		local a = Risk.assess(plan("kubectl label pod/p app-"), facts({ objects = diffOf({ before }, { after }) }))
		expect(reason(a, "pod-owner-labels").advisory).toBe(true)
		expect(reason(a, "removals").severity).toBe("info")
	end)

	it("says so when the dry run changes nothing", function()
		local a = Risk.assess(
			plan("kubectl label configmap/cm a=b"),
			facts({ objects = diffOf({ cm("cm", { a = "b" }) }, { cm("cm", { a = "b" }) }) })
		)
		expect(reason(a, "no-change").severity).toBe("info")
	end)
end)

describe("risk: patch", function()
	it("a JSON patch, -f targets or a cluster-scoped object are typed", function()
		local json = Risk.assess(plan("kubectl patch configmap/cm --type=json -p []"), OK)
		expect(reason(json, "json-patch").tier).toBe("typed")
		expect(reason(Risk.assess(plan("kubectl patch -f cm.yaml -p {}"), OK), "file-targets").tier).toBe("typed")
		local a = Risk.assess(plan("kubectl patch node/n1 -p {}"), facts({ targets = { ref("Node", "n1") } }))
		expect(reason(a, "cluster-scoped").tier).toBe("typed")
		expect(a.token).toBe("n1")
	end)

	it("flags removal-only patches and status subresources", function()
		local a = Risk.assess(
			plan("kubectl patch configmap/cm -p {} --subresource=status"),
			facts({ objects = diffOf({ cm("cm", { a = "b" }) }, { cm("cm") }) })
		)
		expect(reason(a, "removes-fields").severity).toBe("medium")
		expect(reason(a, "subresource").severity).toBe("info")
		expect(a.tier).toBe("simple")
	end)
end)

describe("risk: rollout undo, pause, resume", function()
	local function deploy(image: string, extra: { [string]: any }?): any
		local o: any = {
			apiVersion = "apps/v1",
			kind = "Deployment",
			metadata = { name = "web", namespace = "apps", generation = 2 },
			spec = { template = { spec = { containers = { { name = "c", image = image } } } } },
			status = { observedGeneration = 2 },
		}
		local fields: { [string]: any } = extra or {}
		for k, v in fields do
			o[k] = v
		end
		return o
	end
	local KEY = "apps.v1.Deployment.apps.web"

	it("undo is always typed and names the revision and the image change", function()
		local a = Risk.assess(
			plan("kubectl rollout undo deployment/web"),
			facts({
				targets = { ref("Deployment", "web", "apps") },
				objects = diffOf({ deploy("pause:3.10") }, { deploy("pause:3.9") }),
				undo = { { key = KEY, name = "web", from = 2, to = 1 } },
			})
		)
		expect(a.tier).toBe("typed")
		expect(a.token).toBe("web")
		expect(reason(a, "undo").text).toContain("revision 1 (images pause:3.10 -> pause:3.9)")
	end)

	it("says when the target revision is the current template", function()
		local a = Risk.assess(
			plan("kubectl rollout undo deployment/web --to-revision=2"),
			facts({
				objects = diffOf({ deploy("pause:3.10") }, { deploy("pause:3.10") }),
				undo = { { key = KEY, name = "web", from = 2, to = 2 } },
			})
		)
		expect(reason(a, "undo-noop").severity).toBe("info")
	end)

	it("pause of a paused deployment and resume of a running one change nothing", function()
		local paused = deploy("x", { spec = { paused = true } })
		local p = Risk.assess(plan("kubectl rollout pause deployment/web"), facts({ live = { paused } }))
		expect(reason(p, "already-paused").severity).toBe("info")
		local r = Risk.assess(plan("kubectl rollout resume deployment/web"), facts({ live = { deploy("x") } }))
		expect(reason(r, "not-paused").severity).toBe("info")
	end)

	it("resuming after spec changes made while paused warns about the rollout", function()
		local o = deploy("x", { spec = { paused = true } })
		o.metadata.generation = 5
		local a = Risk.assess(plan("kubectl rollout resume deployment/web"), facts({ live = { o } }))
		expect(reason(a, "resume-pending").severity).toBe("medium")
		expect(a.tier).toBe("simple")
	end)

	-- MUT-F8: kubectl refuses to restart a paused Deployment after the
	-- preview showed no finding at all.
	it("restart of a paused deployment warns that kubectl will refuse it", function()
		local paused = deploy("x", { spec = { paused = true } })
		local a = Risk.assess(plan("kubectl rollout restart deployment/web"), facts({ live = { paused } }))
		local r = reason(a, "restart-paused")
		expect(r.severity).toBe("medium")
		expect(r.text).toContain("paused")
		expect(r.text).toContain("rollout resume")
		local running = Risk.assess(plan("kubectl rollout restart deployment/web"), facts({ live = { deploy("x") } }))
		for _, x in running.reasons do
			expect(x.id ~= "restart-paused").toBe(true)
		end
	end)
end)

describe("risk: cordon, uncordon, drain", function()
	local function node(name: string, cp: boolean, off: boolean?): any
		return {
			apiVersion = "v1",
			kind = "Node",
			metadata = {
				name = name,
				labels = if cp then { ["node-role.kubernetes.io/control-plane"] = "" } else {},
			},
			spec = { unschedulable = off },
		}
	end

	it("cordon is simple, flags a control-plane node and an already cordoned one", function()
		local a = Risk.assess(
			plan("kubectl cordon n1"),
			facts({ targets = { ref("Node", "n1") }, live = { node("n1", true, true) } })
		)
		expect(a.tier).toBe("simple")
		expect(tiers(a)).toEqual({ "simple:already-cordoned", "simple:control-plane" })
		local b = Risk.assess(plan("kubectl uncordon n1"), facts({ live = { node("n1", false) } }))
		expect(reason(b, "already-uncordoned").severity).toBe("info")
		expect(reason(Risk.assess(plan("kubectl cordon -l pool=a"), OK), "broad-selector").tier).toBe("typed")
	end)

	local function drainFacts(): any
		local client = Drain.parse(
			fixtures.read("kubectl/track1/drain-client-ok.txt"),
			fixtures.read("kubectl/track1/drain-client-ok.stderr")
		)
		local server = Drain.parse(
			fixtures.read("kubectl/track1/drain-server-pdb-timeout.txt"),
			fixtures.read("kubectl/track1/drain-server-pdb-timeout.stderr")
		)
		return Drain.merge(client, server)
	end

	it("drain is typed with the node's name and names evictions and blocked pods", function()
		local a = Risk.assess(
			plan("kubectl drain n1 --ignore-daemonsets --timeout=1m --force --delete-emptydir-data --grace-period=0"),
			facts({ targets = { ref("Node", "n1") }, live = { node("n1", true) }, drain = drainFacts() })
		)
		expect(a.tier).toBe("typed")
		expect(a.token).toBe("n1")
		expect(reason(a, "drain").text).toContain("from node n1")
		expect(reason(a, "pdb-blocked").text).toContain("--timeout (1m)")
		expect(reason(a, "force-unmanaged").tier).toBe("typed")
		expect(reason(a, "emptydir-loss").tier).toBe("typed")
		expect(reason(a, "grace-period-zero").tier).toBe("typed")
		expect(reason(a, "control-plane").severity).toBe("high")
	end)

	it("drain without --timeout or with --disable-eviction says what that means", function()
		local a = Risk.assess(plan("kubectl drain n1 --disable-eviction"), facts({ targets = { ref("Node", "n1") } }))
		expect(reason(a, "no-timeout").severity).toBe("medium")
		expect(reason(a, "disable-eviction").tier).toBe("typed")
	end)

	it("a pre-flight refusal fails the preview with the flag that overrides it", function()
		local d = Drain.parse(
			fixtures.read("kubectl/track1/drain-client-preflight.txt"),
			fixtures.read("kubectl/track1/drain-client-preflight.stderr")
		)
		local a = Risk.assess(
			plan("kubectl drain n1 --timeout=1m"),
			facts({ previewOk = false, drain = Drain.merge(d, nil) })
		)
		local r = reason(a, "preview-failed")
		expect(r.tier).toBe("blocked")
		expect(r.overridable).toBe(true)
		expect(r.text).toContain("kubectl would cordon the node, then stop")
		expect(r.text).toContain("(use --force)")
	end)
end)

describe("risk: edit", function()
	local env: T.Env = {
		context = "kind-dev",
		contextSource = "chosen",
		namespace = "apps",
		cwd = "/w",
		edit = { file = "/t/e.yaml", original = "/t/o.yaml" },
	}
	local function editPlan(): T.Plan
		return plan("kubectl edit configmap/cm", env)
	end
	local function edit(over: { [string]: any }): any
		local e: any = { renamed = {}, liveChanged = {}, rejected = nil, changed = 1 }
		for k, v in over do
			e[k] = v
		end
		return e
	end

	it("one changed namespaced object is a simple confirm", function()
		local a = Risk.assess(editPlan(), facts({ targets = { ref("ConfigMap", "cm", "apps") }, edit = edit({}) }))
		expect(a.tier).toBe("simple")
	end)

	it("a renamed object blocks without override: kubectl refuses it", function()
		local a = Risk.assess(editPlan(), facts({ edit = edit({ renamed = { "v1.ConfigMap.apps.cm" } }) }))
		local r = reason(a, "edit-renamed")
		expect(r.tier).toBe("blocked")
		expect(r.overridable).toBe(false)
	end)

	it("a server rejection stays approvable so kubectl can reopen the editor", function()
		local a = Risk.assess(editPlan(), facts({ edit = edit({ rejected = "error: invalid" }) }))
		expect(reason(a, "edit-rejected").tier).toBe("simple")
		expect(a.tier).toBe("simple")
	end)

	it("RBAC kinds, several objects and drifted objects raise the bar or warn", function()
		local a = Risk.assess(
			editPlan(),
			facts({
				targets = { ref("Role", "r", "apps") },
				edit = edit({ changed = 2, liveChanged = { "rbac.authorization.k8s.io.v1.Role.apps.r" } }),
			})
		)
		expect(tiers(a)).toEqual({ "simple:live-changed", "typed:multiple-objects", "typed:sensitive-kind" })
	end)

	it("reports only manifest heuristics the edit introduces", function()
		local pod = "apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\n  namespace: apps\nspec:\n  hostNetwork: true\n"
		local priv = pod .. "  containers:\n    - name: c\n      securityContext:\n        privileged: true\n"
		local a = Risk.assess(
			editPlan(),
			facts({
				edit = edit({}),
				manifests = { { path = "/t/e.yaml", text = priv } },
				baseline = { { path = "/t/o.yaml", text = pod } },
			})
		)
		expect(reason(a, "privileged").advisory).toBe(true)
		for _, r in a.reasons do
			expect(r.id ~= "host-namespaces").toBe(true)
		end
	end)
end)

return nil
