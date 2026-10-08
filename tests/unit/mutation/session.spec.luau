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

local DELETE = "kube-lens://mutate?op=delete&kind=deployment&name=web&namespace=apps&context=kind-dev&source=chosen"
local SCALE =
	"kube-lens://mutate?op=scale&kind=deployment&name=web&namespace=apps&replicas=1&context=kind-dev&source=chosen"

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
		local s, d = ready("kube-lens://mutate?op=restart&kind=deployment&name=web&namespace=apps")
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
			A.init("kube-lens://mutate?op=scale&kind=deployment&name=web&namespace=apps&context=kind-dev")
		expect(s.phase).toBe("input")
		present(A.find(effects, "focus"))
		local respond = A.cluster()
		A.typeText(s, "2", respond)
		A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("ready")
		expect(s.argv).toEqual({ "kubectl", "scale", "deployment/web", "--replicas=2", "-n", "apps" })
	end)

	it("asks for a path when the palette opens an apply with only a cwd", function()
		local s, effects = A.init("kube-lens://mutate?op=apply&cwd=%2Fw%2Frepo&context=kind-dev")
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
		local s = ready("kube-lens://mutate?op=apply&file=%2Fw%2Fapps.yaml&context=kind-dev", {
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
			A.init("kube-lens://mutate?op=apply&file=%2Fw%2Fsecret.yaml&context=kind-dev", { config = config })
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
		expect((string.find(text, "kube-lens-test-not-a-secret", 1, true))).toBeNil()
		expect(text).toContain("      *** (last-applied-configuration redacted by kube-lens)")
		expect(secretPreview(A.config({ showSecretValues = true }))).toContain("kube-lens-test-not-a-secret")
	end)

	it("refuses every native link when mutations are disabled, without running anything", function()
		local s, effects = A.init(SCALE, { config = A.config({ enabled = false }) })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toBe(Session.DISABLED)
		expect(#effects).toBe(0)
		s, effects = A.init("kube-lens://act/cronjob-run?kind=CronJob&name=nightly&namespace=apps", {
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
		local s = ready("kube-lens://mutate?op=apply&file=%2Fw%2Fa.yaml&context=kind-dev", world)
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
		local s = ready("kube-lens://mutate?op=restart&kind=deployment&name=web&namespace=apps")
		A.send(s, A.key("t", "t"), A.cluster())
		local d = A.send(s, A.key("enter"), A.cluster({ current = "prod" }))
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		expect(s.confirmError).toContain("prod")
	end)

	it("requires confirming an inferred target before anything runs", function()
		local s = ready("kube-lens://mutate?op=restart&kind=deployment&name=web&namespace=apps")
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
	local function guard(req: A.Req?, opts: A.Opts?): (Session.State, A.Drive)
		local o: A.Opts = opts or {}
		o.request = o.request or A.request(req or {})
		local s, effects = A.init(A.requestPath(), o)
		return s, A.drive(s, effects, A.cluster())
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
		expect(w.text).toBe(
			"nonce="
				.. A.NONCE
				.. "\ndecision=approve\nfingerprint="
				.. (s.fingerprint :: string)
				.. "\ncontext=kind-dev\napproved_at=1000\n"
		)
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
		expect(s.errors[1]).toContain("outside the kube-lens spool")
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
end)

describe("approve session: quick-action mutations", function()
	local NODE = "kube-lens://act/debug-node?kind=Node&name=worker-1&context=kind-dev"

	it("previews the node and requires typing its name (privileged pod)", function()
		local s = ready(NODE)
		expect(s.phase).toBe("ready")
		expect((s.requirements :: any).typed).toBe("worker-1")
	end)

	it("grants a single-use token bound to the pinned link and opens it", function()
		local s = ready(NODE)
		A.typeText(s, "worker-1", A.cluster())
		local d = A.send(s, A.key("enter"), A.cluster())
		local grant = A.find(d.effects, "grant") :: Effect
		local open = A.find(d.effects, "open") :: Effect
		expect(grant.token).toBe(A.TOKEN)
		expect(open.url).toContain("confirm=" .. A.TOKEN)
		local req = Quick.decode(open.url :: string) :: Quick.Request
		expect(req.target.context).toBe("kind-dev")
		expect(req.target.kubeconfig).toBe("/k/config")
		expect(req.opts.image).toBe(Quick.DEFAULT_IMAGE)
		expect(Link.quickBase(req)).toBe(grant.url)
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		present(A.find(d.effects, "exit"))
	end)

	it("refuses links that already carry a token or do not mutate", function()
		local s = A.init(NODE .. "&confirm=" .. A.TOKEN)
		expect(s.errors[1]).toContain("token")
		s = A.init("kube-lens://act/shell?kind=Pod&name=web&namespace=apps")
		expect(s.errors[1]).toContain("does not need approval")
	end)

	it("dry-runs a cronjob run on the server", function()
		local s, d = ready("kube-lens://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&suffix=abc12")
		expect(s.phase).toBe("ready")
		local dry = A.find(d.runs, "run", "step:dry-run") :: Effect
		expect(table.find(argvOf(dry), "--dry-run=server") ~= nil).toBe(true)
	end)

	-- Chips carry no suffix: the block picks the job name once, previews
	-- exactly that name, and the confirmed link makes the split create it.
	it("names the job for a chip without a suffix and carries the name to the split", function()
		local s, d = ready("kube-lens://act/cronjob-run?kind=CronJob&name=nightly&namespace=batch&context=kind-dev")
		expect(s.phase).toBe("ready")
		local dry = A.find(d.runs, "run", "step:dry-run") :: Effect
		expect(table.find(argvOf(dry), "nightly-manual-3e8") ~= nil).toBe(true)
		d = A.send(s, A.key("enter"), A.cluster())
		local open = A.find(d.effects, "open") :: Effect
		local req = Quick.decode(open.url :: string) :: Quick.Request
		expect(req.opts.suffix).toBe("3e8")
		expect(A.find(d.runs, "run", "exec")).toBeNil()
	end)
end)

return nil
