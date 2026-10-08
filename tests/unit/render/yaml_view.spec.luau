--!strict
local Viewstate = require("../../../plugin/lib/lens/viewstate")
local YamlView = require("../../../plugin/lib/render/yaml_view")
local captures = require("../../lib/captures")
local decoder = require("../../lib/json")
local fixtures = require("../../lib/fixtures")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Node = nodes.Node
type ViewState = Viewstate.ViewState

local PODS = "real/ns-apps/get_pods_-o_yaml"
local PODS_CMD = "kubectl get pods -n tern-test-apps -o yaml"

local function render(capture: any, vs: ViewState?): Node
	return YamlView.render(capture, vs or Viewstate.default(), Viewstate)
end

local function codes(root: Node): { Node }
	return nodes.findAll(root, nodes.kind("code"))
end

local function codeText(n: Node): string
	return (n.p :: any).text
end

local function gridRows(root: Node): { Node }
	return nodes.findAll(root, nodes.class("tk-r"))
end

local MANIFEST = {
	"apiVersion: v1",
	"kind: ConfigMap",
	"metadata:",
	"  name: api-config",
	"  namespace: tern-test-mutate",
	"data:",
	"  LOG_LEVEL: info",
	"---",
	"apiVersion: apps/v1",
	"kind: Deployment",
	"metadata:",
	"  name: api",
	"  namespace: tern-test-mutate",
	"spec:",
	"  replicas: 1",
	"---",
	"apiVersion: v1",
	"kind: Service",
	"metadata:",
	"  name: api",
	"  namespace: tern-test-mutate",
	"spec:",
	"  ports:",
	"    - name: http",
	"      port: 80",
}

