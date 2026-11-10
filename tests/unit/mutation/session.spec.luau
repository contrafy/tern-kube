--!strict
-- The approve block's core. Every case guards one way a mutation could run
-- against something other than what the user saw: before confirmation, after
-- a cancel, after the inputs or the target changed, or for a forged request.
local A = require("../../lib/approve")
local Fixtures = require("../../lib/fixtures")
local Link = require("../../../plugin/lib/mutation/link")
local Quick = require("../../../plugin/lib/actions/quick")
local Session = require("../../../plugin/lib/mutation/session")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Effect = Session.Effect

local function present(x: any)
	expect(x ~= nil).toBe(true)
end

local DELETE = "tern-kube://mutate?op=delete&kind=deployment&name=web&namespace=apps&context=kind-dev&source=chosen"
local SCALE =
	"tern-kube://mutate?op=scale&kind=deployment&name=web&namespace=apps&replicas=1&context=kind-dev&source=chosen"

local function ready(url: string, world: A.World?): (Session.State, A.Drive)
	local s, effects = A.init(url)
	local d = A.drive(s, effects, A.cluster(world))
	return s, d
end

local function argvOf(e: Effect?): { string }
	return if e then e.argv or {} else {}
end

describe("approve session: native preview", function()
	it("pins the link's context in every step and reaches the ready phase", function()
		local s, d = ready(SCALE)
		expect(s.phase).toBe("ready")
		expect(s.target and s.target.server).toBe(A.SERVER)
		for _, e in d.runs do
			local argv = argvOf(e)
			if argv[1] == "kubectl" and e.tag ~= "target" then
				expect(table.find(argv, "--context") ~= nil).toBe(true)
				expect(argv[table.find(argv, "--context") :: number + 1]).toBe("kind-dev")
			end
		end
		expect(A.find(d.runs, "run", "exec")).toBeNil()
	end)

	it("never runs the mutation itself during the preview, only reads and server dry runs", function()
		local _, d = ready(SCALE)
		for _, e in d.runs do
			local argv = argvOf(e)
			if argv[1] == "kubectl" then
				local joined = table.concat(argv, " ")
				local reads = string.find(joined, " get ") or string.find(joined, " config ")
				local dry = string.find(joined, "--dry-run=server", 1, true)
				expect((reads or dry) ~= nil).toBe(true)
			end
		end
	end)

	it("resolves the current-context when the link has none and marks it inferred", function()
		local s, d = ready("tern-kube://mutate?op=restart&kind=deployment&name=web&namespace=apps")
		present(A.find(d.runs, "run", "current"))
		expect((s.plan :: any).contextSource).toBe("inferred")
		expect((s.requirements :: any).targetConfirmation).toBe(true)
	end)

	it("refuses a context the kubeconfig does not have, before any preview", function()
		local s, d = ready(SCALE, { context = "other" })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("kind-dev")
		expect(A.find(d.runs, "run", "step:targets")).toBeNil()
	end)

	it("asks for a replica count when a scale link has none", function()
		local s, effects =
			A.init("tern-kube://mutate?op=scale&kind=deployment&name=web&namespace=apps&context=kind-dev")
		expect(s.phase).toBe("input")
		present(A.find(effects, "focus"))
		local respond = A.cluster()
		A.typeText(s, "2", respond)
		A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("ready")
		expect(s.argv).toEqual({ "kubectl", "scale", "deployment/web", "--replicas=2", "-n", "apps" })
	end)

	it("the replica prompt takes native edits and undo", function()
		local s = A.init("tern-kube://mutate?op=scale&kind=deployment&name=web&namespace=apps&context=kind-dev")
		local respond = A.cluster()
		A.typeText(s, "12", respond)
		A.send(
			s,
			{ t = "edit", id = Session.TYPED_INPUT, edit = { from = 0, to = 0, text = "", cursor = 0, len = 2 } },
			respond
		)
		A.typeText(s, "3", respond)
		expect(s.typed).toBe("312")
		A.send(s, { t = "undo", id = Session.TYPED_INPUT }, respond)
		expect(s.typed).toBe("12")
		A.send(s, A.key("enter"), respond)
		expect(s.argv).toEqual({ "kubectl", "scale", "deployment/web", "--replicas=12", "-n", "apps" })
	end)

	it("asks for a path when the palette opens an apply with only a cwd", function()
		local s, effects = A.init("tern-kube://mutate?op=apply&cwd=%2Fw%2Frepo&context=kind-dev")
		expect(s.phase).toBe("input")
		present(A.find(effects, "focus"))
		local respond = A.cluster({ files = { { path = "/w/repo/k8s", size = 10, sha256 = string.rep("a", 64) } } })
		A.typeText(s, "-", respond)
		A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("input")
		expect(type(s.confirmError)).toBe("string")
		A.send(s, A.key("backspace"), respond)
		A.typeText(s, "k8s -R", respond)
		A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("ready")
		expect(s.argv).toEqual({ "kubectl", "apply", "-f", "/w/repo/k8s", "-R" })
		expect((s.plan :: any).cwd).toBe("/w/repo")
	end)

	it("splits the diff into per-resource segments and counts them", function()
		local s = ready("tern-kube://mutate?op=apply&file=%2Fw%2Fapps.yaml&context=kind-dev", {
			diff = Fixtures.read("real/mutate-preview/diff_-f_preview+apps-mix.yaml.txt"),
			files = { { path = "/w/apps.yaml", size = 10, sha256 = string.rep("a", 64) } },
		})
		expect(s.phase).toBe("ready")
		expect(#(s.diff :: any).segments > 1).toBe(true)
		expect(s.manifests and #(s.manifests :: any)).toBe(1)
	end)

	-- kubectl diff masks Secret data but not the last-applied annotation,
	-- which embeds it: the block must never put those values on screen.
	local SECRET_DIFF = Fixtures.read("tests/shell/drift/cases/secret-last-applied.diff")
	local function secretPreview(config: Session.Config?): string
		local s, effects =
			A.init("tern-kube://mutate?op=apply&file=%2Fw%2Fsecret.yaml&context=kind-dev", { config = config })
		A.drive(
			s,
			effects,
			A.cluster({
				diff = SECRET_DIFF,
				files = { { path = "/w/secret.yaml", size = 10, sha256 = string.rep("a", 64) } },
			})
		)
		expect(s.phase).toBe("ready")
		local seg = (s.diff :: any).segments[1]
		expect(seg.added).toBe(1)
		expect(seg.removed).toBe(3)
		return table.concat(seg.lines, "\n")
	end

	it("redacts Secret last-applied lines in diffs unless secret values are shown", function()
		local text = secretPreview()
		expect((string.find(text, "tern-kube-test-not-a-secret", 1, true))).toBeNil()
		expect(text).toContain("      *** (last-applied-configuration redacted by tern-kube)")
		expect(secretPreview(A.config({ showSecretValues = true }))).toContain("tern-kube-test-not-a-secret")
	end)

	it("refuses every native link when mutations are disabled, without running anything", function()
		local s, effects = A.init(SCALE, { config = A.config({ enabled = false }) })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toBe(Session.DISABLED)
		expect(#effects).toBe(0)
		s, effects = A.init("tern-kube://act/cronjob-run?kind=CronJob&name=nightly&namespace=apps", {
			config = A.config({ enabled = false }),
		})
		expect(s.errors[1]).toBe(Session.DISABLED)
		expect(#effects).toBe(0)
	end)
end)

describe("approve session: native confirm and execute", function()
	it("does not run on enter for a typed-tier delete until the exact name is typed", function()
		local respond = A.cluster()
		local s = ready(DELETE)
		expect((s.requirements :: any).typed).toBe("web")
		local d = A.send(s, A.key("enter"), respond)
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		A.typeText(s, "we", respond)
		d = A.send(s, A.key("enter"), respond)
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		A.typeText(s, "b", respond)
		d = A.send(s, A.key("enter"), respond)
		local exec = A.find(d.runs, "run", "exec") :: Effect
		present(exec)
		expect(argvOf(exec)).toEqual({
			"kubectl",
			"--kubeconfig",
			"/k/config",
			"--context",
			"kind-dev",
			"delete",
			"deployment/web",
			"-n",
			"apps",
		})
		expect(s.phase).toBe("done")
		expect(A.count(d.effects, "audit")).toBe(2)
	end)

	it("edits the typed token at the caret and with native edits; only the exact token confirms", function()
		local respond = A.cluster()
		local s = ready(DELETE)
		A.typeText(s, "wb", respond)
		A.send(s, A.key("left"), respond)
		A.typeText(s, "e", respond)
		expect(s.typed).toBe("web")
		expect((s.input :: any).cursor).toBe(2)
		-- The user selected the whole token and pasted it with a trailing space.
		A.send(
			s,
			{ t = "edit", id = Session.TYPED_INPUT, edit = { from = 0, to = 3, text = "web ", cursor = 4, len = 3 } },
			respond
		)
		expect(s.typed).toBe("web ")
		local d = A.send(s, A.key("enter"), respond)
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		expect(type(s.confirmError)).toBe("string")
		-- An edit made against older text is dropped.
		local _, _, changed = Session.update(s, {
			t = "edit",
			id = Session.TYPED_INPUT,
			edit = { from = 0, to = 3, text = "", cursor = 0, len = 3 },
		})
		expect(changed).toBe(false)
		expect(s.typed).toBe("web ")
		A.send(s, { t = "undo", id = Session.TYPED_INPUT }, respond)
		expect(s.typed).toBe("web")
		expect(s.confirmError).toBeNil()
		d = A.send(s, A.key("enter"), respond)
		present(A.find(d.runs, "run", "exec"))
	end)

	-- Explore refreshes its route only after its own mutation really ran
	-- (MUT-F9): one `applied` effect after a successful execute, none after
	-- a failed one, carrying the link's origin tag back.
	it("emits one applied effect with the origin after a successful execute, none after a failure", function()
		local tagged = SCALE .. "&origin=explore%3A7"
		local s = ready(tagged)
		local d = A.send(s, A.key("enter"), A.cluster())
		expect(s.phase).toBe("done")
		expect(A.count(d.effects, "applied")).toBe(1)
		local applied = (A.find(d.effects, "applied") :: Effect).applied :: Session.Applied
		expect(applied).toEqual({
			origin = "explore:7",
			op = "scale",
			context = "kind-dev",
			namespace = "apps",
			kind = "deployment",
			name = "web",
		})
		local failing = A.cluster({ exec = A.failed(1, "error: forbidden") })
		local s2 = ready(tagged)
		local d2 = A.send(s2, A.key("enter"), failing)
		expect(s2.phase).toBe("done")
		expect(A.count(d2.effects, "applied")).toBe(0)
	end)

	-- One click undoes the obvious next step: Resume after a pause (and
	-- Uncordon after a cordon or drain, see link.spec), same target pins.
	it("offers Resume after a successful pause, opening a pinned resume link; none after a failure", function()
		local pause = Link.encode({
			op = "pause",
			kind = "deployment",
			name = "web",
			namespace = "apps",
			recursive = false,
			overwrite = false,
			context = "kind-dev",
			source = "chosen",
			origin = "explore:7",
		}) :: string
		local s = ready(pause)
		A.send(s, A.key("enter"), A.cluster())
		expect(s.phase).toBe("done")
		local follow = Session.followUps(s)
		expect(#follow).toBe(1)
		expect(follow[1].label).toBe("Resume")
		local r = Link.decode(follow[1].url) :: Link.Request
		expect(r.op).toBe("resume")
		expect(r.context).toBe("kind-dev")
		expect(r.origin).toBe("explore:7")
		local d = A.send(s, { t = "action", act = follow[1].act }, A.cluster())
		expect((A.find(d.effects, "open") :: Effect).url).toBe(follow[1].url)
		local failed = ready(pause)
		A.send(failed, A.key("enter"), A.cluster({ exec = A.failed(1, "error: forbidden") }))
		expect(#Session.followUps(failed)).toBe(0)
	end)

	it("ignores edits to the typed field while it does not take the keyboard", function()
		local s = ready(SCALE)
		local _, _, changed = Session.update(s, {
			t = "edit",
			id = Session.TYPED_INPUT,
			edit = { from = 0, to = 0, text = "x", cursor = 1, len = 0 },
		})
		expect(changed).toBe(false)
		expect(s.typed).toBe("")
	end)

	it("re-reads digests, fingerprint and the target before executing", function()
		local s = ready(SCALE)
		local d = A.send(s, A.key("enter"), A.cluster())
		local order: { string } = {}
		for _, e in d.runs do
			table.insert(order, e.tag :: string)
		end
		expect(order).toEqual({ "v-fp", "v-target", "exec" })
	end)

	it("never executes after a cancel", function()
		local s = ready(SCALE)
		local d = A.send(s, A.key("escape"), A.cluster())
		present(A.find(d.effects, "exit"))
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		expect(s.phase).toBe("closed")
		local audit = A.find(d.effects, "audit") :: Effect
		expect(audit.line).toContain('"decision":"cancelled"')
	end)

	it("refuses when an input file changed after the preview, until previewed again", function()
		local files = { { path = "/w/a.yaml", size = 10, sha256 = string.rep("a", 64) } }
		local world: A.World = { files = files }
		local s = ready("tern-kube://mutate?op=apply&file=%2Fw%2Fa.yaml&context=kind-dev", world)
		files[1] = { path = "/w/a.yaml", size = 11, sha256 = string.rep("b", 64) }
		local d = A.send(s, A.key("enter"), A.cluster(world))
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		expect(s.confirmError).toContain("fingerprint")
		expect(s.stale).toBe(true)
		d = A.send(s, A.key("enter"), A.cluster(world))
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		A.send(s, A.key("r", "r"), A.cluster(world))
		d = A.send(s, A.key("enter"), A.cluster(world))
		present(A.find(d.runs, "run", "exec"))
	end)

	it("refuses when the context now points at another server", function()
		local s = ready(SCALE)
		local d = A.send(s, A.key("enter"), A.cluster({ server = "https://10.0.0.9:6443" }))
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		expect(s.confirmError).toContain("10.0.0.9")
	end)

	it("refuses an inferred target when the current-context moved", function()
		local s = ready("tern-kube://mutate?op=restart&kind=deployment&name=web&namespace=apps")
		A.send(s, A.key("t", "t"), A.cluster())
		local d = A.send(s, A.key("enter"), A.cluster({ current = "prod" }))
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		expect(s.confirmError).toContain("prod")
	end)

	it("requires confirming an inferred target before anything runs", function()
		local s = ready("tern-kube://mutate?op=restart&kind=deployment&name=web&namespace=apps")
		local d = A.send(s, A.key("enter"), A.cluster())
		expect(#d.runs).toBe(0)
		expect(s.confirmError).toContain("Confirm the target")
	end)

	it("blocks when a preview step fails (RBAC) and offers no override by default", function()
		local s = ready(SCALE, { ["step:dry-run"] = A.failed(1, "Error from server (Forbidden): nope") })
		expect((s.assessment :: any).tier).toBe("blocked")
		local d = A.send(s, A.key("enter"), A.cluster())
		expect(#d.runs).toBe(0)
		expect(s.confirmError).toContain("Forbidden")
	end)

	it("blocks a preview that timed out", function()
		local s = ready(SCALE, { ["step:targets"] = A.timeout() })
		expect((s.assessment :: any).tier).toBe("blocked")
		expect((s.assessment :: any).reasons[1].text).toContain("timed out")
	end)

	it("ignores results of a superseded preview", function()
		local s, effects = A.init(SCALE)
		local d = A.drive(s, effects, function(e: Effect): Session.ProcessResult?
			if e.tag == "step:dry-run" then
				return nil
			end
			return A.cluster()(e)
		end)
		local stale = A.find(d.runs, "run", "step:dry-run") :: Effect
		expect(s.phase).toBe("previewing")
		s.phase = "ready"
		A.send(s, A.key("r", "r"), A.cluster())
		local before = s.gen
		local _, more, changed =
			Session.update(s, { t = "result", tag = "step:dry-run", gen = stale.gen, result = A.failed(1, "late") })
		expect(changed).toBe(false)
		expect(#more).toBe(0)
		expect(s.gen).toBe(before)
		expect((s.assessment :: any).tier).toBe("simple")
	end)

	it("shows the result and requeries only read steps", function()
		local s = ready(SCALE)
		A.send(s, A.key("enter"), A.cluster())
		local d = A.send(s, A.key("r", "r"), A.cluster())
		for _, e in d.runs do
			expect(string.sub(e.tag :: string, 1, 3)).toBe("rq:")
			expect(table.find(argvOf(e), "scale")).toBeNil()
		end
		expect(s.requery and s.requery.at).toBe(1000)
	end)

	it("says a running command cannot be cancelled", function()
		local s, effects = A.init(SCALE)
		A.drive(s, effects, A.cluster())
		A.send(s, A.key("enter"), function(e: Effect): Session.ProcessResult?
			return if e.tag == "exec" then nil else A.cluster()(e)
		end)
		expect(s.phase).toBe("executing")
		local d = A.send(s, A.key("escape"), A.cluster())
		expect(A.find(d.effects, "exit")).toBeNil()
		expect(s.notice).toContain("cannot be cancelled")
	end)
end)

describe("approve session: guard requests", function()
	local function guard(req: A.Req?, opts: A.Opts?, world: A.World?): (Session.State, A.Drive)
		local o: A.Opts = opts or {}
		o.request = o.request or A.request(req or {})
		local s, effects = A.init(A.requestPath(), o)
		return s, A.drive(s, effects, A.cluster(world))
	end

	it("previews with the request's program, cwd and kubeconfig and never executes", function()
		local s, d = guard({ kubeconfig = "/u/kc" })
		expect(s.phase).toBe("ready")
		local step = A.find(d.runs, "run", "step:targets") :: Effect
		expect(argvOf(step)[1]).toBe("/usr/local/bin/kubectl")
		expect(argvOf(step)[3]).toBe("/u/kc")
		expect(step.cwd).toBe("/work")
		d = A.send(s, A.key("enter"), A.cluster())
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		local w = A.find(d.effects, "write") :: Effect
		expect(w.path).toBe(A.SPOOL .. "/resp-" .. A.NONCE .. ".env.tmp")
		local head = "nonce="
			.. A.NONCE
			.. "\ndecision=approve\nfingerprint="
			.. (s.fingerprint :: string)
			.. "\ncontext=kind-dev\ncontext_namespace=\ncontext_user=u\napproved_at=1000\naudit="
		expect(string.sub(w.text :: string, 1, #head)).toBe(head)
		-- MUT-F5: the record the guard completes after kubectl exits.
		local tpl = string.match(w.text :: string, "\naudit=([^\n]*)\n$") :: string
		expect(tpl).toContain('{"v":1,"decided_at":@,"decision":"@","mode":"guard","op":"scale"')
		expect(tpl).toContain('"exit_code":@,"previewed_at":')
		expect(tpl).toContain('"started_at":@,"finished_at":@,"objects":["Deployment apps/web"]')
		expect(argvOf(w)[#argvOf(w)]).toBe(A.SPOOL .. "/resp-" .. A.NONCE .. ".env")
		present(A.find(d.effects, "exit"))
	end)

	it("pins kubectl's default kubeconfig when the shell had no KUBECONFIG", function()
		local _, d = guard({})
		local step = A.find(d.runs, "run", "step:targets") :: Effect
		expect(argvOf(step)[3]).toBe(A.HOME .. "/.kube/config")
	end)

	it("accepts a request decoded into locked tables, as tern.json.decode returns them", function()
		local function lock(v: any): any
			if type(v) == "table" then
				for k, x in v do
					v[k] = lock(x)
				end
				setmetatable(v, { __metatable = "locked" })
			end
			return v
		end
		local s, effects = A.init(A.requestPath(), {
			request = A.request({}),
			decode = function(text: string): any
				return lock(json.decode(text))
			end,
		})
		A.drive(s, effects, A.cluster())
		expect(s.errors[1]).toBeNil()
		expect(s.phase).toBe("ready")
	end)

	it("writes a deny on cancel so the shell reports a denial", function()
		local s = guard({})
		local d = A.send(s, A.key("escape"), A.cluster())
		expect((A.find(d.effects, "write") :: Effect).text).toContain("decision=deny")
	end)

	it("denies with the reason when mutations are disabled, without previewing", function()
		local s, d = guard({}, { config = A.config({ enabled = false }) })
		local w = A.find(d.effects, "write") :: Effect
		expect(w.text).toContain("decision=deny\n")
		expect(w.text).toContain("\nreason=" .. Session.DISABLED .. "\n")
		for _, e in d.runs do
			expect(string.sub(e.tag or "", 1, 5) ~= "step:").toBe(true)
		end
		expect(s.plan).toBeNil()
		present(A.find(d.effects, "exit"))
	end)

	it("refuses a request outside the plugin spool", function()
		local s, effects = A.init("/tmp/evil/req-" .. A.NONCE .. ".json", { request = A.request({}) })
		A.drive(s, effects, A.cluster())
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("outside the tern-kube spool")
		local d = A.send(s, A.key("escape"), A.cluster())
		expect(A.find(d.effects, "write")).toBeNil()
	end)

	it("refuses malformed nonces, mismatched nonces and expired or orphaned requests", function()
		local s = A.init(A.SPOOL .. "/req-abc.json", { request = A.request({}) })
		expect(s.errors[1]).toContain("request path")
		s = A.init(A.requestPath(), { request = A.request({ nonce = string.rep("1", 32) }) })
		expect(s.errors[1]).toContain("nonce")
		s = A.init(A.requestPath(), { request = A.request({ created = 100, timeout = 60 }) })
		expect(s.errors[1]).toContain("expired")
		s = A.init(A.requestPath(), { request = A.request({ pane = "99" }) })
		expect(s.errors[1]).toContain("gone")
		s = A.init(A.requestPath(), { request = A.request({ created = 5000 }) })
		expect(s.errors[1]).toContain("future")
	end)

	it("refuses a request whose fingerprint does not match its inputs", function()
		local s = guard({ fingerprint = string.rep("c", 64) })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("fingerprint mismatch")
		expect(#s.steps).toBe(0)
	end)

	it("closes without a response when the shell cancels or its pane dies", function()
		local s = guard({})
		local _, effects = Session.update(s, { t = "tick", now = 1001, cancelled = true, paneAlive = true })
		expect(A.find(effects, "write")).toBeNil()
		expect((A.find(effects, "remove") :: Effect).path).toBe(A.SPOOL .. "/cancel-" .. A.NONCE)
		present(A.find(effects, "exit"))
		s = guard({})
		_, effects = Session.update(s, { t = "tick", now = 1001, cancelled = false, paneAlive = false })
		expect(A.find(effects, "write")).toBeNil()
		present(A.find(effects, "exit"))
	end)

	it("expires while open and then refuses to approve", function()
		local s = guard({ created = 990, timeout = 60 })
		Session.update(s, { t = "tick", now = 1100, paneAlive = true, cancelled = false })
		expect(s.phase).toBe("expired")
		local d = A.send(s, A.key("enter"), A.cluster())
		expect(A.find(d.effects, "write")).toBeNil()
		d = A.send(s, A.key("escape"), A.cluster())
		expect(A.find(d.effects, "write")).toBeNil()
		present(A.find(d.effects, "exit"))
	end)

	it("rejects `-f -` from the request with an actionable message", function()
		local s = guard({ argv = { "kubectl", "apply", "-f", "-" } })
		expect(s.errors[1]).toContain("save it to a file")
	end)

	-- MUT-F1: kubens rewrites the context's namespace in place; the request,
	-- its fingerprint and the context name stay equal, so the namespace and
	-- user the preview resolved are re-read at approval and sent to the
	-- guard, which re-checks them right before kubectl runs.
	it("refuses at approval when the context's default namespace changed since the preview", function()
		local s = guard({}, nil, { namespace = "apps" })
		expect((s.plan :: any).targetNamespace).toBe("apps")
		local d = A.send(s, A.key("enter"), A.cluster({ namespace = "default" }))
		expect(A.find(d.effects, "write")).toBeNil()
		expect(s.confirmError).toContain("namespace default")
		expect(s.confirmError).toContain("previewed: apps")
		local audit = A.find(d.effects, "audit") :: Effect
		expect(audit.line).toContain('"decision":"blocked"')
		-- A fresh preview shows the new namespace; approving it binds that one.
		A.send(s, A.key("r", "r"), A.cluster({ namespace = "default" }))
		expect((s.plan :: any).targetNamespace).toBe("default")
		d = A.send(s, A.key("enter"), A.cluster({ namespace = "default" }))
		local w = A.find(d.effects, "write") :: Effect
		expect(w.text).toContain("decision=approve\n")
		expect(w.text).toContain("\ncontext_namespace=default\n")
	end)

	it("refuses at approval when the context's user changed since the preview", function()
		local s = guard({}, nil, { user = "alice" })
		local d = A.send(s, A.key("enter"), A.cluster({ user = "bob" }))
		expect(A.find(d.effects, "write")).toBeNil()
		expect(s.confirmError).toContain("user bob")
		expect(s.confirmError).toContain("previewed: alice")
	end)

	it("ignores the context's namespace when the command names its own", function()
		local argv = { "kubectl", "scale", "deploy/web", "--replicas=2", "-n", "apps" }
		local s = guard({ argv = argv, namespace = "apps" }, nil, { namespace = "team-a" })
		local d = A.send(s, A.key("enter"), A.cluster({ namespace = "team-b" }))
		local w = A.find(d.effects, "write") :: Effect
		expect(w.text).toContain("decision=approve\n")
	end)

	-- MUT-F2: the request pins its context, argv and files; previewing again
	-- cannot make it match, so the block says what helps and offers no `r`.
	it("tells the shell user to run the command again when the request no longer matches", function()
		local s = guard({ source = "current-context" })
		A.send(s, A.key("t", "t"), A.cluster())
		expect(s.targetConfirmed).toBe(true)
		local d = A.send(s, A.key("enter"), A.cluster({ current = "prod" }))
		expect(A.find(d.effects, "write")).toBeNil()
		expect(s.phase).toBe("error")
		expect(s.errors[#s.errors]).toContain("Run the command again")
		expect((string.find(s.errors[#s.errors], "press r", 1, true))).toBeNil()
		expect(s.targetConfirmed).toBe(false)
		expect(Session.canRerun(s)).toBe(false)
		d = A.send(s, A.key("r", "r"), A.cluster())
		expect(#d.runs).toBe(0)
		d = A.send(s, A.key("escape"), A.cluster())
		expect((A.find(d.effects, "write") :: Effect).text).toContain("decision=deny")
	end)

	it("treats input files changed after the preview of a guard request as final", function()
		local files = { { path = "/work/a.yaml", size = 10, sha256 = string.rep("a", 64) } }
		local world: A.World = { files = files }
		local s = guard({ argv = { "kubectl", "apply", "-f", "a.yaml" }, files = files }, nil, world)
		expect(s.phase).toBe("ready")
		files[1] = { path = "/work/a.yaml", size = 11, sha256 = string.rep("b", 64) }
		A.send(s, A.key("enter"), A.cluster(world))
		expect(s.phase).toBe("error")
		expect(s.errors[#s.errors]).toContain("Run the command again")
		expect(Session.canRerun(s)).toBe(false)
	end)

	it("clears the target confirmation on a refusal that previewing again can fix", function()
		local s = guard({ source = "current-context" }, nil, { namespace = "apps" })
		A.send(s, A.key("t", "t"), A.cluster({ namespace = "apps" }))
		A.send(s, A.key("enter"), A.cluster({ namespace = "default" }))
		expect(s.targetConfirmed).toBe(false)
		expect(s.confirmError).toContain("press r")
		expect(Session.canRerun(s)).toBe(true)
	end)
end)

describe("approve session: quick-action mutations", function()
	local NODE = "tern-kube://act/debug-node?kind=Node&name=worker-1&context=kind-dev"

	it("previews the node and requires typing its name (privileged pod)", function()
		local s = ready(NODE)
		expect(s.phase).toBe("ready")
		expect((s.requirements :: any).typed).toBe("worker-1")
	end)

	-- The window minted the token (args[2]) in its own kv: the block may run
	-- on another host, so it only hands the token back in the pinned link.
	it("opens the pinned link once with the window's token, without storing a grant", function()
		local s, first = ready(NODE)
		A.typeText(s, "worker-1", A.cluster())
		local d = A.send(s, A.key("enter"), A.cluster())
		local opens = 0
		for _, e in d.effects do
			if e.t == "open" then
				opens += 1
			end
		end
		expect(opens).toBe(1)
		local open = A.find(d.effects, "open") :: Effect
		expect(open.url).toContain("confirm=" .. A.TOKEN)
		local req = Quick.decode(open.url :: string) :: Quick.Request
		expect(req.target.context).toBe("kind-dev")
		expect(req.target.kubeconfig).toBe("/k/config")
		expect(req.opts.image).toBe(Quick.DEFAULT_IMAGE)
		local grants = Link.mintGrant(nil, A.TOKEN, NODE, 1000) :: Link.Grants
		expect((Link.consumeGrant(grants, A.TOKEN, req, 1010))).toBe(true)
		expect(A.find(d.effects, "grant")).toBeNil()
		expect(A.find(first.runs, "run", "nonce")).toBeNil()
		expect(A.find(d.runs, "run", "nonce")).toBeNil()
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		present(A.find(d.effects, "audit"))
		present(A.find(d.effects, "exit"))
	end)

	it("fails closed without a well-formed token from the window (version skew)", function()
		local cases: { string | boolean } = { false, "short", string.upper(A.TOKEN) }
		for _, token in cases do
			local s, effects = A.init(NODE, { token = token })
			expect(s.phase).toBe("error")
			expect(s.errors[1]).toContain("without a confirmation token")
			expect(s.errors[1]).toContain("same version")
			expect(#effects).toBe(0)
		end
	end)

	it("refuses links that already carry a token or do not mutate", function()
		local s = A.init(NODE .. "&confirm=" .. A.TOKEN)
		expect(s.errors[1]).toContain("token")
		s = A.init("tern-kube://act/shell?kind=Pod&name=web&namespace=apps")
		expect(s.errors[1]).toContain("does not need approval")
	end)

	it("dry-runs a cronjob run on the server", function()
		local s, d = ready("tern-kube://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&suffix=abc12")
		expect(s.phase).toBe("ready")
		local dry = A.find(d.runs, "run", "step:dry-run") :: Effect
		expect(table.find(argvOf(dry), "--dry-run=server") ~= nil).toBe(true)
	end)

	-- Chips carry no suffix: the block picks the job name once, previews
	-- exactly that name, and the confirmed link makes the split create it.
	it("names the job for a chip without a suffix and carries the name to the split", function()
		local s, d = ready("tern-kube://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&context=kind-dev")
		expect(s.phase).toBe("ready")
		local dry = A.find(d.runs, "run", "step:dry-run") :: Effect
		expect(table.find(argvOf(dry), "nightly-manual-3e8") ~= nil).toBe(true)
		d = A.send(s, A.key("enter"), A.cluster())
		local open = A.find(d.effects, "open") :: Effect
		local req = Quick.decode(open.url :: string) :: Quick.Request
		expect(req.opts.suffix).toBe("3e8")
		expect(A.find(d.runs, "run", "exec")).toBeNil()
	end)

	-- The approve block stays with the result so the user can follow the
	-- Job it created (MUT-F9 follow-ups) instead of hunting for its name.
	it("stays open after a confirmed run-now and offers Follow logs of the created Job", function()
		local s = ready("tern-kube://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&context=kind-dev")
		local d = A.send(s, A.key("enter"), A.cluster())
		present(A.find(d.effects, "open"))
		expect(A.find(d.effects, "exit")).toBeNil()
		expect(s.phase).toBe("done")
		local follow = Session.followUps(s)
		expect(#follow).toBe(1)
		expect(follow[1].label).toBe("Follow logs")
		local req = Quick.decode(follow[1].url) :: Quick.Request
		expect(req.action).toBe("logs-follow")
		expect((req.ref :: any).kind).toBe("Job")
		expect((req.ref :: any).name).toBe("nightly-manual-3e8")
		expect(req.target.context).toBe("kind-dev")
		d = A.send(s, { t = "action", act = follow[1].act }, A.cluster())
		expect((A.find(d.effects, "open") :: Effect).url).toBe(follow[1].url)
		d = A.send(s, A.key("escape"), A.cluster())
		present(A.find(d.effects, "exit"))
	end)

	-- MUT-F15: a lens in a pane with its own KUBECONFIG names a context the
	-- approve block's kubeconfig lacks; the error says why and how to fix it.
	it("names the kubeconfig it used and the fixes when the context is missing there", function()
		local s = ready(
			"tern-kube://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&context=xm-other",
			{ context = "kind-dev" }
		)
		expect(s.phase).toBe("error")
		local e = s.errors[1]
		expect(e).toContain("xm-other")
		expect(e).toContain("/k/config")
		expect(e).toContain("--kubeconfig")
		expect(e).toContain("shell snippet")
		local pinned = ready(
			"tern-kube://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&context=xm-other&kubeconfig=%2Fk%2Fpane",
			{ context = "kind-dev" }
		)
		expect((string.find(pinned.errors[1], "shell snippet", 1, true))).toBeNil()
	end)
end)

local function linkFor(fields: { [string]: any }): string
	local r: any = { recursive = false, overwrite = false, context = "kind-dev", source = "chosen" }
	for k, v in fields do
		r[k] = v
	end
	return (Link.encode(r)) :: string
end

describe("approve session: two-stage previews (rollout undo)", function()
	local LIVE = Fixtures.read("kubectl/track1/get-deploy-web-json.txt")
	local HISTORY = Fixtures.read("kubectl/track1/rollout-history-deploy.txt")
	local REV1 = Fixtures.read("kubectl/track1/rollout-history-deploy-rev1-json.txt")
	local KEY = "apps.v1.Deployment.tern-test-t1.web"
	local UNDO = linkFor({ op = "undo", kind = "deployment", name = "web", namespace = "tern-test-t1" })
	local function world(extra: { [string]: any }?): A.World
		local w: A.World = {
			["step:targets"] = A.ok(LIVE),
			["step:history"] = A.ok(HISTORY),
			["step:dry-run"] = A.ok("deployment.apps/web rolled back (server dry run)\n"),
			["step:revision:" .. KEY] = A.ok(REV1),
			["v-history"] = A.ok(HISTORY),
		}
		local fields: { [string]: any } = extra or {}
		for k, v in fields do
			w[k] = v
		end
		return w
	end

	it("reads the target revision only after the history named it, then diffs the template", function()
		local s, d = ready(UNDO, world())
		expect(s.phase).toBe("ready")
		local rev = A.find(d.runs, "run", "step:revision:" .. KEY) :: Effect
		expect(table.find(argvOf(rev), "--revision=1") ~= nil).toBe(true)
		expect(s.undo).toEqual({ { key = KEY, name = "web", from = 2, to = 1 } })
		local diff = s.diff :: any
		expect(diff.modify).toBe(1)
		expect(table.concat(diff.segments[1].lines, "\n")).toContain("pause:3.9")
		expect((s.assessment :: any).tier).toBe("typed")
		expect((s.requirements :: any).typed).toBe("web")
	end)

	it("fails the preview when the history has no revision to roll back to", function()
		local s = ready(
			UNDO,
			world({ ["step:history"] = A.ok("deployment.apps/web\nREVISION  CHANGE-CAUSE\n1         <none>\n") })
		)
		expect(s.phase).toBe("ready")
		expect((s.assessment :: any).tier).toBe("blocked")
		expect((s.assessment :: any).reasons[1].text).toContain("no previous revision")
	end)

	it("refuses at confirm when a rollout happened since the preview", function()
		local moved = HISTORY .. "3         <none>\n"
		local s = ready(UNDO, world({ ["v-history"] = A.ok(moved) }))
		local respond = A.cluster(world({ ["v-history"] = A.ok(moved) }))
		A.typeText(s, "web", respond)
		local d = A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("ready")
		expect(s.stale).toBe(true)
		expect(s.confirmError).toContain("A rollout happened since the preview")
		expect(A.find(d.runs, "run", "exec")).toBeNil()
	end)

	it("runs the undo when the history did not move", function()
		local s = ready(UNDO, world())
		local respond = A.cluster(world())
		A.typeText(s, "web", respond)
		local d = A.send(s, A.key("enter"), respond)
		present(A.find(d.runs, "run", "v-history"))
		local exec = A.find(d.runs, "run", "exec") :: Effect
		expect(table.concat(argvOf(exec), " ")).toContain("rollout undo deployment/web")
	end)
end)

-- GIT-F3: Explore's apply bundles may hold Secret values; the block that was
-- given one deletes it when it closes, and only a bundle in the plugin tmp dir.
describe("approve session: apply bundles", function()
	local function applyLink(path: string): string
		return "tern-kube://mutate?op=apply&file="
			.. string.gsub(path, "/", "%%2F")
			.. "&context=kind-dev&source=chosen"
	end
	local BUNDLE = A.TMP .. "/apply-1762790000-1a2b3c4d5e6f.yaml"

	local function removed(effects: { Effect }): { string }
		local out: { string } = {}
		for _, e in effects do
			if e.t == "remove" then
				table.insert(out, e.path :: string)
			end
		end
		return out
	end

	it("deletes the bundle when the block is cancelled", function()
		local s = ready(applyLink(BUNDLE))
		expect(s.phase).toBe("ready")
		local d = A.send(s, A.key("escape"), A.cluster())
		expect(removed(d.effects)).toEqual({ BUNDLE })
		expect(Session.bundlePath(s)).toBe(BUNDLE)
	end)

	it("keeps it for requery after the run and deletes it when the result closes", function()
		local s = ready(applyLink(BUNDLE))
		local d = A.send(s, A.key("enter"), A.cluster())
		present(A.find(d.runs, "run", "exec"))
		expect(#removed(d.effects)).toBe(0)
		d = A.send(s, A.key("escape"), A.cluster())
		expect(removed(d.effects)).toEqual({ BUNDLE })
	end)

	it("never deletes a file the user named or another plugin tmp file", function()
		for _, path in
			{ "/w/apps.yaml", A.TMP .. "/diff-1-x.yaml", A.TMP .. "/sub/apply-1-x.yaml", "/data/tmpx/apply-1-x.yaml" }
		do
			local s = ready(applyLink(path))
			local d = A.send(s, A.key("escape"), A.cluster())
			expect(#removed(d.effects)).toBe(0)
			expect(Session.bundlePath(s)).toBeNil()
		end
	end)
end)

describe("approve session: object diffs and input ops", function()
	local CM = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"cm","namespace":"apps"%s}}'
	local LABEL = linkFor({ op = "label", kind = "configmap", name = "cm", namespace = "apps", edits = { "a=b" } })
	local function world(): A.World
		return {
			["step:targets"] = A.ok(string.format(CM, "")),
			["step:after"] = A.ok(string.format(CM, ',"labels":{"a":"b"}')),
		}
	end

	it("diffs the live object against the server dry run of the label", function()
		local s, d = ready(LABEL, world())
		expect(s.phase).toBe("ready")
		local after = A.find(d.runs, "run", "step:after") :: Effect
		expect(table.concat(argvOf(after), " ")).toContain("label configmap/cm a=b")
		expect(table.find(argvOf(after), "--dry-run=server") ~= nil).toBe(true)
		local seg = (s.diff :: any).segments[1]
		expect(seg.action).toBe("modify")
		expect(table.concat(seg.lines, "\n")).toContain("+    a: b")
		expect((s.assessment :: any).tier).toBe("simple")
	end)

	it("i returns to the prompt with the last input, and the edited input previews again", function()
		local s = ready(LABEL, world())
		local respond = A.cluster(world())
		local d = A.send(s, A.key("i", "i"), respond)
		expect(s.phase).toBe("input")
		expect(s.typed).toBe("a=b")
		present(A.find(d.effects, "focus"))
		A.typeText(s, " c=d", respond)
		A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("ready")
		expect(s.argv).toEqual({ "kubectl", "label", "configmap/cm", "a=b", "c=d", "-n", "apps" })
	end)

	it("i does nothing for ops without input", function()
		local s = ready(linkFor({ op = "restart", kind = "deployment", name = "web", namespace = "apps" }))
		expect((s.assessment :: any).tier).toBe("simple")
		local _, _, changed = Session.update(s, A.key("i", "i"))
		expect(changed).toBe(false)
		expect(s.phase).toBe("ready")
	end)

	it("starts a label link without edits at the prompt", function()
		local s, effects = A.init(linkFor({ op = "label", kind = "configmap", name = "cm", namespace = "apps" }))
		expect(s.phase).toBe("input")
		expect(s.typed).toBe("")
		present(A.find(effects, "focus"))
	end)

	it("refuses a native drain whose timeout could outlive the execute timeout", function()
		local s, d = ready(linkFor({
			op = "drain",
			kind = "node",
			name = "n1",
			drainFlags = { "--ignore-daemonsets", "--timeout=10m" },
		}))
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("below mutations.execute_timeout_ms (300 s)")
		expect(A.find(d.runs, "run", "step:targets")).toBeNil()
	end)
end)

describe("approve session: edit approvals", function()
	local FILE = "/tmp/kubectl-edit-1.yaml"
	local ORIGINAL = "/tmp/tkube-edit.abc/original.yaml"
	local FILES = {
		{ path = FILE, size = 10, sha256 = string.rep("a", 64) },
		{ path = ORIGINAL, size = 10, sha256 = string.rep("b", 64) },
	}
	local function editRequest(edit: { file: string, original: string }?, files: any?): string
		return A.request({
			argv = { "kubectl", "edit", "widget/w1" },
			files = files or FILES,
			edit = edit or { file = FILE, original = ORIGINAL },
		})
	end

	it("refuses an edit request whose files are not both fingerprinted", function()
		local s = A.init(A.requestPath(), { request = editRequest(nil, { FILES[1] }) })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("both be listed in files")
	end)

	it("refuses relative edit paths", function()
		local s = A.init(A.requestPath(), {
			request = editRequest({ file = "kubectl-edit-1.yaml", original = ORIGINAL }),
		})
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("two absolute paths")
	end)

	it("previews the edit as server dry runs of its merge patch and approves without executing", function()
		local live = Fixtures.read("kubectl/track1/get-widget-json.txt")
		local after = string.gsub(live, '"size": 3', '"size": 4')
		local w: A.World = {
			files = FILES,
			["step:convert-original"] = A.ok(Fixtures.read("kubectl/track1/convert-original.txt")),
			["step:convert-edited"] = A.ok(Fixtures.read("kubectl/track1/convert-edited.txt")),
			["step:targets"] = A.ok(live),
			["step:after:lens.example.com.v1alpha1.Widget.tern-test-t1.w1"] = A.ok(after),
		}
		local s, effects = A.init(A.requestPath(), { request = editRequest() })
		local d = A.drive(s, effects, A.cluster(w))
		expect(s.phase).toBe("ready")
		present(A.find(d.runs, "run", "step:after:lens.example.com.v1alpha1.Widget.tern-test-t1.w1"))
		expect((s.diff :: any).modify).toBe(1)
		expect((s.editFacts :: any).changed).toBe(1)
		d = A.send(s, A.key("enter"), A.cluster(w))
		local write = A.find(d.runs, "write", "respond") :: Effect
		expect(write.text).toContain("decision=approve")
		expect(A.find(d.runs, "run", "exec")).toBeNil()
	end)

	it("lets a server-rejected edit be approved: kubectl reopens the editor with the error", function()
		local w: A.World = {
			files = FILES,
			["step:convert-original"] = A.ok(Fixtures.read("kubectl/track1/convert-original.txt")),
			["step:convert-edited"] = A.failed(1, "error: error parsing edited.yaml: yaml: line 3\n"),
			["step:targets"] = A.ok(Fixtures.read("kubectl/track1/get-widget-json.txt")),
		}
		local s, effects = A.init(A.requestPath(), { request = editRequest() })
		A.drive(s, effects, A.cluster(w))
		expect(s.phase).toBe("ready")
		local a = s.assessment :: any
		expect(a.tier).toBe("simple")
		expect(a.reasons[1].id).toBe("edit-rejected")
	end)
end)

return nil
