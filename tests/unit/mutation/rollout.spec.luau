--!strict
-- `rollout undo --dry-run=server -o json` prints the live object, so the
-- undo preview is built from the revision's template; the revision chosen
-- must be the one kubectl would restore. pause/resume and cordon/uncordon
-- have no object-printing dry run; their after state is one field.
local Rollout = require("../../../plugin/lib/mutation/rollout")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function object(name: string): any
	return json.decode(fixtures.read("kubectl/track1/" .. name))
end

local function image(obj: any): string
	return obj.spec.template.spec.containers[1].image
end

describe("mutation.rollout parseHistory", function()
	it("reads the revision list of each kind kubectl prints", function()
		for _, case in
			{
				{ "rollout-history-deploy.txt", "deployment", "web" },
				{ "rollout-history-ds.txt", "daemonset", "ds" },
				{ "rollout-history-sts.txt", "statefulset", "db" },
			}
		do
			expect(Rollout.parseHistory(fixtures.read("kubectl/track1/" .. case[1]))).toEqual({
				{ kind = case[2], group = "apps", name = case[3], revisions = { 1, 2 } },
			})
		end
	end)

	it("reads one block per object for a selector", function()
		local list = Rollout.parseHistory(fixtures.read("kubectl/track1/rollout-history-selector.txt"))
		expect(list).toEqual({
			{ kind = "deployment", group = "apps", name = "one", revisions = { 1 } },
			{ kind = "deployment", group = "apps", name = "web", revisions = { 1, 2 } },
		})
	end)

	-- Revisions get renumbered on undo (3 1 4), so order must not be trusted.
	it("sorts revisions and ignores change causes that look like resources", function()
		local list = Rollout.parseHistory(
			"deployment.apps/web \nREVISION  CHANGE-CAUSE\n3         <none>\n1         kubectl set image deployment/web c=x\n4         <none>\n"
		)
		expect(list[1].revisions).toEqual({ 1, 3, 4 })
		expect(#list).toBe(1)
	end)
end)

describe("mutation.rollout target", function()
	it("picks the second-highest revision as previous, like kubectl", function()
		expect((Rollout.target({ 1, 3, 4 }, nil))).toBe(3)
		expect((Rollout.target({ 4, 1, 3 }, 0))).toBe(3)
	end)

	it("honours --to-revision when it is listed", function()
		expect((Rollout.target({ 1, 2 }, 1))).toBe(1)
	end)

	-- kubectl: "unable to find specified revision 9 in history" and
	-- "no rollout history found" (recorded); the preview fails the same way.
	it("fails on an unknown revision and on a single revision", function()
		local r, err = Rollout.target({ 1, 2 }, 9)
		expect(r).toBeNil()
		expect(err).toContain("9")
		local single, err2 = Rollout.target({ 1 }, nil)
		expect(single).toBeNil()
		expect(err2).toContain("no previous revision")
	end)
end)

describe("mutation.rollout undoAfter", function()
	-- The Deployment history object is a ReplicaSet whose template carries
	-- the controller's pod-template-hash label; kubectl drops it.
	it("restores a Deployment's template from the revision ReplicaSet without pod-template-hash", function()
		local live = object("get-deploy-web-json.txt")
		local rev = object("rollout-history-deploy-rev1-json.txt")
		expect(rev.kind).toBe("ReplicaSet")
		expect(rev.spec.template.metadata.labels["pod-template-hash"] ~= nil).toBe(true)
		local after = Rollout.undoAfter(live, rev)
		expect(image(live)).toBe("registry.k8s.io/pause:3.10")
		expect(image(after)).toBe("registry.k8s.io/pause:3.9")
		expect(after.spec.template.metadata.labels["pod-template-hash"]).toBeNil()
		expect(after.spec.template.metadata.labels.t1app).toBe("web")
		expect(after.spec.replicas).toBe(live.spec.replicas)
		expect(after.metadata.name).toBe("web")
	end)

	it("restores DaemonSet and StatefulSet templates from their revision objects", function()
		for _, case in
			{
				{ "get-ds-json.txt", "rollout-history-ds-rev1-json.txt", "DaemonSet" },
				{ "get-sts-json.txt", "rollout-history-sts-rev1-json.txt", "StatefulSet" },
			}
		do
			local live, rev = object(case[1]), object(case[2])
			expect(rev.kind).toBe(case[3])
			local after = Rollout.undoAfter(live, rev)
			expect(image(after)).toBe("registry.k8s.io/pause:3.9")
			expect(image(live)).toBe("registry.k8s.io/pause:3.10")
		end
	end)

	it("leaves the live object untouched when the revision has no template", function()
		local live = object("get-deploy-web-json.txt")
		expect(Rollout.undoAfter(live, { kind = "ReplicaSet" })).toEqual(live)
	end)
end)

describe("mutation.rollout field flips", function()
	it("sets and removes spec.paused on a copy", function()
		local live = object("get-deploy-web-json.txt")
		local paused = Rollout.pausedAfter(live, true)
		expect(paused.spec.paused).toBe(true)
		expect(live.spec.paused).toBeNil()
		expect(Rollout.pausedAfter(paused, false).spec.paused).toBeNil()
	end)

	it("sets and removes spec.unschedulable on a node copy", function()
		local node = object("get-node-json.txt")
		local cordoned = Rollout.cordonAfter(node, true)
		expect(cordoned.spec.unschedulable).toBe(true)
		expect(node.spec.unschedulable).toBeNil()
		expect(Rollout.cordonAfter(cordoned, false).spec.unschedulable).toBeNil()
	end)

	-- An object without spec gets one only when the flag is set.
	it("creates spec only when needed", function()
		expect(Rollout.cordonAfter({ kind = "Node" }, true)).toEqual({ kind = "Node", spec = { unschedulable = true } })
		expect(Rollout.cordonAfter({ kind = "Node" }, false)).toEqual({ kind = "Node" })
	end)
end)

return nil
