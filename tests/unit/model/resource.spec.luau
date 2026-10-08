--!strict
local Resource = require("../../../plugin/lib/model/resource")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("resource.fromObject", function()
	it("splits apiVersion into group and version so refs match kubectl's group-qualified names", function()
		local ref = Resource.fromObject({
			apiVersion = "apps/v1",
			kind = "Deployment",
			metadata = { name = "web", namespace = "shop", uid = "u-1" },
		}, "snapshot")
		expect(ref).toEqual({
			group = "apps",
			version = "v1",
			kind = "Deployment",
			name = "web",
			namespace = "shop",
			uid = "u-1",
			source = "snapshot",
		})
	end)

	it("leaves the core group unnamed and cluster-scoped objects without namespace", function()
		local ref = Resource.fromObject({ apiVersion = "v1", kind = "Node", metadata = { name = "n1" } }, "live")
		expect(ref).toEqual({ version = "v1", kind = "Node", name = "n1", source = "live" })
	end)

	-- Never invent identity: an object without kind or name cannot be acted on.
	it("returns nil when kind or metadata.name is missing", function()
		expect(Resource.fromObject({ kind = "Pod", metadata = {} }, "snapshot")).toBeNil()
		expect(Resource.fromObject({ kind = "Pod", metadata = { generateName = "x-" } }, "snapshot")).toBeNil()
		expect(Resource.fromObject({ metadata = { name = "x" } }, "snapshot")).toBeNil()
		expect(Resource.fromObject({ kind = "Pod", metadata = "oops" }, "snapshot")).toBeNil()
	end)
end)

describe("resource.key", function()
	it("identifies the same object identically regardless of context, version and uid", function()
		local a = {
			kind = "Deployment",
			group = "apps",
			version = "v1",
			name = "web",
			namespace = "shop",
			source = "snapshot",
		}
		local b = {
			kind = "Deployment",
			group = "apps",
			version = "v1beta2",
			name = "web",
			namespace = "shop",
			uid = "u",
			clusterContext = "kind-dev",
			source = "live",
		}
		expect(Resource.key(a :: any)).toBe(Resource.key(b :: any))
		expect(Resource.key(a :: any)).toBe("apps/Deployment/shop/web")
	end)

	it("separates objects that differ only by namespace, group or kind", function()
		local base = { kind = "Widget", group = "a.example.com", name = "x", namespace = "n1", source = "snapshot" }
		local seen: { [string]: boolean } = {}
		local refs: { any } = {
			base,
			table.clone(base),
			{ kind = "Widget", group = "b.example.com", name = "x", namespace = "n1", source = "snapshot" },
			{ kind = "Widget", group = "a.example.com", name = "x", namespace = "n2", source = "snapshot" },
			{ kind = "Gadget", group = "a.example.com", name = "x", namespace = "n1", source = "snapshot" },
			{ kind = "Widget", group = "a.example.com", name = "x", source = "snapshot" },
		}
		for _, ref in refs do
			seen[Resource.key(ref :: any)] = true
		end
		local count = 0
		for _ in seen do
			count += 1
		end
		expect(count).toBe(5)
	end)
end)

describe("resource.qualifiedId", function()
	it("produces the kubectl -o name form usable as a command argument", function()
		expect(Resource.qualifiedId({ kind = "Pod", name = "api-1", namespace = "default", source = "snapshot" })).toBe(
			"pod/api-1 -n default"
		)
		expect(Resource.qualifiedId({
			kind = "Deployment",
			group = "apps",
			name = "web",
			namespace = "shop",
			source = "snapshot",
		})).toBe("deployment.apps/web -n shop")
		expect(Resource.qualifiedId({ kind = "Node", name = "kind-control-plane", source = "snapshot" })).toBe(
			"node/kind-control-plane"
		)
		expect(Resource.qualifiedId({
			kind = "Widget",
			group = "acme.example.com",
			name = "w",
			namespace = "ns",
			source = "snapshot",
		})).toBe("widget.acme.example.com/w -n ns")
	end)
end)

return nil
