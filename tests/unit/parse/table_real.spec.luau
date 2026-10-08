--!strict
-- Captured kubectl output from tests/fixtures/real. Ages, restart counts,
-- hashes and IPs change between captures, so assertions stick to structure and
-- stable values.
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local tableParser = require("../../../plugin/lib/parse/table")
local describe, it, expect = t.describe, t.it, t.expect

local function names(tbl: any): { string }
	local out: { string } = {}
	for _, col in tbl.columns do
		table.insert(out, col.name)
	end
	return out
end

local function column(tbl: any, index: number): { string }
	local out: { string } = {}
	for _, row in tbl.rows do
		table.insert(out, row.cells[index])
	end
	return out
end

local function isTableFixture(path: string): boolean
	if string.sub(path, -4) ~= ".txt" or string.find(path, "%-o_[jyn]") then
		return false
	end
	local key = string.match(path, "/([^/]+)$") or ""
	return string.find(key, "^get_") ~= nil or string.find(key, "^top_") ~= nil or key == "api-resources.txt"
end

describe("table.parse on real kubectl output", function()
	-- Every table kubectl printed in the capture world must be cut without a
	-- single fallback, diagnostic or lost row.
	it("parses every captured table with one row per data line", function()
		local checked = 0
		for _, path in fixtures.list("real/") do
			if isTableFixture(path) then
				local lines = fixtures.lines(path)
				local noHeaders = string.find(path, "no%-headers") ~= nil
				local result = tableParser.parse(lines, { noHeaders = noHeaders })
				local dataLines = 0
				for _, line in lines do
					if string.find(line, "%S") then
						dataLines += 1
					end
				end
				local rows, cellsOk = 0, true
				for _, tbl in result.tables do
					rows += #tbl.rows
					for _, row in tbl.rows do
						cellsOk = cellsOk and #row.cells == #tbl.columns
					end
				end
				local headers = if noHeaders then 0 else #result.tables
				expect({
					path = path,
					rows = rows,
					cellsOk = cellsOk,
					diagnostics = result.diagnostics,
				}).toEqual({
					path = path,
					rows = dataLines - headers,
					cellsOk = true,
					diagnostics = {},
				})
				checked += 1
			end
		end
		expect(checked > 50).toBe(true)
	end)

	it("splits `get all` into one table per kind", function()
		local result = tableParser.parse(fixtures.lines("real/ns-apps/get_all.txt"))
		local prefixes: { string } = {}
		for _, tbl in result.tables do
			local first = tbl.rows[1].cells[1]
			table.insert(prefixes, string.match(first, "^[^/]+") or first)
		end
		expect(prefixes).toEqual({
			"pod",
			"service",
			"daemonset.apps",
			"deployment.apps",
			"replicaset.apps",
			"statefulset.apps",
		})
		expect(names(result.tables[3])).toEqual({
			"NAME",
			"DESIRED",
			"CURRENT",
			"READY",
			"UP-TO-DATE",
			"AVAILABLE",
			"NODE SELECTOR",
			"AGE",
		})
		local services = result.tables[2]
		expect(column(services, 4)).toEqual({ "<none>", "docs.example.com", "<none>", "<pending>", "<none>" })
		expect(services.rows[4].cells[5]).toBe("80:30081/TCP,443:30443/TCP")
	end)

	it("keeps pod statuses and restart suffixes intact", function()
		local tbl = tableParser.parse(fixtures.lines("real/ns-apps/get_pods.txt")).tables[1]
		expect(names(tbl)).toEqual({ "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
		local byName: { [string]: { string } } = {}
		for _, row in tbl.rows do
			byName[row.cells[1]] = row.cells
		end
		expect(byName["pending"][3]).toBe("Pending")
		expect(byName["db-0"][3]).toBe("Running")
		expect(string.find(byName["crashloop"][4], "^%d+ %(.+ ago%)$") ~= nil).toBe(true)
	end)

	it("reads empty cells in api-resources without shifting columns", function()
		local tbl = tableParser.parse(fixtures.lines("real/cluster/api-resources.txt")).tables[1]
		expect(names(tbl)).toEqual({ "NAME", "SHORTNAMES", "APIVERSION", "NAMESPACED", "KIND" })
		expect(tbl.rows[1].cells).toEqual({ "bindings", "", "v1", "true", "Binding" })
	end)

	it("handles CRD printer columns, priority-1 wide columns and an empty long column", function()
		local tbl = tableParser.parse(fixtures.lines("real/ns-crd/get_widgets_-o_wide.txt")).tables[1]
		expect(names(tbl)).toEqual({ "NAME", "COLOR", "SIZE", "DESCRIPTION", "AGE", "OWNER", "ENABLED" })
		local byName: { [string]: { string } } = {}
		for _, row in tbl.rows do
			byName[row.cells[1]] = row.cells
		end
		expect(byName["sprocket"][4]).toBe("")
		expect(byName["sprocket"][6]).toBe("team-data")
		expect(#byName["long-description"][4] > 150).toBe(true)
		expect(byName["long-description"][7]).toBe("true")
	end)

	it("keeps free-text event messages whole", function()
		local tbl = tableParser.parse(fixtures.lines("real/ns-apps/get_events.txt")).tables[1]
		expect(names(tbl)).toEqual({ "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" })
		local found = false
		for _, row in tbl.rows do
			if row.cells[3] == "ScalingReplicaSet" and row.cells[4] == "deployment/web" then
				expect(string.find(row.cells[5], "^Scaled up replica set web%-%w+ from 0 to 2$") ~= nil).toBe(true)
				found = true
			end
		end
		expect(found).toBe(true)
	end)

	-- kubectl top pads its last column too; trailing padding must not create
	-- an extra column or leak into cells.
	it("parses kubectl top including its padded last column", function()
		local tbl = tableParser.parse(fixtures.lines("real/cluster/top_nodes.txt")).tables[1]
		expect(names(tbl)).toEqual({ "NAME", "CPU(cores)", "CPU(%)", "MEMORY(bytes)", "MEMORY(%)" })
		expect(string.find(tbl.rows[1].cells[5], "^%d+%%$") ~= nil).toBe(true)
	end)

	it("reads --no-headers rows with columns known from the command", function()
		local headed = tableParser.parse(fixtures.lines("real/ns-apps/get_pods.txt")).tables[1]
		local result = tableParser.parse(fixtures.lines("real/ns-apps/get_pods_--no-headers.txt"), {
			noHeaders = true,
			knownColumns = names(headed),
		})
		local tbl = result.tables[1]
		expect(names(tbl)).toEqual(names(headed))
		expect(column(tbl, 1)).toEqual(column(headed, 1))
		expect(tbl.unparsed).toEqual({})
	end)

	it("reads custom-columns output against the user's headers", function()
		local tbl = tableParser.parse(
			fixtures.lines("real/ns-apps/get_pods_-o_custom-columns=NAME:.metadata.name,NODE:.spec.nodeName.txt"),
			{ expectedHeaders = { "NAME", "NODE" } }
		).tables[1]
		expect(names(tbl)).toEqual({ "NAME", "NODE" })
		expect(tbl.rows[1].cells[2]).toBe("tern-kube-dev-control-plane")
	end)
end)

describe("table.parse on real kubectl stderr", function()
	local function severities(path: string): { string }
		local result = tableParser.parse(fixtures.lines(path))
		expect(result.tables).toEqual({})
		local out: { string } = {}
		for _, d in result.diagnostics do
			table.insert(out, d.severity)
		end
		return out
	end

	it("reports empty namespaces as info", function()
		expect(severities("real/ns-empty/get_pods.stderr")).toEqual({ "info" })
		expect(severities("real/ns-empty/get_all.stderr")).toEqual({ "info" })
	end)

	it("reports API and client errors as errors", function()
		expect(severities("real/errors/get_pod_does-not-exist.stderr")).toEqual({ "error" })
		expect(severities("real/errors/get_foos.stderr")).toEqual({ "error" })
		expect(severities("real/errors-context/get_pods.stderr")).toEqual({ "error" })
		expect(severities("real/errors/get_secrets_--as=system:serviceaccount:tern-test-apps:default.stderr")).toEqual({
			"error",
		})
	end)

	it("reports klog lines and the final connection error of an unreachable server", function()
		local list = severities("real/errors/get_pods_--server=https:++127.0.0.1:1_--request-timeout=5s.stderr")
		expect(#list > 1).toBe(true)
		for _, severity in list do
			expect(severity).toBe("error")
		end
	end)

	-- Partial NotFound: found rows still form a table next to the error.
	it("keeps the table when stderr reports a partial failure", function()
		local lines = fixtures.lines("real/errors/get_pods_does-not-exist_crashloop.stderr")
		for _, line in fixtures.lines("real/errors/get_pods_does-not-exist_crashloop.txt") do
			table.insert(lines, line)
		end
		local result = tableParser.parse(lines)
		expect(#result.tables).toBe(1)
		expect(result.tables[1].headerLine).toBe(2)
		expect(column(result.tables[1], 1)).toEqual({ "crashloop" })
		expect(result.diagnostics[1].severity).toBe("error")
		expect(result.diagnostics[1].line).toBe(1)
	end)

	it("reports deprecation warnings as warnings next to the table", function()
		local lines = fixtures.lines("real/ns-apps/get_endpoints.stderr")
		for _, line in fixtures.lines("real/ns-apps/get_endpoints.txt") do
			table.insert(lines, line)
		end
		local result = tableParser.parse(lines)
		expect(#result.tables).toBe(1)
		expect(#result.diagnostics).toBe(1)
		expect(result.diagnostics[1].severity).toBe("warning")
	end)
end)

return nil
