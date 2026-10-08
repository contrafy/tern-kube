--!strict
-- Kustomize overlays and Helm releases are what actually gets applied, so
-- drift and "Diff vs manifest" must use their rendered output, while "Open
-- manifest" should still land on the file a human edits. These specs feed
-- renders captured from the real tools (scripts/fixtures/capture-gitops.sh:
-- `kubectl kustomize`, `helm template`) into the index.
local Index = require("../../../plugin/lib/gitops/index")
local fixtures = require("../../lib/fixtures")
local repo = require("../../lib/gitops")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function ref(group: string?, kind: string, namespace: string?, name: string): any
	return { group = group, kind = kind, namespace = namespace, name = name, source = "live" }
end

local function rendered(index: Index.Index, source: Index.Source): { Index.ManifestDoc }
	local out = {}
	for _, d in index.docs do
		if d.rendered and d.source == source then
			table.insert(out, d)
		end
	end
	return out
end

local function overlay(index: Index.Index, name: string): Index.Source
	local source = Index.source(index, "kustomize", repo.abs("kustomize/overlays/" .. name), nil)
	Index.addRendered(index, source, fixtures.read("gitops/captured/kustomize-" .. name .. ".yaml"))
	return source
end

local function helm(index: Index.Index, namespace: string?): Index.Source
	local source = Index.source(index, "helm", repo.abs("helm/chart"), {
		release = "web",
		namespace = namespace,
		values = { repo.abs("helm/values-staging.yaml") },
	})
	Index.addRendered(index, source, fixtures.read("gitops/captured/helm-web.yaml"))
	return source
end

describe("gitops index addRendered: kustomize", function()
	it("keys rendered objects by the overlay namespace and points at the files that declare them", function()
		local index = repo.index()
		local source = overlay(index, "staging")
		expect(repo.brief(rendered(index, source))).toEqual({
			"kustomize/overlays/staging/configmap.yaml:1-6 /ConfigMap/tern-test-staging/shop-config",
			"kustomize/base/service.yaml:1-10 /Service/tern-test-staging/shop",
			"kustomize/base/deployment.yaml:1-21 apps/Deployment/tern-test-staging/shop",
		})
		for _, d in rendered(index, source) do
			expect(d.namespaceInferred).toBe(false)
		end
	end)

	it("carries the rendered document text, which is what diff must compare", function()
		local index = repo.index()
		local source = overlay(index, "staging")
		local deploy = rendered(index, source)[3]
		local text = deploy.text :: string
		expect(string.sub(text, 1, 16)).toBe("apiVersion: apps")
		-- The overlay patch is applied in the render, not in the base file.
		expect(string.find(text, "replicas: 2", 1, true) ~= nil).toBe(true)
		expect((string.find(text, "---", 1, true))).toBeNil()
	end)

	it("follows namePrefix back to the base file", function()
		local index = repo.index()
		local source = overlay(index, "prod")
		expect(repo.brief(rendered(index, source))).toEqual({
			"kustomize/base/service.yaml:1-10 /Service/tern-test-prod/prod-shop",
			"kustomize/base/deployment.yaml:1-21 apps/Deployment/tern-test-prod/prod-shop",
		})
	end)

	it("ranks the rendered overlay object first, then the raw base for the default namespace", function()
		local index = repo.index()
		overlay(index, "staging")
		local docs = Index.match(index, ref("apps", "Deployment", "tern-test-staging", "shop"), {
			defaultNamespace = "tern-test-staging",
		})
		expect(#docs).toBe(2)
		expect(docs[1].rendered).toBe(true)
		expect(docs[2].rendered).toBe(false)
		expect(docs[2].file).toBe(repo.abs("kustomize/base/deployment.yaml"))
	end)

	it("replaces the previous render of a source on refresh", function()
		local index = repo.index()
		local before = #index.docs
		overlay(index, "staging")
		overlay(index, "staging")
		expect(#index.docs).toBe(before + 3)
		expect(#index.byKey["/ConfigMap/tern-test-staging/shop-config"]).toBe(2)
		expect(Index.duplicates(index)).toEqual({})
	end)

	it("lists rendered sources once", function()
		local index = repo.index()
		overlay(index, "staging")
		overlay(index, "staging")
		local n = 0
		for _, s in index.sources do
			if s.type == "kustomize" then
				n += 1
				expect(s.label).toBe("kustomize/overlays/staging")
			end
		end
		expect(n).toBe(1)
	end)

	it("falls back to the kustomization file when no declaring file is indexed", function()
		local index = Index.new(repo.ROOT, nil)
		local source = Index.source(index, "kustomize", repo.abs("kustomize/overlays/staging"), nil)
		Index.addRendered(index, source, fixtures.read("gitops/captured/kustomize-staging.yaml"))
		for _, d in rendered(index, source) do
			expect(d.file).toBe(repo.abs("kustomize/overlays/staging/kustomization.yaml"))
			expect(d.startLine).toBe(1)
		end
		expect(#rendered(index, source)).toBe(3)
	end)
end)

describe("gitops index addRendered: helm", function()
	it("maps each rendered object to its template via the # Source comment", function()
		local index = repo.index()
		local source = helm(index, "tern-test-helm")
		expect(repo.brief(rendered(index, source))).toEqual({
			"helm/chart/templates/configmap.yaml:1-1 /ConfigMap/tern-test-helm/web-shop-config",
			"helm/chart/templates/service.yaml:1-1 /Service/tern-test-helm/web-shop",
			"helm/chart/templates/deployment.yaml:1-1 apps/Deployment/tern-test-helm/web-shop",
		})
	end)

	it("puts objects without a namespace into the release namespace", function()
		local index = repo.index()
		local svc = rendered(index, helm(index, "tern-test-helm"))[2]
		expect(svc.namespaceInferred).toBe(false)
		expect(svc.text :: string).toBe(table.concat({
			"apiVersion: v1",
			"kind: Service",
			"metadata:",
			"  name: web-shop",
			"  labels:",
			"    app.kubernetes.io/name: shop",
			"    app.kubernetes.io/instance: web",
			"spec:",
			"  selector:",
			"    app.kubernetes.io/name: shop",
			"    app.kubernetes.io/instance: web",
			"  ports:",
			"    - port: 80",
			"      targetPort: 80",
		}, "\n") .. "\n")
	end)

	it("leaves the namespace inferred when the release namespace is not chosen", function()
		local index = repo.index()
		local docs = rendered(index, helm(index, nil))
		expect(docs[1].key).toBe("/ConfigMap/tern-test-helm/web-shop-config")
		expect(docs[2].key).toBeNil()
		expect(docs[2].namespaceInferred).toBe(true)
	end)

	it("labels helm sources by release and chart path", function()
		local index = repo.index()
		local source = helm(index, "tern-test-helm")
		expect(source.label).toBe("helm/chart (release web)")
		expect(source.root).toBe(repo.ROOT)
	end)
end)

return nil
