--!strict
-- What the approve block shows. The confirm control must match the tier (no
-- clickable Confirm while a typed token or a blocking reason is unmet), the
-- target and the exact command must always be visible, and diffs must be the
-- per-resource hunks the preview produced.
local A = require("../../lib/approve")
local Fixtures = require("../../lib/fixtures")
local Link = require("../../../plugin/lib/mutation/link")
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

	-- MUT-F4: while the field takes the keyboard `t` is text, so the dock names
	-- ctrl+t for the target step and the exact token to type.
	it("typed tier with an inferred target: the dock names ctrl+t and the token", function()
		local s = ready("tern-kube://mutate?op=delete&kind=deployment&name=web&namespace=apps")
		local dock = N.text(Render.view(s).dock :: N.Node)
		expect(dock).toContain('ctrl+t confirm target · type "web" · enter confirms when it matches')
		local d = A.send(s, A.key("t", "t"), A.cluster())
		expect(s.targetConfirmed).toBe(false)
		expect(s.typed).toBe("t")
		A.send(s, A.key("backspace"), A.cluster())
		local ctrlT = A.key("t", "t")
		ctrlT.key = { name = "t", text = "t", ctrl = true, alt = false, shift = false, meta = false }
		A.send(s, ctrlT, A.cluster())
		expect(s.targetConfirmed).toBe(true)
		expect(s.typed).toBe("")
		expect((string.find(N.text(Render.view(s).dock :: N.Node), "ctrl+t", 1, true))).toBeNil()
		A.typeText(s, "web", A.cluster())
		d = A.send(s, A.key("enter"), A.cluster())
		present(A.find(d.runs, "run", "exec"))
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

	-- MUT-F2: a request whose context moved cannot be previewed into a match.
	it("guard mode: a final refusal offers Deny and no Preview again", function()
		local s, effects = A.init(A.requestPath(), { request = A.request({ source = "current-context" }) })
		A.drive(s, effects, A.cluster())
		A.send(s, A.key("t", "t"), A.cluster())
		A.send(s, A.key("enter"), A.cluster({ current = "prod" }))
		local v = Render.view(s)
		expect(N.find(v.main, N.all(N.kind("el"), N.key("rerun")))).toBeNil()
		expect(N.ownText(N.find(v.main, N.all(N.kind("el"), N.key("cancel"))) :: N.Node)).toBe("Deny")
		local dock = N.text(v.dock :: N.Node)
		expect(dock).toContain("esc deny")
		expect((string.find(dock, "preview again", 1, true))).toBeNil()
		expect(N.text(v.main)).toContain("Run the command again")
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

	-- GIT-F4: the dry run reports a Secret (stringData) configured while
	-- kubectl diff shows nothing for it; every object must be accounted for.
	it("lists objects the dry run configures but kubectl diff shows no change for", function()
		local dry = Fixtures.read("real/mutate-preview/apply_--dry-run=server_-f_preview+apps-mix.yaml.txt")
			.. "secret/app-secret configured (server dry run)\n"
		local w = table.clone(world)
		w["step:dry-run"] = A.ok(dry)
		local v = Render.view(ready(APPLY, w))
		local note = N.text(N.find(v.main, N.key("no-visible-diff")) :: N.Node)
		expect(note).toBe("Configured, no visible diff: secret/app-secret")
		expect(N.text(N.find(v.main, N.key("unchanged")) :: N.Node)).toBe("Unchanged: service/web")
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

local function linkFor(fields: { [string]: any }): string
	local r: any = { recursive = false, overwrite = false, context = "kind-dev", source = "chosen" }
	for k, v in fields do
		r[k] = v
	end
	return (Link.encode(r)) :: string
end

describe("approve view: track 1 verbs", function()
	it("asks for input with the op's prompt and hint", function()
		local s = A.init(linkFor({ op = "label", kind = "configmap", name = "cm", namespace = "apps" }))
		local v = Render.view(s)
		expect(N.text(N.find(v.main, N.key("prompt")) :: N.Node)).toContain("Labels for configmap/cm")
		expect(N.text(v.dock :: N.Node)).toContain("enter preview · esc cancel")
	end)

	it("groups the pods a drain evicts by namespace and marks the blocked and unmanaged ones", function()
		local url = linkFor({
			op = "drain",
			kind = "node",
			name = "n1",
			drainFlags = { "--ignore-daemonsets", "--timeout=1m" },
		})
		local s = ready(url, {
			["step:targets"] = A.ok(Fixtures.read("kubectl/track1/get-node-json.txt")),
			["step:dry-run"] = {
				status = 0,
				stdout = Fixtures.read("kubectl/track1/drain-client-ok.txt"),
				stderr = Fixtures.read("kubectl/track1/drain-client-ok.stderr"),
				timed_out = false,
			},
			["step:evict"] = {
				status = 1,
				stdout = Fixtures.read("kubectl/track1/drain-server-pdb-timeout.txt"),
				stderr = Fixtures.read("kubectl/track1/drain-server-pdb-timeout.stderr"),
				timed_out = false,
			},
		})
		expect(s.phase).toBe("ready")
		local card = N.text(N.find(Render.view(s).main, N.key("drain")) :: N.Node)
		expect(card).toContain("6 pod(s) to evict")
		expect(card).toContain("tern-test-t1")
		expect(card).toContain("PDB-blocked")
		expect(card).toContain("no controller")
		expect(card).toContain("DaemonSet ignored")
	end)

	it("shows the revision each workload rolls back to", function()
		local KEY = "apps.v1.Deployment.tern-test-t1.web"
		local w: A.World = {
			["step:targets"] = A.ok(Fixtures.read("kubectl/track1/get-deploy-web-json.txt")),
			["step:history"] = A.ok(Fixtures.read("kubectl/track1/rollout-history-deploy.txt")),
			["step:dry-run"] = A.ok("deployment.apps/web rolled back (server dry run)\n"),
		}
		w["step:revision:" .. KEY] = A.ok(Fixtures.read("kubectl/track1/rollout-history-deploy-rev1-json.txt"))
		local s = ready(linkFor({ op = "undo", kind = "deployment", name = "web", namespace = "tern-test-t1" }), w)
		local objects = N.text(N.find(Render.view(s).main, N.key("objects")) :: N.Node)
		expect(objects).toContain("to be rolled back")
		expect(objects).toContain("revision 2 → 1")
	end)

	it("names the edited file and the pane of an edit approval", function()
		local files = {
			{ path = "/tmp/kubectl-edit-1.yaml", size = 1, sha256 = string.rep("a", 64) },
			{ path = "/tmp/d/original.yaml", size = 1, sha256 = string.rep("b", 64) },
		}
		local s, effects = A.init(A.requestPath(), {
			request = A.request({
				argv = { "kubectl", "edit", "widget/w1" },
				files = files,
				edit = { file = files[1].path, original = files[2].path },
			}),
		})
		A.drive(
			s,
			effects,
			A.cluster({
				files = files,
				["step:convert-original"] = A.ok(Fixtures.read("kubectl/track1/convert-original.txt")),
				["step:convert-edited"] = A.failed(1, "error: bad yaml"),
				["step:targets"] = A.ok(Fixtures.read("kubectl/track1/get-widget-json.txt")),
			})
		)
		local card = N.text(N.find(Render.view(s).main, N.key("edit")) :: N.Node)
		expect(card).toContain("/tmp/kubectl-edit-1.yaml")
		expect(card).toContain("shell pane 7")
		expect(card).toContain("error: bad yaml")
	end)

	it("offers Change input after an input op's preview and lists i in the help", function()
		local s = ready(linkFor({ op = "scale", kind = "deployment", name = "web", namespace = "apps", replicas = 2 }))
		local v = Render.view(s)
		present(N.find(v.main, N.all(N.kind("el"), N.key("input"))))
		expect(N.text(v.dock :: N.Node)).toContain("i change input")
		A.send(s, A.key("?", "?"), A.cluster())
		expect(N.text(Render.view(s).layer :: N.Node)).toContain("Change the input")
	end)
end)

return nil
