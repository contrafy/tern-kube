--!strict
-- Two kind clusters holding identical objects differ only in server
-- bookkeeping (uid, resourceVersion, status, allocated ClusterIPs,
-- last-applied): after normalization those pairs must be equal, or every
-- compare would report noise. Secret values must survive (equality), and
-- objects Kubernetes creates itself are compared too.
local Normalize = require("../../../plugin/lib/compare/normalize")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function load(name: string): any
	return json.decode(fixtures.read("real/compare/" .. name))
end

local LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration"

describe("compare.normalize", function()
	it("makes identical Deployments and Services of two clusters equal", function()
		for _, name in { "deployment-tkm-api.json", "service-tkm-web.json" } do
			local a, b = load("a-" .. name), load("b-" .. name)
			expect(a.metadata.uid ~= b.metadata.uid).toBe(true)
			expect(Normalize.normalize(a)).toEqual(Normalize.normalize(b))
		end
		local svc = Normalize.normalize(load("a-service-tkm-web.json"))
		expect(svc.spec.clusterIP).toBeNil()
		expect(svc.spec.clusterIPs).toBeNil()
		expect(svc.status).toBeNil()
	end)

	it("keeps Secret values but drops the last-applied copy", function()
		local s = Normalize.normalize(load("a-secret-tkm-secret.json"))
		expect(s.data).toEqual({ password = "czNjcmV0LUE=", username = "YWRtaW4=" })
		expect(s.stringData).toBeNil()
		expect(s.metadata.annotations).toBeNil()
		local raw = load("a-secret-tkm-secret.json")
		expect(raw.metadata.annotations[LAST_APPLIED] ~= nil).toBe(true)
	end)

	it("compares kube-root-ca.crt instead of skipping it", function()
		local list = load("a-mixed-list.json")
		local root
		for _, item in list.items do
			if item.metadata.name == "kube-root-ca.crt" then
				root = item
			end
		end
		local n = Normalize.normalize(root)
		expect(n.metadata.name).toBe("kube-root-ca.crt")
		expect(n.data["ca.crt"]).toBe("REDACTED")
	end)

	it("never modifies its input", function()
		local a = load("a-deployment-tkm-web.json")
		Normalize.normalize(a)
		expect(a.metadata.resourceVersion ~= nil).toBe(true)
		expect(a.status ~= nil).toBe(true)
		expect(Normalize.normalize(nil)).toBeNil()
	end)
end)

return nil
