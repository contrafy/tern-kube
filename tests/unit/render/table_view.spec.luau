--!strict
-- The table body a user clicks through: chips filter, rows open the right
-- inspector, Inspect shows everything about one row, pages cap rendering,
-- and every click carries the rest of the view state along.
local Capture = require("../../../plugin/lib/lens/capture")
local Link = require("../../../plugin/lib/mutation/link")
local Quick = require("../../../plugin/lib/actions/quick")
local TableView = require("../../../plugin/lib/render/table_view")
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
	for _, r in nodes.findAll(node, nodes.class("kl-r")) do
		local first = nodes.find(r, nodes.class("kl-c")) :: any
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
		expect(#nodes.findAll(node, nodes.class("kl-grid"))).toBe(1)
		expect(#rowNames(node)).toBe(7)
		expect(counts).toEqual({ shown = 7, matched = 7, total = 7 })
	end)

	it("get all stacks one grid per kind under kind headings", function()
		local node = render(build("ns-apps/get_all"), vsm.default())
		expect(#nodes.findAll(node, nodes.class("kl-grid"))).toBe(6)
		local headings = nodes.findAll(node, nodes.role("kube-lens.kind"))
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
		expect(nodes.text(nodes.find(node, nodes.class("kl-open")) :: any)).toContain("db-0")
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
		expect(nodes.text(insp)).toContain("db-0")
	end)

	it("a filtered-out open row shows no inspector rather than another row's", function()
		local c = build("ns-apps/get_pods")
		local vs = vsm.toggledFilter(vsm.opened(vsm.default(), "/Pod/tern-test-apps/pending"), "STATUS", "Running")
		local node = render(c, vs)
		expect(nodes.find(node, nodes.role("kube-lens.inspector"))).toBeNil()
	end)

	it("the inspector shows the clicked row's cells and target-aware actions", function()
		local c = build("ns-apps/get_pods")
		local node = render(c, vsm.opened(vsm.default(), "/Pod/tern-test-apps/crashloop"))
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
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
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
		expect(table.find(nodes.actions(insp), "copy=logs|apps/Deployment/tern-test-apps/web")).toBeNil()
	end)

	it("every grid and inspector action carries sort, filters and selection along", function()
		local c = build("ns-apps/get_pods")
		local base = vsm.toggledFilter(vsm.sortedBy(vsm.default(), "AGE"), "STATUS", "Running")
		base = vsm.opened(base, "/Pod/tern-test-apps/db-0")
		local node = render(c, base)
		local checked = 0
		for _, region in nodes.findAll(node, nodes.class("kl-grid")) do
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
		local rowVs = decodeAction(nodes.action(nodes.findAll(node, nodes.class("kl-r"))[1]) :: string) :: vsm.ViewState
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
		expect(nodes.find(node, nodes.class("kl-grid"))).toBeNil()
		local crumbs = nodes.text(nodes.find(node, nodes.role("kube-lens.breadcrumb")) :: any)
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
		expect(#nodes.findAll(node, nodes.class("kl-r"))).toBe(500)
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
		expect(nodes.text(nodes.find(node2, nodes.role("kube-lens.pages")) :: any)).toContain("Rows 501-1000 of 1000")
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
		expect(nodes.text(nodes.find(node, nodes.role("kube-lens.pages")) :: any)).toContain("801-1000")
	end)
end)

-- Quick actions are two clicks from any row: open the row, click a chip. The
-- chip's only payload is a kube-lens://act/ link the window validates again,
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
		local insp = nodes.find(node, nodes.role("kube-lens.inspector")) :: any
		local out: { [string]: Quick.Request } = {}
		for _, chip in nodes.findAll(insp, nodes.role("kube-lens.quick")) do
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
		expect(shell.ref.kind).toBe("Pod")
		expect(shell.ref.name).toBe("db-0")
		expect(shell.ref.namespace).toBe("tern-test-apps")
		expect(chips.Logs.action).toBe("logs-follow")
		expect(chips["Port-forward"].action).toBe("port-forward")
	end)

	it("pins the lensed command's --context and --kubeconfig in every chip", function()
		local c = pinned("ns-apps/get_pods", { "--context", "kind-kube-lens-dev", "--kubeconfig", "/tmp/k c/config" })
		for _, req in quick(c, "/Pod/tern-test-apps/db-0") do
			expect(req.target.context).toBe("kind-kube-lens-dev")
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
		expect(chips.Logs.ref.group).toBe("apps")
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
		for _, chip in nodes.findAll(node, nodes.role("kube-lens.quick")) do
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
		return nodes.find(node :: any, nodes.role("kube-lens.inspector")) :: any
	end

	local function mutateChips(insp: any): { [string]: Link.Request }
		local out: { [string]: Link.Request } = {}
		for _, chip in nodes.findAll(insp, nodes.role("kube-lens.mutate")) do
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
		for _, chip in nodes.findAll(insp, nodes.role("kube-lens.quick")) do
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
		expect(quickLabels(insp)).toEqual({ "Debug", "Logs", "Port-forward", "Shell" })
	end)

	it("a CronJob row offers Run now", function()
		local insp = inspector(build("ns-batch/get_cronjobs"), "batch/CronJob/tern-test-batch/nightly-report", true)
		expect(table.find(quickLabels(insp), "Run now") ~= nil).toBe(true)
	end)

	it("pins the lensed command's --context as a flag-sourced target", function()
		local f = runs.load("ns-apps/get_deployments")
		local args = { "--context", "kind-kube-lens-dev" }
		table.move(f.run.args, 1, #f.run.args, #args + 1, args)
		local c = Capture.build({ program = f.run.program, args = args }, f.lines, f.status, { decode = json.decode })
		for _, req in mutateChips(inspector(c, "apps/Deployment/tern-test-apps/web", true)) do
			expect(req.context).toBe("kind-kube-lens-dev")
			expect(req.source).toBe("flag")
		end
	end)

	it("offers no mutating chip when mutations are disabled", function()
		local insp = inspector(build("ns-apps/get_pods"), "/Pod/tern-test-apps/db-0", false)
		expect(#nodes.findAll(insp, nodes.role("kube-lens.mutate"))).toBe(0)
		expect(quickLabels(insp)).toEqual({ "Logs", "Port-forward", "Shell" })
	end)
end)

return nil
