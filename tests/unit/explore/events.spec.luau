--!strict
-- Explore's events route: the namespace timeline (`v`) and an object's own
-- events plus those of what it owns (`V`), read with `get events -o json`
-- only on request. Its rows stand for their involved object, so every object
-- key acts on what the event is about.
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local Timeline = require("../../../plugin/lib/events/timeline")
local W = require("../../lib/explore")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State

-- The capture's newest event (crashloop BackOff) is 30 s old at NOW.
local NOW = Timeline.parseTime("2026-11-02T16:48:00Z") :: number

local function top(s: State): State.Route
	return s.stack[#s.stack]
end

local function open(params: { [string]: string }?, responder: W.Responder?): (State, W.Trace)
	local env = W.env()
	env.now = NOW
	local p = params or { context = W.CTX, namespace = W.NS, kind = "Pod" }
	local s, effects = State.init({ W.link(p) }, nil, W.config(nil), env)
	return W.settle(s, effects, responder)
end

local function keys(s: State, names: { string }, responder: W.Responder?): (State, W.Trace)
	local trace: W.Trace = { runs = {}, effects = {} }
	for _, name in names do
		local effects
		s, effects = State.update(s, W.key(name))
		s, trace = W.settle(s, effects, responder, trace)
	end
	return s, trace
end

local function argvText(trace: W.Trace): { string }
	local out: { string } = {}
	for _, run in trace.runs do
		table.insert(out, table.concat(run.argv :: { string }, " "))
	end
	return out
end

local function eventsOf(s: State): { any }
	local data = (State.currentLoad(s) :: State.Load).data :: State.EventsData
	local byKey: { [string]: any } = {}
	for _, e in data.events do
		byKey[e.key] = e
	end
	local out: { any } = {}
	for _, item in State.items(s) do
		table.insert(out, byKey[item.key])
	end
	return out
end

local function typeText(s: State, text: string): State
	local names = { "/" }
	for i = 1, #text do
		table.insert(names, string.sub(text, i, i))
	end
	table.insert(names, "enter")
	return (keys(s, names))
end

-- What a cluster answers for `get replicasets,pods,jobs`: the broken-image
-- Deployment's ReplicaSet and the Pod the capture's events are about, owned
-- by name (no uids), plus an unrelated pod.
local OWNED = [[{"apiVersion":"v1","kind":"List","items":[
{"apiVersion":"apps/v1","kind":"ReplicaSet","metadata":{"name":"broken-image-6869879767","namespace":"tern-test-apps",
 "ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"broken-image","controller":true}]}},
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"broken-image-6869879767-8fqd7","namespace":"tern-test-apps",
 "ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"broken-image-6869879767","controller":true}]}},
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"crashloop","namespace":"tern-test-apps"}}]}]]

local function withOwned(argv: { string }): (W.Result?, string?)
	if table.find(argv, "replicasets,pods,jobs") then
		return { status = 0, stdout = OWNED, stderr = "", timed_out = false }
	end
	return W.responder(argv)
end

local DEPLOY_LINK = { context = W.CTX, namespace = W.NS, kind = "Deployment", group = "apps", name = "broken-image" }

describe("explore events: namespace timeline", function()
	it("v reads get events -o json of the namespace in view, newest first", function()
		local s, trace = keys(open(), { "v" })
		expect(top(s).kind).toBe("events")
		expect(argvText(trace)).toEqual({
			"kubectl --kubeconfig /home/u/.kube/config --context kind-tern-kube-dev get events -n tern-test-apps -o json",
		})
		local events = eventsOf(s)
		expect(#events).toBe(5)
		expect(events[1].reason).toBe("BackOff")
		expect((events[1].object :: any).name).toBe("crashloop")
		expect(events[#events].reason).toBe("FailedScheduling")
		expect(Render.title(s)).toContain("Events ns tern-test-apps")
	end)

	it("x keeps Warning events only; ] [ step through Warnings from the top", function()
		local s = keys(open(), { "v" })
		local s1 = keys(s, { "]" })
		expect(((State.selectedItem(s1) :: State.Item).ref :: any).name).toBe("crashloop")
		local s2 = keys(s1, { "]" })
		expect(eventsOf(s2)[State.selectedIndex(s2, State.items(s2))].reason).toBe("Failed")
		s = keys(s, { "x" })
		expect(top(s).warnings).toBe(true)
		local events = eventsOf(s)
		expect(#events).toBe(3)
		for _, e in events do
			expect(e.type).toBe("Warning")
		end
		s = keys(s, { "x" })
		expect(#eventsOf(s)).toBe(5)
	end)

	it("/ filters by reason, object and message", function()
		local s = typeText(keys(open(), { "v" }), "crashloop")
		local events = eventsOf(s)
		expect(#events).toBe(2)
		for _, e in events do
			expect(e.object.name).toBe("crashloop")
		end
		s = typeText((State.update(s, { t = "action", act = "filter-clear" })), "scheduling")
		expect(#eventsOf(s)).toBe(1)
	end)

	-- Every object key (d y L R s l shift+f, mutations) acts on what the
	-- selected event is about.
	it("the focused object is the event's involved object; enter opens it", function()
		local s = typeText(keys(open(), { "v" }), "pending")
		local ref = State.focusRef(s) :: any
		expect(ref.kind).toBe("Pod")
		expect(ref.name).toBe("pending")
		expect(ref.namespace).toBe(W.NS)
		local d = keys(s, { "d" })
		expect(top(d).kind).toBe("describe")
		expect((top(d).ref :: any).name).toBe("pending")
		s = keys(s, { "enter" })
		expect(top(s).kind).toBe("detail")
		expect((top(s).ref :: any).name).toBe("pending")
	end)

	it("r is the only re-read", function()
		local s = keys(open(), { "v" })
		local _, idle = keys(s, { "j", "k", "x" })
		expect(#idle.runs).toBe(0)
		local _, again = keys(s, { "r" })
		expect(argvText(again)[1]).toContain("get events -n tern-test-apps -o json")
	end)
end)

describe("explore events: object scope", function()
	it("V on a Deployment includes the events of the ReplicaSets and Pods it owns", function()
		local s = open(DEPLOY_LINK, withOwned)
		expect(top(s).kind).toBe("detail")
		local trace
		s, trace = keys(s, { "V" }, withOwned)
		expect(top(s).kind).toBe("events")
		expect(State.related(top(s))).toBe(true)
		expect(argvText(trace)[2]).toContain("get replicasets,pods,jobs -n tern-test-apps -o json")
		local events = eventsOf(s)
		expect(#events).toBe(2)
		for _, e in events do
			expect(e.object.name).toBe("broken-image-6869879767-8fqd7")
		end
		expect(Render.title(s)).toContain("Events deployment/broken-image")
	end)

	it("without related events a Deployment shows only its own; Whole namespace widens the scope", function()
		local s = keys(open(DEPLOY_LINK, withOwned), { "V" }, withOwned)
		local s2, trace = W.settle(State.update(s, { t = "action", act = "events-related" }))
		expect(State.related(top(s2))).toBe(false)
		expect(#trace.runs).toBe(1)
		expect(#eventsOf(s2)).toBe(0)
		local s3 = W.settle(State.update(s, { t = "action", act = "events-scope" }))
		expect(top(s3).ref).toBeNil()
		expect(#eventsOf(s3)).toBe(5)
	end)

	-- The list capture is from another day of the cluster: its crashloop Pod
	-- has a new uid, and the events in the events capture belong to the old
	-- Pod of that name. Once the object (and so its uid) is known, they are
	-- not its events.
	it("a recreated object does not inherit the events of its namesake", function()
		local s = typeText(open(), "crashloop")
		local trace
		s, trace = keys(s, { "V" })
		expect(#trace.runs).toBe(1)
		expect(#eventsOf(s)).toBe(0)
	end)

	it("an unreadable ownership list still shows the object's own events, with a note", function()
		local function denied(argv: { string }): (W.Result?, string?)
			if table.find(argv, "replicasets,pods,jobs") then
				return W.fail(1, 'Error from server (Forbidden): pods is forbidden: User "u" cannot list pods')
			end
			return W.responder(argv)
		end
		local s = keys(open(DEPLOY_LINK, denied), { "V" }, denied)
		local load = State.currentLoad(s) :: State.Load
		expect(load.status).toBe("ok")
		expect((load.data :: State.EventsData).note :: string).toContain("could not be read")
	end)
end)

describe("explore events: links", function()
	it("route=events opens the namespace timeline; types=Warning starts with Warnings only", function()
		local s, trace = open({ context = W.CTX, namespace = W.NS, route = "events", types = "Warning" })
		expect(top(s).kind).toBe("events")
		expect(top(s).ref).toBeNil()
		expect(top(s).warnings).toBe(true)
		expect(argvText(trace)[2]).toContain("get events -n tern-test-apps -o json")
		expect(#eventsOf(s)).toBe(3)
	end)

	it("namespace=* reads every namespace", function()
		local s, trace = open({ context = W.CTX, namespace = "*", route = "events" })
		expect(s.target.allNamespaces).toBe(true)
		expect(argvText(trace)[2]).toContain("get events -A -o json")
		expect(Render.title(s)).toContain("Events all namespaces")
	end)

	-- The palette command opens Explore with only a cwd and the route.
	it("route=events without a namespace follows the context's default namespace", function()
		local s, trace = open({ route = "events" })
		expect(top(s).kind).toBe("events")
		local argv = argvText(trace)
		expect(argv[#argv]).toContain("get events -o json")
	end)

	it("an object link scopes the timeline to the object", function()
		local s, trace = open({
			context = W.CTX,
			namespace = W.NS,
			kind = "Pod",
			name = "crashloop",
			route = "events",
		})
		local kinds: { string } = {}
		for _, r in s.stack do
			table.insert(kinds, r.kind)
		end
		expect(kinds).toEqual({ "list", "detail", "events" })
		expect(#trace.runs).toBe(2)
		expect(#eventsOf(s)).toBe(2)
	end)

	it("an events route survives save and restore", function()
		local s = keys(open(), { "v", "x" })
		local again = State.init({}, State.save(s), W.config(nil), W.env())
		local r = again.stack[#again.stack]
		expect(r.kind).toBe("events")
		expect(r.warnings).toBe(true)
	end)
end)

return nil
