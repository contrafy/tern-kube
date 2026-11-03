--!strict
-- `helm rollback` through the approve block, from captured helm output: what
-- the preview reads (both stored revisions, the live objects), what it must
-- refuse (a release that moved since the preview, a run the block cannot
-- outwait) and what it must never show (values echoed into manifests).
local A = require("../../lib/approve")
local Audit = require("../../../plugin/lib/mutation/audit")
local Fixtures = require("../../lib/fixtures")
local Link = require("../../../plugin/lib/mutation/link")
local N = require("../../lib/nodes")
local Plan = require("../../../plugin/lib/mutation/plan")
local Render = require("../../../plugin/lib/mutation/render")
local Risk = require("../../../plugin/lib/mutation/risk")
local Session = require("../../../plugin/lib/mutation/session")
local Steps = require("../../../plugin/lib/mutation/steps")
local T = require("../../../plugin/lib/mutation/types")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Effect = Session.Effect

local function present(x: any)
	expect(x ~= nil).toBe(true)
end

local function cap(name: string): string
	return Fixtures.read("helm/captured/" .. name)
end

local NS = "tern-test-helm"

local function rollback(
	release: string,
	revision: number,
	opts: { wait: boolean?, cleanup: boolean?, force: boolean? }?
): string
	return Link.forRelease(
		{ name = release, namespace = NS },
		revision,
		{ context = "kind-dev", source = "chosen", kubeconfig = "/k/config" },
		opts
	) :: string
end

local function dryRunOk(): Session.ProcessResult
	return A.ok("Rollback was a success! Happy Helming!\n")
end

-- shop-a at revision 3 (deployed), rolled back to 1.
local function shopWorld(extra: { [string]: any }?): A.World
	local w: A.World = {
		["step:helm-current"] = A.ok(cap("status-shop-a-r3.json")),
		["step:helm-target"] = A.ok(cap("status-shop-a-r1.json")),
		["step:helm-latest"] = A.ok(cap("history-shop-a-max1.json")),
		["step:helm-hooks"] = A.ok(cap("extras-shop-a-r1.txt")),
		["step:dry-run"] = dryRunOk(),
		["step:diff"] = { status = 1, stdout = cap("kubectl-diff-shop-a-r1.txt"), stderr = "", timed_out = false },
		["v-history"] = A.ok(cap("history-shop-a-max1.json")),
		exec = A.ok("Rollback was a success! Happy Helming!\n"),
		["rq:helm-after"] = A.ok(
			'[{"revision":3,"updated":"2026-01-01T00:03:00Z","status":"superseded","chart":"shop-0.1.0",'
				.. '"app_version":"1.27","description":"Upgrade complete"},{"revision":4,"updated":"2026-01-01T00:20:00Z",'
				.. '"status":"deployed","chart":"shop-0.1.0","app_version":"1.27","description":"Rollback to 1"}]'
		),
	}
	for k, v in extra or {} :: { [string]: any } do
		w[k] = v
	end
	return w
end

local function ready(url: string, world: A.World, opts: A.Opts?): (Session.State, A.Drive)
	local s, effects = A.init(url, opts)
	return s, A.drive(s, effects, A.cluster(world))
end

local function reasonIds(s: Session.State): { string }
	local out: { string } = {}
	for _, r in (s.assessment :: T.Assessment).reasons do
		table.insert(out, r.tier .. ":" .. r.id)
	end
	return out
end

local function has(list: { string }, x: string): boolean
	return table.find(list, x) ~= nil
end

local function viewText(s: Session.State): string
	local v = Render.view(s)
	return N.text(v.main) .. "\n" .. N.text(v.dock :: any)
end

