--!strict
-- The table body a user clicks through: chips filter, rows open the right
-- inspector, Inspect shows everything about one row, pages cap rendering,
-- and every click carries the rest of the view state along.
local Capture = require("../../../plugin/lib/lens/capture")
local Link = require("../../../plugin/lib/mutation/link")
local Quick = require("../../../plugin/lib/actions/quick")
local TableView = require("../../../plugin/lib/render/table_view")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function build(id: string): Capture.Capture
	local f = runs.load(id)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function render(c: Capture.Capture, vs: vsm.ViewState): (any, TableView.Counts)
	local node, counts = TableView.render(c, vs)
	assert(node, "expected a table body")
	return node, counts
end

local function rowNames(node: any): { string }
	local out: { string } = {}
	for _, r in nodes.findAll(node, nodes.class("tk-r")) do
		local first = nodes.find(r, nodes.class("tk-c")) :: any
		table.insert(out, nodes.text(first))
	end
	return out
end

local function decodeAction(a: string): vsm.ViewState?
	if string.sub(a, 1, 2) ~= "v=" then
		return nil
	end
	return vsm.decode(string.sub(a, 3))
end

local function chipAction(node: any, label: string): string
	local chip = nodes.find(node, function(n)
		return n.k == "badge" and string.find(nodes.ownText(n), label, 1, true) == 1
	end)
	assert(chip, "no chip " .. label)
	return nodes.action(chip) :: string
end

