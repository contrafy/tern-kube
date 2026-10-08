--!strict
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local tableParser = require("../../../plugin/lib/parse/table")
local values = require("../../../plugin/lib/model/values")
local describe, it, expect = t.describe, t.it, t.expect

describe("values.duration", function()
	-- kubectl prints ages with HumanDuration: two most significant units,
	-- coarser as the age grows; sorting by age must compare them numerically.
	it("reads every HumanDuration form as seconds", function()
		expect(values.duration("0s")).toBe(0)
		expect(values.duration("90s")).toBe(90)
		expect(values.duration("5m30s")).toBe(330)
		expect(values.duration("179m")).toBe(179 * 60)
		expect(values.duration("3h15m")).toBe(3 * 3600 + 15 * 60)
		expect(values.duration("45h")).toBe(45 * 3600)
		expect(values.duration("3d4h")).toBe(3 * 86400 + 4 * 3600)
		expect(values.duration("400d")).toBe(400 * 86400)
		expect(values.duration("2y3d")).toBe(2 * 365 * 86400 + 3 * 86400)
		expect(values.duration("9y")).toBe(9 * 365 * 86400)
	end)

	it("has no value for placeholders or other text", function()
		expect(values.duration("<invalid>")).toBeNil()
		expect(values.duration("<unknown>")).toBeNil()
		expect(values.duration("")).toBeNil()
		expect(values.duration("web")).toBeNil()
		expect(values.duration("3h4d")).toBeNil()
		expect(values.duration("5")).toBeNil()
	end)
end)

describe("values.ratio / count / percent", function()
	it("reads READY-style ratios", function()
		local num, den = values.ratio("1/2")
		expect(num).toBe(1)
		expect(den).toBe(2)
		expect((values.ratio("Running"))).toBeNil()
		expect((values.ratio("1/"))).toBeNil()
	end)

	-- RESTARTS shows the last restart age next to the count; only the count
	-- matters for sorting.
	it("reads restart counts with or without the trailing age", function()
		expect(values.count("3 (5m ago)")).toBe(3)
		expect(values.count("0")).toBe(0)
		expect(values.count("<none>")).toBeNil()
		expect(values.count("3m")).toBeNil()
	end)

	it("reads percentages", function()
		expect(values.percent("12%")).toBe(12)
		expect(values.percent("0%")).toBe(0)
		expect(values.percent("12")).toBeNil()
		expect(values.percent("<unknown>")).toBeNil()
	end)
end)

describe("values.quantity", function()
	-- kubectl top and resource columns mix millicores, binary and decimal
	-- suffixes; comparisons need a single base unit.
	it("normalises Kubernetes quantity suffixes to base units", function()
		expect(values.quantity("250m")).toBe(0.25)
		expect(values.quantity("2")).toBe(2)
		expect(values.quantity("1.5")).toBe(1.5)
		expect(values.quantity("10k")).toBe(10000)
		expect(values.quantity("128Mi")).toBe(128 * 1024 * 1024)
		expect(values.quantity("1Gi")).toBe(1024 * 1024 * 1024)
		expect(values.quantity("2G")).toBe(2e9)
		expect(values.quantity("500n")).toBe(500e-9)
		expect(values.quantity("1e3")).toBe(1000)
	end)

	it("rejects text that is not a quantity", function()
		expect(values.quantity("<unknown>")).toBeNil()
		expect(values.quantity("12%")).toBeNil()
		expect(values.quantity("5Xi")).toBeNil()
		expect(values.quantity("")).toBeNil()
	end)
end)

describe("values.timestamp", function()
	it("orders RFC3339 times across offsets and fractions without a clock", function()
		local utc = values.timestamp("2026-10-08T07:00:00Z")
		expect(utc).toBe(1791442800)
		expect(values.timestamp("2026-10-08T09:00:00+02:00")).toBe(utc)
		expect(values.timestamp("1970-01-01T00:00:00Z")).toBe(0)
		local frac = values.timestamp("2026-10-08T07:00:00.5Z")
		expect(frac).toBe(1791442800.5)
		expect(values.timestamp("2026-10-08")).toBeNil()
		expect(values.timestamp("<unknown>")).toBeNil()
	end)
end)

