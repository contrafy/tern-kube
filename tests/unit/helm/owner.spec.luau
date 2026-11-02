--!strict
-- Object -> Helm release. Helm 3.2+ stamps every object it creates with the
-- release-name/namespace annotations (F12); hooks carry none and release
-- records are Secrets of their own, so each must be told apart: a hook is
-- not "managed by" the release and a record links to its revision.
local Owner = require("../../../plugin/lib/helm/owner")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local objects = json.decode(fixtures.read("helm/captured/objects.json")).items

local function find(kind: string, name: string): any
	for _, o in objects do
		if o.kind == kind and o.metadata.name == name then
			return o
		end
	end
	error("no " .. kind .. "/" .. name .. " in objects.json")
end

local function meta(m: { [string]: any }): any
	return { kind = "ConfigMap", metadata = m }
end

describe("Owner.fromObject", function()
	it("maps every captured release object to its release", function()
		local owned = 0
		for _, o in objects do
			local ann = o.metadata.annotations or {}
			local rel = ann["meta.helm.sh/release-name"]
			if rel then
				owned += 1
				expect(Owner.fromObject(o)).toEqual({ release = rel, namespace = "tern-test-helm", via = "annotation" })
			end
		end
		expect(owned).toBe(15)
		expect(Owner.fromObject(find("Secret", "web-b-web-auth"))).toEqual({
			release = "web-b",
			namespace = "tern-test-helm",
			via = "annotation",
		})
	end)

	it("treats hook objects as hooks, not owned objects", function()
		for _, name in { "web-b-web-post-install", "web-b-web-pre-upgrade" } do
			local o = find("ConfigMap", name)
			expect(Owner.fromObject(o)).toBeNil()
			expect(Owner.hook(o) ~= nil).toBe(true)
		end
	end)

	it("ignores objects helm did not create", function()
		expect(Owner.fromObject(find("ConfigMap", "kube-root-ca.crt"))).toBeNil()
		expect(Owner.fromObject(nil)).toBeNil()
		expect(Owner.fromObject("x")).toBeNil()
		expect(Owner.fromObject({ metadata = { annotations = { ["meta.helm.sh/release-name"] = "" } } })).toBeNil()
	end)

	-- The release namespace annotation is what helm uses; the object's own
	-- namespace is only a fallback (a release may create objects elsewhere).
	it("prefers the release-namespace annotation over the object namespace", function()
		local o = meta({
			namespace = "other",
			annotations = { ["meta.helm.sh/release-name"] = "r", ["meta.helm.sh/release-namespace"] = "apps" },
		})
		expect(Owner.fromObject(o)).toEqual({ release = "r", namespace = "apps", via = "annotation" })
		o = meta({ namespace = "other", annotations = { ["meta.helm.sh/release-name"] = "r" } })
		expect(Owner.fromObject(o)).toEqual({ release = "r", namespace = "other", via = "annotation" })
		o = meta({ annotations = { ["meta.helm.sh/release-name"] = "r" } })
		expect(Owner.fromObject(o)).toBeNil()
	end)

	-- Objects from helm < 3.2 lack the annotations; the standard labels are a
	-- guess (charts set them by convention), hence `instance-label`.
	it("falls back to the managed-by and instance labels", function()
		local o = meta({
			namespace = "apps",
			labels = { ["app.kubernetes.io/managed-by"] = "Helm", ["app.kubernetes.io/instance"] = "old" },
		})
		expect(Owner.fromObject(o)).toEqual({ release = "old", namespace = "apps", via = "instance-label" })
		o = meta({ namespace = "apps", labels = { ["app.kubernetes.io/instance"] = "old" } })
		expect(Owner.fromObject(o)).toBeNil()
		o = meta({
			namespace = "apps",
			labels = { ["app.kubernetes.io/managed-by"] = "Helm", ["app.kubernetes.io/instance"] = "old" },
			annotations = { ["helm.sh/hook"] = "pre-install" },
		})
		expect(Owner.fromObject(o)).toBeNil()
	end)
end)

describe("Owner.hook", function()
	it("reads hook events", function()
		expect(Owner.hook(find("ConfigMap", "web-b-web-pre-upgrade"))).toEqual({
			events = { "pre-upgrade", "pre-rollback" },
		})
		expect(Owner.hook(find("ConfigMap", "web-b-web-post-install"))).toEqual({ events = { "post-install" } })
		expect(Owner.hook(meta({ annotations = { ["helm.sh/hook"] = " test , post-delete " } }))).toEqual({
			events = { "test", "post-delete" },
		})
	end)

	it("is nil for ordinary objects", function()
		expect(Owner.hook(find("Deployment", "shop-a-shop"))).toBeNil()
		expect(Owner.hook(nil)).toBeNil()
	end)
end)

