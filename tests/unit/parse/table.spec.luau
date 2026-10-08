--!strict
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local tableParser = require("../../../plugin/lib/parse/table")
local describe, it, expect = t.describe, t.it, t.expect

-- Renders rows the way kubectl's printer does (text/tabwriter: minwidth 6,
-- padding 3, space padded, widths in runes, last column unpadded), so inline
-- cases stay byte-faithful without hand-counting spaces.
local function tab(rows: { { string } }): { string }
	local widths: { number } = {}
	for _, row in rows do
		for i = 1, #row - 1 do
			local w = math.max(6, (utf8.len(row[i]) or #row[i]) + 3)
			if w > (widths[i] or 0) then
				widths[i] = w
			end
		end
	end
	local out: { string } = {}
	for _, row in rows do
		local parts: { string } = {}
		for i, cell in row do
			if i < #row then
				table.insert(parts, cell .. string.rep(" ", widths[i] - (utf8.len(cell) or #cell)))
			else
				table.insert(parts, cell)
			end
		end
		table.insert(out, table.concat(parts))
	end
	return out
end

local function concat(...: { string }): { string }
	local out: { string } = {}
	for _, part in { ... } do
		for _, line in part do
			table.insert(out, line)
		end
	end
	return out
end

local function names(parsed: any): { string }
	local out: { string } = {}
	for _, col in parsed.columns do
		table.insert(out, col.name)
	end
	return out
end

local function cells(parsed: any): { { string } }
	local out: { { string } } = {}
	for _, row in parsed.rows do
		table.insert(out, row.cells)
	end
	return out
end

describe("table.parse", function()
	it("splits a default pod table by header spans so multi-word cells survive", function()
		local result = tableParser.parse(fixtures.lines("kubectl/get_pods.txt"))
		expect(#result.tables).toBe(1)
		expect(result.diagnostics).toEqual({})
		local tbl = result.tables[1]
		expect(tbl.headerLine).toBe(1)
		expect(names(tbl)).toEqual({ "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
		expect(tbl.columns[1]).toEqual({ name = "NAME", start = 1, stop = 25 })
		expect(tbl.columns[5]).toEqual({ name = "AGE", start = 67 })
		expect(#tbl.rows).toBe(6)
		expect(tbl.rows[2]).toEqual({
			line = 3,
			cells = { "api-7d9f8b6c5-9zrtm", "1/1", "Running", "2 (5h ago)", "3d4h" },
		})
		expect(tbl.rows[3].cells[4]).toBe("14 (2m ago)")
		expect(tbl.unparsed).toEqual({})
	end)

	it("handles the NAMESPACE column added by -A", function()
		local lines = tab({
			{ "NAMESPACE", "NAME", "READY", "STATUS", "RESTARTS", "AGE" },
			{ "kube-system", "coredns-7db6d8ff4d-4xk2p", "1/1", "Running", "0", "10m" },
			{ "default", "web-0", "1/1", "Running", "1 (2m ago)", "2m" },
		})
		local tbl = tableParser.parse(lines).tables[1]
		expect(names(tbl)).toEqual({ "NAMESPACE", "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
		expect(cells(tbl)).toEqual({
			{ "kube-system", "coredns-7db6d8ff4d-4xk2p", "1/1", "Running", "0", "10m" },
			{ "default", "web-0", "1/1", "Running", "1 (2m ago)", "2m" },
		})
	end)

	it("keeps multi-word -o wide headers and <none> values as single columns", function()
		local lines = tab({
			{ "NAME", "READY", "STATUS", "RESTARTS", "AGE", "IP", "NODE", "NOMINATED NODE", "READINESS GATES" },
			{ "web-0", "1/1", "Running", "0", "5m", "10.244.0.5", "kind-control-plane", "<none>", "<none>" },
		})
		local tbl = tableParser.parse(lines).tables[1]
		expect(names(tbl)).toEqual({
			"NAME",
			"READY",
			"STATUS",
			"RESTARTS",
			"AGE",
			"IP",
			"NODE",
			"NOMINATED NODE",
			"READINESS GATES",
		})
		expect(tbl.rows[1].cells[8]).toBe("<none>")
		expect(tbl.rows[1].cells[9]).toBe("<none>")
	end)

	it("recognises kubectl top and event headers with parentheses, percent and spaces", function()
		local top = tableParser.parse(tab({
			{ "NAME", "CPU(cores)", "CPU%", "MEMORY(bytes)", "MEMORY%" },
			{ "kind-control-plane", "152m", "1%", "612Mi", "7%" },
		})).tables[1]
		expect(names(top)).toEqual({ "NAME", "CPU(cores)", "CPU%", "MEMORY(bytes)", "MEMORY%" })
		expect(top.rows[1].cells).toEqual({ "kind-control-plane", "152m", "1%", "612Mi", "7%" })

		local events = tableParser.parse(tab({
			{ "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" },
			{
				"2m",
				"Warning",
				"BackOff",
				"pod/web-0",
				"Back-off restarting failed container web in pod web-0_default(1a2b)",
			},
			{ "5m", "Normal", "Scheduled", "pod/web-0", "Successfully assigned default/web-0 to kind-control-plane" },
		})).tables[1]
		expect(names(events)).toEqual({ "LAST SEEN", "TYPE", "REASON", "OBJECT", "MESSAGE" })
		expect(events.rows[1].cells[5]).toBe("Back-off restarting failed container web in pod web-0_default(1a2b)")
	end)

	it("splits `get all` style output into one table per kind at blank lines", function()
		local lines = concat(
			tab({
				{ "NAME", "READY", "STATUS", "RESTARTS", "AGE" },
				{ "pod/web-0", "1/1", "Running", "0", "5m" },
			}),
			{ "" },
			tab({
				{ "NAME", "TYPE", "CLUSTER-IP", "EXTERNAL-IP", "PORT(S)", "AGE" },
				{ "service/kubernetes", "ClusterIP", "10.96.0.1", "<none>", "443/TCP", "20m" },
				{ "service/web", "NodePort", "10.96.12.4", "<none>", "80:30080/TCP,443:30443/TCP", "5m" },
			}),
			{ "" },
			tab({
				{ "NAME", "READY", "UP-TO-DATE", "AVAILABLE", "AGE" },
				{ "deployment.apps/web", "1/1", "1", "1", "5m" },
			})
		)
		local result = tableParser.parse(lines)
		expect(result.diagnostics).toEqual({})
		expect(#result.tables).toBe(3)
		expect(result.tables[1].headerLine).toBe(1)
		expect(result.tables[2].headerLine).toBe(4)
		expect(result.tables[3].headerLine).toBe(8)
		expect(names(result.tables[2])).toEqual({ "NAME", "TYPE", "CLUSTER-IP", "EXTERNAL-IP", "PORT(S)", "AGE" })
		expect(result.tables[2].rows[2]).toEqual({
			line = 6,
			cells = { "service/web", "NodePort", "10.96.12.4", "<none>", "80:30080/TCP,443:30443/TCP", "5m" },
		})
		expect(result.tables[3].rows[1].cells[1]).toBe("deployment.apps/web")
	end)

	-- tabwriter pads by rune count, so byte offsets drift after any non-ASCII
	-- cell; spans must be measured in runes.
	it("aligns by runes when cells contain multi-byte characters", function()
		local lines = tab({
			{ "NAME", "OWNER", "NOTE" },
			{ "café-config", "zoë", "naïve ☃ value" },
			{ "plain", "日本語チーム", "ok" },
		})
		local result = tableParser.parse(lines, { expectedHeaders = { "NAME", "OWNER", "NOTE" } })
		expect(cells(result.tables[1])).toEqual({
			{ "café-config", "zoë", "naïve ☃ value" },
			{ "plain", "日本語チーム", "ok" },
		})
		expect(result.tables[1].unparsed).toEqual({})
	end)

	it("reads empty cells from their span instead of shifting later columns", function()
		local lines = tab({
			{ "CURRENT", "NAME", "CLUSTER", "AUTHINFO", "NAMESPACE" },
			{ "*", "kind-dev", "kind-dev", "kind-dev", "" },
			{ "", "kind-prod", "kind-prod", "kind-prod", "payments" },
		})
		local tbl = tableParser.parse(lines).tables[1]
		expect(cells(tbl)).toEqual({
			{ "*", "kind-dev", "kind-dev", "kind-dev", "" },
			{ "", "kind-prod", "kind-prod", "kind-prod", "payments" },
		})
	end)

	-- `kubectl get -w` prints later events with remembered (grown) widths, so
	-- rows can stop lining up with the header printed earlier.
	it("falls back to 2+ space splitting for misaligned watch rows", function()
		local lines = concat(fixtures.lines("kubectl/get_pods_-w.txt"), {
			"worker-5c8d7f9b4-lq7vn-extra-long   0/1     Pending   3 (1s ago)   47m",
		})
		local tbl = tableParser.parse(lines).tables[1]
		expect(#tbl.rows).toBe(4)
		expect(tbl.rows[4]).toEqual({
			line = 5,
			cells = { "worker-5c8d7f9b4-lq7vn-extra-long", "0/1", "Pending", "3 (1s ago)", "47m" },
		})
	end)

	it("never fabricates cells for rows that fit neither spans nor splitting", function()
		local lines = concat(fixtures.lines("kubectl/get_pods.txt"), {
			"worker-5c8d7f9b4-lq7vn-extra-long   0/1   Pending",
		})
		local result = tableParser.parse(lines)
		local tbl = result.tables[1]
		expect(#tbl.rows).toBe(6)
		expect(tbl.unparsed).toEqual({ { line = 8, text = "worker-5c8d7f9b4-lq7vn-extra-long   0/1   Pending" } })
		expect(#result.diagnostics).toBe(1)
		expect(result.diagnostics[1].line).toBe(8)
		expect(result.diagnostics[1].severity).toBe("warning")
	end)

	it("uses known columns for --no-headers output when the split count matches", function()
		local lines = tab({
			{ "web-0", "1/1", "Running", "2 (5h ago)", "3d" },
			{ "web-1", "0/1", "Pending", "0", "5s" },
		})
		table.insert(lines, "broken-row   0/1")
		local result = tableParser.parse(lines, {
			noHeaders = true,
			knownColumns = { "NAME", "READY", "STATUS", "RESTARTS", "AGE" },
		})
		local tbl = result.tables[1]
		expect(tbl.headerLine).toBeNil()
		expect(names(tbl)).toEqual({ "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
		expect(cells(tbl)).toEqual({
			{ "web-0", "1/1", "Running", "2 (5h ago)", "3d" },
			{ "web-1", "0/1", "Pending", "0", "5s" },
		})
		expect(tbl.unparsed).toEqual({ { line = 3, text = "broken-row   0/1" } })
		expect(result.diagnostics[1].severity).toBe("warning")
	end)

	it("still splits --no-headers output when the columns are unknown", function()
		local result = tableParser.parse(
			tab({
				{ "web-0", "1/1", "Running" },
				{ "web-1", "0/1", "Pending" },
			}),
			{ noHeaders = true }
		)
		local tbl = result.tables[1]
		expect(names(tbl)).toEqual({ "", "", "" })
		expect(tbl.rows[2].cells).toEqual({ "web-1", "0/1", "Pending" })
	end)

	it("accepts user-chosen custom-columns headers that are not upper-case", function()
		local lines = tab({
			{ "name", "node ip", "phase" },
			{ "web-0", "172.18.0.2", "Running" },
		})
		local result = tableParser.parse(lines, { expectedHeaders = { "name", "node ip", "phase" } })
		expect(result.diagnostics).toEqual({})
		expect(names(result.tables[1])).toEqual({ "name", "node ip", "phase" })
		expect(result.tables[1].rows[1].cells).toEqual({ "web-0", "172.18.0.2", "Running" })
	end)

	it("returns nothing for empty output", function()
		expect(tableParser.parse({})).toEqual({ tables = {}, diagnostics = {} })
	end)

	it("reports `No resources found` as info rather than a table", function()
		expect(tableParser.parse({ "No resources found in default namespace." })).toEqual({
			tables = {},
			diagnostics = { { line = 1, severity = "info", text = "No resources found in default namespace." } },
		})
	end)

	it("reports error-only output as error diagnostics", function()
		local result = tableParser.parse(fixtures.lines("kubectl/get_pods_missing.stderr"))
		expect(result.tables).toEqual({})
		expect(result.diagnostics).toEqual({
			{ line = 1, severity = "error", text = [[Error from server (NotFound): pods "missing" not found]] },
		})
	end)

	-- stdout and stderr arrive interleaved; warnings mid-table must not end the
	-- table or be mistaken for rows.
	it("keeps the table open across interleaved warnings and errors", function()
		local lines = fixtures.lines("kubectl/get_pods.txt")
		table.insert(lines, 1, "Warning: v1 ComponentStatus is deprecated in v1.19+")
		table.insert(
			lines,
			4,
			"E1008 12:00:00.000000   12345 memcache.go:265] couldn't get current server API group list"
		)
		local result = tableParser.parse(lines)
		expect(#result.tables).toBe(1)
		expect(result.tables[1].headerLine).toBe(2)
		expect(#result.tables[1].rows).toBe(6)
		expect(result.diagnostics[1]).toEqual({
			line = 1,
			severity = "warning",
			text = "Warning: v1 ComponentStatus is deprecated in v1.19+",
		})
		expect(result.diagnostics[2].line).toBe(4)
		expect(result.diagnostics[2].severity).toBe("error")
	end)
end)

describe("table.classify", function()
	local function severity(line: string): string?
		local d = tableParser.classify(line)
		return if d then d.severity else nil
	end

	it("maps kubectl's stderr conventions to severities", function()
		expect(severity("Warning: resource pods is missing the annotation")).toBe("warning")
		expect(severity("Error from server (Forbidden): pods is forbidden")).toBe("error")
		expect(severity('error: the server doesn\'t have a resource type "pod2"')).toBe("error")
		expect(severity("Error: unknown flag: --bogus")).toBe("error")
		expect(severity("Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused")).toBe(
			"error"
		)
		expect(
			severity(
				"The connection to the server localhost:8080 was refused - did you specify the right host or port?"
			)
		).toBe("error")
		expect(severity("No resources found")).toBe("info")
		expect(severity("Flag --short has been deprecated, and will be removed")).toBe("warning")
	end)

	it("reads klog severity letters", function()
		expect(severity("E1008 12:00:00.000000    1234 memcache.go:265] couldn't get resource list")).toBe("error")
		expect(severity("W1008 12:00:00.123456    1234 warnings.go:70] deprecated")).toBe("warning")
		expect(severity("I1008 12:00:00.123456    1234 request.go:700] throttled")).toBe("info")
		expect(severity("F1008 12:00:00.123456    1234 main.go:1] fatal")).toBe("error")
	end)

	it("does not claim ordinary rows", function()
		expect(severity("error-pod   0/1   Error   0   5m")).toBeNil()
		expect(severity("Warning   BackOff   pod/x   msg")).toBeNil()
	end)
end)

describe("table.parse at scale", function()
	-- Lens callbacks get 2 s and also render; parsing must stay a small slice
	-- of that even for the widest default table.
	it("parses 1000 -A -o wide rows well inside the lens callback budget", function()
		local lines = fixtures.lines("synthetic/rows-1000/get_pods_-A_-o_wide.txt")
		local started = os.clock()
		local result = tableParser.parse(lines)
		local elapsed = os.clock() - started
		local tbl = result.tables[1]
		expect(#result.tables).toBe(1)
		expect(result.diagnostics).toEqual({})
		expect(#tbl.rows).toBe(1000)
		expect(tbl.unparsed).toEqual({})
		expect(#tbl.columns).toBe(10)
		expect(elapsed < 0.2).toBe(true)
	end)

	it("cuts every synthetic layout without falling back or dropping rows", function()
		for _, path in fixtures.list("synthetic/rows-") do
			if string.sub(path, -4) == ".txt" then
				local lines = fixtures.lines(path)
				local result = tableParser.parse(lines)
				expect({ path = path, rows = #result.tables[1].rows }).toEqual({ path = path, rows = #lines - 1 })
				expect({ path = path, diagnostics = result.diagnostics }).toEqual({ path = path, diagnostics = {} })
			end
		end
	end)
end)

return nil