describe("values.columnType", function()
	it("types well-known kubectl headers", function()
		expect(values.columnType("AGE", { "3d4h", "5m" })).toBe("duration")
		expect(values.columnType("LAST SEEN", { "2m" })).toBe("duration")
		expect(values.columnType("READY", { "1/1", "0/1" })).toBe("ratio")
		expect(values.columnType("RESTARTS", { "0", "3 (5m ago)" })).toBe("count")
		expect(values.columnType("STATUS", { "Running" })).toBe("status")
		expect(values.columnType("CPU(cores)", { "152m" })).toBe("quantity")
		expect(values.columnType("MEMORY(bytes)", { "612Mi" })).toBe("quantity")
		expect(values.columnType("CPU%", { "1%" })).toBe("percent")
		expect(values.columnType("MEMORY(%)", { "7%" })).toBe("percent")
		expect(values.columnType("AVAILABLE", { "3" })).toBe("number")
		expect(values.columnType("NAME", { "web-0" })).toBe("text")
	end)

	-- Header names collide across kinds: TYPE is a status for events but plain
	-- text for services; CRD READY columns hold True/False.
	it("lets samples disambiguate shared header names", function()
		expect(values.columnType("TYPE", { "Normal", "Warning" })).toBe("status")
		expect(values.columnType("TYPE", { "ClusterIP", "NodePort" })).toBe("text")
		expect(values.columnType("READY", { "True", "False" })).toBe("status")
	end)

	it("infers types of unknown CRD columns from samples, ignoring placeholders", function()
		expect(values.columnType("REPLICAS", { "3", "<none>", "10" })).toBe("number")
		expect(values.columnType("SYNCED", { "True", "Unknown" })).toBe("status")
		expect(values.columnType("LAST SCHEDULE", { "5m", "<none>" })).toBe("duration")
		expect(values.columnType("CREATED", { "2026-10-08T07:00:00Z" })).toBe("timestamp")
		expect(values.columnType("CERT", { "web-tls" })).toBe("text")
		expect(values.columnType("WHATEVER", {})).toBe("text")
		expect(values.columnType("WHATEVER", { "<none>" })).toBe("text")
	end)
end)

describe("values.statusTone", function()
	local function tones(header: string, list: { string }): { string }
		local out: { string } = {}
		for _, v in list do
			table.insert(out, values.statusTone(header, v))
		end
		return out
	end

	it("colours pod phases and container reasons by urgency", function()
		expect(tones("STATUS", { "Running" })).toEqual({ "success" })
		-- Finished pods are history, not health signals.
		expect(tones("STATUS", { "Completed", "Succeeded" })).toEqual({ "muted", "muted" })
		expect(
			tones("STATUS", { "Pending", "ContainerCreating", "PodInitializing", "Init:0/2", "Terminating", "Unknown" })
		).toEqual({ "warning", "warning", "warning", "warning", "warning", "warning" })
		expect(tones("STATUS", {
			"CrashLoopBackOff",
			"Error",
			"ImagePullBackOff",
			"ErrImagePull",
			"OOMKilled",
			"Evicted",
			"CreateContainerConfigError",
			"Init:CrashLoopBackOff",
			"Init:Error",
		})).toEqual({ "error", "error", "error", "error", "error", "error", "error", "error", "error" })
	end)

	it("takes the worst part of combined node conditions", function()
		expect(tones("STATUS", { "Ready", "NotReady", "Ready,SchedulingDisabled", "NotReady,SchedulingDisabled" })).toEqual({
			"success",
			"error",
			"warning",
			"error",
		})
	end)

	it("colours events, jobs and generic conditions", function()
		expect(tones("TYPE", { "Normal", "Warning" })).toEqual({ "neutral", "warning" })
		expect(tones("STATUS", { "Complete", "Failed", "Suspended" })).toEqual({ "success", "error", "warning" })
		expect(tones("READY", { "True", "False", "Unknown" })).toEqual({ "success", "error", "warning" })
	end)

	-- SUSPEND=True means the CronJob is paused: the generic True=good rule
	-- would invert the meaning.
	it("does not treat a CronJob SUSPEND flag as a health condition", function()
		expect(tones("SUSPEND", { "True", "False" })).toEqual({ "warning", "neutral" })
	end)

	it("warns on partially ready ratios", function()
		expect(tones("READY", { "1/1", "0/1", "2/3", "0/0" })).toEqual({ "success", "warning", "warning", "muted" })
	end)

	it("mutes placeholders and leaves unknown text neutral", function()
		expect(tones("STATUS", { "<none>", "", "Bound", "SomethingNew" })).toEqual({
			"muted",
			"muted",
			"success",
			"neutral",
		})
	end)
end)

