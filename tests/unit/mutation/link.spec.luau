--!strict
-- Mutate links and quick-action grants. A link may only name a target: the
-- block rebuilds the command, so nothing in a URL can smuggle flags or shell
-- text. A grant lets exactly one confirmed action through the window.
local Link = require("../../../plugin/lib/mutation/link")
local Quick = require("../../../plugin/lib/actions/quick")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local TOKEN = string.rep("ab", 16)

describe("mutate links", function()
	it("round-trips every field", function()
		local url = Link.encode({
			op = "scale",
			kind = "deployment.apps",
			name = "web",
			namespace = "apps",
			replicas = 3,
			recursive = false,
			context = "kind dev's",
			source = "chosen",
			kubeconfig = "/k/a b",
		}) :: string
		local r = Link.decode(url) :: Link.Request
		expect(r.op).toBe("scale")
		expect(r.kind).toBe("deployment.apps")
		expect(r.replicas).toBe(3)
		expect(r.context).toBe("kind dev's")
		expect(r.kubeconfig).toBe("/k/a b")
		expect(Link.argv(r, "kubectl")).toEqual({
			"kubectl",
			"scale",
			"deployment.apps/web",
			"--replicas=3",
			"-n",
			"apps",
		})
	end)

	it("builds apply argv from a file or a kustomization, with the input's directory as cwd", function()
		local r = Link.decode("tern-kube://mutate?op=apply&file=%2Fw%2Fm%2Fa.yaml&recursive=1") :: Link.Request
		expect(Link.argv(r, "kubectl")).toEqual({ "kubectl", "apply", "-f", "/w/m/a.yaml", "-R" })
		expect(Link.cwd(r, "/home")).toBe("/w/m")
		r = Link.decode("tern-kube://mutate?op=apply&kustomize=%2Fw%2Fover") :: Link.Request
		expect(Link.argv(r, "kubectl")).toEqual({ "kubectl", "apply", "-k", "/w/over" })
	end)

	it("rejects anything that is not a plain target", function()
		local cases = {
			"tern-kube://mutate?op=exec&kind=pod&name=x",
			"tern-kube://mutate?op=delete&kind=pod&name=--all",
			"tern-kube://mutate?op=delete&kind=pod&name=x&flags=--force",
			"tern-kube://mutate?op=delete&kind=pod",
			"tern-kube://mutate?op=delete&kind=pod&name=x&name=y",
			"tern-kube://mutate?op=delete&kind=pod&name=x;rm",
			"tern-kube://mutate?op=restart&kind=pod&name=x",
			"tern-kube://mutate?op=scale&kind=service&name=x&replicas=1",
			"tern-kube://mutate?op=scale&kind=deploy&name=x&replicas=-1",
			"tern-kube://mutate?op=apply&file=relative.yaml",
			"tern-kube://mutate?op=apply&file=%2Fa&kustomize=%2Fb",
			"tern-kube://mutate?op=apply",
			"tern-kube://mutate?op=delete&kind=node&name=n1&namespace=apps",
			"tern-kube://mutate?op=delete&kind=pod&name=x&context=-x",
			"tern-kube://mutate?op=delete&kind=pod&name=x&namespace=a%0Ab",
		}
		for _, url in cases do
			local r, e = Link.decode(url)
			expect(r).toBeNil()
			expect(type(e)).toBe("string")
		end
	end)

	it("leaves a scale without replicas for the block to ask", function()
		local r = Link.decode("tern-kube://mutate?op=scale&kind=sts&name=db") :: Link.Request
		expect(Link.argv(r, "kubectl")).toBeNil()
	end)

	-- The palette's "Apply file or directory" opens the block with only the
	-- focused pane's cwd; the user types the path there.
	it("leaves an apply with only a cwd for the block to ask, and resolves the typed path", function()
		local r = Link.decode("tern-kube://mutate?op=apply&cwd=%2Fw%2Frepo") :: Link.Request
		expect(Link.argv(r, "kubectl")).toBeNil()
		local function typed(input: string): { string }?
			local out = Link.withPath(r, input, "/home/me")
			return if out then Link.argv(out, "kubectl") else nil
		end
		expect(typed("k8s/app.yaml")).toEqual({ "kubectl", "apply", "-f", "/w/repo/k8s/app.yaml" })
		expect(typed("  ./k8s/../dir with space/ ")).toEqual({ "kubectl", "apply", "-f", "/w/repo/dir with space" })
		expect(typed("-R manifests")).toEqual({ "kubectl", "apply", "-f", "/w/repo/manifests", "-R" })
		expect(typed("manifests -R")).toEqual({ "kubectl", "apply", "-f", "/w/repo/manifests", "-R" })
		expect(typed("-k overlays/dev")).toEqual({ "kubectl", "apply", "-k", "/w/repo/overlays/dev" })
		expect(typed("/abs/x.yaml")).toEqual({ "kubectl", "apply", "-f", "/abs/x.yaml" })
		expect(typed("~/m.yaml")).toEqual({ "kubectl", "apply", "-f", "/home/me/m.yaml" })
		expect((Link.withPath(r, "a.yaml", "/home/me") :: Link.Request).cwd).toBe("/w/repo")
	end)

	it("refuses stdin, empty input and -R with -k at the apply prompt", function()
		local r = Link.decode("tern-kube://mutate?op=apply&cwd=%2Fw") :: Link.Request
		for _, input in { "", "   ", "-", "-f x", "-k -R d", "-k d -R" } do
			local out, e = Link.withPath(r, input)
			expect(out).toBeNil()
			expect(type(e)).toBe("string")
		end
		expect((Link.withPath(r, "~/x"))).toBeNil()
	end)

	it("builds shortcut links per kind: delete everywhere, restart and scale on workloads", function()
		local origin: Link.Origin = { context = "kind-dev", source = "chosen", kubeconfig = "/k/c" }
		local function ops(ref: any): { string }
			local out: { string } = {}
			for _, c in Link.chips(ref, origin) do
				table.insert(out, c.op .. ":" .. c.key)
			end
			return out
		end
		local deploy: any = { kind = "Deployment", group = "apps", name = "web", namespace = "apps", source = "live" }
		expect(ops(deploy)).toEqual({ "delete:ctrl+d", "restart:ctrl+r", "scale:shift+s" })
		expect(ops({ kind = "Pod", name = "p", namespace = "apps", source = "live" })).toEqual({ "delete:ctrl+d" })
		expect(ops({ kind = "Node", name = "n1", source = "live" })).toEqual({ "delete:ctrl+d" })
		local chip = Link.chips(deploy, origin)[1]
		expect(chip.title).toBe("Preview, then confirm: kubectl delete deployment.apps/web -n apps")
		local req = Link.decode(chip.url) :: Link.Request
		expect(req.context).toBe("kind-dev")
		expect(req.source).toBe("chosen")
		expect(req.kubeconfig).toBe("/k/c")
	end)

	it("maps Explore's context source: a confirmed inferred context counts as chosen", function()
		expect(Link.sourceOf("flag", false)).toBe("flag")
		expect(Link.sourceOf("chosen", false)).toBe("chosen")
		expect(Link.sourceOf("inferred", false)).toBe("inferred")
		expect(Link.sourceOf("inferred", true)).toBe("chosen")
		expect(Link.sourceOf("unresolved", true)).toBeNil()
	end)
end)

