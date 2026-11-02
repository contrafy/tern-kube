--!strict
-- The edit preview dry-runs a merge patch computed from kubectl's own
-- conversions of the file before and after the editor (recorded `patch
-- --local -o json`, so YAML 1.1 quirks such as `yes` and `1.50` resolve
-- as kubectl edit sees them). The patch must carry exactly the edit:
-- removals as null, lists whole, `[]` kept, nothing the user did not touch.
local Edit = require("../../../plugin/lib/mutation/edit")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function read(name: string): string
	return fixtures.read("kubectl/track1/" .. name)
end

local function plan(original: string, edited: string): Edit.EditSet
	local set, err = Edit.plan(read(original), read(edited))
	assert(set, err)
	return set
end

describe("mutation.edit plan", function()
	it("patches one edited custom resource with exactly the edit", function()
		local set = plan("convert-original.txt", "convert-edited.txt")
		expect(set.unchanged).toEqual({})
		expect(set.renamed).toEqual({})
		expect(#set.changes).toBe(1)
		local c = set.changes[1]
		expect(c.key).toBe("lens.example.com.v1alpha1.Widget.tern-test-t1.w1")
		expect(c.typeRef).toBe("Widget.v1alpha1.lens.example.com")
		expect(c.name).toBe("w1")
		expect(c.namespace).toBe("tern-test-t1")
		expect(c.liveVersion).toBe("1234")
		expect(c.patch).toBe('{"metadata":{"labels":{"tier":"gold"}},"spec":{"size":4,"tags":["a"],"extra":null}}')
	end)

	-- `kubectl get Kind.version.group/name` resolves core kinds as
	-- `ConfigMap.v1.`; only changed objects of a List are patched.
	it("patches only the changed objects of a List edit", function()
		local set = plan("convert-original-list.txt", "convert-edited-list.txt")
		expect(set.unchanged).toEqual({ "v1.ConfigMap.tern-test-t1.cm2" })
		expect(#set.changes).toBe(1)
		local c = set.changes[1]
		expect(c.typeRef).toBe("ConfigMap.v1.")
		expect(c.liveVersion).toBe("100")
		expect(json.decode(c.patch)).toEqual({ data = { k = "on", added = "1" } })
	end)

	-- kubectl refuses a changed apiVersion, kind or name; the preview
	-- reports both identities instead of patching anything.
	it("reports a rename instead of patching", function()
		local set = plan("convert-original.txt", "convert-edited-renamed.txt")
		expect(set.changes).toEqual({})
		expect(set.renamed).toEqual({
			"lens.example.com.v1alpha1.Widget.tern-test-t1.w1",
			"lens.example.com.v1alpha1.Widget.tern-test-t1.w9",
		})
	end)

	it("reports an unchanged save as unchanged", function()
		local set = plan("convert-original.txt", "convert-original.txt")
		expect(set.changes).toEqual({})
		expect(set.unchanged).toEqual({ "lens.example.com.v1alpha1.Widget.tern-test-t1.w1" })
	end)

	it("fails on output that is not kubectl JSON, naming the side", function()
		local set, err = Edit.plan(read("convert-original.txt"), "error: error parsing")
		expect(set).toBeNil()
		expect(err).toContain("edited")
		local _, err2 = Edit.plan('{"kind":"ConfigMap"}', read("convert-edited.txt"))
		expect(err2).toContain("original object 1")
		local _, err3 =
			Edit.plan(read("convert-original.txt") .. read("convert-original.txt"), read("convert-edited.txt"))
		expect(err3).toContain("twice")
	end)
end)

return nil
