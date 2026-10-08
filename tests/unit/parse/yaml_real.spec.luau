--!strict
local Json = require("../../../plugin/lib/parse/json")
local Yaml = require("../../../plugin/lib/parse/yaml")
local decoder = require("../../lib/json")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function names(docs: { Yaml.Doc }): { string }
	local out = {}
	for _, d in docs do
		table.insert(out, string.format("%s %s/%s", d.kind or "-", d.namespace or "-", d.name or "-"))
	end
	return out
end

describe("yaml.split against real kubectl output", function()
	-- The JSON and YAML captures list the same objects in the same order.
	it("finds exactly the objects the JSON output contains", function()
		local yaml = Yaml.splitLines(fixtures.lines("real/ns-apps/get_pods_-o_yaml.txt"))
		local json = Json.parse(fixtures.read("real/ns-apps/get_pods_-o_json.txt"), decoder.decode)
		local expected = {}
		for _, r in json.resources do
			table.insert(expected, string.format("%s %s/%s", r.ref.kind, r.ref.namespace or "-", r.ref.name))
		end
		expect(#expected > 0).toBe(true)
		expect(names(yaml.docs)).toEqual(expected)
		expect(yaml.diagnostics).toEqual({})
	end)

	it("reads single objects, including CRDs and long-annotated objects", function()
		for path, id in
			{
				["real/ns-apps/get_pod_crashloop_-o_yaml.txt"] = "Pod tern-test-apps/crashloop",
				["real/ns-apps/get_deployment_web_-o_yaml.txt"] = "Deployment tern-test-apps/web",
				["real/cluster/get_crd_widgets.lens.example.com_-o_yaml.txt"] = "CustomResourceDefinition -/widgets.lens.example.com",
				["real/ns-edge/get_pod_labels-odd_-o_yaml.txt"] = "Pod tern-test-edge/labels-odd",
				["real/ns-edge/get_configmap_unicode-config_-o_yaml.txt"] = "ConfigMap tern-test-edge/unicode-config",
			}
		do
			local r = Yaml.splitLines(fixtures.lines(path :: string))
			expect({ path, names(r.docs) }).toEqual({ path, { id } })
		end
	end)

	it("splits a CRD List into Widgets", function()
		local r = Yaml.splitLines(fixtures.lines("real/ns-crd/get_widgets_-o_yaml.txt"))
		expect(#r.docs > 0).toBe(true)
		for _, d in r.docs do
			expect(d.ref and d.ref.group).toBe("lens.example.com")
		end
	end)
end)

describe("yaml.redactSecretData against real kubectl output", function()
	it("removes the fake secret from data and from the last-applied annotation", function()
		local lines = fixtures.lines("real/ns-apps/get_secret_app-secret_-o_yaml.txt")
		local original = table.concat(lines, "\n")
		-- Guard the fixture itself: the leak this test protects against must be present.
		expect(original).toContain("kube-lens-test-not-a-secret")
		local shown = Yaml.redactSecretData(lines, Yaml.splitLines(lines).docs)
		expect(#shown).toBe(#lines)
		local text = table.concat(shown, "\n")
		expect((string.find(text, "kube-lens-test-not-a-secret", 1, true))).toBeNil()
		expect((string.find(text, "kube-lens-test-user", 1, true))).toBeNil()
		for _, line in lines do
			local value = string.match(line, "^  %S+: (%S+)$")
			if value and #value >= 16 and string.match(value, "^[%w+/]+=*$") then
				expect((string.find(text, value, 1, true))).toBeNil()
			end
		end
		expect(text).toContain("kind: Secret")
		expect(text).toContain("bytes base64>")
	end)

	it("leaves ConfigMap data visible", function()
		local lines = fixtures.lines("real/ns-edge/get_configmap_unicode-config_-o_yaml.txt")
		expect(Yaml.redactSecretData(lines, Yaml.splitLines(lines).docs)).toEqual(lines)
	end)
end)

return nil
