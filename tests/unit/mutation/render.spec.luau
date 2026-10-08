--!strict
-- What the approve block shows. The confirm control must match the tier (no
-- clickable Confirm while a typed token or a blocking reason is unmet), the
-- target and the exact command must always be visible, and diffs must be the
-- per-resource hunks the preview produced.
local A = require("../../lib/approve")
local Fixtures = require("../../lib/fixtures")
local N = require("../../lib/nodes")
local Render = require("../../../plugin/lib/mutation/render")
local Session = require("../../../plugin/lib/mutation/session")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local SCALE =
	"tern-kube://mutate?op=scale&kind=deployment&name=web&namespace=apps&replicas=1&context=kind-dev&source=chosen"
local DELETE = "tern-kube://mutate?op=delete&kind=deployment&name=web&namespace=apps&context=kind-dev&source=chosen"
local APPLY = "tern-kube://mutate?op=apply&file=%2Fw%2Fapps.yaml&context=kind-dev"

local function ready(url: string, world: A.World?): Session.State
	local s, effects = A.init(url)
	A.drive(s, effects, A.cluster(world))
	return s
end

local function confirmButton(v: Render.View): N.Node
	return N.find(v.main, N.all(N.kind("el"), N.key("confirm"))) :: N.Node
end

local function present(x: any)
	expect(x ~= nil).toBe(true)
end

describe("approve view: header", function()
	it("always shows the target context, its cluster server and the exact command", function()
		local v = Render.view(ready(SCALE))
		local head = N.text(N.find(v.main, N.key("header")) :: N.Node)
		expect(head).toContain("kind-dev")
		expect(head).toContain("chosen in Tern Kube")
		expect(head).toContain(A.SERVER)
		expect(head).toContain("kubectl --kubeconfig /k/config --context kind-dev scale deployment/web")
	end)

	it("warns when the context was inferred", function()
		local v = Render.view(ready("tern-kube://mutate?op=restart&kind=deployment&name=web&namespace=apps"))
		expect(N.text(v.main)).toContain("inferred from current-context")
		present(N.find(v.main, N.all(N.kind("el"), N.key("tc"))))
	end)

	it("wraps the mode/op/tier bar so a narrow split never squeezes the op to one letter per line", function()
		local bar = N.find(Render.view(ready(SCALE)).main, N.role("tern-kube.bar")) :: N.Node
		expect((bar.p :: any).wrap).toBe(true)
	end)

	it("shows no empty Command row while it still asks for the path", function()
		local s = A.init("tern-kube://mutate?op=apply&cwd=%2Fw%2Frepo&context=kind-dev")
		expect(s.phase).toBe("input")
		local head = N.text(N.find(Render.view(s).main, N.key("header")) :: N.Node)
		expect(string.find(head, "Command", 1, true) == nil).toBe(true)
	end)

	it("names the fallback namespace of an apply without a doubled 'default'", function()
		local head = N.text(N.find(Render.view(ready(APPLY)).main, N.key("header")) :: N.Node)
		expect(head).toContain("as declared in the manifests, else default")
	end)
end)

