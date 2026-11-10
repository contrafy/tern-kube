--!strict
-- Compare views (track 5 plan 2.5): every cell says its state in words (no
-- colour-only signal), the base column is marked as the reference, narrow
-- windows fall back to short labels with a legend, and pairwise diffs show
-- where each side came from so two clusters are never confused.
local CompareView = require("../../../plugin/lib/compare/view")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local A, B, C = "kind-tern-kube-dev", "kind-tern-kube-dev2", "kind-tern-kube-down"

local function col(context: string, label: string, status: string?, extra: { [string]: any }?): any
	local c: { [string]: any } = {
		context = context,
		label = label,
		server = "https://127.0.0.1:" .. #context,
		fetchedAt = 1000,
		status = status or "ok",
	}
	for k, v in (extra or {}) :: { [string]: any } do
		c[k] = v
	end
	return c
end

local function ref(kind: string, name: string): any
	return { kind = kind, group = "apps", namespace = "tern-test-mc", name = name, source = "live" }
end

local function matrix(): any
	return {
		columns = { col(A, "dev"), col(B, "dev2"), col(C, "down", "error", { error = "connection refused" }) },
		rows = {
			{
				key = "apps/Deployment/tern-test-mc/tkm-api",
				ref = ref("Deployment", "tkm-api"),
				cells = { { state = "base" }, { state = "same" }, { state = "error" } },
			},
			{
				key = "apps/Deployment/tern-test-mc/tkm-web",
				ref = ref("Deployment", "tkm-web"),
				cells = {
					{ state = "base" },
					{ state = "changed", paths = { "spec.replicas 2 -> 3" } },
					{ state = "error" },
				},
			},
			{
				key = "apps/Deployment/tern-test-mc/tkm-only-a",
				ref = ref("Deployment", "tkm-only-a"),
				cells = { { state = "base" }, { state = "missing" }, { state = "error" } },
			},
			{
				key = "apps/Deployment/tern-test-mc/tkm-only-b",
				ref = ref("Deployment", "tkm-only-b"),
				cells = { { state = "absent" }, { state = "extra" }, { state = "error" } },
			},
		},
		notes = { "1 context failed" },
	}
end

local function opts(extra: { [string]: any }?): any
	local o: { [string]: any } = { narrow = false, filter = "all", title = "deployments in tern-test-mc" }
	for k, v in (extra or {}) :: { [string]: any } do
		o[k] = v
	end
	return o
end

local function root(list: { any }): any
	return { k = "col", p = {}, c = list }
end

local function rowTexts(node: any): { string }
	local out: { string } = {}
	for _, r in nodes.findAll(node, nodes.class("tk-r")) do
		table.insert(out, nodes.text(r))
	end
	return out
end

