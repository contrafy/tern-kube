--!strict
-- The GitOps routes of Explore touch the user's repository, the cluster and
-- their disk, so every step is pinned down: the manifest index is built only
-- when asked and late results are ignored; diff inputs are written 0600
-- under the plugin data dir and always removed, Secret values never reach
-- the screen; drift buckets drive apply/export; apply goes through the
-- approve block only; export never writes before a previewed confirmation;
-- the git flow refuses to sweep up unrelated staged work, keeps push and PR
-- off until asked and never forces. Inputs are the drift world captured from
-- kind (tests/fixtures/drift) mounted at /repo/drift.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Gitops = require("../../../plugin/lib/explore/gitops")
local Link = require("../../../plugin/lib/mutation/link")
local G = require("../../lib/gitops_world")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Effect = Gitops.Effect
type Ref = Gitops.Ref
type World = G.World

local NS = G.NS

local DEPLOY: Ref = { kind = "Deployment", group = "apps", namespace = NS, name = "web", source = "live" }
local CONFIG: Ref = { kind = "ConfigMap", namespace = NS, name = "app-config", source = "live" }
local SERVICE: Ref = { kind = "Service", namespace = NS, name = "web", source = "live" }
local NAMESPACE: Ref = { kind = "Namespace", name = NS, source = "live" }

local DRIFT = "dir:/repo/drift"

local function setup(cfg: string?, files: { [string]: string }?): (World, Gitops.G, Gitops.Ctx)
	local w = G.new(files)
	local ctx = G.ctx(cfg)
	return w, G.ready(w, ctx), ctx
end

local function step(w: World, g: Gitops.G, ctx: Gitops.Ctx, fn: (effects: { Effect }) -> ())
	local effects: { Effect } = {}
	fn(effects)
	G.core(w, g, ctx, effects)
end

-- The block's drift load of a source (loads are keyed per target).
local function driftOf(g: Gitops.G, ctx: Gitops.Ctx, source: string): Gitops.DriftLoad
	return g.drifts[Gitops.driftId(ctx.target, source)]
end

local function find(lines: { string }, needle: string): string?
	for _, l in lines do
		if string.find(l, needle, 1, true) then
			return l
		end
	end
	return nil
end

local function ofType(effects: { Effect }, kind: string): { Effect }
	local out: { Effect } = {}
	for _, e in effects do
		if e.t == kind then
			table.insert(out, e)
		end
	end
	return out
end

