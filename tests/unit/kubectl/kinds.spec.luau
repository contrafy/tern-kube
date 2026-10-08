--!strict
local t = require("../../lib/test")
local kinds = require("../../../plugin/lib/kubectl/kinds")
local describe, it, expect = t.describe, t.it, t.expect

describe("kinds.normalize", function()
	-- Every spelling kubectl accepts must land on one identity so views,
	-- actions and caches agree.
	it("maps plural, singular, short name and Kind to the same entry", function()
		for _, token in { "pods", "pod", "po", "Pod", "PODS" } do
			local k = kinds.normalize(token)
			expect(k.kind).toBe("Pod")
			expect(k.group).toBeNil()
			expect(k.plural).toBe("pods")
			expect(k.singular).toBe("pod")
			expect(k.namespaced).toBe(true)
			expect(k.known).toBe(true)
		end
		expect(kinds.normalize("po").short).toEqual({ "po" })
	end)

	it("resolves group- and version-qualified names", function()
		for _, token in { "deployment.apps", "deployments.apps", "deploy.apps", "deployments.v1.apps" } do
			local k = kinds.normalize(token)
			expect(k.kind).toBe("Deployment")
			expect(k.group).toBe("apps")
		end
		expect(kinds.normalize("pods.v1").kind).toBe("Pod")
		expect(kinds.normalize("hpa").group).toBe("autoscaling")
		expect(kinds.normalize("crds").kind).toBe("CustomResourceDefinition")
	end)

	it("knows cluster-scoped kinds", function()
		expect(kinds.normalize("nodes").namespaced).toBe(false)
		expect(kinds.normalize("ns").kind).toBe("Namespace")
	end)

	-- `events` exists in core and events.k8s.io; the bare name is the core one
	-- like kubectl, but the group-qualified form must still resolve.
	it("prefers core for shared names but honours explicit groups", function()
		expect(kinds.normalize("events").group).toBeNil()
		expect(kinds.normalize("events.events.k8s.io").group).toBe("events.k8s.io")
	end)

	it("falls back to a generic unknown entry for CRDs", function()
		local k = kinds.normalize("certificates.cert-manager.io")
		expect(k.known).toBe(false)
		expect(k.kind).toBe("certificates")
		expect(k.plural).toBe("certificates")
		expect(k.group).toBe("cert-manager.io")
		expect(k.namespaced).toBeNil()
		expect(k.short).toEqual({})
		local bare = kinds.normalize("widgets")
		expect(bare.known).toBe(false)
		expect(bare.group).toBeNil()
	end)
end)

describe("kinds.fromPrefix", function()
	-- `get all` prints NAME as <kind>.<group>/<name>; rows must map back to kinds.
	it("resolves get-all NAME prefixes", function()
		local cases = {
			{ "pod/x", "Pod" },
			{ "service/x", "Service" },
			{ "deployment.apps/x", "Deployment" },
			{ "replicaset.apps/x", "ReplicaSet" },
			{ "horizontalpodautoscaler.autoscaling/x", "HorizontalPodAutoscaler" },
			{ "cronjob.batch/x", "CronJob" },
			{ "deployment.apps", "Deployment" },
		}
		for _, c in cases do
			local k = kinds.fromPrefix(c[1])
			expect(k.kind).toBe(c[2])
			expect(k.known).toBe(true)
		end
	end)
end)

describe("kinds performance", function()
	it("normalizes 1000 tokens quickly", function()
		local start = os.clock()
		for _ = 1, 1000 do
			kinds.fromPrefix("horizontalpodautoscaler.autoscaling/x")
			kinds.normalize("certificates.cert-manager.io")
		end
		expect(os.clock() - start < 0.2).toBe(true)
	end)
end)

return nil