describe("helm rollback preview", function()
	it("reads both revisions, proves the target exists, then diffs its manifest against the live objects", function()
		local s, d = ready(rollback("shop-a", 1), shopWorld())
		expect(s.errors).toEqual({})
		expect(s.phase).toBe("ready")
		local cur = A.find(d.runs, "run", "step:helm-current") :: Effect
		expect(cur.argv).toEqual({
			"helm",
			"--kube-context",
			"kind-dev",
			"--kubeconfig",
			"/k/config",
			"status",
			"shop-a",
			"-n",
			NS,
			"-o",
			"json",
		})
		expect(cur.env).toEqual({ HELM_DRIVER = "secret" })
		local dry = A.find(d.runs, "run", "step:dry-run") :: Effect
		expect(table.concat(dry.argv or {}, " ")).toBe(
			"helm --kube-context kind-dev --kubeconfig /k/config rollback shop-a 1 -n "
				.. NS
				.. " --timeout 240s --wait --dry-run"
		)
		-- Stage 2: the target manifest goes through stdin, never a file.
		local diff = A.find(d.runs, "run", "step:diff") :: Effect
		expect(diff.argv).toEqual({
			"kubectl",
			"--kubeconfig",
			"/k/config",
			"--context",
			"kind-dev",
			"--namespace",
			NS,
			"diff",
			"-f",
			"-",
		})
		expect(diff.stdin).toBe(json.decode(cap("status-shop-a-r1.json")).manifest)
		expect((diff.env :: any).KUBECTL_EXTERNAL_DIFF).toBe("")
		-- Recorded change r3 -> r1: Deployment (replicas, image) and ConfigMap (mode).
		local rd = s.diff :: any
		expect(rd.modify).toBe(2)
		expect((s.liveDiff :: any).modify).toBe(2)
		-- Both live changes are explained by the recorded change: no drift.
		expect(has(reasonIds(s), "simple:helm-live-drift")).toBe(false)
		local a = s.assessment :: T.Assessment
		expect(a.tier).toBe("typed")
		expect((s.requirements :: any).typed).toBe("shop-a")
		local ids = reasonIds(s)
		expect(has(ids, "typed:helm-rollback")).toBe(true)
		expect(a.reasons[1].text).toContain("from revision 3 to 1")
		expect(has(ids, "typed:helm-pending")).toBe(false)
		expect(A.find(d.runs, "run", "exec")).toBeNil()
		local text = viewText(s)
		expect(text).toContain("helm rollback")
		expect(text).toContain("Recorded change (helm revisions 3 → 1)")
		expect(text).toContain("Against live objects")
	end)

	it("types the release name, re-reads the history, runs the pinned argv and shows the new revision", function()
		local w = shopWorld()
		local s = ready(rollback("shop-a", 1), w)
		local respond = A.cluster(w)
		A.typeText(s, "shop-a", respond)
		local d = A.send(s, A.key("enter"), respond)
		local v = A.find(d.runs, "run", "v-history") :: Effect
		expect(table.concat(v.argv or {}, " ")).toContain("history shop-a -n " .. NS .. " -o json --max 1")
		local exec = A.find(d.runs, "run", "exec") :: Effect
		expect(exec.argv).toEqual({
			"helm",
			"--kube-context",
			"kind-dev",
			"--kubeconfig",
			"/k/config",
			"rollback",
			"shop-a",
			"1",
			"-n",
			NS,
			"--timeout",
			"240s",
			"--wait",
		})
		expect(exec.env).toEqual({ HELM_DRIVER = "secret" })
		expect(s.phase).toBe("done")
		present(A.find(d.runs, "run", "rq:helm-after"))
		expect(viewText(s)).toContain("now at revision 4 (deployed): Rollback to 1")
		local lines: { string } = {}
		for _, e in d.effects do
			if e.t == "audit" then
				table.insert(lines, e.line :: string)
			end
		end
		expect(#lines).toBe(2)
		expect(lines[2]).toContain('"decision":"executed"')
		expect(lines[2]).toContain('"family":"helm-rollback"')
		expect(lines[2]).toContain('"release":"shop-a","revision":1,"from_revision":3')
	end)

	it("refuses at confirm when the release moved since the preview", function()
		local moved = '[{"revision":4,"updated":"2026-01-01T00:30:00Z","status":"deployed","chart":"shop-0.1.0",'
			.. '"app_version":"1.27","description":"Upgrade complete"}]'
		local w = shopWorld({ ["v-history"] = A.ok(moved) })
		local s = ready(rollback("shop-a", 1), w)
		local respond = A.cluster(w)
		A.typeText(s, "shop-a", respond)
		local d = A.send(s, A.key("enter"), respond)
		expect(s.phase).toBe("ready")
		expect(s.stale).toBe(true)
		expect(s.confirmError).toContain(
			"The release changed since the preview (revision 4 deployed, previewed 3 deployed)"
		)
		expect(A.find(d.runs, "run", "exec")).toBeNil()
	end)

	it("types a pending release instead of blocking it: rollback is how a stuck upgrade recovers", function()
		local s = ready(
			rollback("stuck-d", 1),
			shopWorld({
				["step:helm-current"] = A.ok(cap("status-stuck-d-r2.json")),
				["step:helm-target"] = A.ok(cap("status-stuck-d-r1.json")),
				["step:helm-latest"] = A.ok(cap("history-stuck-d.json")),
				["step:helm-hooks"] = A.ok(cap("extras-stuck-d-r1.txt")),
			})
		)
		expect(s.phase).toBe("ready")
		local a = s.assessment :: T.Assessment
		expect(a.tier).toBe("typed")
		expect(has(reasonIds(s), "typed:helm-pending")).toBe(true)
		expect(a.reasons[1].id).toBe("helm-pending")
		expect(a.reasons[1].text).toContain("pending-upgrade")
	end)

	it("fails the preview when the revision is gone (the dry run is the existence check)", function()
		local s = ready(
			rollback("shop-a", 99),
			shopWorld({
				["step:helm-target"] = A.failed(1, "Error: release: not found\n"),
				["step:dry-run"] = A.failed(1, "Error: release has no 99 version\n"),
			})
		)
		expect(s.phase).toBe("ready")
		expect((s.assessment :: T.Assessment).tier).toBe("blocked")
		expect(viewText(s)).toContain("release has no 99 version")
	end)

	it("keeps going without the stored hooks: they are a note, not a failed preview", function()
		local s =
			ready(rollback("shop-a", 1), shopWorld({ ["step:helm-hooks"] = A.failed(1, "Error: template: boom\n") }))
		expect((s.assessment :: T.Assessment).tier).toBe("typed")
		expect(s.notes[1]).toContain("Chart and hooks unavailable")
	end)

	it("refuses a rollback whose --timeout the block cannot outwait", function()
		local config = A.config()
		config.helm.rollback.timeoutS = 290
		local s, d = ready(rollback("shop-a", 1), shopWorld(), { config = config })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("exceeds mutations.execute_timeout_ms (300 s)")
		expect(A.find(d.runs, "run", "step:helm-current")).toBeNil()
	end)

	it("says helm is missing instead of asking for input", function()
		local s = A.init(rollback("shop-a", 1), { noHelm = true })
		expect(s.phase).toBe("error")
		expect(s.errors[1]).toContain("helm was not found")
	end)

	it("an option chip previews the toggled command afresh", function()
		local w = shopWorld()
		local s = ready(rollback("shop-a", 1), w)
		local fp = s.fingerprint
		local d = A.send(s, { t = "action", act = "helm-cleanup" }, A.cluster(w))
		expect(s.phase).toBe("ready")
		expect(s.fingerprint ~= fp).toBe(true)
		local exec = Session.commandText(s)
		expect(exec).toContain("--wait --cleanup-on-fail")
		expect(exec).toContain("HELM_DRIVER=secret")
		present(A.find(d.runs, "run", "step:helm-current"))
	end)

	it("never shows values echoed into the live diff or the revision diff", function()
		local echo = table.concat({
			"diff -u -N /tmp/LIVE-1/v1.ConfigMap."
				.. NS
				.. ".web-b-web-config /tmp/MERGED-1/v1.ConfigMap."
				.. NS
				.. ".web-b-web-config",
			"--- /tmp/LIVE-1/v1.ConfigMap." .. NS .. ".web-b-web-config\t2026-01-01 00:00:00",
			"+++ /tmp/MERGED-1/v1.ConfigMap." .. NS .. ".web-b-web-config\t2026-01-01 00:00:00",
			"@@ -1,3 +1,3 @@",
			" data:",
			'-  dsn: "postgres://app:old-pw@db:5432/app"',
			'+  dsn: "postgres://app:hunter2-REDACTME@db:5432/app"',
			"",
		}, "\n")
		local w = shopWorld({
			["step:helm-current"] = A.ok(cap("status-web-b-r2.json")),
			["step:helm-target"] = A.ok(cap("status-web-b-r1.json")),
			["step:helm-latest"] = A.ok(cap("history-web-b.json")),
			["step:helm-hooks"] = A.ok(cap("extras-web-b-r1.txt")),
			["step:diff"] = { status = 1, stdout = echo, stderr = "", timed_out = false },
		})
		local s = ready(rollback("web-b", 1), w)
		expect(s.phase).toBe("ready")
		for i in (s.diff :: any).segments do
			s.expanded[i] = true
		end
		for i in (s.liveDiff :: any).segments do
			s.liveExpanded[i] = true
		end
		s.showCommand = true
		local text = viewText(s)
		expect((string.find(text, "REDACTME", 1, true))).toBeNil()
		expect(text).toContain("web-b-web-config")
		expect(has(reasonIds(s), "simple:helm-hooks")).toBe(true)
		-- The opt-in shows them.
		local cfg = A.config({ showSecretValues = true })
		local shown = ready(rollback("web-b", 1), w, { config = cfg })
		for i in (shown.liveDiff :: any).segments do
			shown.liveExpanded[i] = true
		end
		expect(viewText(shown)).toContain("hunter2-REDACTME")
	end)
end)

describe("helm rollback risk", function()
	local function planFor(line: string): T.Plan
		local p = Plan.fromArgv(string.split(line, " "), {
			context = "kind-dev",
			contextSource = "chosen",
			cwd = "/",
			program = "kubectl",
			helmDriver = "secret",
		})
		return p :: T.Plan
	end
	local P = planFor("helm rollback shop-a 3 -n shop --timeout 60s --force")
	local function row(revision: number, status: string): any
		return {
			revision = revision,
			updated = "2026-01-01T00:00:00Z",
			status = status,
			chart = "shop-0.1.0",
			chartName = "shop",
			chartVersion = "0.1.0",
			appVersion = "1.27",
			description = "",
		}
	end

	it("re-applying the latest revision is simple info, force and no-wait are flagged", function()
		local a = Risk.assess(P, { previewOk = true, helm = { latest = row(3, "deployed") } })
		local ids: { string } = {}
		for _, r in a.reasons do
			table.insert(ids, r.id)
		end
		expect(has(ids, "helm-same")).toBe(true)
		expect(has(ids, "helm-force")).toBe(true)
		expect(has(ids, "helm-no-wait")).toBe(true)
		expect(a.token).toBe("shop-a")
	end)

	it("flags live objects the recorded change does not explain (edited outside helm)", function()
		local function seg(kind: string, name: string): any
			return {
				key = kind .. name,
				kind = kind,
				name = name,
				namespace = "shop",
				action = "modify",
				added = 1,
				removed = 1,
				binary = false,
				lines = {},
			}
		end
		local function summary(list: { any }): any
			return {
				segments = list,
				create = 0,
				modify = #list,
				delete = 0,
				unknown = 0,
				added = 0,
				removed = 0,
				notes = {},
			}
		end
		local a = Risk.assess(P, {
			previewOk = true,
			helm = {
				latest = row(4, "deployed"),
				revdiff = {
					summary = summary({ seg("Deployment", "web") }),
					masked = {},
					maskedChanges = 0,
					hooks = { added = {}, removed = {}, changed = {} },
				},
				live = summary({ seg("Deployment", "web"), seg("ConfigMap", "edited") }),
			},
		})
		local drift: T.Reason? = nil
		for _, r in a.reasons do
			if r.id == "helm-live-drift" then
				drift = r
			end
		end
		expect(drift ~= nil).toBe(true)
		expect((drift :: T.Reason).advisory).toBe(true)
		expect((drift :: T.Reason).text).toContain("ConfigMap edited")
	end)
end)

describe("helm rollback steps and audit", function()
	it("re-reads only the newest revision at confirm and the two newest after the run", function()
		local p = Plan.fromArgv({ "helm", "rollback", "shop-a", "1", "--timeout", "60s" }, {
			context = "kind-dev",
			cwd = "/",
			namespace = "shop",
		}) :: T.Plan
		local v = Steps.verifySteps(p)
		expect(#v).toBe(1)
		expect(v[1].id).toBe("helm-latest")
		local rq = Steps.requerySteps(p)
		expect(table.concat(rq[1].argv, " ")).toContain("--max 2")
		local r = Audit.record(p, { mode = "native", decision = "approved", decidedAt = 1, fromRevision = 3 })
		expect(r.release).toBe("shop-a")
		expect(r.revision).toBe(1)
		expect(r.from_revision).toBe(3)
		expect(r.family).toBe("helm-rollback")
	end)
end)

return nil
