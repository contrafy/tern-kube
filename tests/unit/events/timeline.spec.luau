--!strict
-- The Explore timeline promises "newest first", time buckets, a Warning
-- filter and object scopes that follow ownership. All of it must be pure and
-- time-zone free (lenses run in the user's zone, CI in UTC), so `now` is
-- always passed in and every time is parsed without os.time.
local Model = require("../../../plugin/lib/events/model")
local Timeline = require("../../../plugin/lib/events/timeline")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Event = Model.Event

local function ev(key: string, last: string?, opts: { [string]: any }?): Event
	local o: { [string]: any } = opts or {}
	return {
		key = key,
		type = o.type or "Normal",
		reason = o.reason or "Pulled",
		message = o.message or "",
		object = o.object,
		count = 1,
		first = o.first,
		last = last,
		namespace = "ns",
		series = false,
	}
end

local function keys(events: { Event }): { string }
	local out: { string } = {}
	for _, e in events do
		table.insert(out, e.key)
	end
	return out
end

local function pod(name: string, uid: string?): any
	return { kind = "Pod", name = name, namespace = "ns", uid = uid, source = "live" }
end

describe("timeline parseTime", function()
	it("returns epoch seconds for UTC times without consulting the local zone", function()
		expect(Timeline.parseTime("1970-01-01T00:00:00Z")).toBe(0)
		expect(Timeline.parseTime("2026-11-02T16:14:08Z")).toBe(1793636048)
		expect(Timeline.parseTime("2000-02-29T12:00:00Z")).toBe(951825600)
	end)

	it("keeps fractional seconds so series events order within the same second", function()
		expect(Timeline.parseTime("2026-11-02T16:14:08.5Z")).toBe(1793636048.5)
		local micro = Timeline.parseTime("2026-11-02T16:14:08.090640Z") :: number
		expect(math.abs(micro - 1793636048.09064) < 1e-6).toBe(true)
		expect(micro > (Timeline.parseTime("2026-11-02T16:14:08.09Z") :: number)).toBe(true)
	end)

	it("applies numeric offsets, so +02:00 and Z spellings of one instant are equal", function()
		expect(Timeline.parseTime("2026-11-02T18:14:08+02:00")).toBe(1793636048)
		expect(Timeline.parseTime("2026-11-02T13:44:08-02:30")).toBe(1793636048)
	end)

	it("rejects malformed input instead of guessing a time", function()
		for _, s in
			{
				"",
				"2026-11-02",
				"2026-11-02T16:14:08",
				"2026-13-02T16:14:08Z",
				"2026-02-30T16:14:08Z",
				"2025-02-29T00:00:00Z",
				"2026-11-02T24:00:00Z",
				"2026-11-02T16:14:08.Z",
				"2026-11-02T16:14:08+2:00",
				"<unknown>",
			}
		do
			expect(s .. "=" .. tostring(Timeline.parseTime(s))).toBe(s .. "=nil")
		end
	end)
end)

describe("timeline sort", function()
	it("orders newest first by last seen, because kubectl events prints oldest first", function()
		local events = {
			ev("a", "2026-11-02T10:00:00Z"),
			ev("b", "2026-11-02T12:00:00Z"),
			ev("c", "2026-11-02T11:00:00+02:00"),
		}
		expect(keys(Timeline.sort(events))).toEqual({ "b", "a", "c" })
		expect(keys(events)).toEqual({ "a", "b", "c" })
	end)

	it("falls back to first, breaks ties by key and puts timeless events last in input order", function()
		local events = {
			ev("none-1", nil),
			ev("z", "2026-11-02T10:00:00Z"),
			ev("first-only", nil, { first = "2026-11-02T11:00:00Z" }),
			ev("none-2", "garbage"),
			ev("m", "2026-11-02T10:00:00Z"),
		}
		expect(keys(Timeline.sort(events))).toEqual({ "first-only", "m", "z", "none-1", "none-2" })
	end)

	it("sorts the real namespace EventList with every event dated", function()
		local events = Model.fromList(json.decode(fixtures.read("real/ns-apps/get_events_-o_json.txt")))
		local sorted = Timeline.sort(events)
		expect(#sorted).toBe(#events)
		for i = 2, #sorted do
			local prev = Timeline.parseTime(sorted[i - 1].last :: string) :: number
			local cur = Timeline.parseTime(sorted[i].last :: string) :: number
			expect(prev >= cur).toBe(true)
		end
	end)
end)

describe("timeline filter", function()
	local crash = pod("crashloop", "u1")
	local web = pod("web-1")
	local events = {
		ev("w1", nil, { type = "Warning", reason = "BackOff", object = crash, message = "Back-off restarting" }),
		ev("n1", nil, { reason = "Pulled", object = web, message = "Container image present" }),
		ev("w2", nil, { type = "Warning", reason = "FailedScheduling", object = web }),
		ev("orphan", nil, { type = "Warning", reason = "Odd" }),
	}

	it("keeps only Warning events for the `x` toggle", function()
		expect(keys(Timeline.filter(events, { warnings = true }))).toEqual({ "w1", "w2", "orphan" })
	end)

	it("matches text case-insensitively over reason, Kind/name and message", function()
		expect(keys(Timeline.filter(events, { warnings = false, text = "backoff" }))).toEqual({ "w1" })
		expect(keys(Timeline.filter(events, { warnings = false, text = "POD/WEB" }))).toEqual({ "n1", "w2" })
		expect(keys(Timeline.filter(events, { warnings = false, text = "image present" }))).toEqual({ "n1" })
		expect(keys(Timeline.filter(events, { warnings = false, text = "" }))).toEqual({ "w1", "n1", "w2", "orphan" })
	end)

	it("treats search text literally, so regex characters in a filter cannot break it", function()
		expect(#Timeline.filter(events, { warnings = false, text = "(x" })).toBe(0)
	end)

	it("scopes by uid when both sides have one, so a recreated pod with the same name is excluded", function()
		local recreated = pod("crashloop", "u2")
		expect(#Timeline.filter(events, { warnings = false, scope = { recreated } })).toBe(0)
		expect(keys(Timeline.filter(events, { warnings = false, scope = { pod("crashloop", "u1") } }))).toEqual({
			"w1",
		})
	end)

	it("scopes by kind, name and namespace when a uid is missing, as for table rows", function()
		local scoped = Timeline.filter(events, { warnings = false, scope = { pod("web-1", "uid-x") } })
		expect(keys(scoped)).toEqual({ "n1", "w2" })
		local otherNs = { kind = "Pod", name = "web-1", namespace = "other", source = "live" } :: any
		expect(#Timeline.filter(events, { warnings = false, scope = { otherNs } })).toBe(0)
	end)

	it("combines warnings, text and scope, and an empty scope matches nothing", function()
		expect(keys(Timeline.filter(events, { warnings = true, text = "failed", scope = { web } }))).toEqual({ "w2" })
		expect(#Timeline.filter(events, { warnings = false, scope = {} })).toBe(0)
	end)
end)

describe("timeline groups", function()
	local now = Timeline.parseTime("2026-11-02T12:00:00Z") :: number

	it("buckets against the given now and keeps input order inside buckets", function()
		local events = {
			ev("future", "2026-11-02T12:00:30Z"),
			ev("1m", "2026-11-02T11:59:00Z", { type = "Warning" }),
			ev("4m59", "2026-11-02T11:55:01Z"),
			ev("5m", "2026-11-02T11:55:00Z", { type = "Warning" }),
			ev("59m", "2026-11-02T11:01:00Z"),
			ev("2h", "2026-11-02T10:00:00Z", { type = "Warning" }),
			ev("yesterday-evening", "2026-11-01T18:00:00Z"),
			ev("25h", "2026-11-01T11:00:00Z", { type = "Warning" }),
			ev("undated", nil, { type = "Warning" }),
		}
		local groups = Timeline.groups(events, now)
		local shape = {}
		for _, g in groups do
			table.insert(shape, { label = g.label, keys = keys(g.events), warnings = g.warnings })
		end
		expect(shape).toEqual({
			{ label = "last 5 minutes", keys = { "future", "1m", "4m59" }, warnings = 1 },
			{ label = "last hour", keys = { "5m", "59m" }, warnings = 1 },
			{ label = "today", keys = { "2h", "yesterday-evening" }, warnings = 1 },
			{ label = "earlier", keys = { "25h", "undated" }, warnings = 2 },
		})
	end)

	it("treats today as the rolling last 24 hours, because a pure module cannot know the user's zone", function()
		local groups = Timeline.groups({ ev("just-after-utc-midnight-minus", "2026-11-01T12:00:01Z") }, now)
		expect(groups[1].label).toBe("today")
		groups = Timeline.groups({ ev("exactly-24h", "2026-11-01T12:00:00Z") }, now)
		expect(groups[1].label).toBe("earlier")
	end)

	it("omits empty buckets so the timeline shows no bare separators", function()
		local groups = Timeline.groups({ ev("old", "2026-10-01T00:00:00Z") }, now)
		expect(#groups).toBe(1)
		expect(groups[1].label).toBe("earlier")
		expect(#Timeline.groups({}, now)).toBe(0)
	end)
end)

describe("timeline owned", function()
	local function world(path: string): { any }
		return json.decode(fixtures.read("real/json-world/ns-apps/" .. path)).items
	end

	local function names(refs: { any }): { string }
		local out: { string } = {}
		for _, r in refs do
			table.insert(out, r.kind .. "/" .. r.name)
		end
		return out
	end

	it("walks Deployment -> ReplicaSet -> Pods in the captured world, scope first", function()
		local objects = {}
		for _, path in { "get_pods_-o_json.txt", "get_replicasets_-o_json.txt" } do
			for _, o in world(path) do
				table.insert(objects, o)
			end
		end
		local scope =
			{ kind = "Deployment", group = "apps", name = "web", namespace = "tern-test-apps", source = "live" }
		expect(names(Timeline.owned(scope :: any, objects))).toEqual({
			"Deployment/web",
			"ReplicaSet/web-65d7d99975",
			"Pod/web-65d7d99975-bmgbn",
			"Pod/web-65d7d99975-zsb95",
		})
	end)

	it("matches owners by uid when the scope has one, so a same-named stale owner is ignored", function()
		local objects = world("get_replicasets_-o_json.txt")
		local stale =
			{ kind = "Deployment", name = "web", namespace = "tern-test-apps", uid = "not-the-uid", source = "live" }
		expect(names(Timeline.owned(stale :: any, objects))).toEqual({ "Deployment/web" })
		local real = table.clone(stale)
		real.uid = "8352ff74-5659-43df-987c-45ef74621d25"
		expect(names(Timeline.owned(real :: any, objects))).toEqual({ "Deployment/web", "ReplicaSet/web-65d7d99975" })
	end)

	local function obj(kind: string, name: string, uid: string, owner: { string }?): any
		local metadata: any = { name = name, namespace = "ns", uid = uid }
		if owner then
			metadata.ownerReferences = { { kind = owner[1], name = owner[2], uid = owner[3] } }
		end
		return { kind = kind, apiVersion = if kind == "Pod" then "v1" else "batch/v1", metadata = metadata }
	end

	it("walks CronJob -> Jobs -> Pods and stays inside the namespace", function()
		local objects = {
			obj("Pod", "nightly-1-abc", "p1", { "Job", "nightly-1", "j1" }),
			obj("Job", "nightly-1", "j1", { "CronJob", "nightly", "c1" }),
			obj("Job", "manual", "j2"),
			obj("Pod", "manual-x", "p2", { "Job", "manual", "j2" }),
		}
		local elsewhere = obj("Job", "nightly-2", "j3", { "CronJob", "nightly", "c9" })
		elsewhere.metadata.namespace = "other"
		table.insert(objects, elsewhere)
		local scope = { kind = "CronJob", group = "batch", name = "nightly", namespace = "ns", source = "live" }
		expect(names(Timeline.owned(scope :: any, objects))).toEqual({
			"CronJob/nightly",
			"Job/nightly-1",
			"Pod/nightly-1-abc",
		})
	end)

	it("terminates on ownership cycles and lists each object once", function()
		local objects = {
			obj("Job", "a", "ua", { "Job", "b", "ub" }),
			obj("Job", "b", "ub", { "Job", "a", "ua" }),
			"not an object",
		}
		local scope = { kind = "Job", group = "batch", name = "a", namespace = "ns", uid = "ua", source = "live" }
		expect(names(Timeline.owned(scope :: any, objects))).toEqual({ "Job/a", "Job/b" })
	end)

	it("feeds filter so an object scope includes its pods' events (Explore `V` on a Deployment)", function()
		local scope = { kind = "Deployment", group = "apps", name = "web", namespace = "ns", source = "live" }
		local objects = {
			obj("ReplicaSet", "web-1", "rs1", { "Deployment", "web", "d1" }),
			obj("Pod", "web-1-a", "pa", { "ReplicaSet", "web-1", "rs1" }),
		}
		local events = {
			ev("pod-event", nil, { object = pod("web-1-a", "pa") }),
			ev("other", nil, { object = pod("db-0") }),
		}
		local scoped = Timeline.filter(events, { warnings = false, scope = Timeline.owned(scope :: any, objects) })
		expect(keys(scoped)).toEqual({ "pod-event" })
	end)
end)

return nil
