--!strict
-- The captured world (kubectl 1.34.1, server 1.37.0) is the ground truth for
-- what the events model must survive: every item and every table row has to
-- produce an event pointing at its object, or the timeline and the lens lose
-- rows silently. Ages and counts change between captures, so assertions stay
-- structural.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Model = require("../../../plugin/lib/events/model")
local Timeline = require("../../../plugin/lib/events/timeline")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local tableParser = require("../../../plugin/lib/parse/table")
local describe, it, expect = t.describe, t.it, t.expect

local JSON_FIXTURES = {
	"real/ns-apps/events_-o_json.txt",
	"real/ns-apps/get_events_-o_json.txt",
	"real/ns-logs/get_events_-o_json.txt",
}

local TABLE_FIXTURES = {
	"ns-apps/events",
	"ns-apps/events_-A",
	"ns-apps/events_--for_pod+crashloop",
	"ns-apps/events_--types=Warning",
	"ns-apps/get_events",
	"ns-apps/get_events_-o_wide",
	"all-namespaces/get_events_-A",
	"ns-logs/get_events_-w_--output-watch-events_--request-timeout=8s",
}

local function decoded(path: string): (any, { Model.Event })
	local obj = json.decode(fixtures.read(path))
	return obj, Model.fromList(obj)
end

