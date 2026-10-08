--!strict
local MutationView = require("../../../plugin/lib/render/mutation_view")
local Viewstate = require("../../../plugin/lib/lens/viewstate")
local captures = require("../../lib/captures")
local fixtures = require("../../lib/fixtures")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Node = nodes.Node
type ViewState = Viewstate.ViewState

local NS = "-n tern-test-mutate"

local function render(path: string, command: string, vs: ViewState?): Node
	return MutationView.render(captures.build(path, command), vs or Viewstate.default(), Viewstate)
end

local function badgeTexts(root: Node): { string }
	local out = {}
	for _, b in nodes.findAll(root, nodes.kind("badge")) do
		table.insert(out, (b.p :: any).text)
	end
	return out
end

local function badge(root: Node, text: string): Node?
	return nodes.find(root, function(n)
		return n.k == "badge" and (n.p :: any).text == text
	end)
end

local function toneOf(n: Node?): string?
	return if n and n.p then n.p.tone else nil
end

local function gridRows(root: Node): { Node }
	return nodes.findAll(root, nodes.class("kl-r"))
end

local function cellTexts(row: Node): { string }
	local out = {}
	for _, cell in row.c :: { Node } do
		table.insert(out, nodes.text(cell))
	end
	return out
end

local function lineCount(path: string): number
	return #fixtures.lines(path)
end

