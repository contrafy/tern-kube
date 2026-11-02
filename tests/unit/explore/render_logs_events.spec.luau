--!strict
-- How Explore shows logs and events: records with level badges, sources and
-- times in a windowed grid with an inline inspector; a timeline grouped by
-- recency with Warning and reason tones. Pointer chips mirror every key.
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local Timeline = require("../../../plugin/lib/events/timeline")
local W = require("../../lib/explore")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State

local NOW = Timeline.parseTime("2026-11-02T16:48:00Z") :: number

local function main(s: State): nodes.Node
	return Render.view(s, 160, 50).main :: any
end

local function typeText(s: State, text: string): State
	local names = { "/" }
	for i = 1, #text do
		table.insert(names, string.sub(text, i, i))
	end
	table.insert(names, "enter")
	return (W.keys(s, names))
end

local function headers(m: nodes.Node): { string }
	local out: { string } = {}
	for _, h in nodes.findAll(m, nodes.class("tk-h")) do
		table.insert(out, (h.p :: any).text)
	end
	return out
end

local function rows(m: nodes.Node): { nodes.Node }
	return nodes.findAll(m, nodes.class("tk-r"))
end

local function openEvents(params: { [string]: string }?): State
	local env = W.env()
	env.now = NOW
	local p = params or { context = W.CTX, namespace = W.NS, route = "events" }
	local s, effects = State.init({ W.link(p) }, nil, W.config(nil), env)
	return (W.settle(s, effects))
end