describe("approve view: confirm control per tier", function()
	it("simple tier: an active Confirm button and enter in the hints", function()
		local v = Render.view(ready(SCALE))
		expect(N.action(confirmButton(v))).toBe("confirm")
		expect(N.text(v.dock :: N.Node)).toContain("enter confirm")
		expect(N.find(v.main, N.key("typed"))).toBeNil()
	end)

	it("names t in the hints while an inferred target still needs confirming", function()
		local s = ready("tern-kube://mutate?op=restart&kind=deployment&name=web&namespace=apps")
		expect(N.text(Render.view(s).dock :: N.Node)).toContain("t confirm target · enter confirm")
		s.targetConfirmed = true
		expect(string.find(N.text(Render.view(s).dock :: N.Node), "t confirm target", 1, true) == nil).toBe(true)
	end)

	it("typed tier: a focused-input prompt with the token, Confirm inactive until it matches", function()
		local s = ready(DELETE)
		local v = Render.view(s)
		local input = N.find(v.main, N.all(N.kind("input"), N.key("typed"))) :: N.Node
		present(input)
		-- A direct child of main, so its id is main.typed (cx:frame focus).
		local direct = false
		local children: { N.Node } = v.main.c or {}
		for _, c in children do
			if c == input then
				direct = true
			end
		end
		expect(direct).toBe(true)
		expect(N.text(N.find(v.main, N.key("prompt")) :: N.Node)).toContain("web")
		expect(N.action(confirmButton(v))).toBeNil()
		A.typeText(s, "web", A.cluster())
		expect(N.action(confirmButton(Render.view(s)))).toBe("confirm")
	end)

	it("blocked tier: the reasons, no confirm action", function()
		local v = Render.view(ready(SCALE, { ["step:dry-run"] = A.failed(1, "Error from server (Forbidden): no") }))
		local blocked = N.find(v.main, N.key("blocked")) :: N.Node
		expect(N.text(blocked)).toContain("allow_failed_preview_override")
		expect(N.text(N.find(v.main, N.key("steps")) :: N.Node)).toContain("Forbidden")
		expect(N.action(confirmButton(v))).toBeNil()
	end)

	it("guard mode: cancel reads Deny", function()
		local s, effects = A.init(A.requestPath(), { request = A.request({}) })
		A.drive(s, effects, A.cluster())
		local v = Render.view(s)
		expect(N.ownText(N.find(v.main, N.all(N.kind("el"), N.key("cancel"))) :: N.Node)).toBe("Deny")
		expect(N.ownText(confirmButton(v))).toBe("Approve")
		expect(N.text(v.main)).toContain("shell pane 7")
	end)
end)

describe("approve view: diffs and risks", function()
	local world: A.World = {
		diff = Fixtures.read("real/mutate-preview/diff_-f_preview+apps-mix.yaml.txt"),
		files = { { path = "/w/apps.yaml", size = 10, sha256 = string.rep("a", 64) } },
	}

	it("one collapsible card per resource with only the hunks in a diff node", function()
		local s = ready(APPLY, world)
		local v = Render.view(s)
		local cards = N.findAll(v.main, N.role("tern-kube.approve-diff"))
		expect(#cards).toBe(#(s.diff :: any).segments)
		local diff = N.find(cards[1], N.kind("diff")) :: N.Node
		expect(string.sub((diff.p :: any).text, 1, 2)).toBe("@@")
		expect((cards[1].p :: any).collapsible).toBe(true)
		expect((cards[1].p :: any).collapsed).toBe(true)
	end)

	it("tab expands the next resource diff", function()
		local s = ready(APPLY, world)
		A.send(s, A.key("tab"), A.cluster(world))
		local cards = N.findAll(Render.view(s).main, N.role("tern-kube.approve-diff"))
		expect((cards[1].p :: any).collapsed).toBe(false)
		expect((cards[1].p :: any).selected).toBe(true)
		A.send(s, A.key("tab"), A.cluster(world))
		cards = N.findAll(Render.view(s).main, N.role("tern-kube.approve-diff"))
		expect((cards[1].p :: any).collapsed).toBe(true)
		expect((cards[2].p :: any).collapsed).toBe(false)
	end)

	it("labels heuristic findings as advisory", function()
		local v = Render.view(ready(APPLY, world))
		expect(N.text(N.find(v.main, N.key("risks")) :: N.Node)).toContain("advisory")
	end)
end)

describe("approve view: result and help", function()
	it("renders the executed result as a result (not a preview), with Requery", function()
		local s = ready(SCALE)
		A.send(s, A.key("enter"), A.cluster())
		local v = Render.view(s)
		local result = N.find(v.main, N.key("result")) :: N.Node
		expect(N.text(result)).toContain("Result of an executed command")
		expect(table.find(N.actions(result), "requery") ~= nil).toBe(true)
	end)

	it("shows the key help in the layer", function()
		local s = ready(SCALE)
		A.send(s, A.key("?", "?"), A.cluster())
		expect(N.text(Render.view(s).layer :: N.Node)).toContain("Tern Kube Approve keys")
	end)

	it("titles the pane with the operation and context", function()
		expect(Render.title(ready(SCALE))).toBe("Tern Kube Approve · kubectl scale · kind-dev")
	end)
end)

return nil