describe("Owner.record", function()
	local function record(name: string, labels: { [string]: string }?, kind: string?, typ: string?): any
		return {
			kind = kind or "Secret",
			type = if kind == "ConfigMap" then nil else (typ or "helm.sh/release.v1"),
			metadata = { name = name, namespace = "tern-test-helm", labels = labels },
		}
	end

	it("parses the captured release record names", function()
		for _, line in fixtures.lines("helm/captured/release-records.txt") do
			local name = string.gsub(line, "^secret/", "")
			local r = Owner.record(record(name))
			local rel, rev = string.match(name, "^sh%.helm%.release%.v1%.(.+)%.v(%d+)$")
			expect(r).toEqual({ release = rel, revision = tonumber(rev) })
		end
	end)

	-- Release names may contain dots; the labels say exactly where the name ends.
	it("prefers the owner=helm labels", function()
		local r = Owner.record(
			record("sh.helm.release.v1.a.b.v12", { owner = "helm", name = "a.b", version = "12", status = "deployed" })
		)
		expect(r).toEqual({ release = "a.b", revision = 12 })
		-- HELM_DRIVER=configmap stores the same record in a ConfigMap.
		r = Owner.record(
			record("sh.helm.release.v1.web.v2", { owner = "helm", name = "web", version = "2" }, "ConfigMap")
		)
		expect(r).toEqual({ release = "web", revision = 2 })
	end)

	it("is nil for other Secrets and ConfigMaps", function()
		expect(Owner.record(find("Secret", "web-b-web-auth"))).toBeNil()
		expect(Owner.record(record("sh.helm.release.v1.x.v1", nil, "Secret", "Opaque"))).toBeNil()
		expect(Owner.record(record("sh.helm.release.v1.x.v1", nil, "ConfigMap"))).toBeNil()
		expect(Owner.record(record("sh.helm.release.v1.x.v0"))).toBeNil()
		expect(Owner.record(nil)).toBeNil()
	end)
end)

describe("Owner.fromDescribe", function()
	it("reads the Annotations field of kubectl describe", function()
		local ann = table.concat({
			"deployment.kubernetes.io/revision: 3",
			"meta.helm.sh/release-name: shop-a",
			"meta.helm.sh/release-namespace: tern-test-helm",
		}, "\n")
		expect(Owner.fromDescribe(ann)).toEqual({ release = "shop-a", namespace = "tern-test-helm", via = "annotation" })
		-- Continuation lines may keep describe's alignment padding.
		expect(Owner.fromDescribe("meta.helm.sh/release-name: r\n                    other: x", "apps")).toEqual({
			release = "r",
			namespace = "apps",
			via = "annotation",
		})
	end)

	it("is nil without the release annotation", function()
		expect(Owner.fromDescribe("<none>", "apps")).toBeNil()
		expect(Owner.fromDescribe("helm.sh/hook: pre-upgrade", "apps")).toBeNil()
		expect(Owner.fromDescribe("meta.helm.sh/release-name: r")).toBeNil()
	end)
end)

describe("Owner.fromYamlLines", function()
	it("scans one document's metadata.annotations", function()
		local lines = fixtures.toLines([[
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "3"
    kubectl.kubernetes.io/last-applied-configuration: |
      {"metadata":{"annotations":{"meta.helm.sh/release-name":"decoy"}}}
    meta.helm.sh/release-name: shop-a
    meta.helm.sh/release-namespace: tern-test-helm
  labels:
    app.kubernetes.io/instance: shop-a
  name: shop-a-shop
  namespace: tern-test-helm
spec:
  template:
    metadata:
      annotations:
        meta.helm.sh/release-name: nested
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: plain
]])
		expect(Owner.fromYamlLines(lines, 1, 18)).toEqual({
			release = "shop-a",
			namespace = "tern-test-helm",
			via = "annotation",
		})
		expect(Owner.fromYamlLines(lines, 20, 23)).toBeNil()
	end)

	-- `kubectl get -o yaml` of several objects prints a List: each item's
	-- keys sit after `- ` and metadata may come before apiVersion.
	it("reads List items, quoted keys and values, and the namespace fallback", function()
		local lines = fixtures.toLines([[
apiVersion: v1
items:
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    annotations:
      meta.helm.sh/release-name: "web-b"
    name: web-b-web
    namespace: 'apps'
- metadata:
    annotations:
      "meta.helm.sh/release-name": 'x'
      "meta.helm.sh/release-namespace": "y"
    name: x
  kind: Service
- kind: ConfigMap
  metadata:
    labels:
      app.kubernetes.io/managed-by: Helm
      app.kubernetes.io/instance: old
    namespace: legacy
]])
		expect(Owner.fromYamlLines(lines, 3, 9)).toEqual({ release = "web-b", namespace = "apps", via = "annotation" })
		expect(Owner.fromYamlLines(lines, 10, 15)).toEqual({ release = "x", namespace = "y", via = "annotation" })
		expect(Owner.fromYamlLines(lines, 16, 21)).toEqual({
			release = "old",
			namespace = "legacy",
			via = "instance-label",
		})
	end)

	it("is nil for empty or out-of-range ranges", function()
		expect(Owner.fromYamlLines({}, 1, 0)).toBeNil()
		expect(Owner.fromYamlLines({ "metadata: {}" }, 1, 5)).toBeNil()
	end)
end)

return nil
