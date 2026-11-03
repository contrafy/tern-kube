--!strict
-- The lens never queries helm: its chip carries only the release key read
-- from the captured object, and the click becomes an Explore link pinned to
-- the command's context. Values no chip could produce must open nothing.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Command = require("../../../plugin/lib/kubectl/command")
local HelmChip = require("../../../plugin/lib/render/helm_chip")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function params(url: string): { [string]: string }
	local out: { [string]: string } = {}
	for _, kv in Command.parseQuery(url) do
		out[kv.key] = kv.value
	end
	return out
end

local SHOP: any = { release = "shop-a", namespace = "tern-test-helm-ui", via = "annotation" }

describe("helm chip", function()
	it("labels the release with its namespace and clicks with its key", function()
		local chip = HelmChip.node(SHOP, "k") :: any
		expect(nodes.text(chip)).toBe("Helm release tern-test-helm-ui/shop-a")
		expect(nodes.action(chip)).toBe("helm-release=tern-test-helm-ui/shop-a")
		expect(chip.p.role).toBe(HelmChip.ROLE)
	end)

	it("says probably when only the instance label names the release", function()
		local guess: any = { release = "shop-a", namespace = "ns", via = "instance-label" }
		expect((HelmChip.node(guess) :: any).p.title).toContain("Probably")
		expect((string.find((HelmChip.node(SHOP) :: any).p.title, "Probably", 1, true))).toBeNil()
	end)

	it("shows nothing without an owner or for names helm would reject", function()
		expect(HelmChip.node(nil)).toBeNil()
		local long = string.rep("a", 54)
		expect(HelmChip.node({ release = long, namespace = "ns", via = "annotation" })).toBeNil()
		expect(HelmChip.node({ release = "Shop", namespace = "ns", via = "annotation" })).toBeNil()
		expect(HelmChip.node({ release = "shop", namespace = "NS", via = "annotation" })).toBeNil()
	end)

	it("builds the helm-release Explore link with the command's context, kubeconfig and cwd", function()
		local inv =
			Argv.parse("kubectl", { "--context", "kind-tern-kube-dev", "--kubeconfig", "/k/c", "get", "deploy" })
		local url = HelmChip.url(inv, "tern-test-helm-ui/shop-a", "/repo") :: string
		expect(string.sub(url, 1, #"tern-kube://explore?")).toBe("tern-kube://explore?")
		expect(params(url)).toEqual({
			route = "helm-release",
			release = "shop-a",
			namespace = "tern-test-helm-ui",
			context = "kind-tern-kube-dev",
			kubeconfig = "/k/c",
			cwd = "/repo",
		})
	end)

	-- The release namespace comes from the object, not from `-n`.
	it("keeps the release namespace over the command's -n", function()
		local inv = Argv.parse("kubectl", { "-n", "other", "get", "deploy" })
		expect(params(HelmChip.url(inv, "rel-ns/web-b") :: string).namespace).toBe("rel-ns")
	end)

	it("opens nothing for values no chip produced", function()
		local inv = Argv.parse("kubectl", { "get", "pods" })
		for _, v in { "", "shop-a", "ns/", "/shop", "a/b/c", "ns/Bad_Name", "ns/x&route=delete" } do
			expect(HelmChip.url(inv, v)).toBeNil()
		end
	end)

	it("reads --show-labels cells", function()
		expect(HelmChip.labels("app.kubernetes.io/instance=shop-a,app.kubernetes.io/managed-by=Helm,empty=")).toEqual({
			["app.kubernetes.io/instance"] = "shop-a",
			["app.kubernetes.io/managed-by"] = "Helm",
			empty = "",
		})
		expect(HelmChip.labels("<none>")).toEqual({})
	end)
end)

return nil
