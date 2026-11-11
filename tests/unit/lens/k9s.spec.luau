--!strict
-- Lens captures and views of `rollout history`, `config get-contexts`,
-- `api-resources` and `auth can-i` built from real kubectl output
-- (capture-k9s.sh): the mode each argv gets, rows and facets that match the
-- output, no kubectl message turned into a row, and the header telling an
-- answer (`can-i` no, exit 1) from a failure.
local Capture = require("../../../plugin/lib/lens/capture")
local View = require("../../../plugin/lib/lens/view")
local json = require("../../lib/json")
local k9s = require("../../lib/k9s")
local nodes = require("../../lib/nodes")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function build(id: string, expanded: boolean?): Capture.Capture
	local f = k9s.load(id, expanded)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function tables(c: Capture.Capture): { any }
	return (c.snapshot :: any).tables
end

local function column(c: Capture.Capture, name: string): { string }
	local out: { string } = {}
	for _, tbl in tables(c) do
		local index = table.find(tbl.headers, name)
		for _, row in tbl.rows do
			table.insert(out, if index then row.cells[index] else "")
		end
	end
	return out
end

local function render(c: Capture.Capture, vs: any?): any
	return View.render(c, vs or vsm.default(), { mutations = true }) :: any
end
local function lacks(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) == nil
end

describe("lens k9s modes", function()
	it("maps every argv form to its mode", function()
		local cases: { { string } } = {
			{ "rh-deploy", "history" },
			{ "rh-multi", "history" },
			{ "rh-deploy-rev2", "revision" },
			{ "rh-deploy-rev2-json", "json" },
			{ "rh-deploy-rev2-yaml", "yaml" },
			{ "rh-deploy-name", "name" },
			{ "rh-deploy-json", "raw" },
			{ "ctx-default", "contexts" },
			{ "ctx-name", "contexts" },
			{ "ctx-noheaders", "contexts" },
			{ "ar-wide", "apiresources" },
			{ "ar-name", "apiresources" },
			{ "ar-json", "raw" },
			{ "ar-noheaders", "raw" },
			{ "ci-yes", "cani" },
			{ "ci-quiet-no", "cani" },
			{ "ci-list", "canilist" },
		}
		for _, c in cases do
			expect(c[1] .. " " .. build(c[1]).mode).toBe(c[1] .. " " .. c[2])
		end
	end)
end)