describe("explore render: logs", function()
	it("records show time, source, a level badge and the message with its first fields", function()
		local s = W.keys(W.open(), { "L" })
		local m = main(s)
		expect(headers(m)).toEqual({ "TIME", "SOURCE", "LEVEL", "MESSAGE" })
		local s2 = typeText(s, "server started")
		local text = nodes.text(main(s2))
		expect(text).toContain("16:26:02.377")
		expect(text).toContain("app")
		expect(text).toContain("INFO")
		expect(text).toContain("server started  port=8080")
		local summary = nodes.find(m, nodes.role("tern-kube.logs-summary")) :: nodes.Node
		expect(nodes.text(summary)).toContain("errors")
		expect(nodes.text(summary)).toContain("--tail=500")
	end)

	it("error badges are error-toned and a stack shows as +N lines", function()
		local s = typeText(W.keys(W.open(), { "L" }), "IllegalState")
		local m = main(s)
		local badge = nodes.find(m, nodes.role("tern-kube.level")) :: nodes.Node
		expect((badge.p :: any).text).toBe("ERROR")
		expect((badge.p :: any).tone).toBe("error")
		expect(nodes.text(m)).toContain("+2 lines")
	end)

	-- A 1800-line log must not become 1800 grid rows: the block shows a
	-- window around the selection, newest first in view.
	it("long logs render one window of rows, ending at the newest line", function()
		local s = W.keys(W.open(nil, W.config('{"general":{"max_rendered_rows":20}}')), { "L" })
		local m = main(s)
		expect(#rows(m)).toBe(20)
		expect(nodes.find(m, nodes.key("above")) ~= nil).toBe(true)
		expect(nodes.find(m, nodes.key("overflow"))).toBeNil()
	end)

	it("the inspector shows fields and the copy chips under the selected line", function()
		local s = W.keys(typeText(W.keys(W.open(), { "L" }), "server started"), { "enter" })
		local m = main(s)
		local insp = nodes.find(m, nodes.role("tern-kube.log-inspector")) :: nodes.Node
		local text = nodes.text(insp)
		expect(text).toContain("port")
		expect(text).toContain("8080")
		expect(text).toContain("pod tk-logmix-6856789c59-kh4x5, container app")
		local actions = nodes.actions(insp)
		local item = State.selectedItem(s) :: State.Item
		expect(actions).toContain("lcopy=line:" .. item.key)
		expect(actions).toContain("lcopy=json:" .. item.key)
		expect(actions).toContain("logs-inspect=")
	end)

	it("chips mirror the keys: containers, previous, level floor, errors, wrap, follow", function()
		-- Containers come from what the every-container read printed.
		local link = { context = W.CTX, namespace = "tern-test-logs", route = "logs", selector = "app%3Dtk-logmix" }
		local s = W.keys(W.open(link), { "w" })
		local m = main(s)
		local actions = nodes.actions(m)
		for _, a in
			{
				"container=",
				"container=app",
				"container=side",
				"previous",
				"logs-floor=warn",
				"logs-floor=error",
				"logs-jump=next",
				"logs-jump=prev",
				"logs-wrap",
				"quick=logs-follow",
			}
		do
			expect(actions).toContain(a)
		end
		expect(nodes.find(m, nodes.class("tk-logwrap")) ~= nil).toBe(true)
	end)

	it("a failed read keeps the chips so o can switch back", function()
		local s = W.keys(W.open(), { "L", "o" })
		local m = main(s)
		expect(nodes.text(m)).toContain("No previous instance")
		expect(nodes.actions(m)).toContain("previous")
	end)

	it("objects offer their events timeline", function()
		local s = W.keys(W.open(), { "enter" })
		expect(nodes.actions(main(s))).toContain("nav=events")
	end)
end)

describe("explore render: events", function()
	it("groups events by recency with Warning counts, newest first", function()
		local m = main(openEvents())
		local seps = nodes.findAll(m, nodes.class("tk-sep"))
		local labels: { string } = {}
		for _, sep in seps do
			table.insert(labels, nodes.text(sep))
		end
		expect(labels).toEqual({ "last 5 minutes · 4 (2 Warning)", "last hour · 1 (1 Warning)" })
		expect(headers(m)).toEqual({ "AGE", "TYPE", "REASON", "OBJECT", "MESSAGE", "COUNT" })
		local summary = nodes.find(m, nodes.role("tern-kube.events-summary")) :: nodes.Node
		expect(nodes.text(summary)).toBe("events · ns tern-test-apps · 5 · 3 Warning · newest 30s ago")
	end)

	it("Warnings are badges; failing reasons are error-toned", function()
		local m = main(openEvents())
		local warn = nodes.findAll(m, nodes.role("tern-kube.event-type"))
		expect(#warn).toBe(3)
		expect((warn[1].p :: any).tone).toBe("warning")
		local backoff = nodes.find(m, nodes.all(nodes.kind("text"), nodes.hasText("FailedScheduling"))) :: nodes.Node
		expect(nodes.tones(backoff)).toContain("error")
		expect(nodes.text(m)).toContain("Pod/crashloop")
		expect(nodes.text(m)).toContain("×136")
	end)

	it("chips: Warnings only and the top reasons; object scope adds related and whole namespace", function()
		local actions = nodes.actions(main(openEvents()))
		expect(actions).toContain("events-warnings")
		expect(actions).toContain("events-reason=BackOff")
		expect(table.find(actions, "events-related")).toBeNil()
		local s = openEvents({ context = W.CTX, namespace = W.NS, kind = "Pod", name = "crashloop", route = "events" })
		local scoped = nodes.actions(main(s))
		expect(scoped).toContain("events-related")
		expect(scoped).toContain("events-scope")
		expect(Render.title(s)).toContain("Events pod/crashloop")
	end)

	it("an empty scope says events expire", function()
		local s = openEvents({ context = W.CTX, namespace = "tern-test-empty", route = "events" })
		expect(nodes.text(main(s))).toContain("The cluster keeps events for about an hour.")
	end)

	it("the help layer and dock name the route keys", function()
		local s = openEvents()
		local dock = Render.view(s, 160, 50).dock :: any
		expect(nodes.text(dock)).toContain("x Warning only")
	end)
end)

return nil
