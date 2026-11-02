--!strict
-- One source against several clusters: each cell must be exactly what that
-- cluster's drift report says about the row, so "in sync here, changed
-- there" is visible at a glance and a failing context never hides the
-- others. Inputs are real: the kubectl diff of the source and the live
-- listing of tern-test-mc captured from kind-tern-kube-dev (a) and
-- kind-tern-kube-dev2 (b) (tests/fixtures/real/compare).
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Drift = require("../../../plugin/lib/gitops/drift")
local Index = require("../../../plugin/lib/gitops/index")
local Matrix = require("../../../plugin/lib/gitops/matrix")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ROOT = "/repo"
local A = "kind-tern-kube-dev"
local B = "kind-tern-kube-dev2"

local function report(side: string): Drift.Report
	local index = Index.new(ROOT)
	Index.addFile(index, ROOT .. "/app.yaml", fixtures.read("real/compare/source/app.yaml"))
	local source = Index.source(index, "file", ROOT .. "/app.yaml")
	local segments = Diffseg.parse(fixtures.read("real/compare/" .. side .. "-diff-source.out")).segments
	local live = json.decode(fixtures.read("real/compare/" .. side .. "-mixed-list.json")).items
	return Drift.report(source :: any, index :: any, segments, live, { defaultNamespace = "tern-test-mc" })
end

local function column(context: string, status: string, err: string?): Matrix.Column
	return { context = context, label = context, status = status :: any, error = err }
end

-- "Kind/name" -> per-column "state[+a -r]".
local function grid(m: Matrix.Matrix): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for _, row in m.rows do
		local cells: { string } = {}
		for i, c in row.cells do
			cells[i] = c.state .. (if c.added then string.format(" +%d -%d", c.added, c.removed or 0) else "")
		end
		out[row.ref.kind .. "/" .. row.ref.name] = cells
	end
	return out
end

describe("gitops matrix", function()
	it("folds each context's drift report into one cell per resource", function()
		local m = Matrix.fromReports({ column(A, "ok"), column(B, "ok") }, { report("a"), report("b") })
		expect(grid(m)).toEqual({
			["Deployment/tkm-web"] = { "insync", "changed +4 -3" },
			["Deployment/tkm-api"] = { "insync", "insync" },
			["Service/tkm-web"] = { "insync", "insync" },
			["ConfigMap/tkm-config"] = { "insync", "changed +1 -1" },
			["ConfigMap/tkm-flags"] = { "insync", "missing" },
			["Deployment/tkm-only-a"] = { "unmanaged", "absent" },
			["Deployment/tkm-only-b"] = { "absent", "unmanaged" },
		})
		-- Rows keep one order whatever the context order.
		local keys: { string } = {}
		for _, row in m.rows do
			table.insert(keys, row.key)
		end
		local sorted = table.clone(keys)
		table.sort(sorted)
		expect(keys).toEqual(sorted)
		expect(Matrix.summary(m, 1)).toBe("1 unmanaged")
		expect(Matrix.summary(m, 2)).toBe("2 changed, 1 missing, 1 unmanaged")
	end)

	it("a failed or unfinished context shows its state in every row, the others still report", function()
		local m = Matrix.fromReports(
			{ column(A, "ok"), column(B, "error", "connection refused"), column("c", "running") },
			{ report("a"), nil, nil }
		)
		local web = grid(m)["Deployment/tkm-only-a"]
		expect(web).toEqual({ "unmanaged", "error", "pending" })
		expect(m.rows[1].cells[2].error).toBe("connection refused")
		expect(Matrix.summary(m, 2)).toBe("error")
		expect(Matrix.summary(m, 3)).toBe("running")
	end)

	it("filters: drifted anywhere, or differing between contexts", function()
		local m = Matrix.fromReports({ column(A, "ok"), column(B, "ok") }, { report("a"), report("b") })
		local function names(f: Matrix.Filter): { string }
			local out: { string } = {}
			for _, row in Matrix.filter(m, f).rows do
				table.insert(out, row.ref.kind .. "/" .. row.ref.name)
			end
			return out
		end
		expect(#names("all")).toBe(7)
		expect(names("drifted")).toEqual({
			"ConfigMap/tkm-config",
			"ConfigMap/tkm-flags",
			"Deployment/tkm-only-a",
			"Deployment/tkm-only-b",
			"Deployment/tkm-web",
		})
		-- Same drift everywhere is not a difference between clusters.
		local same = Matrix.fromReports({ column(A, "ok"), column(B, "ok") }, { report("b"), report("b") })
		expect(#Matrix.filter(same, "differs").rows).toBe(0)
		expect(#Matrix.filter(same, "drifted").rows).toBe(4)
		expect(names("differs")).toEqual(names("drifted"))
		expect(Matrix.nextFilter("all")).toBe("drifted")
		expect(Matrix.nextFilter("differs")).toBe("all")
	end)
end)

return nil
