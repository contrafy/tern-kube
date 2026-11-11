--!strict
-- Non-apply verbs have no `kubectl diff`; their preview is the diff of the
-- live object against the server dry run's after state. The diff must show
-- only the intended change (server bookkeeping such as `generation` would
-- otherwise appear on every spec change), read back through Diffseg exactly
-- like kubectl diff output, and never print Secret values.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Objdiff = require("../../../plugin/lib/mutation/objdiff")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local HIDE = { showSecretValues = false, null = json.null }

local function objects(fixture: string): { any }
	local out, err = Objdiff.decodeStream(fixtures.read("kubectl/track1/" .. fixture), json.decode)
	assert(out, err)
	return out
end

local function diffOf(beforeFixture: string, afterFixture: string, opts: Objdiff.Options?): Objdiff.Result
	return Objdiff.compute(Objdiff.pair(objects(beforeFixture), objects(afterFixture)), opts or HIDE)
end

local function changedLines(seg: Diffseg.Segment): { string }
	local out = {}
	for _, line in seg.lines do
		local c = string.sub(line, 1, 1)
		local head = string.sub(line, 1, 4)
		if (c == "+" or c == "-") and head ~= "+++ " and head ~= "--- " then
			table.insert(out, line)
		end
	end
	return out
end

describe("mutation.objdiff identity", function()
	-- kubectl diff's file naming, so Diffseg.identity reads the key back.
	it("keys objects as [group.]version.Kind.namespace.name", function()
		local deploy = { apiVersion = "apps/v1", kind = "Deployment", metadata = { name = "web", namespace = "ns" } }
		local node = { apiVersion = "v1", kind = "Node", metadata = { name = "n.example" } }
		local widget =
			{ apiVersion = "lens.example.com/v1alpha1", kind = "Widget", metadata = { name = "w1", namespace = "ns" } }
		expect(Objdiff.identity(deploy)).toBe("apps.v1.Deployment.ns.web")
		expect(Objdiff.identity(node)).toBe("v1.Node..n.example")
		local key = Objdiff.identity(widget) :: string
		expect(key).toBe("lens.example.com.v1alpha1.Widget.ns.w1")
		expect(Diffseg.identity(key)).toEqual({
			group = "lens.example.com",
			version = "v1alpha1",
			kind = "Widget",
			namespace = "ns",
			name = "w1",
		})
		expect(Objdiff.identity({ kind = "Pod", metadata = { name = "p" } })).toBeNil()
	end)
end)