local function decodeOpen(w: World): Link.Request
	local url = w.opened[#w.opened]
	local req = Link.decode(url)
	assert(req, "not a tern-kube link: " .. tostring(url))
	return req
end

local function result(tag: string, gen: number, status: number, stdout: string): Gitops.Msg
	return {
		t = "result",
		tag = tag,
		gen = gen,
		result = { status = status, stdout = stdout, stderr = "", timed_out = false },
		at = G.AT,
	}
end

describe("explore gitops: manifest index lifecycle", function()
	it("is built only when a route asks, once, with the configured limits", function()
		local ctx = G.ctx('{"gitops":{"max_files":10,"render_kustomize":false}}')
		local g = Gitops.new(G.ROOT)
		expect(g.scan.status).toBe("idle")
		local effects: { Effect } = {}
		Gitops.ensureIndex(g, ctx, effects)
		Gitops.ensureIndex(g, ctx, effects)
		Gitops.rescan(g, ctx, effects)
		local scans = ofType(effects, "scan")
		expect(#scans).toBe(1)
		expect(scans[1].cwd).toBe(G.ROOT)
		expect((scans[1].scan :: any).maxFiles).toBe(10)
		expect((scans[1].scan :: any).renderKustomize).toBe(false)
		expect(g.scan.status).toBe("scanning")
	end)

	it("without a working directory it fails with advice and never scans", function()
		local g = Gitops.new(nil)
		local effects: { Effect } = {}
		Gitops.ensureIndex(g, G.ctx(nil), effects)
		expect(#effects).toBe(0)
		expect(g.scan.status).toBe("error")
		expect(g.scan.error).toBe(Gitops.NO_CWD)
	end)

	-- --no-optional-locks: a plain `git status` rewrites .git/index, and Tern
	-- reloads a linked plugin on any write under its directory, so every
	-- reload-restored route would trigger the next reload.
	it("a finished scan reads the remotes, then git status of the manifest files", function()
		local w, g = setup()
		expect(Gitops.ready(g)).toBe(true)
		expect(G.lines(w)).toEqual({
			"git -C /repo remote -v",
			"git -C /repo --no-optional-locks status --porcelain=v1 -z -- *.yaml *.yml *Kustomization",
		})
		expect(g.repo.git).toBe(true)
		expect(g.repo.remotes).toEqual({ G.REMOTE })
	end)

	it("outside git the index still works and no git status is asked for", function()
		local w = G.new()
		w.answer = function(argv)
			return if argv[1] == "git" then G.fail(128, "fatal: not a git repository") else nil
		end
		local g = G.ready(w, G.ctx(nil))
		expect(Gitops.ready(g)).toBe(true)
		expect(g.repo.git).toBe(false)
		expect(#w.runs).toBe(1)
	end)

	it("progress and results of a superseded scan are ignored", function()
		local w, g, ctx = setup()
		local effects: { Effect } = {}
		Gitops.rescan(g, ctx, effects)
		local first = effects[1]
		local again: { Effect } = {}
		g.scan = { status = "ok", gen = g.scan.gen }
		Gitops.rescan(g, ctx, again)
		expect(
			Gitops.onProgress(
				g,
				{ t = "progress", gen = first.gen, progress = { phase = "read", done = 1, total = 2 } }
			)
		).toBe(false)
		local out: { Effect } = {}
		Gitops.onResult(g, ctx, { t = "result", tag = first.tag, gen = first.gen, index = G.index(w) }, out)
		expect(g.scan.status).toBe("scanning")
		expect(#out).toBe(0)
		expect(
			Gitops.onProgress(
				g,
				{ t = "progress", gen = again[1].gen, progress = { phase = "read", done = 1, total = 2 } }
			)
		).toBe(true)
		expect((g.scan.progress :: any).done).toBe(1)
	end)

	it("a failed scan is reported, drops a queued open, and r retries", function()
		local w = G.new()
		w.scanError = "git ls-files exited 128"
		local ctx = G.ctx(nil)
		local g = Gitops.new(G.ROOT)
		step(w, g, ctx, function(effects)
			Gitops.openManifest(g, ctx, DEPLOY, effects)
		end)
		expect(g.scan.status).toBe("error")
		expect(g.scan.error).toBe("git ls-files exited 128")
		expect(g.pendingOpen).toBeNil()
		expect(#w.opened).toBe(0)
		local again: { Effect } = {}
		Gitops.ensureIndex(g, ctx, again)
		expect(#again).toBe(0)
		w.scanError = nil
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "manifest", ref = DEPLOY }, true, effects)
		end)
		expect(Gitops.ready(g)).toBe(true)
	end)
end)

describe("explore gitops: open manifest", function()
	it("m before the index exists builds it, then opens the best match at its first line", function()
		local w = G.new()
		local ctx = G.ctx(nil)
		local g = Gitops.new(G.ROOT)
		step(w, g, ctx, function(effects)
			Gitops.openManifest(g, ctx, CONFIG, effects)
		end)
		expect(w.opened).toEqual({ "/repo/drift/baseline/app.yaml:29" })
		expect(g.pendingOpen).toBeNil()
	end)

	it("an object no manifest declares says so and points at export", function()
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.openManifest(
				g,
				ctx,
				{ kind = "ConfigMap", namespace = NS, name = "hand-made", source = "live" },
				effects
			)
		end)
		expect(#w.opened).toBe(0)
		expect(G.toastTexts(w)).toEqual({ "No manifest declares configmap/hand-made | E exports it" })
	end)

	it("manifest route items are the matches; m and enter open the selected one, = diffs it", function()
		local w, g, ctx = setup()
		local route = { kind = "manifest", ref = SERVICE } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		expect(#items).toBe(1)
		expect(items[1].key).toBe("/repo/drift/baseline/service.yaml:7")
		G.press(w, g, ctx, route, items[1], "enter")
		expect(w.opened).toEqual({ "/repo/drift/baseline/service.yaml:7" })
		local handled, nav = G.press(w, g, ctx, route, items[1], "=")
		expect(handled).toBe(true)
		expect((nav :: any).push).toEqual({ kind = "diff", ref = SERVICE, doc = 1 })
	end)

	it("the gitops-open action opens path:line", function()
		local w, g, ctx = setup()
		local effects: { Effect } = {}
		local handled =
			Gitops.onAction(g, ctx, { kind = "manifest", ref = DEPLOY }, "gitops-open", "/repo/a b.yaml:12", effects)
		expect(handled).toBe(true)
		expect(effects[1]).toEqual({ t = "openfile", path = "/repo/a b.yaml", line = 12 })
		expect(#w.opened).toBe(0)
	end)
end)

describe("explore gitops: diff vs manifest", function()
	local function diffRoute(ref: Ref, doc: number?): Gitops.Route
		return { kind = "diff", ref = ref, doc = doc or 1 }
	end

	it("reads the file, writes only the matched document 0600, diffs it pinned, then removes it", function()
		local w, g, ctx = setup()
		w.runs = {}
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
		end)
		local tmp = "/data/tmp/diff-1000-n1.yaml"
		local lines = G.lines(w)
		expect(lines[1]).toBe("/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " tern-kube-tmp " .. tmp)
		expect(Gitops.WRITE_SCRIPT).toContain("umask 077")
		expect(lines[2]).toBe("kubectl --context kind-tern-kube-dev diff -f " .. tmp)
		expect(lines[3]).toBe("rm -f -- " .. tmp)
		expect(#lines).toBe(3)
		expect(w.stdin[1]).toBe(Gitops.slice(w.files["/repo/drift/baseline/app.yaml"], 1, 27))
		expect(w.stdin[1]).toContain("kind: Deployment")
		expect((string.find(w.stdin[1], "ConfigMap", 1, true))).toBeNil()
		local diffRun = w.effects[#w.effects - 1]
		expect(diffRun.env).toEqual({ KUBECTL_EXTERNAL_DIFF = "" })
		expect(w.tmp[tmp]).toBeNil()
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("ok")
		expect(load.exit).toBe(1)
		expect(#load.segments).toBe(1)
		expect(load.segments[1].action).toBe("modify")
		expect(load.segments[1].name).toBe("web")
	end)

	it("a document without metadata.namespace is diffed in the object's namespace (-n)", function()
		local files = G.driftFiles()
		files["/repo/loose/cm.yaml"] = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: loose\ndata:\n  a: b\n"
		local w, g, ctx = setup(nil, files)
		local ref: Ref = { kind = "ConfigMap", namespace = NS, name = "loose", source = "live" }
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, diffRoute(ref), false, effects)
		end)
		expect(find(G.lines(w), " diff -f ") :: string).toContain("diff -f /data/tmp/diff-1000-n1.yaml -n " .. NS)
	end)

	it("in sync is exit 0 with no segments", function()
		local w, g, ctx = setup()
		local route = diffRoute(SERVICE)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("ok")
		expect(load.exit).toBe(0)
		expect(#load.segments).toBe(0)
	end)

	-- The reason is kubectl's last line that is not klog noise (GIT-F8).
	it("a failing kubectl diff is an error and the temporary file is still removed", function()
		local w, g, ctx = setup()
		local stderr = 'E1110 10:11:04.215188   79940 memcache.go:265] "Unhandled Error"\n'
			.. "error: the server is unreachable\n"
			.. 'E1110 10:11:04.315188   79940 memcache.go:265] "Unhandled Error"\n'
		w.answer = function(argv)
			return if table.find(argv, "diff") then G.fail(2, stderr) else nil
		end
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("error")
		expect(load.error).toBe("kubectl diff exited 2: error: the server is unreachable")
		expect(w.removed).toEqual({ "/data/tmp/diff-1000-n1.yaml" })
	end)

	it("a timed-out diff is an error, never 'in sync'", function()
		local w, g, ctx = setup()
		w.answer = function(argv)
			return if table.find(argv, "diff") then { status = 0, stdout = "", stderr = "", timed_out = true } else nil
		end
		local route = diffRoute(SERVICE)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		expect(g.diffs[Gitops.diffId(route)].error).toBe("kubectl diff timed out")
	end)

	it("a failed temp write never runs kubectl", function()
		local w, g, ctx = setup()
		w.answer = function(argv)
			return if argv[1] == "/bin/sh" then G.fail(1, "mkdir: permission denied") else nil
		end
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("error")
		expect(load.error).toBe("Writing the temporary manifest exited 1: mkdir: permission denied")
		expect(find(G.lines(w), "kubectl")).toBeNil()
	end)

	it("without a plugin data directory nothing is written", function()
		local w, g, ctx = setup()
		ctx.dataDir = nil
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		expect(g.diffs[Gitops.diffId(route)].status).toBe("error")
		expect(find(G.lines(w), "/bin/sh")).toBeNil()
	end)

	it("an unmatched object is 'nomatch' and runs nothing", function()
		local w, g, ctx = setup()
		local route = diffRoute({ kind = "ConfigMap", namespace = NS, name = "hand-made", source = "live" })
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		expect(g.diffs[Gitops.diffId(route)].status).toBe("nomatch")
		expect(#w.runs).toBe(0)
	end)

	it("exit 1 without any difference is an error, never 'in sync'", function()
		local w, g, ctx = setup()
		w.answer = function(argv)
			return if table.find(argv, "diff") then G.fail(1, 'error: unable to recognize "x.yaml"') else nil
		end
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("error")
		expect(load.error).toBe('kubectl diff exited 1: error: unable to recognize "x.yaml" (no differences printed)')
	end)

	it("before the index exists the diff waits for it, then runs", function()
		local w = G.new()
		local ctx = G.ctx(nil)
		local g = Gitops.new(G.ROOT)
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
			expect(g.diffs[Gitops.diffId(route)].status).toBe("index")
			expect(#ofType(effects, "scan")).toBe(1)
		end)
		expect(g.diffs[Gitops.diffId(route)].status).toBe("ok")
	end)

	it("re-entering keeps the result; r re-runs; a superseded diff result is ignored", function()
		local w, g, ctx = setup()
		local route = diffRoute(DEPLOY)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
		end)
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
		end)
		expect(#w.runs).toBe(0)
		local old = g.diffs[Gitops.diffId(route)].gen
		local effects: { Effect } = {}
		Gitops.enter(g, ctx, route, true, effects)
		local out: { Effect } = {}
		Gitops.onResult(g, ctx, result("gitops|diff|run", old, 0, ""), out)
		expect(g.diffs[Gitops.diffId(route)].status).toBe("reading")
		expect(#out).toBe(0)
	end)

	it("Secret values in the last-applied annotation are masked unless show_secret_values is set", function()
		local secretText = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: creds\n  namespace: "
			.. NS
			.. "\nstringData:\n  password: hunter2\n"
		local diff = table.concat({
			"diff -u -N /tmp/LIVE-1/v1.Secret." .. NS .. ".creds /tmp/MERGED-1/v1.Secret." .. NS .. ".creds",
			"--- /tmp/LIVE-1/v1.Secret." .. NS .. ".creds\t2026-10-08 12:00:00",
			"+++ /tmp/MERGED-1/v1.Secret." .. NS .. ".creds\t2026-10-08 12:00:00",
			"@@ -1,6 +1,6 @@",
			" apiVersion: v1",
			"-    kubectl.kubernetes.io/last-applied-configuration: |",
			'-      {"apiVersion":"v1","kind":"Secret","stringData":{"password":"hunter1"}}',
			'+      {"apiVersion":"v1","kind":"Secret","stringData":{"password":"hunter2"}}',
			"",
		}, "\n")
		local ref: Ref = { kind = "Secret", namespace = NS, name = "creds", source = "live" }
		for _, show in { false, true } do
			local files = G.driftFiles()
			files["/repo/secrets/creds.yaml"] = secretText
			local w, g, ctx = setup(if show then '{"security":{"show_secret_values":true}}' else nil, files)
			w.answer = function(argv)
				return if table.find(argv, "diff")
					then { status = 1, stdout = diff, stderr = "", timed_out = false }
					else nil
			end
			local route = diffRoute(ref)
			step(w, g, ctx, function(effects)
				Gitops.startDiff(g, ctx, route, false, effects)
			end)
			local body = table.concat(g.diffs[Gitops.diffId(route)].segments[1].lines, "\n")
			if show then
				expect(body).toContain("hunter2")
			else
				expect((string.find(body, "hunter", 1, true))).toBeNil()
				expect(body).toContain(Diffseg.REDACTED)
			end
		end
	end)

	it("[ and ] cycle through several matches; m opens the compared one", function()
		local files = G.driftFiles()
		files["/repo/copy/app.yaml"] = files["/repo/drift/baseline/app.yaml"]
		local w, g, ctx = setup(nil, files)
		local route = diffRoute(CONFIG)
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(#load.docs).toBe(2)
		local _, nav = G.press(w, g, ctx, route, nil, "]")
		expect((nav :: any).replace).toEqual({ kind = "diff", ref = CONFIG, doc = 2 })
		local _, back = G.press(w, g, ctx, route, nil, "[")
		expect((back :: any).replace).toEqual({ kind = "diff", ref = CONFIG, doc = 2 })
		G.press(w, g, ctx, route, nil, "m")
		expect(w.opened[#w.opened]).toBe((load.doc :: any).file .. ":29")
	end)
end)

describe("explore gitops: apply bundles", function()
	it("a document alone in its file is applied from that file through the approve block", function()
		local w, g, ctx = setup()
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.applyDocs(g, ctx, Gitops.matches(g, ctx, NAMESPACE), "namespace/" .. NS, effects)
		end)
		expect(#w.runs).toBe(0)
		local req = decodeOpen(w)
		expect(req.op).toBe("apply")
		expect(req.file).toBe("/repo/drift/namespace.yaml")
		expect(req.context).toBe(G.CTX)
		expect(req.recursive).toBe(false)
	end)

	it("a document sharing its file is cut into a kept 0600 bundle holding only it", function()
		local w, g, ctx = setup()
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.applyDocs(g, ctx, Gitops.matches(g, ctx, SERVICE), "service/web", effects)
		end)
		local tmp = "/data/tmp/apply-1000-n1.yaml"
		expect(G.lines(w)).toEqual({ "/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " tern-kube-tmp " .. tmp })
		expect(w.tmp[tmp]).toContain("kind: Service")
		expect((string.find(w.tmp[tmp], "ServiceAccount", 1, true))).toBeNil()
		expect(decodeOpen(w).file).toBe(tmp)
		expect(#w.removed).toBe(0)
		expect(g.bundle).toBeNil()
	end)

	it("several documents from several files become one bundle separated by ---", function()
		local w, g, ctx = setup()
		local docs = { Gitops.matches(g, ctx, DEPLOY)[1], Gitops.matches(g, ctx, SERVICE)[1] }
		step(w, g, ctx, function(effects)
			Gitops.applyDocs(g, ctx, docs, "2 objects", effects)
		end)
		local text = w.tmp["/data/tmp/apply-1000-n1.yaml"]
		expect(text).toContain("kind: Deployment")
		expect(text).toContain("\n---\n")
		expect(text).toContain("kind: Service\n")
	end)

	-- A re-applied export would set the live Secret to REPLACE_ME (GIT-F1).
	it("Secrets with export placeholders are left out, and alone are refused", function()
		local w, g, ctx = setup()
		local held = table.clone(Gitops.matches(g, ctx, SERVICE)[1])
		held.placeholders = { "pw" }
		step(w, g, ctx, function(effects)
			Gitops.applyDocs(g, ctx, { Gitops.matches(g, ctx, DEPLOY)[1], held }, "2 objects", effects)
		end)
		local text = w.tmp["/data/tmp/apply-1000-n1.yaml"]
		expect(text).toContain("kind: Deployment")
		expect((string.find(text, "kind: Service\n", 1, true))).toBeNil()
		expect(G.toastTexts(w)[1]).toContain("Left out 1 Secret with export placeholders")
		expect(G.toastTexts(w)[1]).toContain("service/web (pw)")

		w, g, ctx = setup()
		w.runs = {}
		held = table.clone(Gitops.matches(g, ctx, SERVICE)[1])
		held.placeholders = { "pw" }
		step(w, g, ctx, function(effects)
			Gitops.applyDocs(g, ctx, { held }, "service/web", effects)
		end)
		expect(#w.runs).toBe(0)
		expect(#w.opened).toBe(0)
		expect(w.toasts[1].level).toBe("error")
		expect(G.toastTexts(w)[1]).toContain("still holds the export placeholder REPLACE_ME")
	end)

	it("mutations disabled or no target: nothing is read, written or opened", function()
		for _, case in { "disabled", "unresolved" } do
			local w, g, ctx = setup(if case == "disabled" then '{"mutations":{"enabled":false}}' else nil)
			ctx.resolved = case ~= "unresolved"
			w.runs = {}
			step(w, g, ctx, function(effects)
				Gitops.applyDocs(g, ctx, Gitops.matches(g, ctx, SERVICE), "service/web", effects)
			end)
			expect(#w.runs).toBe(0)
			expect(#w.opened).toBe(0)
			expect(w.toasts[1].level).toBe("error")
		end
	end)

	it("an unreadable file aborts the bundle with an error", function()
		local w, g, ctx = setup()
		local docs = Gitops.matches(g, ctx, SERVICE)
		w.files["/repo/drift/baseline/service.yaml"] = nil
		step(w, g, ctx, function(effects)
			Gitops.applyDocs(g, ctx, docs, "service/web", effects)
		end)
		expect(g.bundle).toBeNil()
		expect(#w.opened).toBe(0)
		expect(G.toastTexts(w)[1]).toContain("Cannot read drift/baseline/service.yaml")
	end)

	it("a in the diff view applies the compared document", function()
		local w, g, ctx = setup()
		local route = { kind = "diff", ref = NAMESPACE, doc = 1 } :: Gitops.Route
		step(w, g, ctx, function(effects)
			Gitops.startDiff(g, ctx, route, false, effects)
		end)
		G.press(w, g, ctx, route, nil, "a")
		expect(decodeOpen(w).file).toBe("/repo/drift/namespace.yaml")
	end)
end)

describe("explore gitops: drift", function()
	local function report(cfg: string?): (World, Gitops.G, Gitops.Ctx, Gitops.DriftLoad)
		local w, g, ctx = setup(cfg)
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "drift", source = DRIFT }, false, effects)
		end)
		return w, g, ctx, driftOf(g, ctx, DRIFT)
	end

	it(
		"the chooser offers the top directory and each directory, current namespace first, and reads controllers",
		function()
			local w, g, ctx = setup()
			w.runs = {}
			step(w, g, ctx, function(effects)
				Gitops.enter(g, ctx, { kind = "drift" }, false, effects)
			end)
			local ids: { string } = {}
			for _, s in Gitops.sources(g, ctx) do
				table.insert(ids, s.id .. " " .. s.docs .. " " .. s.rank)
			end
			expect(ids).toEqual({
				"dir:/repo/drift 9 2",
				"dir:/repo/drift/baseline 5 2",
				"dir:/repo/drift/pending 3 2",
			})
			expect(G.lines(w)[1]).toBe("kubectl --context kind-tern-kube-dev api-resources -o name")
			expect(g.ctl.status).toBe("ok")
			local items = Gitops.items(g, ctx, { kind = "drift" })
			local _, nav = G.press(w, g, ctx, { kind = "drift" }, items[2], "enter")
			expect((nav :: any).push).toEqual({ kind = "drift", source = "dir:/repo/drift/baseline" })
		end
	)

	it("a directory source diffs exactly its files and lists its kinds in its namespaces, pinned", function()
		local w = report()
		expect(G.lines(w)).toEqual({
			"kubectl --context kind-tern-kube-dev get configmap,deployment.apps,service,serviceaccount,widget.lens.example.com -n "
				.. NS
				.. " -o json",
			"kubectl --context kind-tern-kube-dev diff -f /repo/drift/baseline/app.yaml -f /repo/drift/baseline/service.yaml -f /repo/drift/baseline/widgets.yaml -f /repo/drift/namespace.yaml -f /repo/drift/pending/extra.yaml",
		})
		local diffRun = w.effects[#w.effects]
		expect(diffRun.env).toEqual({ KUBECTL_EXTERNAL_DIFF = "" })
	end)

	it("buckets: changed, missing in cluster, unmanaged; defaults and owned objects ignored", function()
		local _, _, _, load = report()
		expect(load.status).toBe("ok")
		local r = load.report :: any
		expect({ r.counts.changed, r.counts.missing, r.counts.unmanaged, r.counts.inSync }).toEqual({ 4, 3, 1, 2 })
		local keys: { string } = {}
		for _, e in Gitops.entries(load) do
			table.insert(keys, e.key)
		end
		expect(keys).toEqual({
			"changed:/ConfigMap/tern-test-drift/app-config",
			"changed:/Namespace//tern-test-drift",
			"changed:apps/Deployment/tern-test-drift/web",
			"changed:lens.example.com/Widget/tern-test-drift/gauge",
			"missing:/ConfigMap/tern-test-drift/only-in-git",
			"missing:lens.example.com/Widget/tern-test-drift/dial.v2",
			"missing:rbac.authorization.k8s.io/ClusterRole//tern-test-drift-reader",
			"unmanaged:/ConfigMap/tern-test-drift/hand-made",
		})
	end)

	it("f cycles all -> changed -> missing -> unmanaged -> all; the filter survives r", function()
		local w, g, ctx = report()
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local seen: { string } = {}
		for _ = 1, 4 do
			G.press(w, g, ctx, route, nil, "f")
			local load = driftOf(g, ctx, DRIFT)
			table.insert(seen, load.filter .. " " .. #Gitops.items(g, ctx, route))
		end
		expect(seen).toEqual({ "changed 4", "missing 3", "unmanaged 1", "all 8" })
		Gitops.setFilter(g, Gitops.driftId(ctx.target, DRIFT), "missing")
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, true, effects)
		end)
		expect(driftOf(g, ctx, DRIFT).filter).toBe("missing")
		expect(driftOf(g, ctx, DRIFT).status).toBe("ok")
	end)

	it("enter drills into an entry whose items are its manifests; m opens them", function()
		local w, g, ctx = report()
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		local _, nav = G.press(w, g, ctx, route, items[3], "enter")
		local item = (nav :: any).push
		expect(item).toEqual({ kind = "drift", source = DRIFT, item = "changed:apps/Deployment/tern-test-drift/web" })
		local docs = Gitops.items(g, ctx, item)
		expect(#docs).toBe(1)
		expect(docs[1].key).toBe("/repo/drift/baseline/app.yaml:1")
		expect((Gitops.focusRef(g, ctx, item, nil) :: Ref).name).toBe("web")
		G.press(w, g, ctx, item, docs[1], "m")
		expect(w.opened).toEqual({ "/repo/drift/baseline/app.yaml:1" })
	end)

	-- ctrl+d from a report row opened a delete preview for a missing object
	-- (nothing to delete) and for declared ones (the next apply restores
	-- them); only unmanaged objects are the cluster's to delete.
	it("refuses ctrl+d on drift entries that are not unmanaged", function()
		local _, g, ctx = report()
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local byBucket: { [string]: any } = {}
		for _, it_ in Gitops.items(g, ctx, route) do
			local bucket = string.match(it_.key, "^(%a+):")
			if bucket and byBucket[bucket] == nil then
				byBucket[bucket] = it_
			end
		end
		expect((Gitops.deleteRefusal(g, ctx, route, byBucket.missing))).toBe("Not in the cluster")
		expect((Gitops.deleteRefusal(g, ctx, route, byBucket.changed))).toBe("Declared in the manifests")
		expect((Gitops.deleteRefusal(g, ctx, route, byBucket.unmanaged))).toBeNil()
		local item = { kind = "drift", source = DRIFT, item = byBucket.missing.key } :: Gitops.Route
		expect((Gitops.deleteRefusal(g, ctx, item, nil))).toBe("Not in the cluster")
	end)

	it("m on an unmanaged entry says no manifest has it", function()
		local w, g, ctx = report()
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		G.press(w, g, ctx, route, items[8], "m")
		expect(#w.opened).toBe(0)
		expect(G.toastTexts(w)).toEqual({ "Not in any manifest | E exports it" })
	end)

	it("a: changed entry applies its manifest, unmanaged has none; A applies the whole source", function()
		local w, g, ctx = report()
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		G.press(w, g, ctx, route, items[2], "a")
		expect(decodeOpen(w).file).toBe("/repo/drift/namespace.yaml")
		G.press(w, g, ctx, route, items[8], "a")
		expect(G.toastTexts(w)).toEqual({ "No manifest to apply | Export it (E) or delete it (ctrl+d)" })
		local before = #w.opened
		G.press(w, g, ctx, route, nil, "A")
		expect(#w.opened).toBe(before + 1)
		local bundle = w.tmp[decodeOpen(w).file :: string]
		expect(bundle).toContain("name: only-in-git")
		expect(bundle).toContain("name: tern-test-drift-reader")
	end)

	it("Secret values from the live listing are dropped, keys kept", function()
		local w, g, ctx = setup()
		w.answer = function(argv)
			if table.find(argv, "get") and table.find(argv, "-n") then
				local live = fixtures.read("drift/live/objects.json")
				live = string.gsub(
					live,
					'"items": %[',
					'"items": [{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s","namespace":"'
						.. NS
						.. '"},"data":{"token":"c2VjcmV0"}},',
					1
				)
				return G.ok(live)
			end
			return nil
		end
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		local load = driftOf(g, ctx, DRIFT)
		local secret: any = nil
		for _, o in load.live do
			if o.kind == "Secret" then
				secret = o
			end
		end
		expect(secret.data).toEqual({ token = "" })
	end)

	it("a failed diff is an error report; a failed listing still reports with a note", function()
		local w, g, ctx = setup()
		w.answer = function(argv)
			return if table.find(argv, "diff") then G.fail(1, "error: unable to recognize") else nil
		end
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		expect(driftOf(g, ctx, DRIFT).status).toBe("error")
		expect(driftOf(g, ctx, DRIFT).error).toBe(
			"kubectl diff exited 1: error: unable to recognize (no differences printed)"
		)

		local w2, g2, ctx2 = setup()
		w2.answer = function(argv)
			return if table.find(argv, "get") then G.fail(1, "Forbidden") else nil
		end
		step(w2, g2, ctx2, function(effects)
			Gitops.startDriftReport(g2, ctx2, DRIFT, false, effects)
		end)
		local load = driftOf(g2, ctx2, DRIFT)
		expect(load.status).toBe("ok")
		expect(load.liveErrors).toEqual({ "namespace " .. NS .. ": kubectl get exited 1: Forbidden" })
	end)

	it("a helm source diffs its render from a temp file that is removed afterwards", function()
		local w = G.new()
		table.insert(w.rendered, {
			kind = "helm",
			path = "/repo/drift/chart",
			helm = { release = "web", namespace = "tern-test-helm", values = {} },
			text = fixtures.read("gitops/captured/helm-web.yaml"),
		})
		local ctx = G.ctx(nil)
		local g = G.ready(w, ctx)
		local id: string? = nil
		for _, s in Gitops.sources(g, ctx) do
			if s.type == "helm" then
				id = s.id
			end
		end
		expect(id).toBe("helm:/repo/drift/chart:web")
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, id :: string, false, effects)
		end)
		local tmp = "/data/tmp/drift-1000-n1.yaml"
		local lines = G.lines(w)
		expect(find(lines, "/bin/sh -c")).toBe("/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " tern-kube-tmp " .. tmp)
		-- helm template leaves metadata.namespace out of most objects (helm
		-- install puts them in the release namespace); without -n kubectl
		-- would diff them against its default namespace and report them missing.
		expect(find(lines, " diff ")).toBe(
			"kubectl --context kind-tern-kube-dev diff -f " .. tmp .. " -n tern-test-helm"
		)
		expect(w.removed).toEqual({ tmp })
		expect(driftOf(g, ctx, id :: string).status).toBe("ok")
		local _, nav = G.press(w, g, ctx, { kind = "drift", source = id }, nil, "X")
		expect(nav).toBeNil()
		expect(G.toastTexts(w)[1]).toContain("Chart objects are not exported")
		-- Applying the render must land where helm installs it, not in
		-- kubectl's default namespace (the documents carry no namespace).
		G.press(w, g, ctx, { kind = "drift", source = id }, nil, "A")
		local req = decodeOpen(w)
		expect(req.op).toBe("apply")
		expect(req.file).toBe("/data/tmp/apply-1000-n2.yaml")
		expect(req.namespace).toBe("tern-test-helm")
	end)

	it("a kustomize source diffs with -k and A applies with kustomize=", function()
		local files: { [string]: string } = {}
		for _, key in fixtures.list("gitops/kustomize/") do
			files["/repo/" .. string.sub(key, #"gitops/" + 1)] = fixtures.read(key)
		end
		local w = G.new(files)
		table.insert(w.rendered, {
			kind = "kustomize",
			path = "/repo/kustomize/overlays/staging",
			text = fixtures.read("gitops/captured/kustomize-staging.yaml"),
		})
		local ctx = G.ctx(nil, "tern-test-staging")
		local g = G.ready(w, ctx)
		local id = "kustomize:/repo/kustomize/overlays/staging"
		expect(Gitops.findSource(g, ctx, id) ~= nil).toBe(true)
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, id, false, effects)
		end)
		expect(find(G.lines(w), " diff ")).toBe(
			"kubectl --context kind-tern-kube-dev diff -k /repo/kustomize/overlays/staging"
		)
		G.press(w, g, ctx, { kind = "drift", source = id }, nil, "A")
		local req = decodeOpen(w)
		expect(req.kustomize).toBe("/repo/kustomize/overlays/staging")
		expect(req.file).toBeNil()
	end)

	it("the drift summary is a markdown table per entry", function()
		local _, _, _, load = report()
		local md = Gitops.driftSummary(load, G.CTX)
		expect(md).toContain("Drift of `drift/` against context `kind-tern-kube-dev` (tern-kube).")
		expect(md).toContain("4 changed, 3 missing in cluster, 1 unmanaged, 2 in sync.")
		expect(md).toContain("| Deployment tern-test-drift/web | changed | +2 -2 |")
	end)
end)

-- Chart auto-detect: chart dirs in the checkout are offered as drift
-- sources for the releases that run them. Helm is asked once per index,
-- the deployed values (which can hold secrets) only touch disk 0600 for the
-- one render and are always removed, and the user's configured entries win.
describe("explore gitops: chart auto-detect", function()
	local HELM_NS = "tern-test-helm"
	local CHART = "/repo/helm/chart"
	local DEPLOYED = "helm:" .. CHART .. ":" .. HELM_NS .. "/shop-a:deployed"
	local STAGING = "helm:" .. CHART .. ":" .. HELM_NS .. "/shop-a:values=/repo/helm/values-staging.yaml"
	local VALUES_TMP = "/data/tmp/values-1000-n1.yaml"

	local function chooser(cfg: string?, ctxHelm: string?): (World, Gitops.G, Gitops.Ctx)
		local w = G.new(G.helmFiles())
		local ctx = G.ctx(cfg, HELM_NS)
		ctx.helm = ctxHelm
		local g = G.ready(w, ctx)
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "drift" } :: Gitops.Route, false, effects)
		end)
		return w, g, ctx
	end

	local function source(g: Gitops.G, ctx: Gitops.Ctx, id: string): Gitops.SourceEntry?
		return Gitops.findSource(g, ctx, id)
	end

	local function helmRuns(w: World): { Effect }
		local out: { Effect } = {}
		for _, e in ofType(w.effects, "run") do
			if (e.argv :: { string })[1] == G.HELM then
				table.insert(out, e)
			end
		end
		return out
	end

	it("lists each matching release with deployed values and with the proposed values file", function()
		local w, g, ctx = chooser(nil, G.HELM)
		local runs = helmRuns(w)
		expect(#runs).toBe(1)
		expect(table.concat(runs[1].argv :: { string }, " ")).toBe(
			G.HELM
				.. " --kube-context kind-tern-kube-dev list --deployed --failed --pending --superseded --uninstalled"
				.. " --uninstalling -o json --time-format 2006-01-02T15:04:05Z07:00 --max 1000 -A"
		)
		expect(runs[1].env).toEqual({ HELM_DRIVER = "secret" })
		local deployed = source(g, ctx, DEPLOYED) :: Gitops.SourceEntry
		expect(deployed.label).toBe("helm/chart as tern-test-helm/shop-a with deployed values")
		expect(deployed.note).toBe("auto: name+version+app version match")
		expect(deployed.namespaces).toEqual({ HELM_NS })
		expect(deployed.rank).toBe(2)
		expect((source(g, ctx, STAGING) :: Gitops.SourceEntry).label).toBe(
			"helm/chart as tern-test-helm/shop-a with helm/values-staging.yaml"
		)
		-- web-b runs another chart.
		for _, s in Gitops.sources(g, ctx) do
			expect((string.find(s.id, "web-b", 1, true))).toBeNil()
		end
		expect(#Gitops.chartDirs(g)).toBe(1)
	end)

	it("asks helm once per index: again on r, not on every visit", function()
		local w, g, ctx = chooser(nil, G.HELM)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "drift" } :: Gitops.Route, false, effects)
		end)
		expect(#helmRuns(w)).toBe(1)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "drift" } :: Gitops.Route, true, effects)
		end)
		expect(#helmRuns(w)).toBe(2)
	end)

	it("offers nothing and asks helm nothing when auto-detect is off or helm is missing", function()
		local w, g, ctx = chooser('{"helm": {"auto_detect": false}}', G.HELM)
		expect(#helmRuns(w)).toBe(0)
		expect(source(g, ctx, DEPLOYED)).toBeNil()
		local w2, g2, ctx2 = chooser(nil, nil)
		expect(#helmRuns(w2)).toBe(0)
		expect(source(g2, ctx2, DEPLOYED)).toBeNil()
	end)

	it("shows a failed helm list and keeps the other sources", function()
		local w = G.new(G.helmFiles())
		w.answer = function(argv)
			return if argv[1] == G.HELM then G.fail(1, "Error: Kubernetes cluster unreachable") else nil
		end
		local ctx = G.ctx(nil, HELM_NS)
		local g = G.ready(w, ctx)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "drift" } :: Gitops.Route, false, effects)
		end)
		expect(g.releases.status).toBe("error")
		expect(g.releases.error).toBe("helm list exited 1: Error: Kubernetes cluster unreachable")
		expect(source(g, ctx, DRIFT) ~= nil).toBe(true)
	end)

	it("lets a configured gitops.helm entry replace the guesses for its release", function()
		local _, g, ctx = chooser(
			'{"gitops": {"helm": [{"chart": "helm/chart", "release": "shop-a", "namespace": "tern-test-helm"}]}}',
			G.HELM
		)
		expect(source(g, ctx, DEPLOYED)).toBeNil()
		expect(source(g, ctx, STAGING)).toBeNil()
		expect(source(g, ctx, "helm:" .. CHART .. ":" .. HELM_NS .. "/stuck-d:deployed") ~= nil).toBe(true)
	end)

	it("renders with the deployed values from a 0600 temp file removed right after the render", function()
		local w, g, ctx = chooser(nil, G.HELM)
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DEPLOYED, false, effects)
		end)
		local lines = G.lines(w)
		local pins = G.HELM .. " --kube-context kind-tern-kube-dev "
		expect(lines[1]).toBe(pins .. "get values shop-a -n tern-test-helm -o json")
		expect(lines[2]).toBe("/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " tern-kube-tmp " .. VALUES_TMP)
		expect(Gitops.WRITE_SCRIPT).toContain("umask 077")
		expect(lines[3]).toBe(
			G.HELM .. " template shop-a " .. CHART .. " --no-hooks -n tern-test-helm -f " .. VALUES_TMP
		)
		expect(lines[4]).toBe("rm -f -- " .. VALUES_TMP)
		expect(w.helmInputs[VALUES_TMP]).toBe(fixtures.read("helm/captured/values-shop-a-r3.json"))
		expect(find(lines, " diff ")).toBe(
			"kubectl --context kind-tern-kube-dev diff -f /data/tmp/drift-1000-n2.yaml -n tern-test-helm"
		)
		expect(w.removed).toEqual({ VALUES_TMP, "/data/tmp/drift-1000-n2.yaml" })
		expect((next(w.tmp))).toBeNil()
		local load = driftOf(g, ctx, DEPLOYED)
		expect(load.status).toBe("ok")
		-- The render now is the source: its objects are what was compared.
		expect((load.report :: any).counts.docs).toBe(3)
	end)

	it("renders with the proposed values file, nothing written", function()
		local w, g, ctx = chooser(nil, G.HELM)
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, STAGING, false, effects)
		end)
		local lines = G.lines(w)
		expect(lines[1]).toBe(
			G.HELM .. " template shop-a " .. CHART .. " --no-hooks -n tern-test-helm -f /repo/helm/values-staging.yaml"
		)
		expect(find(lines, "get values")).toBeNil()
		expect(driftOf(g, ctx, STAGING).status).toBe("ok")
	end)

	it("reports a failed render and still removes the deployed values", function()
		local w, g, ctx = chooser(nil, G.HELM)
		w.answer = function(argv)
			return if table.find(argv, "template")
				then G.fail(1, "Error: found in Chart.yaml, but missing in charts/")
				else nil
		end
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DEPLOYED, false, effects)
		end)
		local load = driftOf(g, ctx, DEPLOYED)
		expect(load.status).toBe("error")
		expect(load.error).toBe("helm template shop-a exited 1: Error: found in Chart.yaml, but missing in charts/")
		expect(w.removed).toEqual({ VALUES_TMP })
	end)

	-- r while helm still runs: the old run's answers are ignored, but its
	-- values file must not stay behind.
	it("removes the values file of a superseded render", function()
		local w, g, ctx = chooser(nil, G.HELM)
		local first: { Effect } = {}
		Gitops.startDriftReport(g, ctx, DEPLOYED, false, first)
		-- The values arrive: the first run asks to write its values file.
		local writes: { Effect } = {}
		for _, e in first do
			Gitops.onResult(
				g,
				ctx,
				{ t = "result", tag = e.tag, gen = e.gen, result = G.respond(w, e), at = G.AT },
				writes
			)
		end
		expect(#writes).toBe(1)
		local second: { Effect } = {}
		Gitops.startDriftReport(g, ctx, DEPLOYED, true, second)
		for _, e in second do
			table.insert(writes, e)
		end
		G.core(w, g, ctx, writes)
		expect(table.find(w.removed, VALUES_TMP) ~= nil).toBe(true)
		expect((next(w.tmp))).toBeNil()
		expect(driftOf(g, ctx, DEPLOYED).status).toBe("ok")
	end)

	it("resolves the best source of a release opened elsewhere", function()
		local w = G.new(G.helmFiles())
		local ctx = G.ctx(nil, HELM_NS)
		local g = G.ready(w, ctx)
		local row = {
			name = "shop-a",
			namespace = HELM_NS,
			revision = 3,
			updated = "2026-01-01T00:03:00Z",
			updatedAt = nil,
			status = "deployed",
			chart = "shop-0.1.0",
			chartName = "shop",
			chartVersion = "0.1.0",
			appVersion = "1.27",
		} :: any
		expect(Gitops.releaseSource(g, ctx, row)).toBe(DEPLOYED)
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DEPLOYED, false, effects)
		end)
		expect(driftOf(g, ctx, DEPLOYED).status).toBe("ok")
		local other = table.clone(row)
		other.chartName = "web"
		expect(Gitops.releaseSource(g, ctx, other)).toBeNil()
	end)

	it("copies an auto source as a gitops.helm entry instead of writing the config", function()
		local w, g, ctx = chooser(nil, G.HELM)
		local effects: { Effect } = {}
		local handled = Gitops.onAction(
			g,
			ctx,
			{ kind = "drift", source = STAGING } :: Gitops.Route,
			"gitops-copyhelm",
			"",
			effects
		)
		expect(handled).toBe(true)
		local copies = ofType(effects, "copy")
		expect(copies[1].text).toBe(
			'{"chart":"helm/chart","release":"shop-a","namespace":"tern-test-helm","values":["helm/values-staging.yaml"]}'
		)
		expect(#ofType(effects, "write")).toBe(0)
		local _ = w
	end)
end)

describe("explore gitops: export", function()
	local function exportUnmanaged(): (World, Gitops.G, Gitops.Ctx)
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		local _, nav = G.press(w, g, ctx, route, items[8], "E")
		expect((nav :: any).push).toEqual({ kind = "export" })
		return w, g, ctx
	end

	it("E on an unmanaged entry previews new files in the source's directory and writes nothing", function()
		local w, g = exportUnmanaged()
		local ex = g.export :: Gitops.ExportState
		expect(ex.status).toBe("ok")
		expect(ex.dir).toBe("/repo/drift")
		expect(ex.label).toBe("1 object from drift/")
		local changes = Gitops.exportChanges(ex)
		expect(#changes > 0).toBe(true)
		for _, c in changes do
			expect(c.status).toBe("new")
			expect(c.diff ~= nil).toBe(true)
		end
		expect(#ofType(w.effects, "write")).toBe(0)
		expect(ofType(w.effects, "readtree")[1].path).toBe("/repo/drift")
	end)

	it("w asks first; esc/n cancels; y writes exactly the previewed files and refreshes git status", function()
		local w, g, ctx = exportUnmanaged()
		local route = { kind = "export" } :: Gitops.Route
		G.press(w, g, ctx, route, nil, "w")
		expect((g.export :: any).confirming).toBe(true)
		expect(#ofType(w.effects, "write")).toBe(0)
		G.press(w, g, ctx, route, nil, "escape")
		expect((g.export :: any).confirming).toBe(false)
		G.press(w, g, ctx, route, nil, "w")
		G.press(w, g, ctx, route, nil, "n")
		expect(#ofType(w.effects, "write")).toBe(0)
		local planned = Gitops.exportChanges(g.export :: any)
		G.press(w, g, ctx, route, nil, "w")
		w.runs = {}
		G.press(w, g, ctx, route, nil, "y")
		local writes = ofType(w.effects, "write")
		expect(#writes).toBe(1)
		local written: { string } = {}
		for i, f in writes[1].files :: { any } do
			written[i] = f.path
			expect(f.text).toBe(planned[i].text)
		end
		expect(written).toEqual((g.export :: any).written)
		expect((g.export :: any).status).toBe("written")
		expect(G.lines(w)[1]).toContain("git -C /repo --no-optional-locks status --porcelain=v1 -z --")
		expect(G.toastTexts(w)[1]).toContain("Wrote ")
	end)

	it("an object whose manifest differs is 'modified' with a diff, never silently replaced", function()
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		G.press(w, g, ctx, route, items[1], "E")
		local ex = g.export :: Gitops.ExportState
		expect(ex.status).toBe("ok")
		local changes = Gitops.exportChanges(ex)
		expect(#changes).toBe(1)
		expect(changes[1].path).toBe("/repo/drift/baseline/app.yaml")
		expect(changes[1].status).toBe("modified")
		expect(changes[1].diff :: string).toContain("-  LOG_LEVEL: info")
		expect(changes[1].text).toContain("kind: Deployment")
		G.press(w, g, ctx, { kind = "export" }, nil, "y")
		expect(#ofType(w.effects, "write")).toBe(0)
	end)

	it("nothing changed: w then y writes nothing", function()
		local w, g, ctx = exportUnmanaged()
		local route = { kind = "export" } :: Gitops.Route
		G.press(w, g, ctx, route, nil, "w")
		G.press(w, g, ctx, route, nil, "y")
		w.toasts = {}
		local ex = table.clone(g.export :: Gitops.ExportState)
		ex.status = "ok"
		local plan = table.clone(ex.plan :: any)
		plan.files = {}
		plan.kustomizationEdits = {}
		ex.plan = plan
		g.export = ex
		G.press(w, g, ctx, route, nil, "w")
		G.press(w, g, ctx, route, nil, "y")
		expect(#ofType(w.effects, "write")).toBe(1)
		expect(G.toastTexts(w)).toEqual({ "Nothing to write | Every file already matches the cluster" })
	end)

	it("a new directory (relative to the repo root) re-plans; an unreadable one is an error", function()
		local w, g, ctx = exportUnmanaged()
		Gitops.setField(g, "dir", "  exported/./cms ")
		step(w, g, ctx, function(effects)
			Gitops.commitField(g, ctx, "dir", effects)
		end)
		local ex = g.export :: Gitops.ExportState
		expect(ex.dir).toBe("/repo/exported/cms")
		expect(ex.status).toBe("ok")
		expect(g.fields.dir).toBeNil()
		w.answer = nil
		local effects: { Effect } = {}
		Gitops.setField(g, "dir", "/elsewhere")
		Gitops.commitField(g, ctx, "dir", effects)
		local out: { Effect } = {}
		Gitops.onResult(g, ctx, result("gitops|export|tree", (g.export :: any).gen, 1, ""), out)
		expect((g.export :: any).status).toBe("error")
	end)

	it("a failed write is an error, not 'written'", function()
		local w, g, ctx = exportUnmanaged()
		local route = { kind = "export" } :: Gitops.Route
		G.press(w, g, ctx, route, nil, "w")
		local effects: { Effect } = {}
		Gitops.onKey(g, ctx, route, nil, "y", G.key("y"), effects)
		local out: { Effect } = {}
		Gitops.onResult(g, ctx, {
			t = "result",
			tag = effects[1].tag,
			gen = effects[1].gen,
			result = { status = 1, stdout = "", stderr = "/repo/x: permission denied", timed_out = false },
		}, out)
		expect((g.export :: any).status).toBe("error")
		expect((g.export :: any).error).toBe("Writing failed: /repo/x: permission denied")
	end)

	it("missing entries have no live object to export", function()
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		local items = Gitops.items(g, ctx, route)
		local _, nav = G.press(w, g, ctx, route, items[5], "E")
		expect(nav).toBeNil()
		expect(G.toastTexts(w)).toEqual({ "Nothing to export | Select a changed or unmanaged object" })
	end)
end)

describe("explore gitops: git flow", function()
	local function written(staged: string?, gh: string?): (World, Gitops.G, Gitops.Ctx)
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		local route = { kind = "drift", source = DRIFT } :: Gitops.Route
		G.press(w, g, ctx, route, Gitops.items(g, ctx, route)[8], "E")
		G.press(w, g, ctx, { kind = "export" }, nil, "w")
		G.press(w, g, ctx, { kind = "export" }, nil, "y")
		w.staged = staged or ""
		w.gh = gh
		w.runs = {}
		local _, nav = G.press(w, g, ctx, { kind = "export" }, nil, "b")
		expect((nav :: any).push).toEqual({ kind = "git" })
		return w, g, ctx
	end

	local function gitArgv(git: Gitops.GitState): { string }
		local out: { string } = {}
		for _, s in Gitops.gitCommands(git, "gh") do
			table.insert(out, table.concat(s.argv, " "))
		end
		return out
	end

	it("b before writing is refused", function()
		local w, g, ctx = setup()
		local effects: { Effect } = {}
		expect(Gitops.startGit(g, ctx, effects)).toBe(false)
		expect(effects[1].text).toBe("Write an export first")
		expect(#w.runs).toBe(2)
	end)

	it("checks status, HEAD, remotes and gh, then defaults to branch + add + commit only", function()
		local w, g = written()
		expect(G.lines(w)).toEqual({
			"git -C /repo --no-optional-locks status --porcelain=v1 -z",
			"git -C /repo rev-parse --abbrev-ref HEAD",
			"git -C /repo remote",
			'/bin/sh -c command -v -- "$1" sh gh',
		})
		local git = g.git :: Gitops.GitState
		expect(git.status).toBe("ready")
		expect(git.push).toBe(false)
		expect(git.pr).toBe(false)
		expect(git.branch).toBe("tern-kube/1-object-from-drift-19700101-001640")
		expect(git.message).toBe("chore(gitops): export 1 object from drift/")
		expect(Gitops.gitBlocker(git)).toBeNil()
		local argv = gitArgv(git)
		expect(#argv).toBe(3)
		expect(argv[1]).toBe("git -C /repo switch -c " .. git.branch)
		expect(argv[2]).toContain("git -C /repo add -- drift/")
		expect(argv[3]).toBe("git -C /repo commit -m " .. git.message)
	end)

	it("unrelated staged changes block the commit until o restricts it to the exported files", function()
		local w, g, ctx = written("M  src/main.go\0A  drift/other.yaml\0?? notes.txt\0")
		local git = g.git :: Gitops.GitState
		expect(git.checks.unrelated).toEqual({ "src/main.go", "drift/other.yaml" })
		expect(Gitops.gitBlocker(git) :: string).toContain(
			"2 unrelated staged change(s) (src/main.go, drift/other.yaml)"
		)
		w.runs = {}
		G.press(w, g, ctx, { kind = "git" }, nil, "enter")
		expect(#w.runs).toBe(0)
		expect(G.toastTexts(w)[#w.toasts]).toContain("Cannot run the git commands")
		G.press(w, g, ctx, { kind = "git" }, nil, "o")
		local only = g.git :: Gitops.GitState
		expect(Gitops.gitBlocker(only)).toBeNil()
		local commit = gitArgv(only)[3]
		expect(commit).toContain("commit -m " .. only.message .. " -- drift/")
	end)

	it("renames in porcelain -z skip the original path", function()
		expect(Gitops.stagedPaths("R  new.yaml\0old.yaml\0 M work.yaml\0A  added.yaml\0")).toEqual({
			"new.yaml",
			"added.yaml",
		})
	end)

	it("runs the steps in order and stops at the first failure", function()
		local w, g, ctx = written()
		w.answer = function(argv)
			return if argv[4] == "add" then G.fail(128, "fatal: pathspec did not match") else nil
		end
		w.runs = {}
		G.press(w, g, ctx, { kind = "git" }, nil, "enter")
		local git = g.git :: Gitops.GitState
		expect(git.status).toBe("error")
		local states: { string } = {}
		for _, s in git.steps do
			table.insert(states, s.id .. " " .. s.status)
		end
		expect(states).toEqual({ "switch ok", "add error", "commit skipped" })
		expect(find(G.lines(w), " commit ")).toBeNil()
		expect(git.error).toBe("Stage the exported files failed")
	end)

	it("success commits on the branch; push and PR were never run", function()
		local w, g, ctx = written()
		w.runs = {}
		G.press(w, g, ctx, { kind = "git" }, nil, "enter")
		local git = g.git :: Gitops.GitState
		expect(git.status).toBe("done")
		expect(find(G.lines(w), " push")).toBeNil()
		expect(find(G.lines(w), "pr create")).toBeNil()
		expect(G.toastTexts(w)[#w.toasts]).toBe("Committed on " .. git.branch)
	end)

	it("p adds a plain push (never forced); P needs gh logged in and implies push", function()
		local w, g, ctx = written(nil, "/opt/fake/gh")
		local git = g.git :: Gitops.GitState
		expect(git.checks.gh).toBe("/opt/fake/gh")
		expect(git.checks.ghAuth).toBe(true)
		expect(git.push).toBe(false)
		G.press(w, g, ctx, { kind = "git" }, nil, "P")
		git = g.git :: Gitops.GitState
		expect(git.push).toBe(true)
		expect(git.pr).toBe(true)
		local steps = Gitops.gitCommands(git, git.checks.gh :: string)
		expect(table.concat(steps[4].argv, " ")).toBe("git -C /repo push -u origin " .. git.branch)
		expect(steps[5].argv[1]).toBe("/opt/fake/gh")
		expect(steps[5].cwd).toBe("/repo")
		expect(table.concat(steps[5].argv, " ")).toContain("pr create --title " .. git.message .. " --body ")
		for _, s in steps do
			for _, a in s.argv do
				expect(a == "--force" or a == "-f" or a == "--force-with-lease" or string.sub(a, 1, 1) == "+").toBe(
					false
				)
			end
		end
		G.press(w, g, ctx, { kind = "git" }, nil, "p")
		git = g.git :: Gitops.GitState
		expect(git.push).toBe(false)
		expect(git.pr).toBe(false)
	end)

	it("PR without gh, or push without origin, is blocked with the reason", function()
		local w, g, ctx = written()
		G.press(w, g, ctx, { kind = "git" }, nil, "P")
		expect(Gitops.gitBlocker(g.git :: any) :: string).toContain("gh is not installed or not logged in")
		local git = table.clone(g.git :: Gitops.GitState)
		git.pr = false
		git.checks = table.clone(git.checks)
		git.checks.origin = false
		expect(Gitops.gitBlocker(git) :: string).toContain("No remote named origin")
	end)

	it("invalid branch names and empty messages block; edits apply on enter", function()
		local w, g, ctx = written()
		for _, bad in { "", "-x", "a..b", "a b", "a~1", "x.lock", "a/.b", "a//b", "@", "ref@{u}", "trail/" } do
			expect(Gitops.validBranch(bad)).toBe(false)
		end
		expect(Gitops.validBranch("tern-kube/export-1")).toBe(true)
		Gitops.setField(g, "branch", "bad name")
		step(w, g, ctx, function(effects)
			Gitops.commitField(g, ctx, "branch", effects)
		end)
		expect(Gitops.gitBlocker(g.git :: any) :: string).toContain("is not valid")
		Gitops.setField(g, "branch", "ok/name")
		Gitops.setField(g, "message", "   ")
		step(w, g, ctx, function(effects)
			Gitops.commitField(g, ctx, "branch", effects)
			Gitops.commitField(g, ctx, "message", effects)
		end)
		expect((g.git :: any).branch).toBe("ok/name")
		expect(Gitops.gitBlocker(g.git :: any)).toBe("The commit message is empty (e edits it).")
	end)

	it("slugs are short, lowercase and safe", function()
		expect(Gitops.slug("3 ConfigMaps from tern-test-a/")).toBe("3-configmaps-from-tern-test-a")
		expect(Gitops.slug("!!!")).toBe("export")
		expect(#Gitops.slug(string.rep("abc ", 30)) <= 40).toBe(true)
	end)
end)

-- GIT-F10: a Helm report offered E/X and then refused every object, even
-- live-only ones the chart does not render. Those are plain objects and can
-- be exported (not into the chart directory); chart objects still cannot.
describe("explore gitops: Helm report export", function()
	local HELM_NS = "tern-test-helm"
	local STRAY = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"stray","namespace":"'
		.. HELM_NS
		.. '","uid":"u1","resourceVersion":"7","creationTimestamp":"2026-01-01T00:00:00Z"},"data":{"k":"v"}}'

	local function helmReport(): (World, Gitops.G, Gitops.Ctx, string)
		local w = G.new()
		table.insert(w.rendered, {
			kind = "helm",
			path = "/repo/drift/chart",
			helm = { release = "web", namespace = HELM_NS, values = {} },
			text = fixtures.read("gitops/captured/helm-web.yaml"),
		})
		w.answer = function(argv)
			if table.find(argv, "get") and table.find(argv, HELM_NS) then
				return G.ok('{"apiVersion":"v1","kind":"List","items":[' .. STRAY .. "]}")
			end
			return nil
		end
		local ctx = G.ctx(nil)
		local g = G.ready(w, ctx)
		local id = "helm:/repo/drift/chart:web"
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, id, false, effects)
		end)
		expect(driftOf(g, ctx, id).status).toBe("ok")
		return w, g, ctx, id
	end

	local function entryItem(g: Gitops.G, ctx: Gitops.Ctx, route: Gitops.Route, prefix: string): any
		for _, item in Gitops.items(g, ctx, route) do
			if string.sub(item.key, 1, #prefix) == prefix then
				return item
			end
		end
		return nil
	end

	it("X exports only the unmanaged objects, into the repository's export directory", function()
		local w, g, ctx, id = helmReport()
		local route = { kind = "drift", source = id } :: Gitops.Route
		expect(entryItem(g, ctx, route, "unmanaged:/ConfigMap/" .. HELM_NS .. "/stray") ~= nil).toBe(true)
		local _, nav = G.press(w, g, ctx, route, nil, "X")
		expect((nav :: any).push).toEqual({ kind = "export" })
		local ex = g.export :: Gitops.ExportState
		expect(#ex.objects).toBe(1)
		expect(ex.objects[1].metadata.name).toBe("stray")
		expect(ex.dir ~= "/repo/drift/chart").toBe(true)
		expect(ex.label).toBe("1 unmanaged object from " .. driftOf(g, ctx, id).source.label)
	end)

	it("E on an object the chart renders is refused and names the way out", function()
		local w, g, ctx, id = helmReport()
		local route = { kind = "drift", source = id } :: Gitops.Route
		local chart = entryItem(g, ctx, route, "missing:") or entryItem(g, ctx, route, "changed:")
		expect(chart ~= nil).toBe(true)
		local _, nav = G.press(w, g, ctx, route, chart, "E")
		expect(nav).toBeNil()
		expect(G.toastTexts(w)).toEqual({
			"Chart objects are not exported | Edit the chart; E and X export unmanaged objects only",
		})
		local stray = entryItem(g, ctx, route, "unmanaged:")
		local _, ok = G.press(w, g, ctx, route, stray, "E")
		expect((ok :: any).push).toEqual({ kind = "export" })
	end)

	-- GIT-F10/F15: the footer offered keys that only toast a refusal.
	it("footers offer export as unmanaged-only on Helm reports and ctrl+d only on unmanaged items", function()
		local GitopsView = require("../../../plugin/lib/gitops/view")
		local _, g, ctx, id = helmReport()
		local report = { kind = "drift", source = id } :: Gitops.Route
		local hint = GitopsView.hint(report, g, ctx)
		expect(hint).toContain("E export unmanaged")
		expect((string.find(hint, "X export all ·", 1, true))).toBeNil()
		local chart = entryItem(g, ctx, report, "missing:") or entryItem(g, ctx, report, "changed:")
		local item = GitopsView.hint({ kind = "drift", source = id, item = chart.key } :: any, g, ctx)
		expect((string.find(item, "ctrl+d", 1, true))).toBeNil()
		expect((string.find(item, "E export", 1, true))).toBeNil()
		local stray = entryItem(g, ctx, report, "unmanaged:")
		local other = GitopsView.hint({ kind = "drift", source = id, item = stray.key } :: any, g, ctx)
		expect(other).toContain("ctrl+d delete")
		expect(other).toContain("E export")
		expect((string.find(other, "a apply", 1, true))).toBeNil()
	end)

	it("plain reports keep E export and X export all; changed items have no ctrl+d", function()
		local GitopsView = require("../../../plugin/lib/gitops/view")
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.startDriftReport(g, ctx, DRIFT, false, effects)
		end)
		local report = { kind = "drift", source = DRIFT } :: Gitops.Route
		expect(GitopsView.hint(report, g, ctx)).toContain("E export · X export all")
		local item = { kind = "drift", source = DRIFT, item = "changed:apps/Deployment/tern-test-drift/web" }
		local hint = GitopsView.hint(item :: any, g, ctx)
		expect(hint).toContain("a apply")
		expect(hint).toContain("E export")
		expect((string.find(hint, "ctrl+d", 1, true))).toBeNil()
	end)
end)

-- GIT-F11/F13, EXP-B7: a Helm-managed object has no hand-written manifest;
-- `=` said "E exports it" although the repository's chart renders it, and
-- ctrl+g on a release picked a values file over the deployed values (which
-- alone reproduce --set) or, before the index existed, the whole chooser.
describe("explore gitops: Helm-managed objects", function()
	local HELM_NS = "tern-test-helm"
	local CHART = "/repo/helm/chart"
	local DEPLOYED = "helm:" .. CHART .. ":" .. HELM_NS .. "/shop-a:deployed"
	local SHOP_ROW = {
		name = "shop-a",
		namespace = HELM_NS,
		revision = 3,
		updated = "2026-01-01T00:03:00Z",
		updatedAt = nil,
		status = "deployed",
		chart = "shop-0.1.0",
		chartName = "shop",
		chartVersion = "0.1.0",
		appVersion = "1.27",
	} :: any

	local function managed(release: string, name: string): (any, Ref)
		local obj = {
			apiVersion = "v1",
			kind = "ConfigMap",
			metadata = {
				name = name,
				namespace = HELM_NS,
				labels = { ["app.kubernetes.io/managed-by"] = "Helm" },
				annotations = {
					["meta.helm.sh/release-name"] = release,
					["meta.helm.sh/release-namespace"] = HELM_NS,
				},
			},
		}
		return obj, { kind = "ConfigMap", namespace = HELM_NS, name = name, source = "live" }
	end

	local function world(files: { [string]: string }?): (World, Gitops.G, Gitops.Ctx)
		local w = G.new(files or G.helmFiles())
		local ctx = G.ctx(nil, HELM_NS)
		ctx.helm = G.HELM
		return w, G.ready(w, ctx), ctx
	end

	it("= on an object of a release diffs it against the detected chart's render", function()
		local w, g, ctx = world()
		local obj, ref = managed("shop-a", "web-shop-config")
		ctx.findObject = function(r: Ref): any
			return if r.name == ref.name then obj else nil
		end
		local route = { kind = "diff", ref = ref, doc = 1 } :: Gitops.Route
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("ok")
		expect((load.doc :: any).rendered).toBe(true)
		expect(driftOf(g, ctx, DEPLOYED) ~= nil).toBe(true)
		expect(find(G.lines(w), " template shop-a ") ~= nil).toBe(true)
	end)

	-- From a lens chip the diff route is pushed before the object view has
	-- read the object, so its Helm annotations were unknown and the diff
	-- said "No manifest declares ... E exports it" (seen live).
	it("= before the object is read reads it and goes to the chart", function()
		local w, g, ctx = world()
		local _, ref = managed("shop-a", "web-shop-config")
		ctx.findObject = function(): any
			return nil
		end
		w.answer = function(argv)
			local joined = table.concat(argv, " ")
			if string.find(joined, " get configmap web-shop-config ", 1, true) then
				return {
					status = 0,
					stdout = '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"web-shop-config",'
						.. '"namespace":"'
						.. HELM_NS
						.. '","annotations":{"meta.helm.sh/release-name":"shop-a",'
						.. '"meta.helm.sh/release-namespace":"'
						.. HELM_NS
						.. '"}}}',
					stderr = "",
					timed_out = false,
				}
			end
			return nil
		end
		local route = { kind = "diff", ref = ref, doc = 1 } :: Gitops.Route
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("ok")
		expect((load.doc :: any).rendered).toBe(true)
	end)

	it("an object of a release without a chart here says so instead of offering export", function()
		local w, g, ctx = world()
		local obj, ref = managed("web-b", "web-b-web-config")
		ctx.findObject = function(): any
			return obj
		end
		local route = { kind = "diff", ref = ref, doc = 1 } :: Gitops.Route
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, false, effects)
		end)
		local load = g.diffs[Gitops.diffId(route)]
		expect(load.status).toBe("nomatch")
		expect(load.helm).toBe(HELM_NS .. "/web-b")
		local GitopsView = require("../../../plugin/lib/gitops/view")
		local hint = GitopsView.hint(route, g, ctx)
		expect((string.find(hint, "a apply", 1, true))).toBeNil()
		expect((string.find(hint, "E export", 1, true))).toBeNil()
		w.toasts = {}
		step(w, g, ctx, function(effects)
			Gitops.openManifest(g, ctx, ref, effects)
		end)
		expect(G.toastTexts(w)[1]).toContain("Managed by Helm release " .. HELM_NS .. "/web-b")
	end)

	it("ctrl+g on a release prefers the deployed values of its best chart", function()
		local files = G.helmFiles()
		files["/repo/helm/values-shop-a.yaml"] = files["/repo/helm/values-staging.yaml"]
		local _, g, ctx = world(files)
		-- The file names the release: it outscores the deployed values.
		expect(table.find(Gitops.chartDirs(g)[1].valuesFiles, "/repo/helm/values-shop-a.yaml") ~= nil).toBe(true)
		expect(Gitops.releaseSource(g, ctx, SHOP_ROW)).toBe(DEPLOYED)
	end)

	it("ctrl+g before the index exists goes to the release's drift once the scan is done", function()
		local w = G.new(G.helmFiles())
		local ctx = G.ctx(nil, HELM_NS)
		ctx.helm = G.HELM
		local g = Gitops.new(G.ROOT)
		expect(Gitops.releaseSource(g, ctx, SHOP_ROW)).toBeNil()
		local chooser = { kind = "drift" } :: Gitops.Route
		expect(Gitops.takeNav(g, ctx, chooser)).toBeNil()
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, chooser, false, effects)
		end)
		expect(Gitops.takeNav(g, ctx, chooser)).toEqual({ replace = { kind = "drift", source = DEPLOYED } })
		-- Taken once: the user may go back to the chooser.
		expect(Gitops.takeNav(g, ctx, chooser)).toBeNil()
	end)

	it("a pending ctrl+g is dropped once the user left the chooser", function()
		local w = G.new(G.helmFiles())
		local ctx = G.ctx(nil, HELM_NS)
		ctx.helm = G.HELM
		local g = Gitops.new(G.ROOT)
		Gitops.releaseSource(g, ctx, SHOP_ROW)
		step(w, g, ctx, function(effects)
			Gitops.ensureIndex(g, ctx, effects)
		end)
		expect(Gitops.takeNav(g, ctx, { kind = "list" } :: any)).toBeNil()
		expect(Gitops.takeNav(g, ctx, { kind = "drift" } :: Gitops.Route)).toBeNil()
	end)

	-- GIT-F15: a chart shared by many releases matched every release of it
	-- cluster-wide, each twice; the chooser keeps the namespace in scope.
	it("the chooser hides chart guesses of other namespaces unless a release asked", function()
		local w = G.new(G.helmFiles())
		w.answer = function(argv)
			if argv[1] == G.HELM and table.find(argv, "list") then
				local list = fixtures.read("helm/captured/list.json")
				local other = string.gsub(list, '"namespace":"tern%-test%-helm"', '"namespace":"other-team"')
				return G.ok((string.gsub(list, "%]%s*$", "," .. string.sub(other, 2))))
			end
			return nil
		end
		local ctx = G.ctx(nil, HELM_NS)
		ctx.helm = G.HELM
		local g = G.ready(w, ctx)
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, { kind = "drift" } :: Gitops.Route, false, effects)
		end)
		local shown, hidden = Gitops.chooserSources(g, ctx)
		expect(hidden > 0).toBe(true)
		for _, s in shown do
			expect((string.find(s.id, "other-team", 1, true))).toBeNil()
		end
		local other = table.clone(SHOP_ROW)
		other.namespace = "other-team"
		local id = Gitops.releaseSource(g, ctx, other) :: string
		local again = Gitops.chooserSources(g, ctx)
		local found = false
		for _, s in again do
			found = found or s.id == id
		end
		expect(found).toBe(true)
		expect(Gitops.findSource(g, ctx, id) ~= nil).toBe(true)
	end)
end)

-- GIT-F12: after an apply or an export the report kept showing the old
-- diff, and `r` on it recompared against the old index (exported files
-- stayed unmanaged until the chooser's own `r`).
describe("explore gitops: freshness after apply and export", function()
	local REPORT = { kind = "drift", source = DRIFT } :: Gitops.Route

	local function report(): (World, Gitops.G, Gitops.Ctx)
		local w, g, ctx = setup()
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, REPORT, false, effects)
		end)
		expect(driftOf(g, ctx, DRIFT).status).toBe("ok")
		return w, g, ctx
	end

	local function diffRuns(w: World): number
		local n = 0
		for _, l in G.lines(w) do
			if string.find(l, " diff ", 1, true) then
				n += 1
			end
		end
		return n
	end

	it("an apply opened from the report marks it stale; returning to it compares again", function()
		local w, g, ctx = report()
		local items = Gitops.items(g, ctx, REPORT)
		G.press(w, g, ctx, REPORT, items[2], "a")
		expect(driftOf(g, ctx, DRIFT).stale).toBe(true)
		local GitopsView = require("../../../plugin/lib/gitops/view")
		-- The report shows it while the approve block is open.
		local body = GitopsView.body({
			g = g,
			gctx = ctx,
			route = REPORT,
			grid = function()
				return {}
			end,
			chip = function(text: string): any
				return { k = "text", p = { text = text } }
			end,
		} :: any)
		local nodes = require("../../lib/nodes")
		expect(nodes.text({ k = "col", p = {}, c = body } :: any)).toContain("Out of date")
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, REPORT, false, effects)
		end)
		expect(diffRuns(w)).toBe(1)
		local load = driftOf(g, ctx, DRIFT)
		expect(load.status).toBe("ok")
		expect(load.stale).toBeNil()
		-- Fresh again: a plain return does not compare once more.
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, REPORT, false, effects)
		end)
		expect(diffRuns(w)).toBe(0)
	end)

	it("r on a report rescans the manifests first, then compares", function()
		local w, g, ctx = report()
		w.effects = {}
		w.runs = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, REPORT, true, effects)
		end)
		expect(#ofType(w.effects, "scan")).toBe(1)
		expect(diffRuns(w)).toBe(1)
		expect(driftOf(g, ctx, DRIFT).status).toBe("ok")
	end)

	it("written export files are in the report when it is opened again", function()
		local w, g, ctx = report()
		local items = Gitops.items(g, ctx, REPORT)
		local _, nav = G.press(w, g, ctx, REPORT, items[8], "E")
		expect((nav :: any).push).toEqual({ kind = "export" })
		local route = { kind = "export" } :: Gitops.Route
		G.press(w, g, ctx, route, nil, "w")
		G.press(w, g, ctx, route, nil, "y")
		expect((g.export :: any).status).toBe("written")
		expect(driftOf(g, ctx, DRIFT).stale).toBe(true)
		w.effects = {}
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, REPORT, false, effects)
		end)
		expect(#ofType(w.effects, "scan")).toBe(1)
		local load = driftOf(g, ctx, DRIFT)
		expect(load.status).toBe("ok")
		expect((load.report :: any).counts.unmanaged).toBe(0)
	end)
end)

return nil
