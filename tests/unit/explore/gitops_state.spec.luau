--!strict
-- The GitOps keys of Explore (m, =, ctrl+g, E, x) and the lens chips' links
-- reach the GitOps routes from any list or object, scan only when asked,
-- and are never persisted: reopening a block must not rescan a repository
-- behind the user's back. Across contexts, every report belongs to the
-- context it ran against and nothing acts on another context.
local Gitops = require("../../../plugin/lib/explore/gitops")
local GitopsView = require("../../../plugin/lib/gitops/view")
local Link = require("../../../plugin/lib/mutation/link")
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local G = require("../../lib/gitops_world")
local W = require("../../lib/explore")
local X = require("../../lib/gitops_explore")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = Gitops.Effect

local APPS = X.APPS
local WEB = X.WEB
local world, env, drive, open, press, top, selectName, scans =
	X.world, X.env, X.drive, X.open, X.press, X.top, X.selectName, X.scans

describe("explore gitops keys", function()
	it("opening Explore never scans the repository", function()
		local w = world()
		local s = open(w)
		expect(top(s).kind).toBe("list")
		expect(scans(w)).toBe(0)
		expect(s.gitops.scan.status).toBe("idle")
	end)

	it("m on a row pushes the manifest view, indexes once and opens the file at the document", function()
		local w = world()
		local s = selectName(w, open(w), "web")
		s = press(w, s, "m")
		expect(top(s).kind).toBe("manifest")
		expect(((top(s).ref :: any) :: any).name).toBe("web")
		expect(scans(w)).toBe(1)
		expect(w.opened).toEqual({ "/repo/apps/web.yaml:1" })
		s = press(w, s, "m")
		expect(#s.stack).toBe(2)
		expect(scans(w)).toBe(1)
		expect(w.opened).toEqual({ "/repo/apps/web.yaml:1", "/repo/apps/web.yaml:1" })
	end)

	it("= pushes a diff of the focused object and runs it", function()
		local w = world()
		local s = selectName(w, open(w), "web")
		s = press(w, s, "=")
		local r = top(s)
		expect(r.kind).toBe("diff")
		expect(r.doc).toBe(1)
		local load = s.gitops.diffs[Gitops.diffId(r)]
		expect(load.status).toBe("ok")
		expect(w.diffInputs).toEqual({ WEB })
	end)

	it("ctrl+g opens the source chooser once; enter compares the selected source", function()
		local w = world()
		local s = open(w)
		s = press(w, s, "g", { ctrl = true })
		expect(top(s).kind).toBe("drift")
		expect(top(s).source).toBeNil()
		s = press(w, s, "g", { ctrl = true })
		expect(#s.stack).toBe(2)
		local first = State.selectedItem(s) :: any
		expect(first.key).toBe("dir:/repo/apps")
		s = press(w, s, "enter")
		expect(top(s).source).toBe("dir:/repo/apps")
		local id = Gitops.driftId(s.target, "dir:/repo/apps")
		expect(s.gitops.drifts[id].status).toBe("ok")
	end)

	it("E on a list exports every row; t edits the directory; the route survives esc only in memory", function()
		local w = world()
		local s = open(w)
		s = press(w, s, "E")
		expect(top(s).kind).toBe("export")
		local ex = s.gitops.export :: Gitops.ExportState
		expect(ex.label).toContain("deployments from " .. APPS)
		expect(ex.status).toBe("ok")
		-- Started before the index existed: the directory still defaults to
		-- where the objects' manifests live, never "".
		expect(ex.dir).toBe("/repo/apps")
		s = press(w, s, "t")
		expect(s.editing).toBe(true)
		expect(s.field).toBe("dir")
		for _ = 1, #ex.dir do
			s = press(w, s, "backspace")
		end
		for _, ch in string.split("out", "") do
			s = press(w, s, ch)
		end
		s = press(w, s, "enter")
		expect(s.editing).toBe(false)
		expect((s.gitops.export :: any).dir).toBe("/repo/out")
		local saved = State.save(s)
		expect(#saved.stack).toBe(1)
		expect(saved.stack[1].kind).toBe("list")
	end)

	it("the directory field takes native edits and undo; esc drops the draft and the focus", function()
		local w = world()
		local s = press(w, open(w), "E")
		local id = State.FIELD_INPUTS.dir
		-- A click in the unfocused field asks for focus, then edits arrive.
		s = X.action(w, s, "field-focus", "dir")
		expect(s.field).toBe("dir")
		local len = #"/repo/apps"
		s = State.update(s, { t = "edit", id = id, edit = { from = 6, to = len, text = "out", cursor = 9, len = len } })
		expect(Gitops.fieldValue(s.gitops, "dir")).toBe("/repo/out")
		s = press(w, s, "left")
		s = press(w, s, "x")
		expect(Gitops.fieldValue(s.gitops, "dir")).toBe("/repo/ouxt")
		s = State.update(s, { t = "undo", id = id })
		expect(Gitops.fieldValue(s.gitops, "dir")).toBe("/repo/out")
		local s2, effects = State.update(s, W.key("escape"))
		expect(effects).toEqual({ { t = "blur" } })
		expect(Gitops.fieldValue(s2.gitops, "dir")).toBe("/repo/apps")
		s = press(w, s, "enter")
		expect((s.gitops.export :: any).dir).toBe("/repo/out")
	end)

	it("E on a row's object view exports that object only", function()
		local w = world()
		local s = selectName(w, open(w), "web")
		s = press(w, s, "enter")
		expect(top(s).kind).toBe("detail")
		s = press(w, s, "E")
		local ex = s.gitops.export :: Gitops.ExportState
		expect(ex.label).toBe("deployment web")
		expect(ex.dir).toBe("/repo/apps")
		expect(#ex.objects).toBe(1)
	end)

	it("a: apply from the diff view goes to the approve block, never runs kubectl apply", function()
		local w = world()
		local s = selectName(w, open(w), "web")
		s = press(w, s, "=")
		press(w, s, "a")
		local req = Link.decode(w.opened[#w.opened]) :: Link.Request
		expect(req.op).toBe("apply")
		expect(req.file).toBe("/repo/apps/web.yaml")
		for _, l in G.lines(w) do
			expect((string.find(l, " apply", 1, true))).toBeNil()
		end
	end)

	it("lens chips: route=manifest / route=diff links land on those views after the object", function()
		local w = world()
		local s = open(w, { context = W.CTX, namespace = APPS, kind = "Deployment", name = "web", route = "diff" })
		expect(#s.stack).toBe(3)
		expect(top(s).kind).toBe("diff")
		expect(s.gitops.diffs[Gitops.diffId(top(s))].status).toBe("ok")
		local m =
			open(world(), { context = W.CTX, namespace = APPS, kind = "Deployment", name = "web", route = "manifest" })
		expect(top(m).kind).toBe("manifest")
		expect(Gitops.ready(m.gitops)).toBe(true)
	end)

	it("a cwd= link parameter sets the index root; a relative one is ignored", function()
		local s = State.init({ W.link({ context = W.CTX, cwd = "/elsewhere" }) }, nil, W.config(nil), env())
		expect(s.gitops.cwd).toBe("/elsewhere")
		local r = State.init({ W.link({ context = W.CTX, cwd = "rel" }) }, nil, W.config(nil), env())
		expect(r.gitops.cwd).toBe(G.ROOT)
	end)

	-- A plugin reload re-inits the block from saved state (Tern 0.9.14):
	-- manifest and diff are cheap reads and come back; drift, matrix, export
	-- and git hold work in progress and are cut with everything above them.
	it("saved state restores manifest routes and cuts drift and the rest", function()
		local w = world()
		local s = selectName(w, open(w), "web")
		s = press(w, s, "enter")
		s = press(w, s, "m")
		local saved = State.save(s)
		expect(#saved.stack).toBe(3)
		local w2 = world()
		local s2, effects = State.init({ W.link({ context = W.CTX }) }, saved, W.config(nil), env())
		s2 = drive(w2, s2, effects)
		expect(top(s2).kind).toBe("manifest")
		expect(scans(w2)).toBe(1)

		local d = press(w, s, "g", { ctrl = true })
		expect(top(d).kind).toBe("drift")
		expect(#State.save(d).stack).toBe(3)
	end)
	-- Explore's mutate keys are global, but GitOps views bind some of the
	-- same letters (export t, drift X, git p P e); inside those views the
	-- view's meaning wins and nothing mutates.
	it("view keys win inside GitOps views; on lists the same keys open mutate links", function()
		local function mutateOpens(effects: { State.Effect }): number
			local n = 0
			for _, e in effects do
				if e.t == "open" and string.sub(e.url or "", 1, #Link.SCHEME) == Link.SCHEME then
					n += 1
				end
			end
			return n
		end
		local w = world()
		local s = selectName(w, open(w), "web")
		local _, onList = State.update(s, W.key("t"))
		expect(mutateOpens(onList)).toBe(1)
		local _, patchList = State.update(s, W.key("X", { text = "X", shift = true }))
		expect(mutateOpens(patchList)).toBe(1)

		local ex = press(w, s, "E")
		expect(top(ex).kind).toBe("export")
		local inExport, effects = State.update(ex, W.key("t"))
		expect(inExport.field).toBe("dir")
		expect(mutateOpens(effects)).toBe(0)

		local d = press(w, open(w), "g", { ctrl = true })
		d = press(w, d, "enter")
		expect(top(d).kind).toBe("drift")
		local afterX, xEffects = State.update(d, W.key("X", { text = "X", shift = true }))
		expect(mutateOpens(xEffects)).toBe(0)
		expect(Gitops.isRoute(top(drive(w, afterX, xEffects)).kind)).toBe(true)
	end)

	-- The block hands its resolved helm to the GitOps routes: without it the
	-- chooser could never offer the repository's charts for live releases.
	it("ctrl+g lists auto-detected chart sources once helm is resolved", function()
		local w = X.helmWorld()
		local s = press(w, X.openHelm(w), "g", { ctrl = true })
		expect(top(s).kind).toBe("drift")
		expect(s.gitops.releases.status).toBe("ok")
		local id = "helm:/repo/helm/chart:tern-test-helm/shop-a:deployed"
		expect(Gitops.findSource(s.gitops, State.gitopsCtx(s), id) ~= nil).toBe(true)
	end)
end)

-- Explore pins the block's kubeconfig on every command (tests/lib/explore env).
local KC = "kubectl --kubeconfig /home/u/.kube/config"

-- The source of tests/fixtures/real/compare against kind-tern-kube-dev (A,
-- the block's context) and kind-tern-kube-dev2 (B).
local function mcWorld(extra: { string }?): G.World
	local w = G.mcWorld(extra)
	w.answer = X.world().answer
	return w
end

local function mcOpen(w: G.World, cfg: string?): State
	return X.open(w, { context = G.DEV, namespace = G.MC_NS, kind = "Deployment" }, cfg)
end

local function mcReport(w: G.World, cfg: string?): State
	local s = press(w, mcOpen(w, cfg), "g", { ctrl = true })
	return X.action(w, s, "open", G.MC_SOURCE)
end

-- The matrix of B against the source, chosen from the report with x.
local function mcMatrix(w: G.World, cfg: string?): State
	local s = press(w, mcReport(w, cfg), "x")
	return X.action(w, s, "open", "=" .. G.DEV2)
end

local function cells(s: State): { [string]: { string } }
	local mx = Gitops.matrix(s.gitops, State.gitopsCtx(s), top(s)) :: any
	local out: { [string]: { string } } = {}
	for _, row in mx.rows do
		local list: { string } = {}
		for i, c in row.cells do
			list[i] = c.state .. (if c.added then string.format(" +%d -%d", c.added, c.removed) else "")
		end
		out[row.ref.kind .. "/" .. row.ref.name] = list
	end
	return out
end

local function count(lines: { string }, needle: string): number
	local n = 0
	for _, l in lines do
		if string.find(l, needle, 1, true) then
			n += 1
		end
	end
	return n
end

describe("explore gitops: one source across contexts", function()
	it("x on a drift report picks a context, runs the source there pinned, and fills the matrix", function()
		local w = mcWorld()
		local s = press(w, mcReport(w), "x")
		expect(top(s).kind).toBe("matrix")
		expect(top(s).across).toBeNil()
		local picks: { string } = {}
		for _, item in State.items(s) do
			table.insert(picks, item.key)
		end
		expect(picks).toEqual({ "=" .. G.DEV2, "*" })
		s = X.action(w, s, "open", "=" .. G.DEV2)
		expect(top(s).across).toBe("=" .. G.DEV2)
		local lines = G.lines(w)
		expect(lines).toContain(KC .. " config view -o json")
		expect(lines).toContain(KC .. " --context " .. G.DEV2 .. " diff -f /repo/mc/app.yaml")
		expect(lines).toContain(
			KC .. " --context " .. G.DEV2 .. " get configmap,deployment.apps,service -n " .. G.MC_NS .. " -o json"
		)
		-- The block's own report is reused, not run again.
		expect(count(lines, "--context " .. G.DEV .. " diff ")).toBe(1)
		expect(cells(s)).toEqual({
			["Deployment/tkm-web"] = { "insync", "changed +4 -3" },
			["Deployment/tkm-api"] = { "insync", "insync" },
			["Service/tkm-web"] = { "insync", "insync" },
			["ConfigMap/tkm-config"] = { "insync", "changed +1 -1" },
			["ConfigMap/tkm-flags"] = { "insync", "missing" },
			["Deployment/tkm-only-a"] = { "unmanaged", "absent" },
			["Deployment/tkm-only-b"] = { "absent", "unmanaged" },
		})
		local text = nodes.text(Render.view(s, 160, 60).main :: any)
		expect(text).toContain("changed +4 -3")
		expect(text).toContain("namespace " .. G.MC_NS)
		expect(text).toContain("2 changed, 1 missing, 1 unmanaged")
	end)

	-- The drill-in is the existing drift item view, read from B's load.
	it("enter on a cell opens that context's drift item; nothing there acts on it", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		s = X.action(w, s, "open", "/ConfigMap/" .. G.MC_NS .. "/tkm-flags")
		local r = top(s)
		expect(r.kind).toBe("drift")
		expect(r.item).toBe("missing:/ConfigMap/" .. G.MC_NS .. "/tkm-flags")
		expect(r.context).toBe(G.DEV2)
		local load = Gitops.driftLoad(s.gitops, State.gitopsCtx(s), r) :: Gitops.DriftLoad
		expect(load.target.context).toBe(G.DEV2)
		local text = nodes.text(Render.view(s, 160, 60).main :: any)
		expect(text).toContain("in context " .. G.DEV2)
		expect(text).toContain("Read-only")
		expect(State.focusRef(s)).toBeNil()
		for _, k in { { "a" }, { "E" }, { "d", "ctrl" } } do
			local extra = if k[2] then { ctrl = true } else nil
			local _, effects = State.update(s, W.key(k[1], extra))
			local opens = 0
			local toastText = ""
			for _, e in effects do
				if e.t == "open" then
					opens += 1
				elseif e.t == "toast" then
					toastText = e.text or ""
				end
			end
			expect(opens).toBe(0)
			expect(toastText).toBe("Switch to " .. G.DEV2 .. " (c) to change it")
		end
		expect(GitopsView.hint(r)).toContain("read-only")
	end)

	it("a on the matrix is refused for another context's column too", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		local _, effects = State.update(s, W.key("a"))
		expect(#effects).toBe(1)
		expect(effects[1].text).toBe("Switch to " .. G.DEV2 .. " (c) to change it")
	end)

	-- After `c` the block's report is a different load: the old context's
	-- report must neither be shown for the new one nor be lost.
	it("drift loads are keyed per context and survive a context switch", function()
		local w = G.mcWorld()
		local ctxA = G.ctx(nil, G.MC_NS)
		local g = G.ready(w, ctxA)
		local route = { kind = "drift", source = G.MC_SOURCE } :: Gitops.Route
		local effects: { Effect } = {}
		Gitops.enter(g, ctxA, route, false, effects)
		G.core(w, g, ctxA, effects)
		local a = Gitops.driftLoad(g, ctxA, route) :: Gitops.DriftLoad
		expect((a.report :: any).counts.changed).toBe(0)

		local ctxB = table.clone(ctxA)
		ctxB.target = table.clone(ctxA.target)
		ctxB.target.context = G.DEV2
		expect(Gitops.driftLoad(g, ctxB, route)).toBeNil()
		effects = {}
		Gitops.enter(g, ctxB, route, false, effects)
		G.core(w, g, ctxB, effects)
		local b = Gitops.driftLoad(g, ctxB, route) :: Gitops.DriftLoad
		expect((b.report :: any).counts.changed).toBe(2)
		expect(b.argv).toEqual({ "kubectl", "--context", G.DEV2, "diff", "-f", "/repo/mc/app.yaml" })
		expect(Gitops.driftLoad(g, ctxA, route)).toBe(a)
	end)

	it("contexts run at most compare.max_parallel at a time; a failing one is an error column", function()
		local w = G.mcWorld({ G.DOWN })
		local ctx = G.ctx('{"compare":{"max_parallel":1}}', G.MC_NS)
		local g = G.ready(w, ctx)
		local picker = { kind = "matrix", source = G.MC_SOURCE } :: Gitops.Route
		local effects: { Effect } = {}
		Gitops.enter(g, ctx, picker, false, effects)
		G.core(w, g, ctx, effects)
		local route = { kind = "matrix", source = G.MC_SOURCE, across = "*" } :: Gitops.Route
		effects = {}
		Gitops.enter(g, ctx, route, false, effects)
		local diffs = 0
		for _, e in effects do
			if e.t == "run" and table.find(e.argv :: { string }, "diff") then
				diffs += 1
			end
		end
		expect(diffs).toBe(1)
		G.core(w, g, ctx, effects)
		local mx = Gitops.matrix(g, ctx, route) :: any
		local status: { string } = {}
		for i, c in mx.columns do
			status[i] = c.context .. " " .. c.status
		end
		expect(status).toEqual({ G.DEV .. " ok", G.DOWN .. " error", G.DEV2 .. " ok" })
		expect(mx.columns[2].error).toContain("connection to the server 127.0.0.1:1 was refused")
		expect(mx.rows[1].cells[2].state).toBe("error")
	end)

	it("r re-runs every column; Y copies every pinned command; x chooses again", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		w.runs = {}
		s = press(w, s, "r")
		local lines = G.lines(w)
		expect(count(lines, "--context " .. G.DEV .. " diff ")).toBe(1)
		expect(count(lines, "--context " .. G.DEV2 .. " diff ")).toBe(1)
		local _, effects = State.update(s, W.key("Y", { text = "Y", shift = true }))
		local copied = ""
		for _, e in effects do
			if e.t == "copy" then
				copied = e.text or ""
			end
		end
		expect(string.split(copied, "\n")).toEqual({
			KC .. " --context " .. G.DEV .. " diff -f /repo/mc/app.yaml",
			KC .. " --context " .. G.DEV .. " get configmap,deployment.apps,service -n " .. G.MC_NS .. " -o json",
			KC .. " --context " .. G.DEV2 .. " diff -f /repo/mc/app.yaml",
			KC .. " --context " .. G.DEV2 .. " get configmap,deployment.apps,service -n " .. G.MC_NS .. " -o json",
		})
		local again = press(w, s, "x")
		expect(top(again).kind).toBe("matrix")
		expect(top(again).across).toBeNil()
		expect(#again.stack).toBe(#s.stack)
	end)

	it("f filters drifted rows; [ ] move the selected column", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		expect(#State.items(s)).toBe(7)
		s = press(w, s, "f")
		expect(#State.items(s)).toBe(5)
		expect(Gitops.matrixColumn(s.gitops, State.gitopsCtx(s), top(s))).toBe(G.DEV2)
		s = press(w, s, "]")
		expect(top(s).context).toBe(G.DEV)
		s = press(w, s, "[")
		expect(top(s).context).toBe(G.DEV2)
	end)

	it("matrix routes are never saved and their hints name every key", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		local saved = State.save(s)
		for _, r in saved.stack do
			expect(Gitops.isRoute(r.kind)).toBe(false)
		end
		local hint = GitopsView.hint(top(s))
		for _, k in { "enter", "[ ]", "f filter", "x contexts", "Y copy", "r again" } do
			expect(hint).toContain(k)
		end
		expect(GitopsView.hint({ kind = "drift", source = G.MC_SOURCE })).toContain("x across contexts")
	end)
end)

-- The last text a copy effect put on the clipboard.
local function copied(w: G.World): string?
	local text: string? = nil
	for _, e in w.effects do
		if e.t == "copy" then
			text = e.text
		end
	end
	return text
end

-- A source of namespace-less manifests: apps/web.yaml and apps/sub/cm.yaml.
local CLI_SOURCE = "dir:/repo/cli"
local NSLESS_WEB = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 1\n"
local NSLESS_CM = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: app\ndata:\n  a: b\n"

local function cliWorld(listing: string, extra: { [string]: string }?): G.World
	local files = {
		["/repo/cli/web.yaml"] = NSLESS_WEB,
		["/repo/cli/sub/cm.yaml"] = NSLESS_CM,
	}
	for path, text in (extra or {}) :: { [string]: string } do
		files[path] = text
	end
	local w = G.new(files)
	w.answer = function(argv: { string }): G.Result?
		if argv[1] == "git" and table.find(argv, "ls-files") then
			return G.ok(listing)
		elseif argv[1] == "kubectl" and table.find(argv, "diff") then
			return G.ok("")
		end
		return nil
	end
	return w
end

local function cliReport(w: G.World, ns: string?): (Gitops.G, Gitops.Ctx, Gitops.Route)
	local ctx = G.ctx(nil, ns or "team")
	local g = G.ready(w, ctx)
	local route = { kind = "drift", source = CLI_SOURCE } :: Gitops.Route
	local effects: { Effect } = {}
	Gitops.enter(g, ctx, route, false, effects)
	G.core(w, g, ctx, effects)
	return g, ctx, route
end

describe("explore gitops: Copy CLI command", function()
	-- Probe E/F: without -n the namespace-less documents were diffed in the
	-- kubeconfig's namespace while the report resolved them in the block's.
	it("namespace-less documents are diffed with -n of the block's namespace", function()
		local w = cliWorld("cli/web.yaml\0cli/sub/cm.yaml\0")
		local g, ctx, route = cliReport(w)
		local load = Gitops.driftLoad(g, ctx, route) :: Gitops.DriftLoad
		expect(load.argv).toEqual({
			"kubectl",
			"--context",
			G.CTX,
			"diff",
			"-f",
			"/repo/cli/sub/cm.yaml",
			"-f",
			"/repo/cli/web.yaml",
			"-n",
			"team",
		})
	end)

	it("Y on a report copies the command; -R when git lists exactly the compared files", function()
		local w = cliWorld("cli/web.yaml\0cli/sub/cm.yaml\0cli/README.md\0")
		local g, ctx, route = cliReport(w)
		local handled = G.press(w, g, ctx, route, nil, "Y")
		expect(handled).toBe(true)
		expect(copied(w)).toBe(
			"tern-kube-drift -R -f /repo/cli --context " .. G.CTX .. " -n team --unmanaged configmap,deployment.apps"
		)
		local toasts = G.toastTexts(w)
		expect(toasts[#toasts]).toContain("Copied tern-kube-drift command")
		expect(toasts[#toasts]).toContain("No --kubeconfig: the command uses your shell's KUBECONFIG")
	end)

	-- kubectl -R would also read the .json and the ignored file (probes D, G4).
	it("anything else under the directory kubectl reads: explicit -f files", function()
		local w = cliWorld("cli/web.yaml\0cli/sub/cm.yaml\0cli/extra.json\0")
		local g, ctx, route = cliReport(w)
		G.press(w, g, ctx, route, nil, "Y")
		expect(copied(w)).toBe(
			"tern-kube-drift -f /repo/cli/sub/cm.yaml -f /repo/cli/web.yaml --context "
				.. G.CTX
				.. " -n team --unmanaged configmap,deployment.apps"
		)
	end)

	it("Y on a drift item copies the same command", function()
		local w = cliWorld("cli/web.yaml\0cli/sub/cm.yaml\0")
		local g, ctx = cliReport(w)
		local item = { kind = "drift", source = CLI_SOURCE, item = "missing:/ConfigMap/team/app" } :: Gitops.Route
		G.press(w, g, ctx, item, nil, "Y")
		expect(copied(w)).toContain("tern-kube-drift -R -f /repo/cli ")
	end)

	it("mixed namespaces: no -n, a report note and the same note on the copy", function()
		local other = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: o\n  namespace: other\n"
		local w = cliWorld("", { ["/repo/cli/other.yaml"] = other })
		local g, ctx, route = cliReport(w)
		local load = Gitops.driftLoad(g, ctx, route) :: Gitops.DriftLoad
		expect(table.find(load.argv :: { string }, "-n")).toBeNil()
		local note = "2 documents without a namespace are compared in the kubeconfig's namespace: "
			.. "kubectl cannot combine -n with documents of other namespaces"
		expect((load.report :: any).notes).toContain(note)
		G.press(w, g, ctx, route, nil, "Y")
		expect((string.find(copied(w) or "", " -n ", 1, true))).toBeNil()
		local toasts = G.toastTexts(w)
		expect(toasts[#toasts]).toContain(note)
	end)

	-- The CLI reads only its source: an object another source declares is
	-- unmanaged there, hidden here.
	it("names objects declared elsewhere that the CLI lists as unmanaged", function()
		local w = cliWorld("cli/web.yaml\0cli/sub/cm.yaml\0", {
			["/repo/other/cm.yaml"] = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: shared\n  namespace: team\n",
		})
		local inner = w.answer :: any
		w.answer = function(argv: { string }, e: Effect): G.Result?
			if argv[1] == "kubectl" and table.find(argv, "get") and table.find(argv, "-n") then
				return G.ok(
					'{"items":[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"shared","namespace":"team"}}]}'
				)
			end
			return inner(argv, e)
		end
		local g, ctx, route = cliReport(w)
		local load = Gitops.driftLoad(g, ctx, route) :: Gitops.DriftLoad
		expect((load.report :: any).declaredElsewhere).toEqual({ "/ConfigMap/team/shared" })
		G.press(w, g, ctx, route, nil, "Y")
		local toasts = G.toastTexts(w)
		expect(toasts[#toasts]).toContain(
			"The CLI also lists 1 object declared elsewhere in this repository as unmanaged: configmap/shared"
		)
	end)

	it("the matrix chip copies every column in order, pinned to the block's kubeconfig", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		s = X.action(w, s, "gitops-copycli", "")
		expect(copied(w)).toBe(
			"tern-kube-drift -f /repo/mc/app.yaml --context "
				.. G.DEV
				.. " --context "
				.. G.DEV2
				.. " --kubeconfig /home/u/.kube/config --unmanaged configmap,deployment.apps,service"
		)
		-- Y in the matrix keeps copying the kubectl commands it ran.
		local _, effects = State.update(s, W.key("Y", { text = "Y", shift = true }))
		for _, e in effects do
			if e.t == "copy" then
				expect(e.text).toContain("kubectl --kubeconfig")
			end
		end
		local text = nodes.text(Render.view(s, 200, 60).main :: any)
		expect(text).toContain("Copy CLI command")
	end)

	-- tern-kube-drift renders charts only with values files; a copy that
	-- silently used the chart defaults would report something else.
	it("refuses an auto Helm source rendered with the deployed values", function()
		local w = X.helmWorld()
		local s = press(w, X.openHelm(w), "g", { ctrl = true })
		local id = "helm:/repo/helm/chart:tern-test-helm/shop-a:deployed"
		s = X.action(w, s, "open", id)
		expect(top(s).source).toBe(id)
		w.effects = {}
		w.toasts = {}
		s = press(w, s, "Y", { shift = true })
		expect(copied(w)).toBeNil()
		expect(w.toasts[1].level).toBe("error")
		expect(w.toasts[1].sub).toBe(Gitops.CLI_DEPLOYED)
	end)
end)

describe("explore gitops: Argo CD / Flux status per target", function()
	local function tracked(): any
		for _, o in json.decode(fixtures.read("drift/controllers/workloads.json")).items do
			local labels = o.metadata.labels or {}
			if labels["app.kubernetes.io/instance"] == "guestbook" then
				return o
			end
		end
		error("no guestbook object")
	end

	-- Bug 1.3-2: one cache for every context labelled cluster B's objects
	-- with cluster A's controllers.
	it("controllers are read and kept per target; another context has none until read", function()
		local w = G.new()
		local ctxA = G.ctx(nil, "tern-test-gitops")
		local g = G.ready(w, ctxA)
		local effects: { Effect } = {}
		Gitops.noticeObject(g, ctxA, tracked(), effects)
		G.core(w, g, ctxA, effects)
		expect((Gitops.owner(g, ctxA, tracked()) :: any).name).toBe("guestbook")
		local ctxB = table.clone(ctxA)
		ctxB.target = table.clone(ctxA.target)
		ctxB.target.context = G.DEV2
		expect(Gitops.ctl(g, ctxB)).toBeNil()
		expect(Gitops.owner(g, ctxB, tracked())).toBeNil()
	end)

	it("r on the chooser and forgetControllers (r on an object) read them again", function()
		local w = G.new()
		local ctx = G.ctx(nil, "tern-test-gitops")
		local g = G.ready(w, ctx)
		local function apiRuns(): number
			return count(G.lines(w), " api-resources ")
		end
		local effects: { Effect } = {}
		Gitops.enter(g, ctx, { kind = "drift" }, false, effects)
		G.core(w, g, ctx, effects)
		expect(apiRuns()).toBe(1)
		effects = {}
		Gitops.enter(g, ctx, { kind = "drift" }, false, effects)
		G.core(w, g, ctx, effects)
		expect(apiRuns()).toBe(1)
		effects = {}
		Gitops.enter(g, ctx, { kind = "drift" }, true, effects)
		G.core(w, g, ctx, effects)
		expect(apiRuns()).toBe(2)
		Gitops.forgetControllers(g, ctx)
		effects = {}
		Gitops.noticeObject(g, ctx, tracked(), effects)
		G.core(w, g, ctx, effects)
		expect(apiRuns()).toBe(3)
	end)

	it("a list that fails is a note, not silently dropped", function()
		local w = G.new()
		w.answer = function(argv: { string }): G.Result?
			if table.find(argv, "applications.argoproj.io") then
				return G.fail(
					1,
					'Error from server (Forbidden): applications.argoproj.io is forbidden: User "u" cannot list'
				)
			end
			return nil
		end
		local ctx = G.ctx(nil, "tern-test-gitops")
		local g = G.ready(w, ctx)
		local effects: { Effect } = {}
		Gitops.loadControllers(g, ctx, effects)
		G.core(w, g, ctx, effects)
		local set = Gitops.ctlSet(g, ctx) :: any
		expect(set.notes).toContain(
			'cannot list applications.argoproj.io: Error from server (Forbidden): applications.argoproj.io is forbidden: User "u" cannot list'
		)
	end)

	-- A matrix column of another context never reads controllers and never
	-- borrows the block's.
	it("a foreign drift item has no controller unless that target's set is loaded", function()
		local w = mcWorld()
		local s = mcMatrix(w)
		local lines = G.lines(w)
		expect(count(lines, "--context " .. G.DEV2 .. " api-resources")).toBe(0)
		local ctxB = State.gitopsCtx(s)
		ctxB.target = table.clone(ctxB.target)
		ctxB.target.context = G.DEV2
		expect(Gitops.ctl(s.gitops, ctxB)).toBeNil()
	end)
end)

return nil