describe("mutation view: successful runs", function()
	it("says the change already happened and summarises created objects", function()
		local view =
			render("real/mutate-create/apply_-f_mutate+app.yaml", "kubectl apply " .. NS .. " -f mutate/app.yaml")
		local bannerNode = nodes.find(view, nodes.role("kube-lens.mutation-banner")) :: Node
		expect(nodes.text(bannerNode)).toContain("Result of an executed command (not a preview)")
		expect(toneOf(badge(view, "exit 0"))).toBe("success")
		expect(toneOf(badge(view, "3 created"))).toBe("success")
		expect(nodes.find(view, nodes.hasText("dry run"))).toBeNil()
		local rows = gridRows(view)
		expect(#rows).toBe(3)
		-- Namespaced kinds take -n; the kind keeps its API group as kubectl printed it.
		expect(cellTexts(rows[2])).toEqual({ "deployment.apps", "api", "tern-test-mutate", "created" })
	end)

	it("counts configured and unchanged separately", function()
		local view = render(
			"real/mutate-configured/apply_-f_mutate+app-v2.yaml",
			"kubectl apply " .. NS .. " -f mutate/app-v2.yaml"
		)
		local texts = badgeTexts(view)
		expect(texts).toContain("2 configured")
		expect(texts).toContain("1 unchanged")
		expect(toneOf(badge(view, "1 unchanged"))).toBe("muted")
	end)

	it("reports an all-unchanged re-apply", function()
		local view =
			render("real/mutate-unchanged/apply_-f_mutate+app.yaml", "kubectl apply " .. NS .. " -f mutate/app.yaml")
		expect(badgeTexts(view)).toContain("3 unchanged")
	end)

	it("marks server and client dry runs as not persisted", function()
		local server = render(
			"real/mutate-create/apply_--dry-run=server_-f_mutate+app.yaml",
			"kubectl apply " .. NS .. " --dry-run=server -f mutate/app.yaml"
		)
		expect(badgeTexts(server)).toContain("dry run (server)")
		expect(badgeTexts(server)).toContain("3 created")
		expect(nodes.text(server)).toContain("nothing was persisted")
		local client = render(
			"real/mutate-configured/apply_--dry-run=client_-f_mutate+app-v2.yaml",
			"kubectl apply " .. NS .. " --dry-run=client -f mutate/app-v2.yaml"
		)
		expect(badgeTexts(client)).toContain("dry run (client)")
	end)

	it("lists deletions with the namespace kubectl named", function()
		local path = "real/mutate-delete/delete_-f_mutate+app-v2.yaml"
		local view = render(path, "kubectl delete " .. NS .. " -f mutate/app-v2.yaml")
		local n = lineCount(path .. ".txt")
		expect(toneOf(badge(view, string.format("%d deleted", n)))).toBe("warning")
		for _, row in gridRows(view) do
			expect(cellTexts(row)[3]).toBe("tern-test-mutate")
		end
	end)

	it("summarises rollout restart and scale", function()
		local restart =
			render("real/mutate-ops/rollout_restart_deployment+api", "kubectl rollout restart deployment/api " .. NS)
		expect(badgeTexts(restart)).toContain("1 restarted")
		local scale = render(
			"real/mutate-ops/scale_deployment+api_--replicas=3",
			"kubectl scale deployment/api --replicas=3 " .. NS
		)
		expect(badgeTexts(scale)).toContain("1 scaled")
		local del = render("real/mutate-ops/delete_pod_scratch", "kubectl delete pod scratch " .. NS)
		expect(badgeTexts(del)).toContain("1 deleted")
	end)
end)

describe("mutation view: failures", function()
	it("shows a rejected manifest as an error with what to do next", function()
		local view =
			render("real/errors/apply_-f_mutate+invalid.yaml", "kubectl apply " .. NS .. " -f mutate/invalid.yaml")
		expect(toneOf(badge(view, "exit 1"))).toBe("error")
		local err = nodes.find(view, nodes.role("kube-lens.error")) :: Node
		expect(nodes.text(err)).toContain('unknown field "spec.replcas"')
		expect(nodes.text(err)).toContain("Fix its spelling or remove it")
		expect(#gridRows(view)).toBe(0)
	end)

	it("gives syntax errors and missing files their own advice", function()
		local broken =
			render("real/errors/apply_-f_mutate+broken.yaml", "kubectl apply " .. NS .. " -f mutate/broken.yaml")
		expect(nodes.text(broken)).toContain("not valid YAML")
		local missing = render(
			"real/errors/apply_-f_mutate+does-not-exist.yaml",
			"kubectl apply " .. NS .. " -f mutate/does-not-exist.yaml"
		)
		expect(nodes.text(missing)).toContain("-f path was not found")
	end)

	it("lists every NotFound when deleting objects that are gone", function()
		local path = "real/errors/delete_-f_mutate+app-v2.yaml"
		local view = render(path, "kubectl delete " .. NS .. " -f mutate/app-v2.yaml")
		local errs = nodes.findAll(view, nodes.role("kube-lens.error"))
		expect(#errs).toBe(lineCount(path .. ".stderr"))
		for _, e in errs do
			expect(nodes.text(e)).toContain("Check the name, -n/--namespace and --context")
		end
	end)

	it("explains failed restart and scale of a missing deployment", function()
		for _, case in
			{
				{ "real/errors/rollout_restart_deployment+api", "kubectl rollout restart deployment/api " .. NS },
				{ "real/errors/scale_deployment+api_--replicas=1", "kubectl scale deployment/api --replicas=1 " .. NS },
			}
		do
			local view = render(case[1], case[2])
			expect(nodes.find(view, nodes.role("kube-lens.error")) ~= nil).toBe(true)
			expect(badge(view, "exit 1") ~= nil).toBe(true)
		end
	end)
end)

describe("mutation view: interaction", function()
	local path = "real/mutate-configured/apply_-f_mutate+app-v2.yaml"
	local command = "kubectl apply " .. NS .. " -f mutate/app-v2.yaml"

	it("sorts results by a clicked column", function()
		local vs = Viewstate.sortedBy(Viewstate.sortedBy(Viewstate.default(), "NAME"), "NAME")
		expect(vs.desc).toBe(true)
		local names = {}
		for _, row in gridRows(render(path, command, vs)) do
			table.insert(names, cellTexts(row)[2])
		end
		expect(names[1]).toBe("api-config")
	end)

	it("carries the whole view state in every click", function()
		local vs = Viewstate.sortedBy(Viewstate.default(), "ACTION")
		local view = render(path, command, Viewstate.opened(vs, "m1"))
		local actions = nodes.actions(view)
		expect(#actions > 0).toBe(true)
		for _, a in actions do
			expect(string.sub(a, 1, 2)).toBe("v=")
			local decoded = Viewstate.decode(string.sub(a, 3))
			-- Header clicks change only the sort; row clicks keep the sort.
			expect(decoded.sort ~= nil).toBe(true)
		end
		for _, row in gridRows(view) do
			local decoded = Viewstate.decode(string.sub(nodes.action(row) :: string, 3))
			expect(decoded.sort).toBe("ACTION")
		end
	end)

	it("opens the clicked result with the output line it came from", function()
		local capture = captures.build(path, command)
		local view = MutationView.render(capture, Viewstate.opened(Viewstate.default(), "m2"), Viewstate)
		local insp = nodes.find(view, nodes.class("kl-insp")) :: Node
		expect(nodes.text(insp)).toContain(capture.lines[2])
		local open = nodes.find(view, nodes.class("kl-open")) :: Node
		-- Clicking the open row closes it.
		expect(Viewstate.decode(string.sub(nodes.action(open) :: string, 3)).open).toBeNil()
	end)
end)

-- With the opt-in shell guard, a typed `kubectl scale` the user denied (or
-- cancelled, or the guard refused) still reaches the lens; claiming it was
-- executed would contradict the guard's own message.
describe("mutation view: stopped by the shell guard", function()
	local command = "kubectl scale deploy/web --replicas=3 " .. NS
	local waiting = "kube-lens guard: waiting for approval in Tern (context kind-dev; Ctrl-C cancels) ..."

	local cases: { { name: string, line: string, status: number } } = {
		{ name = "denied", line = "kube-lens guard: denied in Tern; nothing was executed.", status = 1 },
		{ name = "denied with a reason", line = "kube-lens guard: denied in Tern: Mutations are disabled", status = 1 },
		{ name = "cancelled", line = "kube-lens guard: cancelled; nothing was executed.", status = 130 },
		{
			name = "refused",
			line = "kube-lens guard: nothing was executed. To run it anyway, without preview or confirmation, use: command kubectl ...",
			status = 1,
		},
	}
	for _, case in cases do
		it("says nothing was executed when " .. case.name, function()
			local view = MutationView.render(
				captures.fromLines(command, { waiting, case.line }, case.status),
				Viewstate.default(),
				Viewstate
			)
			local text = nodes.text(nodes.find(view, nodes.role("kube-lens.mutation-banner")) :: Node)
			expect(text).toContain(MutationView.GUARD_BANNER)
			expect(string.find(text, MutationView.BANNER, 1, true) == nil).toBe(true)
			expect(toneOf(badge(view, "Not executed"))).toBe("warning")
			expect(badge(view, "Executed")).toBeNil()
		end)
	end

	it("still reports an approved run as executed", function()
		local view = MutationView.render(
			captures.fromLines(command, { waiting, "deployment.apps/web scaled" }, 0),
			Viewstate.default(),
			Viewstate
		)
		expect(badge(view, "Executed") ~= nil).toBe(true)
	end)
end)

return nil
