--!strict
-- The taint server dry run returns the node only: which pods a NoExecute
-- taint evicts is computed here, so it must follow the Kubernetes
-- toleration rules exactly, or the approve block understates the damage.
local Fixtures = require("../../lib/fixtures")
local Taint = require("../../../plugin/lib/mutation/taint")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function node(taints: { any }): any
	return { metadata = { name = "n1" }, spec = { taints = taints } }
end

local function pod(name: string, tolerations: { any }, extra: { [string]: any }?): any
	local p: any = {
		metadata = { namespace = "apps", name = name },
		spec = { tolerations = tolerations },
		status = { phase = "Running" },
	}
	for k, v in (extra or {}) :: { [string]: any } do
		p.metadata[k] = v
	end
	return p
end

describe("taint spec parsing", function()
	it("reads adds and removals as kubectl does", function()
		local function parsed(spec: string): any
			return (Taint.parse(spec))
		end
		expect(parsed("dedicated=gpu:NoSchedule")).toEqual({
			key = "dedicated",
			value = "gpu",
			effect = "NoSchedule",
			remove = false,
		})
		expect(parsed("k:NoExecute")).toEqual({ key = "k", effect = "NoExecute", remove = false })
		expect(parsed("k-")).toEqual({ key = "k", remove = true })
		expect(parsed("k:NoSchedule-")).toEqual({ key = "k", effect = "NoSchedule", remove = true })
		expect(parsed("k=v:PreferNoSchedule-")).toEqual({ key = "k", effect = "PreferNoSchedule", remove = true })
	end)

	it("rejects specs kubectl rejects (missing or unknown effect, empty key)", function()
		for _, bad in { "k=v", "k:Sometimes", "=v:NoSchedule", "k:Nope-" } do
			local spec, why = Taint.parse(bad)
			expect(spec).toBeNil()
			expect(why ~= nil).toBe(true)
		end
	end)
end)

describe("Taint.tolerates", function()
	local taint = { key = "dedicated", value = "gpu", effect = "NoExecute" }
	it("matches Equal on key and value, Exists on key only", function()
		expect(Taint.tolerates({ key = "dedicated", value = "gpu" }, taint)).toBe(true)
		expect(Taint.tolerates({ key = "dedicated", operator = "Equal", value = "cpu" }, taint)).toBe(false)
		expect(Taint.tolerates({ key = "dedicated", operator = "Exists" }, taint)).toBe(true)
		expect(Taint.tolerates({ key = "other", operator = "Exists" }, taint)).toBe(false)
	end)

	it("treats an empty effect as any effect and an empty Exists key as every taint", function()
		expect(Taint.tolerates({ operator = "Exists" }, taint)).toBe(true)
		expect(Taint.tolerates({ key = "dedicated", operator = "Exists", effect = "NoSchedule" }, taint)).toBe(false)
		expect(Taint.tolerates({ operator = "Exists", effect = "NoExecute" }, taint)).toBe(true)
	end)
end)

describe("Taint.evictions", function()
	local added = node({ { key = "k", value = "v", effect = "NoExecute" } })
	it("evicts pods without a toleration now, tolerationSeconds later, the rest stay", function()
		local e = Taint.evictions(node({}), added, {
			pod("plain", {}),
			pod("timed", { { key = "k", operator = "Exists", tolerationSeconds = 60 } }),
			pod("forever", { { operator = "Exists" } }),
			pod("zero", { { key = "k", operator = "Exists", tolerationSeconds = 0 } }),
		})
		expect(e.immediate).toEqual({ { namespace = "apps", name = "plain" }, { namespace = "apps", name = "zero" } })
		expect(e.delayed).toEqual({ { namespace = "apps", name = "timed", seconds = 60 } })
		expect(e.stays).toEqual({ { namespace = "apps", name = "forever" } })
	end)

	it("counts a changed value as a new taint, an unchanged one as nothing", function()
		local before = node({ { key = "k", value = "old", effect = "NoExecute" } })
		expect(#Taint.evictions(before, added, { pod("plain", {}) }).immediate).toBe(1)
		expect(#Taint.evictions(added, added, { pod("plain", {}) }).immediate).toBe(0)
		local schedule = node({ { key = "k", value = "v", effect = "NoSchedule" } })
		expect(#Taint.evictions(node({}), schedule, { pod("plain", {}) }).immediate).toBe(0)
	end)

	it("skips mirror pods and finished pods", function()
		local mirror = pod("etcd", {}, { annotations = { ["kubernetes.io/config.mirror"] = "x" } })
		local done = pod("job", {})
		done.status.phase = "Succeeded"
		local e = Taint.evictions(node({}), added, { mirror, done })
		expect(#e.immediate + #e.delayed + #e.stays).toBe(0)
	end)

	-- Captured from the kind node (tests/fixtures/kubectl/taint/pods-on-node.json,
	-- built from the design probe's toleration listing): a custom NoExecute
	-- taint evicts coredns, metrics-server and the fixtures, while static pods
	-- (mirror) and DaemonSet pods stay.
	it("matches the pods captured on the kind node", function()
		local doc = json.decode(Fixtures.read("kubectl/taint/pods-on-node.json"))
		local e =
			Taint.evictions(node({}), node({ { key = "tkm-taint", value = "1", effect = "NoExecute" } }), doc.items)
		local function has(list: { { namespace: string, name: string } }, ns: string, prefix: string): boolean
			for _, p in list do
				if p.namespace == ns and string.sub(p.name, 1, #prefix) == prefix then
					return true
				end
			end
			return false
		end
		expect(has(e.immediate, "kube-system", "coredns-")).toBe(true)
		expect(has(e.immediate, "kube-system", "metrics-server-")).toBe(true)
		expect(has(e.immediate, "local-path-storage", "local-path-provisioner-")).toBe(true)
		expect(has(e.stays, "kube-system", "kindnet-")).toBe(true)
		expect(has(e.stays, "kube-system", "kube-proxy-")).toBe(true)
		-- Static pods are mirror pods: the kubelet keeps them, they are not listed.
		expect(has(e.immediate, "kube-system", "etcd-")).toBe(false)
		expect(has(e.stays, "kube-system", "etcd-")).toBe(false)
	end)
end)

return nil