describe("events model on real EventLists", function()
	it("yields one event per item, each with a named object, a count >= 1 and a parseable last time", function()
		for _, path in JSON_FIXTURES do
			local obj, events = decoded(path)
			expect(path .. " " .. #events).toBe(path .. " " .. #obj.items)
			expect(#events > 0).toBe(true)
			for _, e in events do
				local object = e.object
				expect(object ~= nil).toBe(true)
				if object then
					expect(object.kind ~= "" and object.name ~= "").toBe(true)
					expect(object.source).toBe("live")
				end
				expect(e.count >= 1).toBe(true)
				expect(e.last ~= nil and Timeline.parseTime(e.last) ~= nil).toBe(true)
				expect(e.key ~= "").toBe(true)
			end
		end
	end)

	it("contains both series and legacy events, so both normalisation paths meet real data", function()
		local series, legacy = 0, 0
		for _, path in JSON_FIXTURES do
			local _, events = decoded(path)
			for _, e in events do
				if e.series then
					series += 1
				else
					legacy += 1
				end
			end
		end
		expect(series > 0).toBe(true)
		expect(legacy > 0).toBe(true)
	end)

	it("keys every event uniquely by metadata.uid", function()
		local _, events = decoded("real/ns-logs/get_events_-o_json.txt")
		local seen: { [string]: boolean } = {}
		for _, e in events do
			expect(seen[e.key]).toBeNil()
			seen[e.key] = true
		end
	end)

	it("reads the series FailedScheduling event of pod/pending with its series count", function()
		local _, events = decoded("real/ns-apps/events_-o_json.txt")
		local found: Model.Event? = nil
		for _, e in events do
			if e.series and e.reason == "FailedScheduling" then
				found = e
			end
		end
		expect(found ~= nil).toBe(true)
		if found then
			expect(found.object and found.object.name).toBe("pending")
			expect(found.count > 1).toBe(true)
			expect(found.source).toBe("default-scheduler")
			expect(found.type).toBe("Warning")
		end
	end)

	it("dates one-off scheduler events (count null, no series) by eventTime and counts them once", function()
		local _, events = decoded("real/ns-logs/get_events_-o_json.txt")
		local oneOff = 0
		for _, e in events do
			if e.reason == "Scheduled" and e.source == "default-scheduler" then
				oneOff += 1
				expect(e.series).toBe(false)
				expect(e.count).toBe(1)
				expect(e.first ~= nil and e.first == e.last).toBe(true)
				expect(string.find(e.last or "", "%.%d+Z$") ~= nil).toBe(true)
			end
		end
		expect(oneOff > 0).toBe(true)
	end)

	it("carries apps/v1 owners (Deployment, ReplicaSet) with their group and version", function()
		local _, events = decoded("real/ns-logs/get_events_-o_json.txt")
		local seen: { [string]: boolean } = {}
		for _, e in events do
			local o = e.object
			if o and (o.kind == "Deployment" or o.kind == "ReplicaSet") then
				seen[o.kind] = true
				expect(o.group).toBe("apps")
				expect(o.version).toBe("v1")
				expect(o.namespace).toBe("tern-test-logs")
			end
		end
		expect(seen.Deployment and seen.ReplicaSet).toBe(true)
	end)

	it("joins kubelet source and host on legacy events", function()
		local _, events = decoded("real/ns-apps/get_events_-o_json.txt")
		local kubelet = 0
		for _, e in events do
			if e.source and string.find(e.source, "^kubelet, ") then
				kubelet += 1
			end
		end
		expect(kubelet > 0).toBe(true)
	end)
end)

describe("events model on real event tables", function()
	it("gives every parsed row an object ref with kind and name, with namespace from -n or NAMESPACE", function()
		for _, id in TABLE_FIXTURES do
			local fx = runs.load(id)
			local inv = Argv.parse(fx.run.program, fx.run.args)
			local parsed = tableParser.parse(fx.lines)
			local tbl = parsed.tables[1]
			expect(id .. " parsed").toBe(id .. (if tbl then " parsed" else " missing"))
			if not tbl then
				continue
			end
			local headers: { string } = {}
			for _, col in tbl.columns do
				table.insert(headers, col.name)
			end
			local nsIndex = table.find(headers, "NAMESPACE")
			expect(#tbl.rows > 0).toBe(true)
			for _, row in tbl.rows do
				local e = Model.fromRow(headers, row.cells, inv)
				local o = e.object
				expect(id .. ":" .. row.line .. " ref").toBe(id .. ":" .. row.line .. (if o then " ref" else " none"))
				if o then
					expect(o.kind ~= "" and o.name ~= "").toBe(true)
					if o.kind ~= "Node" then
						local want = if nsIndex then row.cells[nsIndex] else inv.namespace
						expect(o.namespace).toBe(want)
					end
				end
				expect(e.count >= 1).toBe(true)
				expect(e.reason ~= "" and e.type ~= "").toBe(true)
			end
		end
	end)

	it("drops the namespace of cluster-scoped Node refs although `events -A` prints them under `default`", function()
		local fx = runs.load("ns-apps/events_-A")
		local inv = Argv.parse(fx.run.program, fx.run.args)
		local tbl = tableParser.parse(fx.lines).tables[1]
		local headers: { string } = {}
		for _, col in tbl.columns do
			table.insert(headers, col.name)
		end
		local nodes = 0
		for _, row in tbl.rows do
			local e = Model.fromRow(headers, row.cells, inv)
			local o = e.object
			if o and o.kind == "Node" then
				nodes += 1
				expect(o.namespace).toBeNil()
				expect(e.namespace).toBe("default")
			end
		end
		expect(nodes > 0).toBe(true)
	end)

	it("reads `x<count> over <age>` from kubectl events rows", function()
		local fx = runs.load("ns-apps/events")
		local inv = Argv.parse(fx.run.program, fx.run.args)
		local tbl = tableParser.parse(fx.lines).tables[1]
		local headers: { string } = {}
		for _, col in tbl.columns do
			table.insert(headers, col.name)
		end
		local repeated = 0
		for _, row in tbl.rows do
			local e = Model.fromRow(headers, row.cells, inv)
			if e.over then
				repeated += 1
				expect(e.count > 1).toBe(true)
			end
		end
		expect(repeated > 0).toBe(true)
	end)

	it("keys -o wide rows by the unique Event NAME", function()
		local fx = runs.load("ns-apps/get_events_-o_wide")
		local inv = Argv.parse(fx.run.program, fx.run.args)
		local tbl = tableParser.parse(fx.lines).tables[1]
		local headers: { string } = {}
		for _, col in tbl.columns do
			table.insert(headers, col.name)
		end
		local seen: { [string]: boolean } = {}
		for _, row in tbl.rows do
			local e = Model.fromRow(headers, row.cells, inv)
			expect(seen[e.key]).toBeNil()
			seen[e.key] = true
			expect(e.source ~= nil).toBe(true)
		end
	end)
end)

return nil