describe("lens rollout history", function()
	it("one table per object, titled TYPE/NAME, current on the highest revision", function()
		local c = build("rh-multi")
		local list = tables(c)
		expect(#list).toBe(2)
		expect(list[1].title).toBe("deployment.apps/hist")
		expect(list[2].title).toBe("deployment.apps/fresh")
		expect(list[1].headers).toEqual({ "REVISION", "CHANGE-CAUSE" })
		expect(column(c, "REVISION")).toEqual({ "1", "2", "3", "1" })
		local d = c.k9s :: any
		expect(d.notes["deployment.apps/hist@3"]).toEqual({ REVISION = "current" })
		expect(d.notes["deployment.apps/hist@2"]).toBeNil()
		expect(d.notes["deployment.apps/fresh@1"]).toEqual({ REVISION = "current" })
		local row = list[1].rows[1]
		expect(row.ref.kind).toBe("Deployment")
		expect(row.ref.group).toBe("apps")
		expect(row.ref.namespace).toBe("tern-test-k9s")
		expect(row.ref.clusterContext).toBe("kind-tern-kube-dev")
		expect(c.unparsed).toBe(0)
	end)

	it("renders the multi-table headings from the titles and the current note", function()
		local text = nodes.text(render(build("rh-multi")))
		expect(text).toContain("deployment.apps/hist")
		expect(text).toContain("deployment.apps/fresh")
		expect(text).toContain("current")
	end)

	it("kubectl's refusals are errors with no rows", function()
		for _, id in { "rh-notfound", "rh-pod", "rh-svc", "rh-noresource" } do
			local c = build(id)
			expect(#tables(c)).toBe(0)
			expect(c.diagnostics[1].severity).toBe("error")
			local node = render(c)
			expect(nodes.find(node, nodes.role("tern-kube.exit")) ~= nil).toBe(true)
		end
	end)
end)

describe("lens rollout history --revision", function()
	it("raw tabs and expanded tabs give the same view", function()
		for _, id in { "rh-deploy-rev2", "rh-ds-rev2", "rh-sts-rev1" } do
			local raw = build(id)
			local expanded = build(id, true)
			expect(raw.describe).toEqual(expanded.describe)
			expect(raw.k9s and raw.k9s.revision).toEqual(expanded.k9s and expanded.k9s.revision)
		end
	end)

	it("summarizes object, revision, cause and images", function()
		local c = build("rh-deploy-rev2", true)
		local info = (c.k9s :: any).revision
		expect(info.type).toBe("deployment.apps")
		expect(info.revision).toBe(2)
		expect(info.cause).toBe("downgrade to 3.9 (it's a test)")
		expect(info.images).toEqual({ "registry.k8s.io/pause:3.9" })
		expect(info.ref.kind).toBe("Deployment")
		local node = render(c)
		local text = nodes.text(node)
		expect(text).toContain("revision 2")
		expect(text).toContain("registry.k8s.io/pause:3.9")
		expect(nodes.find(node, nodes.role("tern-kube.exit"))).toBeNil()
	end)

	it("masks environment values with sensitive names, as describe does", function()
		local lines = {
			"deployment.apps/web with revision #1",
			"Pod Template:",
			"  Labels:\tapp=web",
			"  Containers:",
			"   app:",
			"    Image:\tx",
			"    Environment:",
			"      DB_PASSWORD:\thunter2",
			"      MODE:\tfast",
		}
		local c = Capture.build(
			runs.run("kubectl -n a rollout history deploy/web --revision=1"),
			lines,
			0,
			{ decode = json.decode, policy = { showSecrets = false, strict = true } }
		)
		expect(c.masked).toBe(true)
		expect(lacks(nodes.text(render(c)), "hunter2")).toBe(true)
	end)
end)

describe("lens config get-contexts", function()
	it("rows keep spaced and ARN names; CURRENT gets a note", function()
		local c = build("ctx-default")
		expect(column(c, "NAME")).toEqual({
			"arn:aws:eks:us-east-1:123456789012:cluster/prod",
			"kind-tern-kube-dev",
			"tk spaced",
			"tk-apps",
			"tk-broken",
		})
		expect((c.k9s :: any).notes["context/kind-tern-kube-dev"]).toEqual({ CURRENT = "current" })
		expect(tables(c)[1].facets).toEqual({ "CLUSTER", "AUTHINFO" })
		expect(c.unparsed).toBe(0)
	end)

	it("explains the star when --context is given", function()
		local text = nodes.text(render(build("ctx-flag-context")))
		expect(text).toContain("* is the kubeconfig's current-context, not --context")
		expect(lacks(nodes.text(render(build("ctx-default"))), "not --context")).toBe(true)
	end)

	it("facets CLUSTER and AUTHINFO because they split the rows", function()
		local node = render(build("ctx-default"))
		expect(nodes.find(node, nodes.key("facet-CLUSTER")) ~= nil).toBe(true)
		expect(nodes.find(node, nodes.key("facet-AUTHINFO")) ~= nil).toBe(true)
		expect(nodes.find(node, nodes.key("facet-STATUS"))).toBeNil()
	end)

	it("-o name and a missing context", function()
		expect(column(build("ctx-name"), "NAME")[3]).toBe("tk spaced")
		local missing = build("ctx-missing")
		expect(#tables(missing)[1].rows).toBe(0)
		expect(nodes.text(render(missing))).toContain("error: context nope not found")
	end)
end)

describe("lens api-resources", function()
	it("rows from discovery; tags GROUP, VERB and CATEGORY; facets follow -o wide", function()
		local c = build("ar-wide")
		local tbl = tables(c)[1]
		expect(tbl.facets).toEqual({ "NAMESPACED", "GROUP", "VERB", "CATEGORY" })
		expect(tbl.headers[1]).toBe("NAME")
		expect(table.find(tbl.headers, "VERBS") ~= nil).toBe(true)
		local byKey: { [string]: any } = {}
		for _, row in tbl.rows do
			byKey[row.key] = row
		end
		expect(byKey["api/pods"].tags.GROUP).toEqual({ "core" })
		expect(byKey["api/deployments.apps"].tags.GROUP).toEqual({ "apps" })
		expect(table.find(byKey["api/pods"].tags.VERB, "list") ~= nil).toBe(true)
		expect(byKey["api/widgets.lens.example.com"].tags.CATEGORY).toEqual({ "lens" })
		-- events (core) and events.events.k8s.io are distinct rows.
		expect(byKey["api/events"] ~= nil and byKey["api/events.events.k8s.io"] ~= nil).toBe(true)
		expect(c.unparsed).toBe(0)
		local plain = tables(build("ar-default"))[1]
		expect(plain.facets).toEqual({ "NAMESPACED", "GROUP" })
	end)

	it("tag facets filter rows", function()
		local c = build("ar-wide")
		local vs = vsm.toggledFilter(vsm.default(), "GROUP", "apps")
		local node = render(c, vs)
		local counts = nodes.text(nodes.find(node, nodes.role("tern-kube.counts")) :: any)
		expect(counts).toContain(" of ")
		local text = nodes.text(node)
		expect(text).toContain("deployments")
		expect(lacks(text, "configmaps")).toBe(true)
	end)

	it("-o name rows and a partial discovery", function()
		local names = build("ar-name")
		expect(tables(names)[1].headers).toEqual({ "NAME" })
		expect(column(names, "NAME")[1]).toBe("bindings")
		local partial = build("synthetic/ar-partial")
		expect(#tables(partial)[1].rows > 0).toBe(true)
		local text = nodes.text(render(partial))
		expect(text).toContain("Partial discovery: metrics.k8s.io/v1beta1")
	end)
end)

describe("lens auth can-i", function()
	it("a `no` is an answer: NO card, no exit badge", function()
		local node = render(build("ci-no-as"))
		expect(nodes.find(node, nodes.role("tern-kube.cani-no")) ~= nil).toBe(true)
		expect(nodes.find(node, nodes.role("tern-kube.exit"))).toBeNil()
		expect(nodes.text(node)).toContain(
			"Can system:serviceaccount:tern-test-k9s:viewer delete pods in namespace tern-test-k9s?"
		)
	end)

	it("-q answers from the exit status; warnings still answer", function()
		local quiet = render(build("ci-quiet-yes"))
		expect(nodes.find(quiet, nodes.role("tern-kube.cani-yes")) ~= nil).toBe(true)
		local warned = render(build("ci-unknown"))
		expect(nodes.find(warned, nodes.role("tern-kube.cani-yes")) ~= nil).toBe(true)
		expect(nodes.text(warned)).toContain("the server doesn't have a resource type 'frobs'")
		expect(nodes.text(warned)).toContain("wildcard")
	end)

	it("an error is not an answer: the exit badge stays", function()
		local node = render(build("ci-noargs"))
		expect(nodes.find(node, nodes.role("tern-kube.exit")) ~= nil).toBe(true)
		expect(nodes.find(node, nodes.role("tern-kube.cani-none")) ~= nil).toBe(true)
	end)

	it("--list: rules table with TYPE/VERB/GROUP facets and `all` notes", function()
		local c = build("ci-list")
		local tbl = tables(c)[1]
		expect(tbl.headers).toEqual({ "Resources", "Non-Resource URLs", "Resource Names", "Verbs" })
		expect(tbl.facets).toEqual({ "TYPE", "VERB", "GROUP" })
		local first = tbl.rows[1]
		expect(first.tags.TYPE).toEqual({ "resource" })
		expect((c.k9s :: any).notes[first.key]).toEqual({ Resources = "all", Verbs = "all" })
		-- Duplicate rows ([/healthz] twice) keep unique keys.
		local seen: { [string]: boolean } = {}
		for _, row in tbl.rows do
			expect(seen[row.key]).toBeNil()
			seen[row.key] = true
		end
		expect(c.unparsed).toBe(0)
	end)

	it("--list as someone else notes that Explore runs as the context's user", function()
		local text = nodes.text(render(build("ci-list-as")))
		expect(text).toContain("Explore runs as the context's own user")
		expect(lacks(nodes.text(render(build("ci-list"))), "Explore runs as")).toBe(true)
	end)
end)

return nil
