--!strict
-- `kubectl rollout history` as kubectl v1.34 prints it (tests/fixtures/
-- kubectl/k9s, scripts/fixtures/capture-k9s.sh). The lens must read every
-- block, keep free-text causes whole, and read `--revision=N` both with the
-- raw tabs kubectl writes and with the 8-column stops a terminal shows.
local RolloutHistory = require("../../../plugin/lib/parse/rollout_history")
local Types = require("../../../plugin/lib/model/types")
local k9s = require("../../lib/k9s")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Field = Types.DescribeField

local function field(fields: { Field }, ...: string): Field
	local current: Field? = nil
	local list = fields
	for _, key in { ... } do
		current = nil
		for _, f in list do
			if f.key == key then
				current = f
				break
			end
		end
		assert(current, "missing field " .. key)
		list = current.children
	end
	return current :: Field
end

local function revisions(obj: RolloutHistory.HistoryObject): { number }
	local out: { number } = {}
	for _, r in obj.revisions do
		table.insert(out, r.revision)
	end
	return out
end

describe("parse.rollout_history list", function()
	it("reads the header with kubectl's trailing space and keeps causes verbatim", function()
		local p = RolloutHistory.parseList(k9s.stdout("rh-deploy"))
		expect(p.diagnostics).toEqual({})
		expect(#p.objects).toBe(1)
		local obj = p.objects[1]
		expect(obj.type).toBe("deployment.apps")
		expect(obj.kind).toBe("Deployment")
		expect(obj.group).toBe("apps")
		expect(obj.name).toBe("hist")
		expect(revisions(obj)).toEqual({ 1, 2, 3 })
		expect(obj.revisions[1].cause).toBe("initial pause 3.10")
		-- kubectl copies the last cause to later revisions; quotes stay.
		expect(obj.revisions[3].cause).toBe("downgrade to 3.9 (it's a test)")
	end)

	it("maps <none> to no cause", function()
		local p = RolloutHistory.parseList(k9s.stdout("rh-ds"))
		expect(p.objects[1].kind).toBe("DaemonSet")
		expect(p.objects[1].revisions[1].cause).toBeNil()
		expect(revisions(p.objects[1])).toEqual({ 1, 2 })
	end)

	it("keeps gaps: an undo renumbers the restored revision", function()
		local p = RolloutHistory.parseList(k9s.stdout("rh-after-undo"))
		expect(revisions(p.objects[1])).toEqual({ 2, 3, 4 })
		expect(p.objects[1].revisions[3].cause).toBe("initial pause 3.10")
	end)

	it("reads one block per object (two names, a type, a selector)", function()
		for _, id in { "rh-multi", "rh-all-deploy" } do
			local p = RolloutHistory.parseList(k9s.stdout(id))
			expect(p.diagnostics).toEqual({})
			expect(#p.objects).toBe(2)
		end
		local multi = RolloutHistory.parseList(k9s.stdout("rh-multi"))
		expect(multi.objects[1].name).toBe("hist")
		expect(multi.objects[2].name).toBe("fresh")
		expect(revisions(multi.objects[2])).toEqual({ 1 })
		expect(#RolloutHistory.parseList(k9s.stdout("rh-selector")).objects).toBe(1)
	end)

	it("turns kubectl errors into diagnostics, never objects", function()
		for _, id in { "rh-notfound", "rh-pod", "rh-svc", "rh-noresource" } do
			local f = k9s.load(id)
			local p = RolloutHistory.parseList(f.lines)
			expect(#p.objects).toBe(0)
			expect(#p.diagnostics > 0).toBe(true)
			expect(p.diagnostics[1].severity).toBe("error")
		end
	end)

	it("ignores change causes that look like headers or resources", function()
		local p = RolloutHistory.parseList({
			"deployment.apps/web",
			"REVISION  CHANGE-CAUSE",
			"1         kubectl set image deployment/web c=x",
			"2         REVISION  CHANGE-CAUSE",
		})
		expect(#p.objects).toBe(1)
		expect(p.objects[1].revisions[1].cause).toBe("kubectl set image deployment/web c=x")
		expect(p.objects[1].revisions[2].cause).toBe("REVISION  CHANGE-CAUSE")
	end)
end)

describe("parse.rollout_history revision", function()
	it("reads raw-tab and tab-expanded output identically", function()
		for _, id in { "rh-deploy-rev2", "rh-deploy-rev3", "rh-ds-rev2", "rh-sts-rev1" } do
			local raw = RolloutHistory.parseRevision(k9s.stdout(id))
			local expanded = RolloutHistory.parseRevision(k9s.stdout(id, true))
			expect(raw.diagnostics).toEqual({})
			expect(expanded.diagnostics).toEqual({})
			expect(#raw.describe.objects).toBe(1)
			expect(raw.describe).toEqual(expanded.describe)
		end
	end)

	it("names the workload and revision and keeps every label value", function()
		local p = RolloutHistory.parseRevision(k9s.stdout("rh-deploy-rev2", true))
		expect(p.type).toBe("deployment.apps")
		expect(p.kind).toBe("Deployment")
		expect(p.name).toBe("hist")
		expect(p.revision).toBe(2)
		local obj = p.describe.objects[1]
		expect(obj.name).toBe("hist")
		expect(obj.kind).toBe("Deployment")
		local labels = field(obj.fields, "Pod Template", "Labels")
		expect(#labels.values).toBe(2)
		expect(labels.values[1]).toBe("app=hist")
		expect(string.find(labels.values[2], "^pod%-template%-hash=") ~= nil).toBe(true)
		expect(field(obj.fields, "Pod Template", "Containers", "pause", "Image").value).toBe(
			"registry.k8s.io/pause:3.9"
		)
	end)

	it("keeps Environment children (sts/ds revisions, set env)", function()
		local ds = RolloutHistory.parseRevision(k9s.stdout("rh-ds-rev2"))
		local env = field(ds.describe.objects[1].fields, "Pod Template", "Containers", "pause", "Environment")
		expect(env.children[1].key).toBe("A")
		expect(env.children[1].value).toBe("1")
		local dep = RolloutHistory.parseRevision(k9s.stdout("rh-deploy-rev3", true))
		local mode = field(dep.describe.objects[1].fields, "Pod Template", "Containers", "pause", "Environment", "MODE")
		expect(mode.value).toBe("x")
	end)

	it("a missing revision is an error, not an object", function()
		local f = k9s.load("rh-bad-revision")
		local p = RolloutHistory.parseRevision(f.lines)
		expect(p.revision).toBeNil()
		expect(#p.describe.objects).toBe(0)
		expect(p.diagnostics[1].text).toBe("error: unable to find the specified revision")
	end)

	it("expands tabs to 8-column stops", function()
		expect(RolloutHistory.expandTabs("  Labels:\tapp=x")).toBe("  Labels:       app=x")
		expect(RolloutHistory.expandTabs("\tx")).toBe("        x")
		expect(RolloutHistory.expandTabs("no tabs")).toBe("no tabs")
	end)
end)

return nil
