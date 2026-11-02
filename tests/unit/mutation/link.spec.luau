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
			overwrite = false,
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
			local out = Link.withInput(r, input, "/home/me")
			return if out then Link.argv(out, "kubectl") else nil
		end
		expect(typed("k8s/app.yaml")).toEqual({ "kubectl", "apply", "-f", "/w/repo/k8s/app.yaml" })
		expect(typed("  ./k8s/../dir with space/ ")).toEqual({ "kubectl", "apply", "-f", "/w/repo/dir with space" })
		expect(typed("-R manifests")).toEqual({ "kubectl", "apply", "-f", "/w/repo/manifests", "-R" })
		expect(typed("manifests -R")).toEqual({ "kubectl", "apply", "-f", "/w/repo/manifests", "-R" })
		expect(typed("-k overlays/dev")).toEqual({ "kubectl", "apply", "-k", "/w/repo/overlays/dev" })
		expect(typed("/abs/x.yaml")).toEqual({ "kubectl", "apply", "-f", "/abs/x.yaml" })
		expect(typed("~/m.yaml")).toEqual({ "kubectl", "apply", "-f", "/home/me/m.yaml" })
		expect((Link.withInput(r, "a.yaml", "/home/me") :: Link.Request).cwd).toBe("/w/repo")
	end)

	it("refuses stdin, empty input and -R with -k at the apply prompt", function()
		local r = Link.decode("tern-kube://mutate?op=apply&cwd=%2Fw") :: Link.Request
		for _, input in { "", "   ", "-", "-f x", "-k -R d", "-k d -R" } do
			local out, e = Link.withInput(r, input)
			expect(out).toBeNil()
			expect(type(e)).toBe("string")
		end
		expect((Link.withInput(r, "~/x"))).toBeNil()
	end)

	it("builds shortcut links per kind: rollouts on workloads, node ops on nodes, metadata ops everywhere", function()
		local origin: Link.Origin = { context = "kind-dev", source = "chosen", kubeconfig = "/k/c" }
		local function ops(ref: any): { string }
			local out: { string } = {}
			for _, c in Link.chips(ref, origin) do
				table.insert(out, c.op .. ":" .. c.key)
			end
			return out
		end
		local deploy: any = { kind = "Deployment", group = "apps", name = "web", namespace = "apps", source = "live" }
		expect(ops(deploy)).toEqual({
			"delete:ctrl+d",
			"restart:ctrl+r",
			"scale:shift+s",
			"undo:U",
			"pause:p",
			"resume:P",
			"label:t",
			"annotate:T",
			"patch:X",
		})
		expect(ops({ kind = "Pod", name = "p", namespace = "apps", source = "live" })).toEqual({
			"delete:ctrl+d",
			"label:t",
			"annotate:T",
			"patch:X",
		})
		expect(ops({ kind = "Node", name = "n1", source = "live" })).toEqual({
			"delete:ctrl+d",
			"cordon:C",
			"uncordon:u",
			"drain:D",
			"label:t",
			"annotate:T",
			"patch:X",
		})
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

	-- Each chip offers only what can change: a paused Deployment cannot be
	-- paused again (kubectl exits 1), a cordoned node not cordoned again.
	it("offers Pause or Resume and Cordon or Uncordon from the known state, both when unknown", function()
		local origin: Link.Origin = {}
		local function labels(ref: any, state: Link.ObjState?): string
			local out: { string } = {}
			for _, c in Link.chips(ref, origin, state) do
				table.insert(out, c.label)
			end
			return table.concat(out, ",")
		end
		local deploy: any = { kind = "Deployment", group = "apps", name = "web", namespace = "a", source = "live" }
		expect(labels(deploy, { paused = true })).toBe("Delete,Restart,Scale,Undo,Resume,Label,Annotate,Patch")
		expect(labels(deploy, { paused = false })).toBe("Delete,Restart,Scale,Undo,Pause,Label,Annotate,Patch")
		local node: any = { kind = "Node", name = "n1", source = "live" }
		expect(labels(node, { unschedulable = true })).toBe("Delete,Uncordon,Drain,Label,Annotate,Patch")
		expect(labels(node, { unschedulable = false })).toBe("Delete,Cordon,Drain,Label,Annotate,Patch")
		expect(labels({ kind = "Event", name = "e.1", namespace = "a", source = "live" } :: any, nil)).toBe("Delete")
		local ds: any = { kind = "DaemonSet", group = "apps", name = "d", namespace = "a", source = "live" }
		expect(labels(ds, nil)).toBe("Delete,Restart,Undo,Label,Annotate,Patch")
	end)

	it("builds argv for the ops that need no input, nodes without a namespace", function()
		local origin: Link.Origin = { context = "kind-dev", source = "chosen" }
		local deploy: any = { kind = "Deployment", group = "apps", name = "web", namespace = "apps", source = "live" }
		local node: any = { kind = "Node", name = "w1", source = "live" }
		local function argv(op: Link.Op, ref: any): { string }?
			local url = Link.forRef(op, ref, origin)
			return Link.argv(Link.decode(url :: string) :: Link.Request, "kubectl")
		end
		expect(argv("undo", deploy)).toEqual({ "kubectl", "rollout", "undo", "deployment.apps/web", "-n", "apps" })
		expect(argv("pause", deploy)).toEqual({ "kubectl", "rollout", "pause", "deployment.apps/web", "-n", "apps" })
		expect(argv("resume", deploy)).toEqual({ "kubectl", "rollout", "resume", "deployment.apps/web", "-n", "apps" })
		expect(argv("cordon", node)).toEqual({ "kubectl", "cordon", "w1" })
		expect(argv("uncordon", node)).toEqual({ "kubectl", "uncordon", "w1" })
		local podOnNode: any = { kind = "Node", name = "w1", namespace = "x", source = "live" }
		expect(argv("cordon", podOnNode)).toEqual({ "kubectl", "cordon", "w1" })
	end)

	it("refuses ops on kinds they do not apply to, and parameters of other ops", function()
		local origin: Link.Origin = {}
		local cases: { { any } } = {
			{
				"undo",
				{ kind = "ReplicaSet", group = "apps", name = "r", namespace = "a", source = "live" },
				"rollout undo",
			},
			{
				"pause",
				{ kind = "StatefulSet", group = "apps", name = "s", namespace = "a", source = "live" },
				"deployments only",
			},
			{ "cordon", { kind = "Pod", name = "p", namespace = "a", source = "live" }, "nodes only" },
			{
				"drain",
				{ kind = "Deployment", group = "apps", name = "d", namespace = "a", source = "live" },
				"nodes only",
			},
		}
		for _, c in cases do
			local url, e = Link.forRef(c[1], c[2], origin)
			expect(url).toBeNil()
			expect(e).toContain(c[3])
		end
		for _, url in
			{
				"tern-kube://mutate?op=delete&kind=pod&name=x&edits=a%3Db",
				"tern-kube://mutate?op=scale&kind=deploy&name=x&patch=%7B%7D",
				"tern-kube://mutate?op=label&kind=pod&name=x&drain=--force",
				"tern-kube://mutate?op=patch&kind=pod&name=x&overwrite=1",
				"tern-kube://mutate?op=patch&kind=pod&name=x&patchtype=yaml&patch=%7B%7D",
				"tern-kube://mutate?op=label&kind=pod&name=x&edits=bad%20key%3Dv",
				"tern-kube://mutate?op=drain&kind=node&name=n&drain=--force",
				"tern-kube://mutate?op=drain&kind=node&name=n&drain=--timeout%3D4m%0A--delete-local-data",
			}
		do
			local r, e = Link.decode(url)
			expect(r).toBeNil()
			expect(type(e)).toBe("string")
		end
	end)
end)