describe("quick-action grants", function()
	local url = "tern-kube://act/debug-node?kind=Node&name=w1&context=kind-dev"

	it("lets a matching token through exactly once", function()
		local grants = Link.addGrant(nil, TOKEN, url, 100) :: Link.Grants
		local ok, rest = Link.consumeGrant(grants, TOKEN, url, 110)
		expect(ok).toBe(true)
		expect(rest[TOKEN]).toBeNil()
		local again = Link.consumeGrant(rest, TOKEN, url, 111)
		expect(again).toBe(false)
	end)

	it("refuses expired tokens, other actions and malformed tokens", function()
		local grants = Link.addGrant(nil, TOKEN, url, 100, 30) :: Link.Grants
		expect((Link.consumeGrant(grants, TOKEN, url, 131))).toBe(false)
		local ok, rest, why = Link.consumeGrant(grants, TOKEN, url .. "x", 101)
		expect(ok).toBe(false)
		expect(why).toContain("different action")
		expect(rest[TOKEN]).toBeNil()
		expect((Link.consumeGrant(grants, "nothex", url, 101))).toBe(false)
		expect((Link.addGrant(nil, "short", url, 100))).toBeNil()
	end)

	it("drops expired grants when adding a new one", function()
		local grants = Link.addGrant(nil, TOKEN, url, 100, 10) :: Link.Grants
		local other = string.rep("cd", 16)
		grants = Link.addGrant(grants, other, url, 200) :: Link.Grants
		expect(grants[TOKEN]).toBeNil()
		expect(grants[other].url).toBe(url)
	end)

	it("binds a grant to the link without its confirm parameter", function()
		local req = Quick.decode(url .. "&confirm=" .. TOKEN) :: Quick.Request
		expect(Link.quickBase(req)).toBe(url)
	end)
end)

return nil
