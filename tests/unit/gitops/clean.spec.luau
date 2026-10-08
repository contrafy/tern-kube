--!strict
-- An exported manifest must re-apply cleanly and say nothing the user did
-- not choose: server bookkeeping (uid, resourceVersion, managedFields, ...)
-- makes apply conflict or churn diffs, allocated fields (clusterIP, Job
-- selectors) are immutable or rejected on create, and Secret values must
-- never be written to disk.
local Clean = require("../../../plugin/lib/gitops/clean")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function items(path: string): { any }
	return json.decode(fixtures.read("real/json-world/" .. path)).items
end

local function named(list: { any }, name: string): any
	for _, obj in list do
		if obj.metadata.name == name then
			return obj
		end
	end
	error("no object " .. name)
end

local function codes(notes: { Clean.Note }): { string }
	local out = {}
	for _, n in notes do
		table.insert(out, n.code)
	end
	return out
end

describe("gitops.clean", function()
	it("drops status and server-populated metadata but keeps user metadata", function()
		local live = named(items("ns-apps/get_deployments_-o_json.txt"), "web")
		local obj = Clean.clean(live) :: any
		expect(obj.status).toBeNil()
		for _, k in { "uid", "resourceVersion", "generation", "creationTimestamp", "managedFields" } do
			expect(obj.metadata[k]).toBeNil()
		end
		expect(obj.metadata.name).toBe("web")
		expect(obj.metadata.namespace).toBe("tern-test-apps")
		expect(obj.metadata.annotations).toBeNil()
		expect(obj.spec.template.metadata.creationTimestamp).toBeNil()
	end)

	it("does not mutate the live object", function()
		local live = named(items("ns-apps/get_deployments_-o_json.txt"), "web")
		Clean.clean(live)
		expect(live.status ~= nil).toBe(true)
		expect(live.metadata.uid ~= nil).toBe(true)
	end)

	it("drops allocated Service IPs but keeps headless clusterIP None", function()
		local services = items("ns-apps/get_services_-o_json.txt")
		local web = Clean.clean(named(services, "web")) :: any
		expect(web.spec.clusterIP).toBeNil()
		expect(web.spec.clusterIPs).toBeNil()
		expect(web.spec.ipFamilies).toBeNil()
		expect(web.spec.ipFamilyPolicy).toBeNil()
		local headless = Clean.clean(named(services, "db-headless")) :: any
		expect(headless.spec.clusterIP).toBe("None")
		expect(headless.spec.clusterIPs).toBeNil()
	end)

	it("warns that node ports are kept", function()
		local _, notes = Clean.clean(named(items("ns-apps/get_services_-o_json.txt"), "web-nodeport"))
		expect(codes(notes)).toContain("node-ports")
	end)

	it("drops the generated Job selector and controller labels so the Job can be recreated", function()
		local job, notes = Clean.clean(named(items("ns-batch/get_jobs_-o_json.txt"), "done-job"))
		local j = job :: any
		expect(j.spec.selector).toBeNil()
		expect(j.spec.template.metadata.labels).toEqual({ app = "reports" })
		expect(codes(notes)).toContain("job-selector")
	end)

	it("drops ownerReferences, nodeName and the injected token volume from pods, with notes", function()
		local pod, notes = Clean.clean(named(items("ns-apps/get_pods_-o_json.txt"), "web-65d7d99975-bmgbn"))
		local p = pod :: any
		expect(p.metadata.ownerReferences).toBeNil()
		expect(p.spec.nodeName).toBeNil()
		expect(p.spec.volumes).toBeNil()
		expect(p.spec.containers[1].volumeMounts).toBeNil()
		local c = codes(notes)
		expect(c).toContain("owned")
		expect(c).toContain("node-name")
		expect(c).toContain("api-access-volume")
	end)

	it("strips restartedAt from pod templates", function()
		local live = {
			apiVersion = "apps/v1",
			kind = "Deployment",
			metadata = { name = "d" },
			spec = { template = { metadata = { annotations = { ["kubectl.kubernetes.io/restartedAt"] = "x" } } } },
		}
		local obj, notes = Clean.clean(live)
		expect((obj :: any).spec.template.metadata.annotations).toBeNil()
		expect(codes(notes)).toContain("restarted-at")
	end)

	it("replaces every Secret value with a placeholder in stringData", function()
		local live = {
			apiVersion = "v1",
			kind = "Secret",
			type = "Opaque",
			metadata = { name = "s", namespace = "n" },
			data = { password = "aHVudGVyMg==" },
			stringData = { token = "plain" },
		}
		local obj, notes = Clean.clean(live)
		local s = obj :: any
		expect(s.data).toBeNil()
		expect(s.stringData).toEqual({ password = Clean.PLACEHOLDER, token = Clean.PLACEHOLDER })
		expect(notes[#notes].severity).toBe("warning")
		expect(codes(notes)).toContain("secret-redacted")
	end)

	it("skips objects Kubernetes creates on its own", function()
		local cases = {
			{ apiVersion = "v1", kind = "ConfigMap", metadata = { name = "kube-root-ca.crt" } },
			{ apiVersion = "v1", kind = "ServiceAccount", metadata = { name = "default" } },
			{
				apiVersion = "v1",
				kind = "Secret",
				type = "kubernetes.io/service-account-token",
				metadata = { name = "t" },
			},
		}
		for _, live in cases do
			local obj, notes = Clean.clean(live)
			expect(obj).toBeNil()
			expect(codes(notes)).toEqual({ "skipped" })
		end
		local slice = named(items("ns-apps/get_endpointslices_-o_json.txt"), "web-vkq58")
		expect((Clean.clean(slice))).toBeNil()
	end)

	it("drops Namespace finalizers and the automatic name label", function()
		local live = {
			apiVersion = "v1",
			kind = "Namespace",
			metadata = { name = "a", labels = { ["kubernetes.io/metadata.name"] = "a", team = "x" } },
			spec = { finalizers = { "kubernetes" } },
		}
		local obj = Clean.clean(live) :: any
		expect(obj.metadata.labels).toEqual({ team = "x" })
		expect(obj.spec).toBeNil()
	end)

	it("drops PVC binding state", function()
		local live = {
			apiVersion = "v1",
			kind = "PersistentVolumeClaim",
			metadata = { name = "c", annotations = { ["pv.kubernetes.io/bind-completed"] = "yes" } },
			spec = { volumeName = "pvc-123", resources = { requests = { storage = "1Gi" } } },
		}
		local obj = Clean.clean(live) :: any
		expect(obj.spec.volumeName).toBeNil()
		expect(obj.metadata.annotations).toBeNil()
	end)

	it("keeps finalizers with an info note", function()
		local obj, notes =
			Clean.clean({ apiVersion = "v1", kind = "ConfigMap", metadata = { name = "c", finalizers = { "x/y" } } })
		expect((obj :: any).metadata.finalizers).toEqual({ "x/y" })
		expect(codes(notes)).toEqual({ "finalizers" })
	end)
end)

return nil
