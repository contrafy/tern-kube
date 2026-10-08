--!strict
-- The manifest index maps live objects to the file and lines that declare
-- them. A wrong mapping sends "Open manifest" to the wrong file and makes
-- drift compare an object against someone else's manifest, so identity,
-- namespace resolution and kustomize membership are pinned here against the
-- fixture repos in tests/fixtures/gitops.
local Index = require("../../../plugin/lib/gitops/index")
local repo = require("../../lib/gitops")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function ref(group: string?, kind: string, namespace: string?, name: string): any
	return { group = group, kind = kind, namespace = namespace, name = name, source = "live" }
end

local function sortedKeys(map: { [string]: any }): { string }
	local out: { string } = {}
	for k in map do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

local function docsIn(index: Index.Index, rel: string): { Index.ManifestDoc }
	local out = {}
	for _, d in index.docs do
		if d.file == repo.abs(rel) then
			table.insert(out, d)
		end
	end
	return out
end

describe("gitops index plan", function()
	it("reads manifests, kustomizations first, and leaves helm chart sources to helm", function()
		local plan = Index.plan(repo.files(), {})
		expect(plan.kustomizations).toEqual({
			"kustomize/base",
			"kustomize/overlays/prod",
			"kustomize/overlays/staging",
		})
		expect(plan.charts).toEqual({ "helm/chart" })
		expect(plan.read[1]).toBe("kustomize/base/kustomization.yaml")
		expect(plan.read[2]).toBe("kustomize/overlays/prod/kustomization.yaml")
		expect(plan.read[3]).toBe("kustomize/overlays/staging/kustomization.yaml")
		expect(table.find(plan.read, "helm/chart/templates/deployment.yaml")).toBeNil()
		expect(table.find(plan.read, "helm/values-staging.yaml") ~= nil).toBe(true)
		-- Templates are not YAML until rendered; values files are not objects.
		local reasons: { [string]: string } = {}
		for _, s in plan.skipped do
			reasons[s.path] = s.reason
		end
		expect(reasons["helm/chart/templates/deployment.yaml"]).toBe("helm chart")
		expect(reasons["helm/chart/values.yaml"]).toBe("helm chart")
		expect(reasons["helm/chart/Chart.yaml"]).toBe("helm chart")
		expect(plan.truncated).toBe(false)
	end)

	it("ignores non-YAML files and skips hidden directories", function()
		local plan = Index.plan({ "./a.yaml", "README.md", ".github/workflows/ci.yml", "b/c.YML", "d/e.json" }, {})
		expect(plan.read).toEqual({ "a.yaml", "b/c.YML" })
		expect(plan.skipped).toEqual({ { path = ".github/workflows/ci.yml", reason = "hidden" } })
	end)

	it("stops at maxFiles and says so instead of silently indexing a subset", function()
		local plan = Index.plan({ "c.yaml", "a.yaml", "b.yaml" }, { maxFiles = 2 })
		expect(plan.read).toEqual({ "a.yaml", "b.yaml" })
		expect(plan.skipped).toEqual({ { path = "c.yaml", reason = "limit" } })
		expect(plan.truncated).toBe(true)
	end)

	it("keeps the default byte limits from the contract", function()
		local plan = Index.plan({}, {})
		expect(plan.limits).toEqual({ maxFiles = 2000, maxBytes = 32 * 1024 * 1024, maxFileBytes = 1024 * 1024 })
	end)
end)