describe("compare matrix", function()
	it("names every cell state in words, base column included", function()
		local text = table.concat(rowTexts(root(CompareView.matrix(matrix(), nil, opts()))), "\n")
		expect(text).toContain("tkm-web")
		expect(text).toContain("present")
		expect(text).toContain("same")
		expect(text).toContain("changed")
		expect(text).toContain("missing")
		expect(text).toContain("extra")
		expect(text).toContain("error")
	end)

	it("heads columns with full context names when wide, short labels plus a legend when narrow", function()
		local wide = nodes.text(root(CompareView.matrix(matrix(), nil, opts())))
		expect(wide).toContain(B)
		local narrow = root(CompareView.matrix(matrix(), nil, opts({ narrow = true })))
		local legend = nodes.find(narrow, nodes.key("legend"))
		assert(legend, "no legend")
		expect(nodes.text(legend)).toContain("dev2 = " .. B)
		local heads: { string } = {}
		for _, h in nodes.findAll(narrow, nodes.class("tk-h")) do
			table.insert(heads, nodes.ownText(h))
		end
		expect(table.find(heads, "dev2") ~= nil).toBe(true)
	end)

	it("every row opens its pairwise diff and the selected row is marked", function()
		local m = matrix()
		local node = root(CompareView.matrix(m, m.rows[2].key, opts()))
		local rows = nodes.findAll(node, nodes.class("tk-r"))
		expect(nodes.action(rows[1])).toBe("open=" .. m.rows[1].key)
		expect(string.find((rows[2].p :: any).class, "tk-sel", 1, true) ~= nil).toBe(true)
	end)

	-- The base column is the reference (present or absent), not a result;
	-- a "dev: nothing" line read like a failure.
	it("gives the base column no counts line", function()
		local counts =
			nodes.find(root(CompareView.matrix(matrix(), nil, opts())), nodes.role("tern-kube.compare-counts"))
		assert(counts, "no counts")
		expect((string.find(nodes.text(counts), "dev:", 1, true))).toBeNil()
	end)

	-- Tern keeps `class` on elements only; the tone sheet needs it in the DOM.
	it("puts each cell's tone class on an element", function()
		local node = root(CompareView.matrix(matrix(), nil, opts()))
		local cell = nodes.find(node, nodes.class("tk-cmp-extra")) :: any
		assert(cell, "no tk-cmp-extra")
		expect(cell.k).toBe("el")
	end)

	it("counts each context's states and shows the matrix notes", function()
		local text = nodes.text(root(CompareView.matrix(matrix(), nil, opts())))
		expect(text).toContain("dev2: 1 same, 1 changed, 1 missing, 1 extra")
		expect(text).toContain("down: error: connection refused")
		expect(text).toContain("1 context failed")
	end)

	it("says when the filter hides every row", function()
		local m = matrix()
		m.rows = {}
		local text = nodes.text(root(CompareView.matrix(m, nil, opts({ filter = "differs" }))))
		expect(text).toContain("No object differs")
	end)

	it("builds only the window's rows and offers paging", function()
		local node = root(CompareView.matrix(matrix(), nil, opts({ window = { first = 2, last = 3 } })))
		expect(#nodes.findAll(node, nodes.class("tk-r"))).toBe(2)
		expect(nodes.find(node, nodes.key("above")) ~= nil).toBe(true)
		expect(nodes.find(node, nodes.key("overflow")) ~= nil).toBe(true)
	end)
end)

describe("compare fan-out", function()
	it("lists one row per context with state, first changes and fetch time", function()
		local m = matrix()
		m.rows = { m.rows[2] }
		local node = root(CompareView.fanout(m, B, opts()))
		local rows = rowTexts(node)
		expect(#rows).toBe(3)
		expect(rows[1]).toContain(A)
		expect(rows[1]).toContain("base")
		expect(rows[2]).toContain("changed")
		expect(rows[2]).toContain("spec.replicas 2 -> 3")
		expect(rows[3]).toContain("connection refused")
		expect(nodes.action(nodes.findAll(node, nodes.class("tk-r"))[2])).toBe("open=" .. B)
	end)
end)

describe("compare picker", function()
	it("one row per choice; disabled rows give their reason and warnings show", function()
		local choices: { any } = {
			{ id = "=" .. B, label = B, contexts = { B }, note = "https://127.0.0.1:59680" },
			{ id = "=other", label = "other", contexts = { "other" }, warning = "same server as base" },
			{
				id = "*",
				label = "All contexts (3)",
				contexts = { B, "other" },
				disabled = "more than compare.max_contexts (1)",
			},
		}
		local node = root(CompareView.picker(choices, "*"))
		local rows = rowTexts(node)
		expect(#rows).toBe(3)
		expect(rows[2]).toContain("same server as base")
		expect(rows[3]).toContain("more than compare.max_contexts (1)")
		local els = nodes.findAll(node, nodes.class("tk-r"))
		expect(nodes.action(els[1])).toBe("open==" .. B)
		expect(string.find((els[3].p :: any).class, "tk-sel", 1, true) ~= nil).toBe(true)
	end)
end)

describe("compare pair", function()
	local diff: any = {
		summary = {
			segments = {
				{
					key = "apps.v1.Deployment.tern-test-mc.tkm-web",
					kind = "Deployment",
					namespace = "tern-test-mc",
					name = "tkm-web",
					action = "modify",
					added = 1,
					removed = 1,
					lines = {
						"--- " .. A .. "/x",
						"+++ " .. B .. "/x",
						"@@ -1 +1 @@",
						"-  replicas: 2",
						"+  replicas: 3",
					},
				},
			},
			create = 0,
			modify = 1,
			delete = 0,
			unknown = 0,
		},
		unchanged = {},
		pairs = {},
	}

	it("shows both provenance lines, the status, the differences and the diff", function()
		local cell: any = { state = "changed", added = 1, removed = 1, paths = { "spec.replicas 2 -> 3" } }
		local node = root(CompareView.pair(cell, diff, { col(A, "dev"), col(B, "dev2") }, nil))
		local text = nodes.text(node)
		expect(text).toContain("base " .. A)
		expect(text).toContain("other " .. B)
		expect(text).toContain("differs (+1 -1)")
		expect(text).toContain("spec.replicas 2 -> 3")
		expect(text).toContain("+  replicas: 3")
		-- EXP-U12: "MODIFY" read like a pending mutation; nothing changes here.
		expect(text).toContain("DIFFERS  Deployment")
		expect((string.find(text, "MODIFY", 1, true))).toBeNil()
	end)

	it("names the side an object is missing from and collapses the present side", function()
		local seg = table.clone(diff.summary.segments[1])
		seg.action = "delete"
		local result: any = table.clone(diff)
		result.summary = table.clone(diff.summary)
		result.summary.segments = { seg }
		local node =
			root(CompareView.pair({ state = "missing" } :: any, result, { col(A, "dev"), col(B, "dev2") }, nil))
		expect(nodes.text(node)).toContain("missing in " .. B)
		local card = nodes.find(node, nodes.kind("card")) :: any
		expect(card.p.collapsed).toBe(true)
		local extra = root(CompareView.pair({ state = "extra" } :: any, result, { col(A, "dev"), col(B, "dev2") }, nil))
		expect(nodes.text(extra)).toContain("missing in " .. A)
	end)

	it("an unreachable side is an error, never a difference", function()
		local cols = { col(A, "dev"), col(C, "down", "error", { error = "connection refused" }) }
		local text =
			nodes.text(root(CompareView.pair({ state = "error" } :: any, nil, cols, "Secret values are masked")))
		expect(text).toContain("connection refused")
		expect(text).toContain("Secret values are masked")
		expect((string.find(text, "differs", 1, true))).toBeNil()
	end)

	it("says same when nothing differs", function()
		local text =
			nodes.text(root(CompareView.pair({ state = "same" } :: any, nil, { col(A, "dev"), col(B, "dev2") }, nil)))
		expect(text).toContain("same")
	end)
end)

return nil