describe("mutate link input", function()
	local function req(op: Link.Op, kind: string, name: string, namespace: string?): Link.Request
		return Link.decode(Link.encode({
			op = op,
			kind = kind,
			name = name,
			namespace = namespace,
			recursive = false,
			overwrite = false,
		}) :: string) :: Link.Request
	end

	it("knows which ops ask for input before they can preview", function()
		for _, op in { "scale", "apply", "label", "annotate", "patch", "drain" } do
			expect(Link.takesInput(op :: Link.Op)).toBe(true)
		end
		for _, op in { "delete", "restart", "undo", "pause", "resume", "cordon", "uncordon" } do
			expect(Link.takesInput(op :: Link.Op)).toBe(false)
		end
		local label = req("label", "configmap", "cm", "a")
		expect(Link.needsInput(label)).toBe(true)
		expect(Link.argv(label, "kubectl")).toBeNil()
		local done = Link.withInput(label, "app=web") :: Link.Request
		expect(Link.needsInput(done)).toBe(false)
		expect(Link.needsInput(req("undo", "deployment.apps", "web", "a"))).toBe(false)
	end)

	it("reads the replica count for scale", function()
		local r = req("scale", "deployment.apps", "web", "a")
		local out = Link.withInput(r, " 3 ") :: Link.Request
		expect(Link.argv(out, "kubectl")).toEqual({
			"kubectl",
			"scale",
			"deployment.apps/web",
			"--replicas=3",
			"-n",
			"a",
		})
		expect(Link.inputText(out)).toBe("3")
		for _, bad in { "", "-1", "1.5", "three", "100001", "3 4" } do
			local none, e = Link.withInput(r, bad)
			expect(none).toBeNil()
			expect(e).toBe("Enter a whole number of replicas")
		end
	end)

	it("reads label edits and --overwrite into kubectl's positional form", function()
		local r = req("label", "configmap", "cm", "a")
		local p = Link.prompt(r)
		expect(p.text).toBe("Labels for configmap/cm: KEY=VALUE sets, KEY- removes; add --overwrite to change values")
		expect(p.prefill).toBe("")
		local out = Link.withInput(r, "app=web  tier- example.com/team=a_b.c --overwrite") :: Link.Request
		expect(Link.argv(out, "kubectl")).toEqual({
			"kubectl",
			"label",
			"configmap/cm",
			"app=web",
			"tier-",
			"example.com/team=a_b.c",
			"--overwrite",
			"-n",
			"a",
		})
		expect(Link.inputText(out)).toBe("app=web tier- example.com/team=a_b.c --overwrite")
		local again = Link.decode(Link.encode(out) :: string) :: Link.Request
		expect(again.edits).toEqual({ "app=web", "tier-", "example.com/team=a_b.c" })
		expect(again.overwrite).toBe(true)
	end)

	-- kubectl rejects these too, but only after a round trip; the prompt
	-- says why at once, and nothing but edits and --overwrite gets through.
	it("refuses keys, values and flags kubectl would reject or that change the command", function()
		local r = req("label", "configmap", "cm", "a")
		for _, bad in
			{
				"",
				"--overwrite",
				"app",
				"-l app=web",
				"--all app=x",
				"app=web app-",
				"app=has space",
				"Bad_/x=y",
				"a/b/c=d",
				string.rep("k", 64) .. "=v",
				"app=" .. string.rep("v", 64),
				"app=-x",
				"'unterminated=x",
			}
		do
			local out, e = Link.withInput(r, bad)
			expect(out).toBeNil()
			expect(type(e)).toBe("string")
		end
		expect((Link.withInput(r, ""))).toBeNil()
		local _, e = Link.withInput(r, "")
		expect(e).toBe("label needs at least one KEY=VALUE or KEY-")
	end)

	it("lets annotation values hold any printable text, quoted", function()
		local r = req("annotate", "deployment.apps", "web", "a")
		local out = Link.withInput(r, [[note="it's a \"test\"" owner='Ops Team' x=]]) :: Link.Request
		expect(out.edits).toEqual({ [[note=it's a "test"]], "owner=Ops Team", "x=" })
		local again = Link.withInput(r, Link.inputText(out)) :: Link.Request
		expect(again.edits).toEqual(out.edits)
		expect((Link.withInput(r, "a=" .. string.rep("x", 65537)))).toBeNil()
	end)

	it("reads a patch with an optional --type, defaulting to merge for custom resources", function()
		local deploy = req("patch", "deployment.apps", "web", "a")
		expect(Link.prompt(deploy).prefill).toBe("--type=strategic ")
		local cr = req("patch", "widgets.lens.example.com", "w", "a")
		expect(Link.prompt(cr).prefill).toBe("--type=merge ")
		local out = Link.withInput(deploy, '--type=merge {"spec":{"replicas":2}}') :: Link.Request
		expect(Link.argv(out, "kubectl")).toEqual({
			"kubectl",
			"patch",
			"deployment.apps/web",
			"--type=merge",
			"-p",
			'{"spec":{"replicas":2}}',
			"-n",
			"a",
		})
		expect(Link.inputText(out)).toBe('--type=merge {"spec":{"replicas":2}}')
		local plain = Link.withInput(cr, '{"spec":{"size":1}}') :: Link.Request
		expect(plain.patchType).toBe("merge")
		local json = Link.withInput(deploy, '--type=json [{"op":"remove","path":"/metadata/labels/a"}]') :: Link.Request
		expect(json.patchType).toBe("json")
		for _, bad in { "", "--type=merge", "--type=yaml {}", "--type=json {}", "-p {}", "spec: 1", "{\n}" } do
			expect((Link.withInput(deploy, bad))).toBeNil()
		end
	end)

	-- A drain without --timeout retries forever when a PodDisruptionBudget
	-- blocks it; the native block cannot stop a spawned process.
	it("reads drain options from an allow-list and requires a bounded --timeout", function()
		local r = req("drain", "node", "w1")
		local p = Link.prompt(r)
		expect(p.text).toBe("Drain node w1 with:")
		expect(p.prefill).toBe("--ignore-daemonsets --timeout=4m")
		local out = Link.withInput(
			r,
			"--timeout=90s --pod-selector='app in (a, b)' --ignore-daemonsets --grace-period=-1"
		) :: Link.Request
		expect(Link.argv(out, "kubectl")).toEqual({
			"kubectl",
			"drain",
			"w1",
			"--ignore-daemonsets",
			"--grace-period=-1",
			"--timeout=90s",
			"--pod-selector=app in (a, b)",
		})
		expect(Link.drainTimeoutMs(out)).toBe(90000)
		expect(Link.inputText(out)).toBe(
			"--ignore-daemonsets --grace-period=-1 --timeout=90s '--pod-selector=app in (a, b)'"
		)
		expect(Link.drainTimeoutMs(Link.withInput(r, "--timeout=1h") :: Link.Request)).toBe(3600000)
		expect(Link.drainTimeoutMs(Link.withInput(r, "--timeout=1m30s") :: Link.Request)).toBe(90000)
		for _, bad in
			{
				"",
				"--ignore-daemonsets",
				"--timeout=0s",
				"--timeout=0",
				"--timeout=2h",
				"--timeout=4x",
				"--timeout=4m --timeout=5m",
				"--timeout=4m --force=true",
				"--timeout=4m --grace-period=-2",
				"--timeout=4m --delete-local-data",
				"--timeout=4m --dry-run=server",
				"--timeout=4m -l app=x",
				"--timeout=4m other-node",
			}
		do
			local none, e = Link.withInput(r, bad)
			expect(none).toBeNil()
			expect(type(e)).toBe("string")
		end
	end)

	it("takes no input for ops without a prompt", function()
		local r = req("cordon", "node", "w1")
		local none, e = Link.withInput(r, "x")
		expect(none).toBeNil()
		expect(e).toBe("cordon takes no input")
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
