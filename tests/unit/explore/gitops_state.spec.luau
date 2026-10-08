--!strict
-- The GitOps keys of Explore (m, =, ctrl+g, E) and the lens chips' links
-- reach the GitOps routes from any list or object, scan only when asked,
-- and are never persisted: reopening a block must not rescan a repository
-- behind the user's back.
local Gitops = require("../../../plugin/lib/explore/gitops")
local Link = require("../../../plugin/lib/mutation/link")
local State = require("../../../plugin/lib/explore/state")
local G = require("../../lib/gitops_world")
local W = require("../../lib/explore")
local X = require("../../lib/gitops_explore")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State

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
		expect(s.gitops.drifts["dir:/repo/apps"].status).toBe("ok")
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

	it("saved state never restores a GitOps route", function()
		local w = world()
		local s = selectName(w, open(w), "web")
		s = press(w, s, "enter")
		s = press(w, s, "m")
		local saved = State.save(s)
		expect(#saved.stack).toBe(2)
		local w2 = world()
		local s2, effects = State.init({ W.link({ context = W.CTX }) }, saved, W.config(nil), env())
		s2 = drive(w2, s2, effects)
		expect(top(s2).kind).toBe("detail")
		expect(scans(w2)).toBe(0)
	end)
end)

return nil