describe("table view", function()
	it("renders one grid with every pod and counts", function()
		local node, counts = render(build("ns-apps/get_pods"), vsm.default())
		expect(#nodes.findAll(node, nodes.class("tk-grid"))).toBe(1)
		expect(#rowNames(node)).toBe(7)
		expect(counts).toEqual({ shown = 7, matched = 7, total = 7 })
	end)

	it("get all stacks one grid per kind under kind headings", function()
		local node = render(build("ns-apps/get_all"), vsm.default())
		expect(#nodes.findAll(node, nodes.class("tk-grid"))).toBe(6)
		local headings = nodes.findAll(node, nodes.role("tern-kube.kind"))
		expect(#headings).toBe(6)
		expect(string.find(nodes.text(headings[4]), "Deployment", 1, true) ~= nil).toBe(true)
	end)

	it("offers STATUS chips with counts and a Problems chip", function()
		local node = render(build("ns-apps/get_pods"), vsm.default())
		local action = chipAction(node, "Running ")
		local vs = decodeAction(action) :: vsm.ViewState
		expect(vs.filters).toEqual({ "STATUS=Running" })
		local problems = decodeAction(chipAction(node, "Problems 3")) :: vsm.ViewState
		expect(problems.problems).toBe(true)
	end)

	it("offers KIND chips only when several kinds are shown, NAMESPACE only when several", function()
		local all = render(build("ns-apps/get_all"), vsm.default())
		expect(nodes.find(all, nodes.key("facet-KIND")) ~= nil).toBe(true)
		expect(nodes.find(all, nodes.key("facet-NAMESPACE"))).toBeNil()
		local pods = render(build("ns-apps/get_pods"), vsm.default())
		expect(nodes.find(pods, nodes.key("facet-KIND"))).toBeNil()
		local allNs = render(build("all-namespaces/get_pods_-A"), vsm.default())
		expect(nodes.find(allNs, nodes.key("facet-NAMESPACE")) ~= nil).toBe(true)
	end)

	it("filtering keeps only matching rows and keeps the open row open", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.toggledFilter(vsm.opened(vsm.default(), "/Pod/tern-test-apps/db-0"), "STATUS", "Running")
		local node, counts = render(c, vs)
		for _, n in rowNames(node) do
			expect(n == "pending" or n == "crashloop").toBe(false)
		end
		expect(counts.matched < counts.total).toBe(true)
		expect(nodes.text(nodes.find(node, nodes.class("tk-open")) :: any)).toContain("db-0")
		local insp = nodes.find(node, nodes.role("tern-kube.inspector")) :: any
		expect(nodes.text(insp)).toContain("db-0")
	end)

	it("a filtered-out open row shows no inspector rather than another row's", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.toggledFilter(vsm.opened(vsm.default(), "/Pod/tern-test-apps/pending"), "STATUS", "Running")
		local node = render(c, vs)
		expect(nodes.find(node, nodes.role("tern-kube.inspector"))).toBeNil()
	end)

	it("the inspector shows the clicked row's cells and target-aware actions", function()
		local c = build("ns-apps/get_pods")
		local node = render(c, vsm.opened(vsm.default(), "/Pod/tern-test-apps/crashloop"))
		local insp = nodes.find(node, nodes.role("tern-kube.inspector")) :: any
		local text = nodes.text(insp)
		expect(text).toContain("crashloop")
		expect(text).toContain("RESTARTS")
		local actions = nodes.actions(insp)
		expect(table.find(actions, "explore=/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
		expect(table.find(actions, "copy=logs|/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
		expect(table.find(actions, "copy=describe|/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
	end)

	it("non-pod rows offer no logs copy", function()
		local c = build("ns-apps/get_deployments")
		local node = render(c, vsm.opened(vsm.default(), "apps/Deployment/tern-test-apps/web"))
		local insp = nodes.find(node, nodes.role("tern-kube.inspector")) :: any
		expect(table.find(nodes.actions(insp), "copy=logs|apps/Deployment/tern-test-apps/web")).toBeNil()
	end)

	it("every grid and inspector action carries sort, filters and selection along", function()
		local c = build("ns-apps/get_pods")
		local base = vsm.toggledFilter(vsm.sortedBy(vsm.default(), "AGE"), "STATUS", "Running")
		base = vsm.opened(base, "/Pod/tern-test-apps/db-0")
		local node = render(c, base)
		local checked = 0
		for _, region in nodes.findAll(node, nodes.class("tk-grid")) do
			for _, a in nodes.actions(region) do
				local vs = decodeAction(a)
				if vs then
					checked += 1
					expect(vs.filters).toEqual({ "STATUS=Running" })
					expect(vs.sort ~= nil).toBe(true)
				end
			end
		end
		expect(checked > 10).toBe(true)
		local rowVs = decodeAction(nodes.action(nodes.findAll(node, nodes.class("tk-r"))[1]) :: string) :: vsm.ViewState
		expect(rowVs.sort).toBe("AGE")
		local closeVs = decodeAction(chipAction(node, "Close")) :: vsm.ViewState
		expect(closeVs.open).toBeNil()
		expect(closeVs.sort).toBe("AGE")
		expect(closeVs.filters).toEqual({ "STATUS=Running" })
	end)

	it("Inspect opens a full view with breadcrumb, all cells, source line and Back", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.inspect(vsm.default(), "/Pod/tern-test-apps/db-0")
		local node = render(c, vs)
		expect(nodes.find(node, nodes.class("tk-grid"))).toBeNil()
		local crumbs = nodes.text(nodes.find(node, nodes.role("tern-kube.breadcrumb")) :: any)
		expect(crumbs).toBe("Snapshot › Pod › db-0")
		local code = nodes.find(node, nodes.kind("code")) :: any
		expect(string.sub(code.p.text, 1, 4)).toBe("db-0")
		local back = decodeAction(chipAction(node, "Back")) :: vsm.ViewState
		expect(back.full).toBe(false)
		expect(back.open).toBe("/Pod/tern-test-apps/db-0")
	end)

	it("Inspect of a -o json row shows the object tree", function()
		local c = build("ns-apps/get_pods_-o_json")
		local node = render(c, vsm.inspect(vsm.default(), "/Pod/tern-test-apps/db-0"))
		expect(nodes.find(node, nodes.kind("tree")) ~= nil).toBe(true)
	end)

	it("pages 1000 rows by 500 with page chips", function()
		local c = build("synthetic/rows-1000/get_pods")
		local node, counts = render(c, vsm.default())
		expect(counts).toEqual({ shown = 500, matched = 1000, total = 1000 })
		expect(#nodes.findAll(node, nodes.class("tk-r"))).toBe(500)
		local second = decodeAction(chipAction(node, "501-1000")) :: vsm.ViewState
		expect(second.page).toBe(1)
		local node2, counts2 = render(c, second)
		expect(counts2.shown).toBe(500)
		local page1: { [string]: boolean } = {}
		for _, n in rowNames(node) do
			page1[n] = true
		end
		for _, n in rowNames(node2) do
			expect(page1[n]).toBeNil()
		end
		expect(nodes.text(nodes.find(node2, nodes.role("tern-kube.pages")) :: any)).toContain("Rows 501-1000 of 1000")
	end)

	it("a page past the end shows the last page", function()
		local c = build("synthetic/rows-1000/get_pods")
		local _, counts = render(c, vsm.paged(vsm.default(), 9))
		expect(counts.shown).toBe(500)
	end)

	it("returns nil when there is no table (error-only output)", function()
		local node = TableView.render(build("errors/get_foos"), vsm.default())
		expect(node).toBeNil()
	end)

	it("max_rendered_rows sets the page size", function()
		local c = build("synthetic/rows-1000/get_pods")
		local node, counts = TableView.render(c, vsm.default(), { pageSize = 200 })
		assert(node, "expected a table body")
		expect(counts).toEqual({ shown = 200, matched = 1000, total = 1000 })
		expect(nodes.text(nodes.find(node, nodes.role("tern-kube.pages")) :: any)).toContain("801-1000")
	end)
end)

-- Quick actions are two clicks from any row: open the row, click a chip. The
-- chip's only payload is a tern-kube://act/ link the window validates again,
-- so what it decodes to is what would run.
describe("table view quick-action chips", function()
	-- The fixture's output under a command line that pins the target, as a
	-- user would type it.
	local function pinned(id: string, flags: { string }): Capture.Capture
		local f = runs.load(id)
		local args = table.clone(flags)
		table.move(f.run.args, 1, #f.run.args, #args + 1, args)
		return Capture.build({ program = f.run.program, args = args }, f.lines, f.status, { decode = json.decode })
	end

	local function quick(c: Capture.Capture, key: string): { [string]: Quick.Request }
		local node = render(c, vsm.opened(vsm.default(), key))
		local insp = nodes.find(node, nodes.role("tern-kube.inspector")) :: any
		local out: { [string]: Quick.Request } = {}
		for _, chip in nodes.findAll(insp, nodes.role("tern-kube.quick")) do
			local action = nodes.action(chip) :: string
			expect(string.sub(action, 1, 4 + #Quick.SCHEME)).toBe("act=" .. Quick.SCHEME)
			local req, err = Quick.decode(string.sub(action, 5))
			assert(req, err)
			out[nodes.ownText(chip)] = req
		end
		return out
	end

	local function labels(chips: { [string]: Quick.Request }): { string }
		local out: { string } = {}
		for label in chips do
			table.insert(out, label)
		end
		table.sort(out)
		return out
	end

	it("a pod row offers Shell, Logs and Port-forward for that pod", function()
		local chips = quick(build("ns-apps/get_pods"), "/Pod/tern-test-apps/db-0")
		expect(labels(chips)).toEqual({ "Logs", "Port-forward", "Shell" })
		local shell = chips.Shell
		expect(shell.action).toBe("shell")
		local r = assert(shell.ref, "shell chip has a ref")
		expect(r.kind).toBe("Pod")
		expect(r.name).toBe("db-0")
		expect(r.namespace).toBe("tern-test-apps")
		expect(chips.Logs.action).toBe("logs-follow")
		expect(chips["Port-forward"].action).toBe("port-forward")
	end)

	it("pins the lensed command's --context and --kubeconfig in every chip", function()
		local c = pinned("ns-apps/get_pods", { "--context", "kind-tern-kube-dev", "--kubeconfig", "/tmp/k c/config" })
		for _, req in quick(c, "/Pod/tern-test-apps/db-0") do
			expect(req.target.context).toBe("kind-tern-kube-dev")
			expect(req.target.kubeconfig).toBe("/tmp/k c/config")
		end
	end)

	it("an unpinned command leaves the context out, so the split prints the effective one", function()
		for _, req in quick(build("ns-apps/get_pods"), "/Pod/tern-test-apps/db-0") do
			expect(req.target.context).toBeNil()
		end
	end)

	it("a deployment row offers Logs and Port-forward but no Shell (no ready pod is known)", function()
		local chips = quick(build("ns-apps/get_deployments"), "apps/Deployment/tern-test-apps/web")
		expect(labels(chips)).toEqual({ "Logs", "Port-forward" })
		expect(assert(chips.Logs.ref, "logs chip has a ref").group).toBe("apps")
	end)

	it("a service row forwards its first service port from PORT(S)", function()
		local chips = quick(build("ns-apps/get_svc"), "/Service/tern-test-apps/web-lb")
		expect(labels(chips)).toEqual({ "Port-forward" })
		expect(chips["Port-forward"].opts.port).toBe(80)
	end)

	it("kinds without quick actions get no chips", function()
		expect(labels(quick(build("ns-apps/get_configmaps"), "/ConfigMap/tern-test-apps/app-config"))).toEqual({})
	end)

	it("chips leave the view state alone: no chip action is a v= state change", function()
		local vs = vsm.opened(vsm.sortedBy(vsm.default(), "AGE"), "/Pod/tern-test-apps/db-0")
		local node = render(build("ns-apps/get_pods"), vs)
		local seen = 0
		for _, chip in nodes.findAll(node, nodes.role("tern-kube.quick")) do
			seen += 1
			expect(decodeAction(nodes.action(chip) :: string)).toBeNil()
		end
		expect(seen).toBe(3)
	end)

	it("parses service ports from PORT(S) cells", function()
		expect(TableView.servicePorts("80:30081/TCP,443:30443/TCP")).toEqual({ 80, 443 })
		expect(TableView.servicePorts("5432/TCP")).toEqual({ 5432 })
		expect(TableView.servicePorts("<none>")).toEqual({})
		expect(TableView.servicePorts("99999/TCP")).toEqual({})
	end)
end)

-- With mutations enabled (config mutations.enabled), the inspector also
-- offers Delete / Restart / Scale and the mutating quick actions. Their only
-- payload is a link the approve block validates and previews: a chip can at
-- most ask for a preview of an ordinary command on that one object.
describe("table view mutation chips", function()
	local function inspector(c: Capture.Capture, key: string, mutations: boolean?): any
		local node = TableView.render(c, vsm.opened(vsm.default(), key), { mutations = mutations })
		return nodes.find(node :: any, nodes.role("tern-kube.inspector")) :: any
	end

	local function mutateChips(insp: any): { [string]: Link.Request }
		local out: { [string]: Link.Request } = {}
		for _, chip in nodes.findAll(insp, nodes.role("tern-kube.mutate")) do
			local action = nodes.action(chip) :: string
			expect(string.sub(action, 1, 7 + #Link.SCHEME)).toBe("mutate=" .. Link.SCHEME)
			local req, err = Link.decode(string.sub(action, 8))
			assert(req, err)
			out[nodes.ownText(chip)] = req
		end
		return out
	end

	local function quickLabels(insp: any): { string }
		local out: { string } = {}
		for _, chip in nodes.findAll(insp, nodes.role("tern-kube.quick")) do
			table.insert(out, nodes.ownText(chip))
		end
		table.sort(out)
		return out
	end

	it("a deployment row offers Delete, Restart and Scale for that object", function()
		local chips =
			mutateChips(inspector(build("ns-apps/get_deployments"), "apps/Deployment/tern-test-apps/web", true))
		expect(chips.Delete.op).toBe("delete")
		expect(chips.Delete.kind).toBe("deployment.apps")
		expect(chips.Delete.name).toBe("web")
		expect(chips.Delete.namespace).toBe("tern-test-apps")
		expect(chips.Restart.op).toBe("restart")
		expect(chips.Scale.op).toBe("scale")
		expect(chips.Scale.replicas).toBeNil()
		expect(chips.Delete.context).toBeNil()
	end)

	it("a pod row offers Delete and Debug but neither Restart nor Scale", function()
		local insp = inspector(build("ns-apps/get_pods"), "/Pod/tern-test-apps/db-0", true)
		local chips = mutateChips(insp)
		expect(chips.Delete.kind).toBe("pod")
		expect(chips.Restart).toBeNil()
		expect(chips.Scale).toBeNil()
		expect(quickLabels(insp)).toEqual({ "Debug", "Edit", "Logs", "Port-forward", "Shell" })
		expect(chips.Label.op).toBe("label")
		expect(chips.Annotate.op).toBe("annotate")
		expect(chips.Patch.op).toBe("patch")
		expect(chips.Patch.patch).toBeNil()
	end)

	local function chipLabels(chips: { [string]: Link.Request }): { string }
		local out: { string } = {}
		for label in chips do
			table.insert(out, label)
		end
		table.sort(out)
		return out
	end

	-- A table never shows spec.paused, so a Deployment row offers both;
	-- the approve block's preview says which one would change nothing.
	it("a deployment row offers the rollout verbs, both Pause and Resume, and the metadata verbs", function()
		local insp = inspector(build("ns-apps/get_deployments"), "apps/Deployment/tern-test-apps/web", true)
		expect(chipLabels(mutateChips(insp))).toEqual({
			"Annotate",
			"Delete",
			"Label",
			"Patch",
			"Pause",
			"Restart",
			"Resume",
			"Scale",
			"Undo",
		})
		expect(table.find(quickLabels(insp), "Edit") ~= nil).toBe(true)
	end)

	-- STATUS says whether a node is cordoned: only the op that changes
	-- something is offered.
	it("a node row offers Cordon or Uncordon from STATUS, plus Drain and no namespace", function()
		local f = runs.load("cluster/get_nodes")
		local key = "/Node//tern-kube-dev-control-plane"
		local ready = Capture.build(f.run, f.lines, f.status, { decode = json.decode })
		local chips = mutateChips(inspector(ready, key, true))
		expect(chipLabels(chips)).toEqual({ "Annotate", "Cordon", "Delete", "Drain", "Label", "Patch" })
		expect(chips.Cordon.kind).toBe("node")
		expect(chips.Cordon.namespace).toBeNil()
		local cordoned: { string } = {}
		for i, line in f.lines do
			cordoned[i] = (string.gsub(line, " Ready ", " Ready,SchedulingDisabled "))
		end
		local off = Capture.build(f.run, cordoned, f.status, { decode = json.decode })
		expect(chipLabels(mutateChips(inspector(off, key, true)))).toEqual({
			"Annotate",
			"Delete",
			"Drain",
			"Label",
			"Patch",
			"Uncordon",
		})
	end)

	it("a CronJob row offers Run now", function()
		local insp = inspector(build("ns-batch/get_cronjobs"), "batch/CronJob/tern-test-batch/nightly-report", true)
		expect(table.find(quickLabels(insp), "Run now") ~= nil).toBe(true)
	end)

	it("pins the lensed command's --context as a flag-sourced target", function()
		local f = runs.load("ns-apps/get_deployments")
		local args = { "--context", "kind-tern-kube-dev" }
		table.move(f.run.args, 1, #f.run.args, #args + 1, args)
		local c = Capture.build({ program = f.run.program, args = args }, f.lines, f.status, { decode = json.decode })
		for _, req in mutateChips(inspector(c, "apps/Deployment/tern-test-apps/web", true)) do
			expect(req.context).toBe("kind-tern-kube-dev")
			expect(req.source).toBe("flag")
		end
	end)

	it("offers no mutating chip when mutations are disabled", function()
		local insp = inspector(build("ns-apps/get_pods"), "/Pod/tern-test-apps/db-0", false)
		expect(#nodes.findAll(insp, nodes.role("tern-kube.mutate"))).toBe(0)
		expect(quickLabels(insp)).toEqual({ "Logs", "Port-forward", "Shell" })
	end)
end)

-- Track 2 plan 5: events tables split by TYPE and REASON, tint Warnings,
-- and every row opens on its involved object.
describe("table view events overlay", function()
	local function facetValues(node: any, col: string): { string }
		local row = nodes.find(node, nodes.key("facet-" .. col))
		if row == nil then
			return {}
		end
		local out: { string } = {}
		for _, b in nodes.findAll(row, nodes.kind("badge")) do
			table.insert(out, nodes.ownText(b))
		end
		return out
	end

	it("offers TYPE and REASON facets with counts", function()
		local node = render(build("ns-apps/events"), vsm.default())
		expect(#facetValues(node, "TYPE")).toBe(2)
		local reasons = facetValues(node, "REASON")
		expect(#reasons > 1).toBe(true)
		expect(#reasons <= TableView.FACET_VALUES).toBe(true)
		expect(string.find(reasons[1], "^%a+ %d+$") ~= nil).toBe(true)
	end)

	it("REASON filters keep only that reason", function()
		local c = build("ns-apps/events")
		local node = render(c, vsm.toggledFilter(vsm.default(), "REASON", "BackOff"))
		for _, r in nodes.findAll(node, nodes.class("tk-r")) do
			expect(nodes.text(nodes.findAll(r, nodes.class("tk-c"))[3])).toBe("BackOff")
		end
	end)

	it("keeps the EVENT column of watch events as a facet", function()
		local node = render(build("ns-logs/get_events_-w_--output-watch-events_--request-timeout=8s"), vsm.default())
		local events = facetValues(node, "EVENT")
		expect(#events).toBe(2)
		expect(string.find(events[1], "^ADDED %d+$") ~= nil).toBe(true)
		expect(string.find(events[2], "^MODIFIED %d+$") ~= nil).toBe(true)
		expect(nodes.find(node, nodes.key("facet-REASON")) ~= nil).toBe(true)
	end)

	it("tints Warning rows and shows the LAST SEEN note in the cell", function()
		local node = render(build("ns-apps/events"), vsm.default())
		local rows = nodes.findAll(node, nodes.class("tk-r"))
		local first = rows[1]
		expect(string.find((first.p :: any).class, "tk-lvl-warn", 1, true) ~= nil).toBe(true)
		expect(nodes.text(nodes.findAll(first, nodes.class("tk-c"))[1])).toBe("11m ×12 over 4h30m")
		local normal = rows[2]
		expect((string.find((normal.p :: any).class, "tk-lvl-warn", 1, true))).toBeNil()
	end)

	it("the inspector acts on the involved object and opens its events timeline", function()
		local c = build("ns-apps/events")
		local node = render(c, vsm.opened(vsm.default(), "/Pod/tern-test-apps/pending"))
		local insp = nodes.find(node, nodes.role("tern-kube.inspector")) :: any
		expect(chipAction(insp, "Events for pod/pending")).toBe("explore-route=events|/Pod/tern-test-apps/pending")
		expect(chipAction(insp, "Explore live")).toBe("explore=/Pod/tern-test-apps/pending")
		expect(nodes.text(insp)).toContain("×12 over 4h30m")
	end)

	it("non-event tables get no Events-for chip", function()
		local node = render(build("ns-apps/get_pods"), vsm.opened(vsm.default(), "/Pod/tern-test-apps/db-0"))
		expect(nodes.find(node, nodes.hasText("Events for"))).toBeNil()
	end)

	-- Track 5 plan 1/2.6: the lens opens the context picker of Explore's
	-- compare route for the row, so one object can be checked across clusters.
	it("every object row offers Compare across contexts", function()
		local node = render(build("ns-apps/get_pods"), vsm.opened(vsm.default(), "/Pod/tern-test-apps/db-0"))
		local insp = nodes.find(node, nodes.role("tern-kube.inspector")) :: any
		expect(chipAction(insp, "Compare across contexts")).toBe("explore-route=compare|/Pod/tern-test-apps/db-0")
	end)
end)

-- Plan 7: rows of Helm-managed objects link their release. `-o json` rows
-- read the release annotations (captured `helm install` objects); plain
-- tables only know it from `--show-labels` and the instance label.
describe("table view Helm release chip", function()
	local OBJECTS_CMD = "kubectl -n tern-test-helm get deployments,services,configmaps,secrets -o json"

	local function helmChips(c: Capture.Capture, key: string): { any }
		local node = TableView.render(c, vsm.opened(vsm.default(), key))
		local insp = nodes.find(node :: any, nodes.role("tern-kube.inspector"))
		assert(insp, "no inspector for " .. key)
		return nodes.findAll(insp, nodes.role("tern-kube.helm-release"))
	end

	local function objects(): Capture.Capture
		return Capture.build(runs.run(OBJECTS_CMD), fixtures.lines("helm/captured/objects.json"), 0, {
			decode = json.decode,
		})
	end

	it("json rows of release objects show the release from their annotations", function()
		local c = objects()
		local releases: { [string]: string } = {
			["apps/Deployment/tern-test-helm/shop-a-shop"] = "shop-a",
			["/Service/tern-test-helm/web-b-web"] = "web-b",
			["/ConfigMap/tern-test-helm/stuck-d-shop-config"] = "stuck-d",
		}
		for key, release in releases do
			local chips = helmChips(c, key)
			expect(#chips).toBe(1)
			expect(nodes.action(chips[1])).toBe("helm-release=tern-test-helm/" .. release)
		end
	end)

	it("the full Inspect view carries the same chip", function()
		local key = "apps/Deployment/tern-test-helm/shop-a-shop"
		local c = objects()
		local row, tbl = Capture.findRow(c, key)
		assert(row and tbl, "row " .. key)
		local view = TableView.inspectView(c, tbl, row, vsm.inspect(vsm.default(), key))
		local chip = nodes.find(view, nodes.role("tern-kube.helm-release")) :: any
		expect(nodes.action(chip)).toBe("helm-release=tern-test-helm/shop-a")
	end)

	it("objects no release owns show no chip", function()
		local c = objects()
		expect(#helmChips(c, "/ConfigMap/tern-test-helm/kube-root-ca.crt")).toBe(0)
		-- Hooks carry no release annotation (helm.sh/hook only).
		expect(#helmChips(c, "/ConfigMap/tern-test-helm/web-b-web-post-install")).toBe(0)
		expect(#helmChips(build("ns-apps/get_deployments"), "apps/Deployment/tern-test-apps/web")).toBe(0)
	end)

	it("--show-labels rows show the release from the instance label, in the row's namespace", function()
		local c = Capture.build(runs.run("kubectl get deploy -n tern-test-helm-ui --show-labels"), {
			"NAME          READY   UP-TO-DATE   AVAILABLE   AGE   LABELS",
			"shop-a-shop   2/2     2            2           5m    app.kubernetes.io/instance=shop-a,app.kubernetes.io/managed-by=Helm,app=shop",
			"plain         1/1     1            1           5m    app.kubernetes.io/instance=plain,app=plain",
		}, 0, { decode = json.decode })
		local chips = helmChips(c, "apps/Deployment/tern-test-helm-ui/shop-a-shop")
		expect(#chips).toBe(1)
		expect(nodes.action(chips[1])).toBe("helm-release=tern-test-helm-ui/shop-a")
		expect(chips[1].p.title).toContain("Probably")
		-- An instance label without managed-by=Helm is not Helm's.
		expect(#helmChips(c, "apps/Deployment/tern-test-helm-ui/plain")).toBe(0)
	end)
end)

return nil
