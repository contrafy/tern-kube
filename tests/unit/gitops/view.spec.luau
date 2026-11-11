--!strict
-- What the GitOps views show decides what the user writes to their repo
-- and applies to their cluster: where a manifest is (file:line, git state),
-- what kubectl actually ran, which bucket each drifted object is in, which
-- files an export creates or modifies (with the diff) before anything is
-- written, the exact git commands, and why they are blocked. Rendered
-- through the real Explore render so selection, chips and paging match.
local Controllers = require("../../../plugin/lib/gitops/controllers")
local Gitops = require("../../../plugin/lib/explore/gitops")
local GitopsView = require("../../../plugin/lib/gitops/view")
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local G = require("../../lib/gitops_world")
local X = require("../../lib/gitops_explore")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State

local DRIFT = "dir:/repo/drift"

local function body(s: State): nodes.Node
	local main = Render.view(s, 160, 60).main :: any
	return nodes.find(main, nodes.role("tern-kube.explore-" .. X.top(s).kind)) :: nodes.Node
end

local function dockText(s: State): string
	return nodes.text(Render.view(s, 160, 60).dock :: any)
end

-- Row ids of the native tables in `b`: Tern sends `open` with the id on
-- activation, so the id is what a row opens.
local function rowIds(b: nodes.Node): { string }
	local out: { string } = {}
	for _, tbl in nodes.findAll(b, nodes.kind("table")) do
		for _, row in (tbl.p :: any).rows do
			table.insert(out, row.id)
		end
	end
	return out
end

local function onWeb(w: G.World, cfg: string?): State
	return X.selectName(w, X.open(w, nil, cfg), "web")
end

local function driftReport(w: G.World, cfg: string?): State
	local s = X.press(w, X.open(w, nil, cfg), "g", { ctrl = true })
	return X.action(w, s, "open", DRIFT)
end

describe("gitops view: manifest", function()
	it("lists each match with file, lines, source and git state, and offers open / diff / rescan", function()
		local w = X.world()
		local s = X.press(w, onWeb(w), "m")
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("manifests in ")
		expect(text).toContain("under /repo")
		expect(text).toContain("1 manifest declares deployment/web -n " .. X.APPS)
		expect(text).toContain("apps/web.yaml")
		expect(text).toContain("1-7")
		expect(text).toContain("clean")
		local actions = nodes.actions(b)
		expect(rowIds(b)).toContain("/repo/apps/web.yaml:1")
		expect(actions).toContain("gitops-key=m")
		expect(actions).toContain("gitops-diff=1")
		expect(actions).toContain("refresh")
		expect(dockText(s)).toContain("m open at line")
	end)

	it("an object without a manifest says so and offers export", function()
		local w = X.world()
		local s = X.press(w, X.selectName(w, X.open(w), "broken-image"), "m")
		local b = body(s)
		expect(nodes.find(b, nodes.role("tern-kube.gitops-none")) ~= nil).toBe(true)
		expect(nodes.actions(b)).toContain("gitops=export")
	end)

	it("a failed index shows the error instead of an empty list", function()
		local w = X.world()
		w.scanError = "git ls-files exited 128: fatal: bad object"
		local s = X.press(w, onWeb(w), "m")
		local err = nodes.find(body(s), nodes.role("tern-kube.error")) :: nodes.Node
		expect(nodes.text(err)).toBe("Manifest index failed: git ls-files exited 128: fatal: bad object")
	end)

	it("a modified manifest file shows its git state", function()
		local w = X.world()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if argv[1] == "git" and G.gitVerb(argv) == "status" and table.find(argv, "--") then
					return G.ok(" M apps/web.yaml\0")
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = X.press(w, onWeb(w), "m")
		expect(nodes.text(body(s))).toContain("modified")
	end)
end)

