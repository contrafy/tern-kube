--!strict
local Objtree = require("../../../plugin/lib/render/objtree")
local decoder = require("../../lib/json")
local fixtures = require("../../lib/fixtures")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type TreeNode = Objtree.TreeNode

local function labelOf(n: TreeNode): string
	return nodes.spansText(n.label)
end

local function child(list: { TreeNode }, prefix: string): TreeNode
	for _, n in list do
		if string.sub(labelOf(n), 1, #prefix) == prefix then
			return n
		end
	end
	error("no tree node starting with " .. prefix)
end

local function firstPod(): any
	local list = decoder.decode(fixtures.read("real/ns-apps/get_pods_-o_json.txt"))
	return list.items[1]
end

describe("objtree", function()
	it("orders identity before spec and status, like the YAML a user knows", function()
		local top = Objtree.nodes(firstPod())
		local labels = {}
		for _, n in top do
			table.insert(labels, (string.match(labelOf(n), "^([^%s:]+)")))
		end
		expect({ labels[1], labels[2], labels[3], labels[4], labels[#labels] }).toEqual({
			"apiVersion",
			"kind",
			"metadata",
			"spec",
			"status",
		})
		expect(labelOf(child(top, "kind"))).toBe("kind: Pod")
	end)

	it("opens the first two levels and keeps deeper levels collapsed", function()
		local top = Objtree.nodes(firstPod())
		local metadata = child(top, "metadata")
		expect(metadata.open).toBe(true)
		local labels = child(metadata.children :: { TreeNode }, "labels")
		expect(labels.open).toBe(true)
		local spec = child(top, "spec")
		local containers = child(spec.children :: { TreeNode }, "containers")
		local first = (containers.children :: { TreeNode })[1]
		-- Array items carry their name so a collapsed container is still identifiable.
		expect(labelOf(first)).toContain("[0] ")
		expect(first.open).toBe(false)
	end)

	it("masks Secret data and the last-applied annotation that embeds it", function()
		local secret = {
			apiVersion = "v1",
			kind = "Secret",
			metadata = {
				name = "app-secret",
				annotations = {
					["kubectl.kubernetes.io/last-applied-configuration"] = '{"data":{"password":"aHVudGVyMg=="}}',
				},
			},
			data = { password = "aHVudGVyMg==" },
			stringData = { token = "plain-token" },
		}
		local text = nodes.text(Objtree.tree(secret))
		expect((string.find(text, "aHVudGVyMg==", 1, true))).toBeNil()
		expect((string.find(text, "plain-token", 1, true))).toBeNil()
		expect(text).toContain("<redacted: 12 bytes base64>")
		-- The input object is untouched: Raw and copy actions still see the original.
		expect(secret.data.password).toBe("aHVudGVyMg==")
	end)

	it("masks Secrets inside a List", function()
		local list =
			{ kind = "List", items = { { kind = "Secret", metadata = { name = "s" }, data = { k = "c2VjcmV0" } } } }
		local text = nodes.text(Objtree.tree(list))
		expect((string.find(text, "c2VjcmV0", 1, true))).toBeNil()
		expect(text).toContain("redacted")
	end)

	it("caps children per node with an overflow line instead of rendering everything", function()
		local big = {}
		for i = 1, 1000 do
			big[i] = { name = "item-" .. i }
		end
		local top = Objtree.nodes({ items = big })
		local items = child(top, "items")
		local kids = items.children :: { TreeNode }
		expect(#kids).toBe(201)
		expect(labelOf(kids[201])).toBe("… 800 more (Raw shows everything)")
	end)

	it("shortens very long strings and says how long they were", function()
		local long = string.rep("x", 5000)
		local top = Objtree.nodes({ note = long })
		local label = labelOf(top[1])
		expect(#label < 400).toBe(true)
		expect(label).toContain("(5000 bytes)")
	end)

	it("renders numbers as integers and shows empty maps", function()
		local top = Objtree.nodes({ replicas = 3, resources = {} })
		expect(labelOf(child(top, "replicas"))).toBe("replicas: 3")
		expect(labelOf(child(top, "resources"))).toBe("resources: {}")
	end)
	it("gives every node a stable unique id so Tern keeps what the user expanded", function()
		local seen: { [string]: boolean } = {}
		local dupes = 0
		local function visit(list: { TreeNode })
			for _, n in list do
				if seen[n.id] then
					dupes += 1
				end
				seen[n.id] = true
				if n.children then
					visit(n.children)
				end
			end
		end
		local pod = firstPod()
		local a = Objtree.nodes(pod)
		visit(a)
		expect(dupes).toBe(0)
		expect(Objtree.nodes(pod)[3].id).toBe(a[3].id)
	end)
end)

return nil
