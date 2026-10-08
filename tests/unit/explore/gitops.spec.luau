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
	assert(req, "not a kube-lens link: " .. tostring(url))
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

	it("a finished scan reads the remotes, then git status of the manifest files", function()
		local w, g = setup()
		expect(Gitops.ready(g)).toBe(true)
		expect(G.lines(w)).toEqual({
			"git -C /repo remote -v",
			"git -C /repo status --porcelain=v1 -z -- *.yaml *.yml *Kustomization",
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
		expect(lines[1]).toBe("/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " kube-lens-tmp " .. tmp)
		expect(Gitops.WRITE_SCRIPT).toContain("umask 077")
		expect(lines[2]).toBe("kubectl --context kind-kube-lens-dev diff -f " .. tmp)
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

	it("a failing kubectl diff is an error and the temporary file is still removed", function()
		local w, g, ctx = setup()
		w.answer = function(argv)
			return if table.find(argv, "diff") then G.fail(2, "error: the server is unreachable\nmore") else nil
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
		expect(G.lines(w)).toEqual({ "/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " kube-lens-tmp " .. tmp })
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
		return w, g, ctx, g.drifts[DRIFT]
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
			expect(G.lines(w)[1]).toBe("kubectl --context kind-kube-lens-dev api-resources -o name")
			expect(g.ctl.status).toBe("ok")
			local items = Gitops.items(g, ctx, { kind = "drift" })
			local _, nav = G.press(w, g, ctx, { kind = "drift" }, items[2], "enter")
			expect((nav :: any).push).toEqual({ kind = "drift", source = "dir:/repo/drift/baseline" })
		end
	)

	it("a directory source diffs exactly its files and lists its kinds in its namespaces, pinned", function()
		local w = report()
		expect(G.lines(w)).toEqual({
			"kubectl --context kind-kube-lens-dev get configmap,deployment.apps,service,serviceaccount,widget.lens.example.com -n "
				.. NS
				.. " -o json",
			"kubectl --context kind-kube-lens-dev diff -f /repo/drift/baseline/app.yaml -f /repo/drift/baseline/service.yaml -f /repo/drift/baseline/widgets.yaml -f /repo/drift/namespace.yaml -f /repo/drift/pending/extra.yaml",
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
			local load = g.drifts[DRIFT]
			table.insert(seen, load.filter .. " " .. #Gitops.items(g, ctx, route))
		end
		expect(seen).toEqual({ "changed 4", "missing 3", "unmanaged 1", "all 8" })
		Gitops.setFilter(g, DRIFT, "missing")
		step(w, g, ctx, function(effects)
			Gitops.enter(g, ctx, route, true, effects)
		end)
		expect(g.drifts[DRIFT].filter).toBe("missing")
		expect(g.drifts[DRIFT].status).toBe("ok")
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
		local load = g.drifts[DRIFT]
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
		expect(g.drifts[DRIFT].status).toBe("error")
		expect(g.drifts[DRIFT].error).toBe("kubectl diff exited 1: error: unable to recognize (no differences printed)")

		local w2, g2, ctx2 = setup()
		w2.answer = function(argv)
			return if table.find(argv, "get") then G.fail(1, "Forbidden") else nil
		end
		step(w2, g2, ctx2, function(effects)
			Gitops.startDriftReport(g2, ctx2, DRIFT, false, effects)
		end)
		local load = g2.drifts[DRIFT]
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
		expect(find(lines, "/bin/sh -c")).toBe("/bin/sh -c " .. Gitops.WRITE_SCRIPT .. " kube-lens-tmp " .. tmp)
		expect(find(lines, " diff ")).toBe("kubectl --context kind-kube-lens-dev diff -f " .. tmp)
		expect(w.removed).toEqual({ tmp })
		expect(g.drifts[id :: string].status).toBe("ok")
		local _, nav = G.press(w, g, ctx, { kind = "drift", source = id }, nil, "X")
		expect(nav).toBeNil()
		expect(G.toastTexts(w)[1]).toContain("Charts are not exported")
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
			"kubectl --context kind-kube-lens-dev diff -k /repo/kustomize/overlays/staging"
		)
		G.press(w, g, ctx, { kind = "drift", source = id }, nil, "A")
		local req = decodeOpen(w)
		expect(req.kustomize).toBe("/repo/kustomize/overlays/staging")
		expect(req.file).toBeNil()
	end)

	it("the drift summary is a markdown table per entry", function()
		local _, _, _, load = report()
		local md = Gitops.driftSummary(load, G.CTX)
		expect(md).toContain("Drift of `drift/` against context `kind-kube-lens-dev` (kube-lens).")
		expect(md).toContain("4 changed, 3 missing in cluster, 1 unmanaged, 2 in sync.")
		expect(md).toContain("| Deployment tern-test-drift/web | changed | +2 -2 |")
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
		expect(G.lines(w)[1]).toContain("git -C /repo status --porcelain=v1 -z --")
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
			"git -C /repo status --porcelain=v1 -z",
			"git -C /repo rev-parse --abbrev-ref HEAD",
			"git -C /repo remote",
			'/bin/sh -c command -v -- "$1" sh gh',
		})
		local git = g.git :: Gitops.GitState
		expect(git.status).toBe("ready")
		expect(git.push).toBe(false)
		expect(git.pr).toBe(false)
		expect(git.branch).toBe("kube-lens/1-object-from-drift-19700101-001640")
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
		expect(Gitops.validBranch("kube-lens/export-1")).toBe(true)
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

return nil