describe("values.compare / sortKey", function()
	local function sorted(columnType: any, list: { string }, descending: boolean?): { string }
		local copy = table.clone(list)
		table.sort(copy, function(a, b)
			return values.compare(columnType, a, b, descending)
		end)
		return copy
	end

	it("sorts ages by elapsed time, not text", function()
		expect(sorted("duration", { "3d4h", "45h", "5m30s", "90s", "2y3d" })).toEqual({
			"90s",
			"5m30s",
			"45h",
			"3d4h",
			"2y3d",
		})
	end)

	-- Placeholders carry no value; whichever way the user sorts they belong at
	-- the bottom so real values stay together at the top.
	it("keeps placeholders and blanks last in both directions", function()
		local list = { "<unknown>", "5m", "", "<invalid>", "1h", "<none>" }
		local asc = sorted("duration", list)
		expect({ asc[1], asc[2] }).toEqual({ "5m", "1h" })
		local desc = sorted("duration", list, true)
		expect({ desc[1], desc[2] }).toEqual({ "1h", "5m" })
		for i = 3, 6 do
			expect(values.sortKey("duration", asc[i])).toBeNil()
			expect(values.sortKey("duration", desc[i])).toBeNil()
		end
	end)

	it("sorts quantities, counts, ratios and percents numerically", function()
		expect(sorted("quantity", { "1Gi", "512Mi", "2" })).toEqual({ "2", "512Mi", "1Gi" })
		expect(sorted("count", { "10", "3 (5m ago)", "0" })).toEqual({ "0", "3 (5m ago)", "10" })
		expect(sorted("ratio", { "1/1", "0/1", "1/2" })).toEqual({ "0/1", "1/2", "1/1" })
		expect(sorted("percent", { "10%", "9%", "100%" })).toEqual({ "9%", "10%", "100%" })
		expect(sorted("timestamp", { "2026-10-08T07:00:00Z", "2026-10-08T06:00:00-02:00" })).toEqual({
			"2026-10-08T07:00:00Z",
			"2026-10-08T06:00:00-02:00",
		})
	end)

	it("sorts text naturally so numbered replicas stay in order", function()
		expect(sorted("text", { "web-10", "web-2", "Web-1" })).toEqual({ "Web-1", "web-2", "web-10" })
	end)

	it("leaves ties to the caller", function()
		expect(values.compare("duration", "5m", "5m")).toBe(false)
		expect(values.compare("text", "<none>", "")).toBe(false)
	end)
end)

describe("values on a realistic pod table", function()
	local tbl = tableParser.parse(fixtures.lines("synthetic/rows-1000/get_pods_-A_-o_wide.txt")).tables[1]
	local function column(index: number): { string }
		local out: { string } = {}
		for _, row in tbl.rows do
			table.insert(out, row.cells[index])
		end
		return out
	end

	it("types every default pod column", function()
		local types: { string } = {}
		for i, col in tbl.columns do
			table.insert(types, values.columnType(col.name, column(i)))
		end
		expect(types).toEqual({
			"text",
			"text",
			"ratio",
			"status",
			"count",
			"duration",
			"text",
			"text",
			"text",
			"ratio",
		})
	end)

	-- A cell that fails to parse would silently sort last and look like a
	-- placeholder; every generated age/restart/ready cell must have a key.
	it("gives every age, restart count and ready ratio a sort key", function()
		local checks: { { index: number, kind: any } } =
			{ { index = 3, kind = "ratio" }, { index = 5, kind = "count" }, { index = 6, kind = "duration" } }
		for _, check in checks do
			for _, cell in column(check.index) do
				expect({ cell = cell, ok = values.sortKey(check.kind, cell) ~= nil }).toEqual({
					cell = cell,
					ok = true,
				})
			end
		end
	end)

	it("knows a tone for every generated pod status", function()
		for _, cell in column(4) do
			expect({ cell = cell, neutral = values.statusTone("STATUS", cell) == "neutral" }).toEqual({
				cell = cell,
				neutral = false,
			})
		end
	end)
end)

return nil