describe("mutation.objdiff decodeStream", function()
	it("flattens kubectl's concatenated objects and List items alike", function()
		local after = objects("label-cm-cm2-json.txt")
		local before = objects("get-cm-json.txt")
		expect(#after).toBe(2)
		expect(#before).toBe(2)
		expect(before[1].metadata.name).toBe("cm")
	end)

	it("reports undecodable output instead of dropping objects", function()
		local out, err = Objdiff.decodeStream('{"a":1}{"b":', json.decode)
		expect(out).toBeNil()
		expect(err).toContain("unterminated")
		local bad, decodeErr = Objdiff.decodeStream("{nope}", json.decode)
		expect(bad).toBeNil()
		expect(decodeErr).toContain("object 1")
	end)
end)

describe("mutation.objdiff pair", function()
	it("matches by identity in before order and keeps one-sided objects", function()
		local a = { apiVersion = "v1", kind = "ConfigMap", metadata = { name = "a", namespace = "ns" } }
		local b = { apiVersion = "v1", kind = "ConfigMap", metadata = { name = "b", namespace = "ns" } }
		local c = { apiVersion = "v1", kind = "ConfigMap", metadata = { name = "c", namespace = "ns" } }
		local pairs = Objdiff.pair({ a, b }, { c, a })
		expect(#pairs).toBe(3)
		expect(pairs[1]).toEqual({ key = "v1.ConfigMap.ns.a", before = a, after = a })
		expect(pairs[2].after).toBeNil()
		expect(pairs[3].before).toBeNil()
	end)
end)

describe("mutation.objdiff compute", function()
	it("shows the added label of each object and nothing else", function()
		local result = diffOf("get-cm-json.txt", "label-cm-cm2-json.txt")
		expect(result.unchanged).toEqual({})
		expect(result.summary.modify).toBe(2)
		expect(result.summary.added).toBe(2)
		expect(result.summary.removed).toBe(0)
		local seg = result.summary.segments[1]
		expect(seg.key).toBe("v1.ConfigMap.tern-test-t1.cm")
		expect(seg.lines[1]).toBe("--- /live/v1.ConfigMap.tern-test-t1.cm")
		expect(seg.lines[2]).toBe("+++ /merged/v1.ConfigMap.tern-test-t1.cm")
		-- `y` is a YAML 1.1 boolean, so the emitter quotes it.
		expect(changedLines(seg)).toEqual({ "+    x: 'y'" })
	end)

	-- The server bumps metadata.generation on every spec change.
	it("strips generation so a replicas patch shows only replicas", function()
		local result = diffOf("get-deploy-web-json.txt", "patch-deploy-replicas-json.txt")
		expect(#result.summary.segments).toBe(1)
		expect(changedLines(result.summary.segments[1])).toEqual({ "-  replicas: 2", "+  replicas: 3" })
	end)

	it("keys custom resources with their group", function()
		local result = diffOf("get-widget-json.txt", "patch-widget-merge-json.txt")
		local seg = result.summary.segments[1]
		expect(seg.group).toBe("lens.example.com")
		expect(seg.kind).toBe("Widget")
		expect(changedLines(seg)).toEqual({ "-  size: 3", "+  size: 4" })
	end)

	it("lists objects the change leaves equal as unchanged", function()
		local live = objects("get-cm-json.txt")
		local result = Objdiff.compute(Objdiff.pair(live, live), HIDE)
		expect(result.unchanged).toEqual({ "v1.ConfigMap.tern-test-t1.cm", "v1.ConfigMap.tern-test-t1.cm2" })
		expect(#result.summary.segments).toBe(0)
	end)

	-- Secret data, and the last-applied annotation holding the applied
	-- stringData in clear text, are masked; a changed key stays visible.
	it("masks Secret values but marks the changed key", function()
		local result = diffOf("get-secret-json.txt", "patch-secret-json.txt")
		local text = table.concat(result.summary.segments[1].lines, "\n")
		expect((string.find(text, "Zml4", 1, true))).toBeNil()
		expect((string.find(text, "cm90YXRlZA", 1, true))).toBeNil()
		expect((string.find(text, "fixture-pass", 1, true))).toBeNil()
		local changed = changedLines(result.summary.segments[1])
		expect(#changed).toBe(2)
		expect(changed[1]).toContain("pass: ")
		expect(changed[1]).toContain(Objdiff.REDACTED)
		expect(changed[2]).toContain(Objdiff.REDACTED_CHANGED)
	end)

	it("shows Secret values only when show_secret_values is on", function()
		local result = diffOf("get-secret-json.txt", "patch-secret-json.txt", { showSecretValues = true })
		expect(changedLines(result.summary.segments[1])).toEqual({
			"-  pass: Zml4dHVyZS1wYXNz",
			"+  pass: cm90YXRlZA==",
		})
	end)

	it("never writes into the caller's objects", function()
		local before, after = objects("get-secret-json.txt"), objects("patch-secret-json.txt")
		Objdiff.compute(Objdiff.pair(before, after), HIDE)
		expect(before[1].data.pass).toBe("Zml4dHVyZS1wYXNz")
		expect(before[1].metadata.resourceVersion ~= nil).toBe(true)
	end)

	it("classifies one-sided pairs as created and deleted", function()
		local cm = objects("get-cm-json.txt")
		local result = Objdiff.compute(Objdiff.pair({ cm[1] }, { cm[2] }), HIDE)
		expect(result.summary.delete).toBe(1)
		expect(result.summary.create).toBe(1)
		expect(result.summary.segments[1].key).toBe("v1.ConfigMap.tern-test-t1.cm")
		expect(result.summary.segments[2].key).toBe("v1.ConfigMap.tern-test-t1.cm2")
	end)

	-- Comparing two clusters, the headers name the contexts instead of
	-- live/merged; Diffseg still reads the object key from the new side.
	it("names both sides with the paths option", function()
		local cm = objects("get-cm-json.txt")
		local changed = table.clone(cm[1])
		changed.data = { k = "other" }
		local result = Objdiff.compute(Objdiff.pair({ cm[1] }, { changed }), {
			showSecretValues = false,
			null = json.null,
			paths = { "kind-tern-kube-dev", "arn:aws:eks:x:1:cluster/prod" },
		})
		local seg = result.summary.segments[1]
		expect(seg.lines[1]).toBe("--- kind-tern-kube-dev/v1.ConfigMap.tern-test-t1.cm")
		expect(seg.lines[2]).toBe("+++ arn:aws:eks:x:1:cluster/prod/v1.ConfigMap.tern-test-t1.cm")
		expect(seg.key).toBe("v1.ConfigMap.tern-test-t1.cm")
		expect(seg.name).toBe("cm")
	end)
end)

-- replace --force re-creates: uid, age and status cannot carry over, so the
-- preview diff must not show them as kept or as removed by the file.
describe("mutation.objdiff recreated and manifests", function()
	it("drops identity, age and status from both sides of a forced replace", function()
		local live = {
			apiVersion = "v1",
			kind = "ConfigMap",
			metadata = { name = "c", namespace = "a", uid = "u1", creationTimestamp = "t", resourceVersion = "5" },
			data = { k = "1" },
			status = { x = 1 },
		}
		local out = Objdiff.recreated({ live })
		expect(out[1].metadata).toEqual({ name = "c", namespace = "a" })
		expect(out[1].status).toBeNil()
		expect(live.metadata.uid).toBe("u1")
	end)

	it("renders objects as YAML documents the manifest heuristics can read", function()
		local m = Objdiff.manifests(
			{ { apiVersion = "v1", kind = "Service", metadata = { name = "web" }, spec = { type = "NodePort" } } },
			HIDE
		)
		expect(m[1].path).toBe("v1.Service..web")
		expect(m[1].text).toContain("kind: Service")
		expect(m[1].text).toContain("type: NodePort")
	end)
end)

return nil
