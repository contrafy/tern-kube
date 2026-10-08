--!strict
-- Derived columns are checked against kubectl's own table output captured
-- from the same kind cluster in the same run (tests/fixtures/real).
local Json = require("../../../plugin/lib/parse/json")
local decoder = require("../../lib/json")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local decode = decoder.decode

-- Rows of a kubectl table keyed by `keyColumn`, cut at header-derived spans.
local function tableRows(path: string, keyColumn: string): { [string]: { [string]: string } }
	local lines = fixtures.lines(path)
	local header = lines[1]
	local starts: { number } = {}
	local names: { string } = {}
	for start, name in string.gmatch(header, "()(%S+)") do
		table.insert(starts, start :: number)
		table.insert(names, name :: string)
	end
	local rows = {}
	for i = 2, #lines do
		local row: { [string]: string } = {}
		for c, start in starts do
			local stop = if starts[c + 1] then starts[c + 1] - 1 else #lines[i]
			row[names[c]] = (string.match(string.sub(lines[i], start, stop), "^%s*(.-)%s*$")) :: string
		end
		rows[row[keyColumn]] = row
	end
	return rows
end

local function cells(resource: Json.Resource): { [string]: string }
	local out = {}
	for i, header in resource.summary.headers do
		out[header] = resource.summary.cells[i]
	end
	return out
end

-- Captures are seconds apart, so the crashlooping pod may flip between
-- CrashLoopBackOff and Error and gain a restart in between.
local FLAPPING = { crashloop = true }

describe("json.parse against real kubectl output", function()
	it("matches kubectl's READY, STATUS and RESTARTS for every pod", function()
		local result = Json.parse(fixtures.read("real/ns-apps/get_pods_-o_json.txt"), decode)
		local table_ = tableRows("real/ns-apps/get_pods.txt", "NAME")
		expect(result.kind).toBe("list")
		expect(result.diagnostics).toEqual({})
		expect(#result.resources > 0).toBe(true)
		for _, resource in result.resources do
			local ours = cells(resource)
			local theirs = table_[resource.ref.name]
			expect(theirs ~= nil).toBe(true)
			expect({ resource.ref.name, ours.READY }).toEqual({ resource.ref.name, theirs.READY })
			if FLAPPING[resource.ref.name] then
				expect({ "CrashLoopBackOff", "Error" }).toContain(ours.STATUS)
			else
				expect({ resource.ref.name, ours.STATUS }).toEqual({ resource.ref.name, theirs.STATUS })
				local restarts = string.match(theirs.RESTARTS, "^%d+") or ""
				expect({ resource.ref.name, ours.RESTARTS }).toEqual({ resource.ref.name, restarts })
			end
		end
	end)

	it("matches kubectl's node STATUS, ROLES and VERSION", function()
		local result = Json.parse(fixtures.read("real/cluster/get_nodes_-o_json.txt"), decode)
		local table_ = tableRows("real/cluster/get_nodes.txt", "NAME")
		expect(#result.resources > 0).toBe(true)
		for _, resource in result.resources do
			local ours = cells(resource)
			local theirs = table_[resource.ref.name]
			expect({ ours.STATUS, ours.ROLES, ours.VERSION }).toEqual({ theirs.STATUS, theirs.ROLES, theirs.VERSION })
		end
	end)

	it("identifies custom resources by their API group", function()
		local result = Json.parse(fixtures.read("real/ns-crd/get_widgets_-o_json.txt"), decode)
		local table_ = tableRows("real/ns-crd/get_widgets.txt", "NAME")
		expect(result.kind).toBe("list")
		for _, resource in result.resources do
			expect(resource.ref.group).toBe("lens.example.com")
			expect(resource.ref.kind).toBe("Widget")
			expect(table_[resource.ref.name] ~= nil).toBe(true)
		end
		expect(#result.resources).toBe(#fixtures.lines("real/ns-crd/get_widgets.txt") - 1)
	end)

	it("parses an empty namespace's List as valid and empty", function()
		local result = Json.parse(fixtures.read("real/ns-empty/get_pods_-o_json.txt"), decode)
		expect(result.kind).toBe("list")
		expect(result.resources).toEqual({})
		expect(result.diagnostics).toEqual({})
	end)

	it("handles odd labels and multi-container pods without losing identity", function()
		local result = Json.parse(fixtures.read("real/ns-edge/get_pod_labels-odd_-o_json.txt"), decode)
		expect(result.kind).toBe("object")
		local resource = result.resources[1]
		expect(resource.ref.name).toBe("labels-odd")
		expect(resource.ref.namespace).toBe("tern-test-edge")
		local theirs = tableRows("real/ns-edge/get_pods.txt", "NAME")["labels-odd"]
		local ours = cells(resource)
		expect({ ours.READY, ours.STATUS }).toEqual({ theirs.READY, theirs.STATUS })
	end)
end)

return nil