describe("gitops view: diff", function()
	it("in sync is said plainly, with the exact kubectl argv that ran", function()
		local w = X.world()
		local s = X.press(w, onWeb(w), "=")
		local b = body(s)
		expect(nodes.find(b, nodes.role("tern-kube.gitops-insync")) ~= nil).toBe(true)
		expect(nodes.text(b)).toContain("Live deployment/web -n " .. X.APPS .. " vs apps/web.yaml")
		expect(nodes.text(b)).toContain("--context kind-tern-kube-dev diff -f /data/tmp/diff-1000-")
		expect(nodes.actions(b)).toContain("gitops-key=a")
	end)

	it("differences are per-resource cards with the hunks; no apply chip when mutations are off", function()
		local w = X.world()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if table.find(argv, "diff") then
					return G.capturedDiff("drift/baseline/app.yaml")
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = X.press(w, onWeb(w, '{"mutations":{"enabled":false}}'), "=")
		local b = body(s)
		local cards = nodes.findAll(b, nodes.role("tern-kube.gitops-diff"))
		expect(#cards).toBe(2)
		expect(nodes.text(cards[1])).toContain("MODIFY")
		expect(nodes.text(cards[1])).toContain("-  replicas: 2")
		expect(table.find(nodes.actions(b), "gitops-key=a")).toBeNil()
	end)

	it("errors are shown as errors", function()
		local w = X.world()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if table.find(argv, "diff") then
					return G.fail(2, "error: Unauthorized")
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = X.press(w, onWeb(w), "=")
		local err = nodes.find(body(s), nodes.role("tern-kube.error")) :: nodes.Node
		expect(nodes.text(err)).toBe("kubectl diff exited 2: error: Unauthorized")
	end)
end)

describe("gitops view: drift", function()
	it("the chooser is a grid of sources with type, docs and namespaces", function()
		local w = X.world()
		local s = X.press(w, X.open(w), "g", { ctrl = true })
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("4 sources · enter compares one with the cluster")
		expect(text).toContain("drift/baseline/")
		expect(text).toContain("directory")
		expect(rowIds(b)).toContain(DRIFT)
		expect(dockText(s)).toContain("enter open")
	end)

	it("the report counts every bucket as a filter chip and lists entries with their manifest", function()
		local w = X.world()
		local s = driftReport(w)
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("Drift of drift/")
		expect(text).toContain("All 8")
		expect(text).toContain("Changed 4")
		expect(text).toContain("Missing in cluster 3")
		expect(text).toContain("Unmanaged 1")
		expect(text).toContain("in sync 2")
		expect(text).toContain("drift/baseline/app.yaml:29")
		expect(text).toContain("hand-made")
		local actions = nodes.actions(b)
		expect(actions).toContain("gitops-filter=unmanaged")
		expect(actions).toContain("gitops-key=A")
		expect(actions).toContain("gitops-key=X")
		s = X.action(w, s, "gitops-filter", "unmanaged")
		local filtered = nodes.text(body(s))
		expect(filtered).toContain("hand-made")
		expect((string.find(filtered, "only-in-git", 1, true))).toBeNil()
		expect(dockText(s)).toContain("f filter")
	end)

	it("a drilled-in missing entry says why; an unmanaged one offers export and delete", function()
		local w = X.world()
		local s = driftReport(w)
		local missing = X.action(w, s, "open", "missing:/ConfigMap/tern-test-drift/only-in-git")
		expect(nodes.text(body(missing))).toContain("kubectl diff would create it.")
		expect(nodes.text(body(missing))).toContain("drift/pending/extra.yaml")
		expect(table.find(nodes.actions(body(missing)), "gitops-key=E")).toBeNil()
		local unmanaged = X.action(w, s, "open", "unmanaged:/ConfigMap/tern-test-drift/hand-made")
		local actions = nodes.actions(body(unmanaged))
		expect(actions).toContain("gitops-key=E")
		expect(actions).toContain("mutate=delete")
		expect(dockText(unmanaged)).toContain("ctrl+d delete")
	end)

	-- GIT-F1: kubectl masks Secret values, so the report itself must say a
	-- manifest still holds the export placeholder. GIT-F6: with two
	-- declarations the diff is of one of them only; the row must not pretend
	-- it is the first file's.
	it("marks export placeholders and ambiguous declarations", function()
		local w = X.world()
		w.files["/repo/drift/secret.yaml"] = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: db\n"
			.. "  namespace: tern-test-drift\nstringData:\n  password: REPLACE_ME\n"
		w.files["/repo/drift/zz-dup.yaml"] = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: app-config\n"
			.. "  namespace: tern-test-drift\ndata:\n  LOG_LEVEL: debug\n"
		local s = driftReport(w)
		local text = nodes.text(body(s))
		expect(text).toContain("ambiguous: 2 manifests")
		expect(text).toContain("placeholder")
		local secret = X.action(w, s, "open", "missing:/Secret/tern-test-drift/db")
		local stext = nodes.text(body(secret))
		expect(stext).toContain("Placeholder: password still holds REPLACE_ME from an export")
		local dup = X.action(w, s, "open", "changed:/ConfigMap/tern-test-drift/app-config")
		expect(nodes.text(body(dup))).toContain("Ambiguous: 2 documents declare this object")
	end)

	it("a drift error is shown as an error", function()
		local w = X.world()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if table.find(argv, "diff") then
					return G.fail(2, "error: connection refused")
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = driftReport(w)
		local err = nodes.find(body(s), nodes.role("tern-kube.error")) :: nodes.Node
		expect(nodes.text(err)).toBe("kubectl diff exited 2: error: connection refused")
	end)

	-- GIT-F8: kubectl prints klog noise first; the reason is the last real line.
	it("a drift error names kubectl's last meaningful line, not klog noise", function()
		local w = X.world()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if table.find(argv, "diff") then
					return G.fail(
						2,
						'E1110 10:11:04.215188   79940 memcache.go:265] "Unhandled Error" err="couldn\'t get"\n'
							.. "The connection to the server 127.0.0.1:1 was refused - did you specify the right host or port?\n"
					)
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = driftReport(w)
		local err = nodes.find(body(s), nodes.role("tern-kube.error")) :: nodes.Node
		expect(nodes.text(err)).toBe(
			"kubectl diff exited 2: The connection to the server 127.0.0.1:1 was refused - did you specify the right host or port?"
		)
	end)

	-- GIT-F7: a cluster without the source's namespace (not provisioned yet)
	-- is the common first run on a new context: everything is missing.
	it("a context without the source's namespace shows every object missing, not an error", function()
		local w = X.world()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if table.find(argv, "diff") then
					return G.fail(2, 'Error from server (NotFound): namespaces "tern-test-drift" not found\n')
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = X.press(w, X.open(w, nil, nil), "g", { ctrl = true })
		s = X.action(w, s, "open", "dir:/repo/drift/baseline")
		local text = nodes.text(body(s))
		expect(nodes.find(body(s), nodes.role("tern-kube.error"))).toBeNil()
		expect(text).toContain("namespace tern-test-drift does not exist in this cluster: every object is missing")
		expect(text).toContain("Missing in cluster 5")
	end)

	-- An auto source is a guess: the chooser says why it matched and which
	-- values it renders with, so the user can tell the variants apart.
	it("the chooser lists auto-detected charts per release and values variant", function()
		local w = X.helmWorld()
		local s = X.press(w, X.openHelm(w), "g", { ctrl = true })
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("helm/chart as tern-test-helm/shop-a with deployed values")
		expect(text).toContain("helm/chart as tern-test-helm/shop-a with helm/values-staging.yaml")
		expect(text).toContain("auto: name+version+app version match")
		expect(rowIds(b)).toContain("helm:/repo/helm/chart:tern-test-helm/shop-a:deployed")
	end)

	it("a failed helm list is said in the chooser", function()
		local w = X.helmWorld()
		w.answer = (function(prev: any)
			return function(argv: { string }, e: any)
				if argv[1] == G.HELM then
					return G.fail(1, "Error: Kubernetes cluster unreachable")
				end
				return prev(argv, e)
			end
		end)(w.answer)
		local s = X.press(w, X.openHelm(w), "g", { ctrl = true })
		local err = nodes.find(body(s), nodes.role("tern-kube.error")) :: nodes.Node
		expect(nodes.text(err)).toBe(
			"Chart auto-detect unavailable: helm list exited 1: Error: Kubernetes cluster unreachable"
		)
	end)

	it("an auto report says how it was rendered and copies a config entry instead of writing one", function()
		local w = X.helmWorld()
		local s = X.press(w, X.openHelm(w), "g", { ctrl = true })
		s = X.action(w, s, "open", "helm:/repo/helm/chart:tern-test-helm/shop-a:deployed")
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("Drift of helm/chart as tern-test-helm/shop-a with deployed values")
		expect(text).toContain("Rendered with the deployed values of tern-test-helm/shop-a")
		expect(text).toContain(
			"rendered by /opt/helm/bin/helm template shop-a /repo/helm/chart --no-hooks -n tern-test-helm -f /data/tmp/values-"
		)
		expect(nodes.actions(b)).toContain("gitops-copyhelm=")
		expect(table.find(nodes.actions(b), "gitops-key=E")).toBeNil()
		local _, effects = State.update(s, { t = "action", act = "gitops-copyhelm", value = "" })
		local copied: string? = nil
		local warned: string? = nil
		for _, e in effects do
			if e.t == "copy" then
				copied = e.text
			elseif e.t == "toast" then
				warned = (e.text or "") .. " | " .. (e.sub or "")
			end
		end
		expect(copied).toBe('{"chart":"helm/chart","release":"shop-a","namespace":"tern-test-helm","values":[]}')
		-- GIT-F14: pasted, this entry renders with the chart defaults, not
		-- the deployed values: a different report, so the copy says so.
		expect(warned).toContain("without values")
		expect(warned).toContain("Deployed values (and --set) cannot go in the config")
	end)
end)

describe("gitops view: export and git", function()
	local function exported(w: G.World): State
		local s = driftReport(w)
		s = X.action(w, s, "open", "unmanaged:/ConfigMap/tern-test-drift/hand-made")
		return X.press(w, s, "E")
	end

	it("previews files with status and objects before writing; enter shows a file's diff", function()
		local w = X.world()
		local s = exported(w)
		expect(X.top(s).kind).toBe("export")
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("Export 1 object from drift/ to /repo/drift")
		expect(text).toContain("1 new · 0 modified · 0 unchanged")
		expect(text).toContain("configmap/hand-made")
		expect(nodes.actions(b)).toContain("gitops-key=w")
		expect(#nodes.findAll(b, nodes.role("tern-kube.gitops-diff"))).toBe(0)
		local item = State.selectedItem(s) :: any
		s = X.action(w, s, "open", item.key)
		local diff = nodes.find(body(s), nodes.role("tern-kube.gitops-diff")) :: nodes.Node
		expect(nodes.text(diff)).toContain("name: hand-made")
	end)

	it("w shows the confirmation with the count and directory; y writes; then b offers the git flow", function()
		local w = X.world()
		local s = X.press(w, exported(w), "w")
		local confirm = nodes.find(body(s), nodes.role("tern-kube.gitops-confirm")) :: nodes.Node
		expect(nodes.text(confirm)).toContain("Write 1 file under /repo/drift?")
		s = X.press(w, s, "y")
		local done = nodes.find(body(s), nodes.role("tern-kube.gitops-written")) :: nodes.Node
		expect(nodes.text(done)).toContain("Wrote 1 file.")
		expect(nodes.actions(body(s))).toContain("gitops-key=b")
	end)

	it("the git view shows toggles off, each command, and blocks on unrelated staged changes", function()
		local w = X.world()
		local s = X.press(w, X.press(w, exported(w), "w"), "y")
		w.staged = "M  src/app.go\0"
		s = X.press(w, s, "b")
		expect(X.top(s).kind).toBe("git")
		local b = body(s)
		local text = nodes.text(b)
		expect(text).toContain("Push: off (p)")
		expect(text).toContain("Pull request: off (P)")
		expect(text).toContain("gh not found")
		expect(text).toContain("git -C /repo switch -c tern-kube/")
		expect(text).toContain("1 staged change(s) not from this export: src/app.go")
		expect(#nodes.findAll(b, nodes.role("tern-kube.gitops-step"))).toBe(3)
		local blocked = nodes.find(b, nodes.role("tern-kube.gitops-blocked")) :: nodes.Node
		expect(nodes.text(blocked)).toContain("Press o to commit only the exported files")
		s = X.press(w, s, "o")
		expect(nodes.find(body(s), nodes.role("tern-kube.gitops-blocked"))).toBeNil()
		s = X.press(w, s, "enter")
		local finished = nodes.find(body(s), nodes.role("tern-kube.gitops-done")) :: nodes.Node
		expect(nodes.text(finished)).toContain("Done: committed on tern-kube/")
		expect(dockText(s)).toContain("p push")
	end)
end)

describe("gitops view: controller line", function()
	it("an Argo CD tracked object says which app manages it, with sync and health", function()
		local w = G.new()
		local ctx = G.ctx(nil, "tern-test-gitops")
		local g = G.ready(w, ctx)
		local effects: { Gitops.Effect } = {}
		Gitops.loadControllers(g, ctx, effects)
		G.core(w, g, ctx, effects)
		expect((Gitops.ctl(g, ctx) :: Gitops.Ctl).status).toBe("ok")
		local tracked: any = nil
		for _, o in json.decode(fixtures.read("drift/controllers/workloads.json")).items do
			local owner = Controllers.owner(o, Gitops.ctlSet(g, ctx) :: any)
			if owner and owner.controller == "argocd" then
				tracked = o
				break
			end
		end
		assert(tracked, "no Argo CD tracked object in the fixture")
		local line = GitopsView.controllerLine({
			g = g,
			gctx = ctx,
			route = { kind = "manifest" },
			selectedKey = nil,
			grid = function()
				return {}
			end,
			chip = function(text: string, action: string)
				return { k = "chip", p = { label = text, actions = { click = action } } }
			end,
			object = tracked,
		}, tracked) :: any
		local text = nodes.text(line)
		expect(text).toContain("Managed by Argo CD app ")
		expect(text).toContain("applied 4f2a9c1")
		-- The first tracked object belongs to guestbook-drifted (auto-sync, no self-heal).
		expect(text).toContain("Argo CD auto-sync: the next sync overwrites changes not in Git")
		expect(
			nodes.find(line, nodes.role("tern-kube.gitops-controller")) ~= nil
				or line.p.role == "tern-kube.gitops-controller"
		).toBe(true)
		local untracked = GitopsView.controllerLine({
			g = g,
			gctx = ctx,
			route = { kind = "manifest" },
			selectedKey = nil,
			grid = function()
				return {}
			end,
			chip = function()
				return { k = "chip" }
			end,
			object = nil,
		}, { metadata = { name = "x" } })
		expect(untracked).toBeNil()
	end)

	it("crumbs name each view", function()
		local g = Gitops.new("/repo")
		expect(GitopsView.crumb(g, { kind = "manifest", ref = { kind = "Deployment", name = "web", source = "live" } })).toBe(
			"Manifest deployment/web"
		)
		expect(GitopsView.crumb(g, { kind = "drift" })).toBe("Drift sources")
		expect(GitopsView.crumb(g, { kind = "drift", source = DRIFT, item = "changed:apps/Deployment/ns/web" })).toBe(
			"Drift web"
		)
		expect(GitopsView.crumb(g, { kind = "git" })).toBe("Git")
	end)
end)

-- The repository the controller fixtures point at, checked out at /repo:
-- the drift world under tests/integration/manifests/drift. HEAD is the
-- commit Flux applied; Argo CD applied another one.
describe("gitops view: Argo CD / Flux status", function()
	local BASE = "/repo/tests/integration/manifests/drift"
	local SOURCE = "dir:" .. BASE .. "/baseline"
	local HEAD = "0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c"

	local function setup(): (G.World, Gitops.G, Gitops.Ctx)
		local files: { [string]: string } = {}
		for path, text in G.driftFiles() do
			files[BASE .. string.sub(path, #"/repo/drift" + 1)] = text
		end
		local w = G.new(files)
		w.remotes = "origin\thttps://github.com/contrafy/tern-kube.git (fetch)\n"
		w.answer = function(argv: { string }): G.Result?
			if argv[1] == "git" and table.find(argv, "rev-parse") then
				return G.ok(HEAD .. "\n")
			end
			return nil
		end
		local ctx = G.ctx(nil, "tern-test-drift")
		local g = G.ready(w, ctx)
		local effects: { Gitops.Effect } = {}
		Gitops.enter(g, ctx, { kind = "drift" }, false, effects)
		G.core(w, g, ctx, effects)
		return w, g, ctx
	end

	local function view(g: Gitops.G, ctx: Gitops.Ctx, route: any): GitopsView.Ctx
		return {
			g = g,
			gctx = ctx,
			route = route,
			selectedKey = nil,
			grid = function()
				return {}
			end,
			chip = function(text: string, action: string)
				return { k = "chip", p = { label = text, actions = { click = action } } } :: any
			end,
			object = nil,
		}
	end

	it("the chooser note carries each controller's verdict and applied revision", function()
		local _, g, ctx = setup()
		local entry = Gitops.findSource(g, ctx, SOURCE) :: Gitops.SourceEntry
		expect(entry.note).toBe(
			"Argo CD app guestbook-drifted: OutOfSync · Degraded · SyncError @4f2a9c1, "
				.. "Flux Kustomization drift: Not ready (HealthCheckFailed) @0b1c2d3"
		)
		-- Another namespace: the note says where the controller deploys.
		local other = table.clone(ctx)
		other.target = table.clone(ctx.target)
		other.target.namespace = "elsewhere"
		local entryOther = Gitops.findSource(g, other, SOURCE) :: Gitops.SourceEntry
		expect(entryOther.note).toContain("@4f2a9c1 (deploys to ns tern-test-drift; n switches)")
	end)

	it("the report card compares what the controller applied with the checkout", function()
		local w, g, ctx = setup()
		local route = { kind = "drift", source = SOURCE }
		local effects: { Gitops.Effect } = {}
		Gitops.enter(g, ctx, route :: any, false, effects)
		G.core(w, g, ctx, effects)
		local load = Gitops.driftLoad(g, ctx, route :: any) :: Gitops.DriftLoad
		local cards = GitopsView.controllerCards(view(g, ctx, route), load)
		expect(#cards).toBe(2)
		expect((cards[1].p :: any).role).toBe("tern-kube.gitops-controller-status")
		local argo = nodes.text(cards[1])
		expect(argo).toContain("Argo CD app guestbook-drifted: OutOfSync · Degraded · SyncError")
		expect(argo).toContain(
			"applied 4f2a9c1 · your checkout 0b1c2d3: this report compares your checkout, not what the controller applied"
		)
		expect(argo).toContain("last sync Failed: one or more objects failed to apply")
		expect(argo).toContain("reconciled 2026-10-08T00:06:00Z")
		local flux = nodes.text(cards[2])
		expect(flux).toContain("applied 0b1c2d3 · your checkout 0b1c2d3 (same) · attempted 4f2a9c1")
	end)

	it("revert warnings sit above the apply chips", function()
		local w, g, ctx = setup()
		local route = { kind = "drift", source = SOURCE }
		local effects: { Gitops.Effect } = {}
		Gitops.enter(g, ctx, route :: any, false, effects)
		G.core(w, g, ctx, effects)
		local out = GitopsView.body(view(g, ctx, route))
		local riskAt, chipsAt = 0, 0
		for i, n in out do
			local role = (n.p :: any).role
			if role == "tern-kube.gitops-controller-risk" and riskAt == 0 then
				riskAt = i
			elseif role == "tern-kube.chips" and (n.p :: any).key == "rc" then
				chipsAt = i
			end
		end
		expect(riskAt > 0 and chipsAt > riskAt).toBe(true)
		local text = nodes.text({ k = "col", p = {}, c = out } :: any)
		expect(text).toContain("Argo CD auto-sync: the next sync overwrites changes not in Git")
		expect(text).toContain("Flux re-applies this source every 10m: changes applied outside Git are reverted")
		expect(nodes.actions({ k = "col", p = {}, c = out } :: any)).toContain("gitops-key=Y")
	end)
end)

return nil
