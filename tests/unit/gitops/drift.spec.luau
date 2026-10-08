--!strict
-- Drift report for one manifest source. The report is what a user acts on
-- ("re-apply", "export into git", "delete"), so each live/git disagreement
-- must land in exactly one bucket: changed (diff modifies), missing in the
-- cluster (diff creates, or absent from the live listing), unmanaged (live,
-- in the source's namespaces and kinds, in no manifest) or ignored with a
-- reason (cluster defaults, owned or bookkeeping objects). Inputs are real:
-- kubectl diff output, the diffed manifests and the live listing captured
-- from the kind cluster by scripts/fixtures/capture-drift.sh.
local Controllers = require("../../../plugin/lib/gitops/controllers")
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Drift = require("../../../plugin/lib/gitops/drift")
local Kinds = require("../../../plugin/lib/kubectl/kinds")
local Resource = require("../../../plugin/lib/model/resource")
local Yaml = require("../../../plugin/lib/parse/yaml")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ROOT = "/repo/drift"
local SOURCE: Drift.Source = { type = "dir", root = "/repo", path = ROOT, label = "drift" }

local function addDocs(docs: { Drift.Doc }, rel: string, text: string, source: Drift.Source)
	for _, d in Yaml.split(text).docs do
		local ref = d.ref
		if ref then
			local info = Kinds.normalize(ref.kind .. if ref.group then "." .. ref.group else "")
			local clusterScoped = info.known and info.namespaced == false
			local key = if ref.namespace or clusterScoped then Resource.key(ref) else nil
			table.insert(docs, {
				key = key,
				ref = ref,
				file = ROOT .. "/" .. rel,
				startLine = d.startLine,
				endLine = d.endLine,
				source = source,
				namespaceInferred = key == nil,
				rendered = false,
			})
		end
	end
end

-- The index as gitops/index.luau builds it: one "dir" source per directory.
local function index(): Drift.Index
	local docs: { Drift.Doc } = {}
	for _, path in fixtures.list("drift/manifests/") do
		local rel = string.sub(path, #"drift/manifests/" + 1)
		local dir = string.match(rel, "^(.*)/[^/]+$")
		local source: Drift.Source = { type = "dir", root = "/repo", path = if dir then ROOT .. "/" .. dir else ROOT }
		addDocs(docs, rel, fixtures.read(path), source)
	end
	return { docs = docs }
end

local function segments(path: string): { Diffseg.Segment }
	return Diffseg.parse(fixtures.read("drift/" .. path)).segments
end

local function live(): { any }
	return json.decode(fixtures.read("drift/live/objects.json")).items
end

-- Report rows (Changed, Missing, Unmanaged) all carry `key`.
local function keys<T>(entries: { T }): { string }
	local out = {}
	for _, e in entries do
		table.insert(out, (e :: any).key)
	end
	return out
end

local function ignoredPairs(report: Drift.Report): { string }
	local out = {}
	for _, e in report.ignored do
		table.insert(out, e.key .. " = " .. e.reason)
	end
	return out
end

describe("drift.scope", function()
	it("lists the namespaces and kinds whose live objects the report needs", function()
		local s = Drift.scope(SOURCE, index(), {})
		expect(s.namespaces).toEqual({ "tern-test-drift" })
		expect(s.kinds).toEqual({
			"configmap",
			"deployment.apps",
			"service",
			"serviceaccount",
			"widget.lens.example.com",
		})
		expect(#s.docs).toBe(9)
	end)

	it("covers only the chosen directory and honours the kinds override", function()
		local s = Drift.scope({ type = "dir", path = ROOT .. "/baseline" }, index(), {
			unmanagedKinds = { "ConfigMap", "replicasets.apps" },
		})
		expect(#s.docs).toBe(5)
		expect(s.kinds).toEqual({ "configmap", "replicaset.apps" })
	end)

	it("resolves namespace-less manifests to the default namespace", function()
		local docs: { Drift.Doc } = {}
		addDocs(docs, "x/cm.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n", SOURCE)
		expect(Drift.scope(SOURCE, { docs = docs }, { defaultNamespace = "team" }).namespaces).toEqual({ "team" })
		expect(Drift.scope(SOURCE, { docs = docs }, {}).namespaces).toEqual({})
	end)
end)

describe("drift.report over a whole source (kubectl diff -R -f drift)", function()
	local function full(): Drift.Report
		return Drift.report(SOURCE, index(), segments("source/diff_-R_-f_drift.txt"), live(), {})
	end

	it("reports modified objects with their diff and manifest location", function()
		local r = full()
		expect(keys(r.changed)).toEqual({
			"/ConfigMap/tern-test-drift/app-config",
			"/Namespace//tern-test-drift",
			"apps/Deployment/tern-test-drift/web",
			"lens.example.com/Widget/tern-test-drift/gauge",
		})
		local web = r.changed[3]
		expect(web.segment.action).toBe("modify")
		expect(Diffseg.text(web.segment)).toContain("-  replicas: 2\n+  replicas: 1")
		expect(#web.docs).toBe(1)
		expect(web.docs[1].file).toBe(ROOT .. "/baseline/app.yaml")
		expect(web.docs[1].startLine).toBe(1)
		expect(r.changed[1].docs[1].startLine).toBe(29)
	end)

	it("reports objects in git but not in the cluster as missing (namespaced, CRD, cluster-scoped)", function()
		local r = full()
		expect(keys(r.missing)).toEqual({
			"/ConfigMap/tern-test-drift/only-in-git",
			"lens.example.com/Widget/tern-test-drift/dial.v2",
			"rbac.authorization.k8s.io/ClusterRole//tern-test-drift-reader",
		})
		for _, m in r.missing do
			expect(m.reason).toBe("create")
			expect(m.docs[1].file).toBe(ROOT .. "/pending/extra.yaml")
		end
	end)

	it("reports cluster objects no manifest declares, but not defaults", function()
		local r = full()
		expect(keys(r.unmanaged)).toEqual({ "/ConfigMap/tern-test-drift/hand-made" })
		local summary = r.unmanaged[1].object
		expect(summary.kind).toBe("ConfigMap")
		expect(summary.apiVersion).toBe("v1")
		expect(summary.namespace).toBe("tern-test-drift")
		expect(summary.created ~= nil).toBe(true)
		expect(ignoredPairs(r)).toEqual({
			"/ConfigMap/tern-test-drift/kube-root-ca.crt = cluster default",
			"/ServiceAccount/tern-test-drift/default = cluster default",
		})
	end)

	it("counts what is in sync", function()
		expect(full().counts).toEqual({ changed = 4, missing = 3, unmanaged = 1, ignored = 2, inSync = 2, docs = 9 })
	end)
end)

describe("drift.report per scenario", function()
	it("unchanged manifests (diff exit 0, empty output) are all in sync", function()
		local r = Drift.report(
			{ type = "file", path = ROOT .. "/baseline/service.yaml" },
			index(),
			segments("unchanged/diff_-f_drift+baseline+service.yaml.txt"),
			live(),
			{}
		)
		expect(#r.changed + #r.missing).toBe(0)
		expect(r.counts.inSync).toBe(2)
		expect(r.counts.docs).toBe(2)
	end)

	it("a CRD object edited in the cluster is changed", function()
		local r = Drift.report(
			{ type = "file", path = ROOT .. "/baseline/widgets.yaml" },
			index(),
			segments("crd/diff_-f_drift+baseline+widgets.yaml.txt"),
			live(),
			{}
		)
		expect(keys(r.changed)).toEqual({ "lens.example.com/Widget/tern-test-drift/gauge" })
		expect(r.changed[1].segment.added).toBe(3)
	end)

	it("a relabelled namespace is a cluster-scoped change", function()
		local r = Drift.report(
			{ type = "file", path = ROOT .. "/namespace.yaml" },
			index(),
			segments("cluster-scoped/diff_-f_drift+namespace.yaml.txt"),
			nil,
			{}
		)
		expect(keys(r.changed)).toEqual({ "/Namespace//tern-test-drift" })
		expect(r.changed[1].ref.namespace).toBeNil()
		expect(r.changed[1].docs[1].file).toBe(ROOT .. "/namespace.yaml")
	end)

	it("without a live listing, unmanaged objects are unknown rather than empty-handed guesses", function()
		local r = Drift.report(SOURCE, index(), segments("missing/diff_-f_drift+pending+extra.yaml.txt"), nil, {})
		expect(#r.unmanaged).toBe(0)
		expect(r.notes).toContain("live objects not listed: unmanaged objects not checked")
	end)
end)

describe("drift.report edge cases", function()
	it("flags a manifest absent from the live listing as missing even without a diff segment", function()
		local everything = live()
		local without = {}
		for _, o in everything do
			if o.metadata.name ~= "web" or o.kind ~= "Service" then
				table.insert(without, o)
			end
		end
		local r = Drift.report(SOURCE, index(), {}, without, {})
		-- Nothing was diffed: the pending objects are absent from the listing too.
		expect(keys(r.missing)).toEqual({
			"/ConfigMap/tern-test-drift/only-in-git",
			"/Service/tern-test-drift/web",
			"lens.example.com/Widget/tern-test-drift/dial.v2",
		})
		expect(r.missing[2].reason).toBe("absent")
	end)

	it("ignores owned objects when an override widens the kinds", function()
		local r = Drift.report(SOURCE, index(), {}, live(), { unmanagedKinds = { "ReplicaSet.apps" } })
		expect(#r.unmanaged).toBe(0)
		expect(#r.ignored).toBe(1)
		expect(string.match(r.ignored[1].reason, "^owned by Deployment/web$") ~= nil).toBe(true)
	end)

	it("skips bookkeeping objects of Helm, Argo CD and Flux", function()
		local objects: { any } = {
			{
				apiVersion = "v1",
				kind = "Secret",
				type = "helm.sh/release.v1",
				metadata = { name = "sh.helm.release.v1.web.v1", namespace = "ns", labels = { owner = "helm" } },
			},
			{
				apiVersion = "v1",
				kind = "Secret",
				metadata = {
					name = "repo-creds",
					namespace = "ns",
					labels = { ["argocd.argoproj.io/secret-type"] = "repository" },
				},
			},
			{ apiVersion = "v1", kind = "Secret", metadata = { name = "mine", namespace = "ns" } },
			{
				apiVersion = "v1",
				kind = "Secret",
				metadata = { name = "going", namespace = "ns", deletionTimestamp = "2026-10-08T00:00:00Z" },
			},
		}
		local docs: { Drift.Doc } = {}
		addDocs(docs, "s.yaml", "apiVersion: v1\nkind: Secret\nmetadata:\n  name: app\n  namespace: ns\n", SOURCE)
		local r = Drift.report(SOURCE, { docs = docs }, {}, objects, {})
		expect(keys(r.unmanaged)).toEqual({ "/Secret/ns/mine" })
		expect(ignoredPairs(r)).toEqual({
			"/Secret/ns/going = being deleted",
			"/Secret/ns/repo-creds = argo cd bookkeeping",
			"/Secret/ns/sh.helm.release.v1.web.v1 = helm release record",
		})
		expect(keys(r.missing)).toEqual({ "/Secret/ns/app" })
	end)

	it("matches namespace-less manifests through the default namespace", function()
		local docs: { Drift.Doc } = {}
		addDocs(docs, "cm.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: app-config\n", SOURCE)
		local diff = segments("changed/diff_-f_drift+baseline+app.yaml.txt")
		local r = Drift.report(SOURCE, { docs = docs }, diff, live(), { defaultNamespace = "tern-test-drift" })
		expect(keys(r.changed)).toEqual({
			"/ConfigMap/tern-test-drift/app-config",
			"apps/Deployment/tern-test-drift/web",
		})
		expect(#r.changed[1].docs).toBe(1)
		expect(#r.changed[2].docs).toBe(0)
		expect(r.notes).toContain("apps/Deployment/tern-test-drift/web: no manifest in this source")
		-- app-config resolves through the default namespace, so only hand-made is unmanaged.
		expect(keys(r.unmanaged)).toEqual({ "/ConfigMap/tern-test-drift/hand-made" })
	end)

	it("treats prune deletions as unmanaged and keeps their diff", function()
		local seg = Diffseg.parse(table.concat({
			"diff -u -N /tmp/LIVE-1/v1.ConfigMap.tern-test-drift.hand-made /tmp/MERGED-2/v1.ConfigMap.tern-test-drift.hand-made",
			"--- /tmp/LIVE-1/v1.ConfigMap.tern-test-drift.hand-made\t2026",
			"+++ /tmp/MERGED-2/v1.ConfigMap.tern-test-drift.hand-made\t2026",
			"@@ -1,2 +0,0 @@",
			"-a",
			"-b",
		}, "\n")).segments
		local r = Drift.report(SOURCE, index(), seg, live(), {})
		expect(keys(r.unmanaged)).toEqual({ "/ConfigMap/tern-test-drift/hand-made" })
		expect((r.unmanaged[1].segment :: Diffseg.Segment).action).toBe("delete")
	end)

	it("skips raw kustomize bases and patches in a plain directory source", function()
		local docs: { Drift.Doc } = {}
		addDocs(
			docs,
			"base/cm.yaml",
			"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n  namespace: ns\n",
			SOURCE
		)
		docs[1].kustomization = ROOT .. "/overlay"
		addDocs(docs, "patch.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: b\n  namespace: ns\n", SOURCE)
		docs[2].patch = true
		local r = Drift.report(SOURCE, { docs = docs }, {}, {}, {})
		expect(#r.missing).toBe(0)
		expect(ignoredPairs(r)).toEqual({
			"/ConfigMap/ns/a = rendered by kustomization " .. ROOT .. "/overlay",
			"/ConfigMap/ns/b = kustomize patch",
		})
		expect(r.counts.docs).toBe(0)
	end)

	it("labels changed and unmanaged objects with their GitOps controller", function()
		local set = Controllers.parse({
			["applications.argoproj.io"] = {
				items = {
					{
						metadata = { name = "web", namespace = "argocd" },
						spec = { source = { repoURL = "https://github.com/o/r", path = "drift" } },
						status = { sync = { status = "OutOfSync" } },
					},
				},
			},
		})
		local objects = live()
		for _, o in objects do
			if o.metadata.name == "hand-made" then
				o.metadata.labels = { ["app.kubernetes.io/instance"] = "web" }
			end
		end
		local r = Drift.report(SOURCE, index(), {}, objects, { controllers = set })
		local owner = r.unmanaged[1].object.controller :: Controllers.Owner
		expect(owner.name).toBe("web")
		expect(owner.sync).toBe("OutOfSync")
	end)

	it("passes diff notes through", function()
		local r = Drift.report(SOURCE, index(), {}, nil, { diffNotes = { "Warning: x" } })
		expect(r.notes).toContain("Warning: x")
	end)
end)

return nil