describe("yaml view: lists", function()
	it("lists every object of a List and shows no YAML until one is opened", function()
		local capture = captures.build(PODS, PODS_CMD)
		local view = render(capture)
		local pods = decoder.decode(fixtures.read("real/ns-apps/get_pods_-o_json.txt")).items
		local rows = gridRows(view)
		expect(#rows).toBe(#pods)
		expect(nodes.text(rows[1])).toContain(pods[1].metadata.name)
		expect(#codes(view)).toBe(0)
	end)

	it("opens the clicked object as standalone YAML numbered like the raw output", function()
		local capture = captures.build(PODS, PODS_CMD)
		local closed = render(capture)
		local action = nodes.action(gridRows(closed)[2]) :: string
		local vs = Viewstate.decode(string.sub(action, 3))
		expect(vs.open).toBe(YamlView.docKey(2))
		local view = render(capture, vs)
		local list = codes(view)
		-- Only the opened document is materialized.
		expect(#list).toBe(1)
		local p = list[1].p :: any
		expect(p.lang).toBe("yaml")
		expect(p.start).toBe((capture.yaml :: any).docs[2].startLine)
		local text = codeText(list[1])
		-- The list item's "- " is gone, so it reads as an object of its own.
		expect(string.sub(text, 1, 14)).toBe("apiVersion: v1")
		expect(text).toContain("kind: Pod")
		local pods = decoder.decode(fixtures.read("real/ns-apps/get_pods_-o_json.txt")).items
		expect(text).toContain("name: " .. pods[2].metadata.name)
		expect((string.find(text, "name: " .. pods[3].metadata.name .. "\n", 1, true))).toBeNil()
	end)

	it("keeps the sort when a row is clicked", function()
		local capture = captures.build(PODS, PODS_CMD)
		local sorted = Viewstate.sortedBy(Viewstate.sortedBy(Viewstate.default(), "NAME"), "NAME")
		local view = render(capture, sorted)
		for _, row in gridRows(view) do
			local vs = Viewstate.decode(string.sub(nodes.action(row) :: string, 3))
			expect(vs.sort).toBe("NAME")
			expect(vs.desc).toBe(true)
		end
		local names = {}
		for _, row in gridRows(view) do
			table.insert(names, nodes.text((row.c :: { Node })[2]))
		end
		local copy = table.clone(names)
		table.sort(copy, function(a, b)
			return a > b
		end)
		expect(names).toEqual(copy)
	end)
end)

describe("yaml view: single objects and secrets", function()
	it("shows a single object's YAML directly", function()
		local view = render(
			captures.build(
				"real/ns-apps/get_pod_crashloop_-o_yaml",
				"kubectl get pod crashloop -n tern-test-apps -o yaml"
			)
		)
		expect(#gridRows(view)).toBe(0)
		local list = codes(view)
		expect(#list).toBe(1)
		expect(codeText(list[1])).toContain("name: crashloop")
		expect(nodes.text(view)).toContain("Pod crashloop")
	end)

	it("masks Secret data and says so", function()
		local capture = captures.build(
			"real/ns-apps/get_secret_app-secret_-o_yaml",
			"kubectl get secret app-secret -n tern-test-apps -o yaml"
		)
		local raw = table.concat(capture.lines, "\n")
		expect(raw).toContain("tern-kube-test-not-a-secret")
		local view = render(capture)
		local warning = nodes.find(view, nodes.role("tern-kube.sensitive")) :: Node
		expect((warning.p :: any).tone).toBe("warning")
		local text = codeText(codes(view)[1])
		expect((string.find(text, "tern-kube-test-not-a-secret", 1, true))).toBeNil()
		expect((string.find(text, "a3ViZS1sZW5zLXRlc3Qtbm90LWEtc2VjcmV0", 1, true))).toBeNil()
		expect(text).toContain("<redacted:")
	end)

	-- With values shown, the masking banner would be a lie, but the user
	-- must still be told the block holds Secret values.
	it("warns instead of claiming to mask when Secret values are shown", function()
		local capture = captures.build(
			"real/ns-apps/get_secret_app-secret_-o_yaml",
			"kubectl get secret app-secret -n tern-test-apps -o yaml",
			{ showSecrets = true, strict = false }
		)
		local view = render(capture)
		local warning = nodes.find(view, nodes.role("tern-kube.sensitive")) :: Node
		expect((warning.p :: any).tone).toBe("warning")
		expect(nodes.text(warning)).toContain("security.show_secret_values")
		expect((string.find(nodes.text(view), YamlView.SENSITIVE, 1, true))).toBeNil()
		expect(codeText(codes(view)[1])).toContain("tern-kube-test-not-a-secret")
	end)

	it("says when strict mode masked values outside Secrets", function()
		local lines = { "apiVersion: v1", "data:", "  api_key: abc123", "kind: ConfigMap", "metadata:", "  name: c" }
		local capture = captures.fromLines("kubectl get cm c -o yaml", lines, 0, { showSecrets = false, strict = true })
		local view = render(capture)
		local warning = nodes.find(view, nodes.role("tern-kube.sensitive")) :: Node
		expect(nodes.text(warning)).toContain("sensitive_output_strict_mode")
		expect(codeText(codes(view)[1])).toContain("api_key: '<redacted: 6 bytes>'")
		local plain = render(captures.fromLines("kubectl get cm c -o yaml", lines, 0))
		expect(nodes.find(plain, nodes.role("tern-kube.sensitive"))).toBeNil()
	end)

	it("splits a multi-document manifest into its objects", function()
		local capture = captures.fromLines("kubectl get -f mutate/app.yaml -o yaml", MANIFEST, 0)
		local view = render(capture, Viewstate.opened(Viewstate.default(), YamlView.docKey(2)))
		local kinds = {}
		for _, row in gridRows(view) do
			table.insert(kinds, nodes.text((row.c :: { Node })[1]))
		end
		expect(kinds).toEqual({ "ConfigMap", "Deployment", "Service" })
		local text = codeText(codes(view)[1])
		expect(text).toContain("kind: Deployment")
		expect((string.find(text, "kind: Service", 1, true))).toBeNil()
		expect((string.find(text, "---", 1, true))).toBeNil()
	end)
end)

describe("yaml view: large lists", function()
	local function bigList(n: number): { string }
		local lines = { "apiVersion: v1", "items:" }
		for i = 1, n do
			table.insert(lines, "- apiVersion: v1")
			table.insert(lines, "  kind: ConfigMap")
			table.insert(lines, "  metadata:")
			table.insert(lines, string.format("    name: cm-%04d", i))
			table.insert(lines, "    namespace: bulk")
			table.insert(lines, "  data:")
			table.insert(lines, string.format("    value: v%d", i))
		end
		table.insert(lines, "kind: List")
		table.insert(lines, "metadata:")
		table.insert(lines, '  resourceVersion: ""')
		return lines
	end

	it("pages a 1000-document list and renders the opened document in under 30 ms", function()
		local capture = captures.fromLines("kubectl get configmaps -n bulk -o yaml", bigList(1000), 0)
		expect(#(capture.yaml :: any).docs).toBe(1000)
		local vs = Viewstate.opened(Viewstate.default(), YamlView.docKey(250))
		local runs = 10
		local start = os.clock()
		local view: Node
		for _ = 1, runs do
			view = render(capture, vs)
		end
		local ms = (os.clock() - start) * 1000 / runs
		expect(ms < 30).toBe(true)
		local v = view :: Node
		expect(#gridRows(v)).toBe(YamlView.PAGE_SIZE)
		expect(#codes(v)).toBe(1)
		expect(codeText(codes(v)[1])).toContain("name: cm-0250")
		local pager = nodes.find(v, nodes.role("tern-kube.pager")) :: Node
		local pageActions = nodes.actions(pager)
		expect(#pageActions).toBe(2)
		-- Paging keeps the open document.
		local second = Viewstate.decode(string.sub(pageActions[2], 3))
		expect(second.page).toBe(1)
		expect(second.open).toBe(YamlView.docKey(250))
		local page2 = render(capture, second)
		expect(nodes.text(gridRows(page2)[1])).toContain("cm-0501")
	end)
end)

return nil