describe("gitops index addFile", function()
	it("records every document of a multi-doc file with its exact lines", function()
		local index = repo.index()
		expect(repo.brief(docsIn(index, "multidoc/app.yaml"))).toEqual({
			"multidoc/app.yaml:3-24 apps/Deployment/tern-test-multi/web",
			"multidoc/app.yaml:26-36 /Service/tern-test-multi/web",
			"multidoc/app.yaml:38-44 /ConfigMap/tern-test-multi/web-config",
		})
	end)

	it("leaves the namespace unresolved for namespaced objects that do not set one", function()
		local index = repo.index()
		local docs = docsIn(index, "flat/serviceaccount-deployer.yaml")
		expect(#docs).toBe(1)
		expect(docs[1].key).toBeNil()
		expect(docs[1].namespaceInferred).toBe(true)
		expect((docs[1].ref :: any).name).toBe("deployer")
	end)

	it("keys cluster-scoped objects without a namespace", function()
		local index = repo.index()
		local docs = docsIn(index, "multidoc/cluster.yaml")
		expect(repo.brief(docs)).toEqual({
			"multidoc/cluster.yaml:1-4 /Namespace//tern-test-multi",
			"multidoc/cluster.yaml:6-13 rbac.authorization.k8s.io/ClusterRole//tern-test-multi-reader",
		})
		expect(docs[1].namespaceInferred).toBe(false)
	end)

	it("applies the kustomization namespace to the resources it lists", function()
		local index = repo.index()
		local cm = docsIn(index, "kustomize/overlays/staging/configmap.yaml")[1]
		expect(cm.key).toBe("/ConfigMap/tern-test-staging/shop-config")
		expect(cm.namespaceInferred).toBe(false)
		expect(cm.kustomization).toBe(repo.abs("kustomize/overlays/staging"))
		-- The base has no namespace of its own; overlays decide it.
		local base = docsIn(index, "kustomize/base/deployment.yaml")[1]
		expect(base.key).toBeNil()
		expect(base.namespaceInferred).toBe(true)
		expect(base.kustomization).toBe(repo.abs("kustomize/base"))
	end)

	it("never offers a kustomize patch as the manifest of an object", function()
		local index = repo.index()
		local patch = docsIn(index, "kustomize/overlays/staging/replicas.yaml")[1]
		expect(patch.patch).toBe(true)
		expect(Index.match(index, ref("apps", "Deployment", "default", "shop"), { defaultNamespace = "default" })).toEqual({
			docsIn(index, "kustomize/base/deployment.yaml")[1],
		})
	end)

	it("parses kustomization fields written with quotes, comments and unindented lists", function()
		local index = repo.index()
		local k = index.kustomizations[repo.abs("kustomize/overlays/prod")]
		expect(k.namespace).toBe("tern-test-prod")
		expect(k.namePrefix).toBe("prod-")
		expect(k.resources).toEqual({ repo.abs("kustomize/base") })
		local staging = index.kustomizations[repo.abs("kustomize/overlays/staging")]
		expect(staging.resources).toEqual({
			repo.abs("kustomize/base"),
			repo.abs("kustomize/overlays/staging/configmap.yaml"),
		})
		expect(staging.patches).toEqual({ repo.abs("kustomize/overlays/staging/replicas.yaml") })
	end)

	it("reads only real patch files and local resources from a kustomization", function()
		local index = Index.new("/r", nil)
		Index.addFile(
			index,
			"/r/app/kustomization.yaml",
			table.concat({
				"resources: [deploy.yaml, 'https://github.com/x/y//base?ref=v1']",
				"components:",
				"- github.com/org/repo/comp",
				"- ../shared # local",
				"patches:",
				"  - target:",
				"      kind: Deployment",
				"    patch: |-",
				"      - op: replace",
				"        path: /spec/replicas",
				"        value: 3",
				"  - path: patches/env.yaml",
				"    target: {kind: Deployment}",
				"  - target:",
				"      kind: Service",
				'    path: "patches/svc.yaml"',
				"patchesStrategicMerge:",
				"- legacy.yaml",
				"- |-",
				"  apiVersion: v1",
			}, "\n")
		)
		local k = index.kustomizations["/r/app"]
		expect(k.resources).toEqual({ "/r/app/deploy.yaml", "/r/shared" })
		expect(k.patches).toEqual({ "/r/app/patches/env.yaml", "/r/app/patches/svc.yaml", "/r/app/legacy.yaml" })
		expect(k.namespace).toBeNil()
	end)

	it("does not index kustomization files or non-manifest YAML as objects", function()
		local index = repo.index()
		expect(#docsIn(index, "kustomize/base/kustomization.yaml")).toBe(0)
		expect(#docsIn(index, "helm/values-staging.yaml")).toBe(0)
		for _, d in index.diagnostics do
			expect(d.file ~= repo.abs("helm/values-staging.yaml")).toBe(true)
		end
	end)

	it("does not depend on the order files are read in", function()
		local forward, backward = repo.index(false), repo.index(true)
		expect(sortedKeys(backward.byKey)).toEqual(sortedKeys(forward.byKey))
		local function summary(index: Index.Index): { string }
			local out = {}
			for _, d in index.docs do
				table.insert(
					out,
					string.format(
						"%s:%d %s %s %s %s",
						d.file,
						d.startLine,
						d.key or "-",
						tostring(d.namespaceInferred),
						d.kustomization or "-",
						tostring(d.patch)
					)
				)
			end
			table.sort(out)
			return out
		end
		expect(summary(backward)).toEqual(summary(forward))
	end)

	it("flags keys declared by more than one manifest", function()
		local index = Index.new("/r", nil)
		local cm = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n  namespace: ns\n"
		Index.addFile(index, "/r/one.yaml", cm)
		Index.addFile(index, "/r/two.yaml", cm)
		expect(Index.duplicates(index)).toEqual({ "/ConfigMap/ns/a" })
		expect(#index.byKey["/ConfigMap/ns/a"]).toBe(2)
	end)

	it("refuses input past the byte budget and marks the index truncated", function()
		local index = Index.new("/r", { maxFiles = 10, maxBytes = 60, maxFileBytes = 60 })
		local cm = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n"
		expect(Index.addFile(index, "/r/a.yaml", cm)).toBe(true)
		expect(Index.addFile(index, "/r/b.yaml", cm)).toBe(false)
		expect(index.truncated).toBe(true)
		expect(index.scannedFiles).toBe(1)
		expect(index.bytes).toBe(#cm)
	end)

	it("re-adding a file replaces its documents", function()
		local index = Index.new("/r", nil)
		Index.addFile(index, "/r/a.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n  namespace: ns\n")
		Index.addFile(index, "/r/a.yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: b\n  namespace: ns\n")
		expect(sortedKeys(index.byKey)).toEqual({ "/ConfigMap/ns/b" })
		expect(#index.docs).toBe(1)
	end)

	it("groups plain files into one dir source per directory", function()
		local index = repo.index()
		local doc = docsIn(index, "plain/deployments/web.yaml")[1]
		expect(doc.source.type).toBe("dir")
		expect(doc.source.path).toBe(repo.abs("plain/deployments"))
		expect(doc.source.label).toBe("plain/deployments")
		expect(doc.rendered).toBe(false)
	end)
end)

describe("gitops index match", function()
	it("finds the manifest of a namespaced object by exact namespace", function()
		local index = repo.index()
		local docs =
			Index.match(index, ref("apps", "Deployment", "tern-test-flat", "web"), { defaultNamespace = "default" })
		expect(repo.brief(docs)).toEqual({ "flat/deployment-web.yaml:1-22 apps/Deployment/tern-test-flat/web" })
	end)

	it("matches manifests without a namespace only for the default namespace", function()
		local index = repo.index()
		local sa = ref(nil, "ServiceAccount", "team", "deployer")
		expect(#Index.match(index, sa, { defaultNamespace = "team" })).toBe(1)
		expect(#Index.match(index, sa, { defaultNamespace = "default" })).toBe(0)
	end)

	it("ranks an exact namespace above an inferred one", function()
		local index = Index.new(repo.ROOT, nil)
		Index.addFile(index, repo.abs("b.yaml"), "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n")
		Index.addFile(
			index,
			repo.abs("a.yaml"),
			"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n  namespace: ns\n"
		)
		local docs = Index.match(index, ref(nil, "ConfigMap", "ns", "a"), { defaultNamespace = "ns" })
		expect(repo.brief(docs)).toEqual({ "a.yaml:1-5 /ConfigMap/ns/a", "b.yaml:1-4 ConfigMap/a (ns?)" })
	end)

	it("does not confuse kinds from different API groups", function()
		local index = repo.index()
		expect(Index.match(index, ref("extensions", "Deployment", "tern-test-flat", "web"), {})).toEqual({})
	end)

	it("matches cluster-scoped objects", function()
		local index = repo.index()
		local docs =
			Index.match(index, ref("rbac.authorization.k8s.io", "ClusterRole", nil, "tern-test-multi-reader"), {})
		expect(#docs).toBe(1)
		expect(docs[1].file).toBe(repo.abs("multidoc/cluster.yaml"))
	end)
end)

describe("gitops index layout", function()
	local function brief(l: Index.Layout): string
		return string.format(
			"%s %s %s %s kustomization=%s",
			l.style,
			l.kindDir or "-",
			l.naming,
			l.ext,
			tostring(l.kustomization)
		)
	end

	it("recognises per-kind directories named by plural", function()
		local l = Index.layout(repo.index(), repo.abs("plain"))
		expect(brief(l)).toBe("per-kind-dirs <plural> <name> .yaml kustomization=false")
		expect(l.confidence).toBe(1)
		expect(l.samples).toBe(5)
	end)

	it("recognises namespace/kind directories named by kind", function()
		local l = Index.layout(repo.index(), repo.abs("per-namespace") .. "/")
		expect(brief(l)).toBe("per-namespace-kind-dirs <kind> <name> .yaml kustomization=false")
		expect(l.confidence).toBe(1)
	end)

	it("recognises flat file-per-resource repos and their file naming", function()
		local l = Index.layout(repo.index(), repo.abs("flat"))
		expect(brief(l)).toBe("file-per-resource - <kind>-<name> .yaml kustomization=false")
		expect(l.confidence).toBe(1)
	end)

	it("recognises multi-document files", function()
		local l = Index.layout(repo.index(), repo.abs("multidoc"))
		expect(l.style).toBe("multi-doc")
		expect(l.confidence).toBe(1)
	end)

	it("recognises kustomize bases with files named after their kind", function()
		local l = Index.layout(repo.index(), repo.abs("kustomize/base"))
		expect(brief(l)).toBe("file-per-resource - <kind> .yaml kustomization=true")
	end)

	it("says unknown for a repo that mixes conventions", function()
		local l = Index.layout(repo.index(), repo.abs("mixed"))
		expect(l.style).toBe("unknown")
		expect(l.confidence < 0.8).toBe(true)
		expect(l.samples).toBe(5)
	end)

	it("says unknown with no samples for an empty directory", function()
		local l = Index.layout(repo.index(), repo.abs("nowhere"))
		expect(l.style).toBe("unknown")
		expect(l.samples).toBe(0)
		expect(l.ext).toBe(".yaml")
	end)
end)

describe("gitops index helpers", function()
	it("turns `git ls-files -z` output into absolute paths", function()
		expect(Index.parseFileList("/r", "a.yaml\0dir/b c.yml\0")).toEqual({ "/r/a.yaml", "/r/dir/b c.yml" })
		expect(Index.parseFileList("/r", "")).toEqual({})
	end)

	it("parses `git status --porcelain=v1 -z` including renames", function()
		local out = " M a.yaml\0?? new.yaml\0R  moved.yaml\0old.yaml\0UU c.yaml\0A  d.yaml\0M  e.yaml\0 D f.yaml\0"
		local status = Index.parseGitStatus("/r", out)
		expect(status["/r/a.yaml"]).toEqual({ code = " M", state = "modified" })
		expect(status["/r/new.yaml"]).toEqual({ code = "??", state = "untracked" })
		expect(status["/r/moved.yaml"]).toEqual({ code = "R ", state = "renamed" })
		expect(status["/r/old.yaml"]).toBeNil()
		expect(status["/r/c.yaml"].state).toBe("conflicted")
		expect(status["/r/d.yaml"].state).toBe("added")
		expect(status["/r/e.yaml"].state).toBe("staged")
		expect(status["/r/f.yaml"].state).toBe("deleted")
	end)
end)

return nil
