--!strict
-- What the lens and Explore show of a store: filtered pages (newest first by
-- default), the context window of a jump, next/prev error, and the merge by
-- kubelet time of `--timestamps --prefix` runs.
local t = require("../../lib/test")
local json = require("../../lib/json")
local Query = require("../../../plugin/lib/logs/query")
local Store = require("../../../plugin/lib/logs/store")
local describe, it, expect = t.describe, t.it, t.expect

local function build(lines: { string }, prefix: boolean?, timestamps: boolean?): Store.Store
	local s = Store.new(
		{ prefix = prefix == true, timestamps = timestamps == true, follow = false, decode = json.decode },
		{ maxLines = 100000, maxBytes = 1e9 }
	)
	for _, l in lines do
		Store.push(s, l)
	end
	Store.finish(s, 0)
	return s
end

local ALL: Query.Filter = { merge = false }

local MIXED = build({
	"[pod/a/app] INFO one",
	"[pod/a/app] ERROR two",
	"[pod/b/app] WARN three",
	"[pod/b/app] DEBUG four",
	"[pod/a/app] FATAL five",
	'[pod/b/app] {"level":"error","msg":"six","path":"/Checkout"}',
}, true)

describe("logs query: apply", function()
	it("shows the newest page by default because the end of a log is what users read first", function()
		local s = build({ "1", "2", "3", "4", "5" })
		local w = Query.apply(s, ALL, nil, 2)
		expect(w.indices).toEqual({ 5 })
		expect(w.page).toBe(3)
		expect(w.pages).toBe(3)
		expect(w.matched).toBe(5)
		expect(Query.apply(s, ALL, 1, 2).indices).toEqual({ 1, 2 })
	end)

	it("clamps out-of-range pages so a stale action value still renders", function()
		local s = build({ "1", "2", "3" })
		expect(Query.apply(s, ALL, 99, 2).page).toBe(2)
		expect(Query.apply(s, ALL, 0, 2).page).toBe(1)
	end)

	it("returns one empty page when nothing matches", function()
		local w = Query.apply(MIXED, { merge = false, text = "nothing-like-this" }, nil, 10)
		expect(w.indices).toEqual({})
		expect(w.matched).toBe(0)
		expect(w.pages).toBe(1)
	end)

	it("filters by a level set (the level chips)", function()
		local w = Query.apply(MIXED, { merge = false, levels = { error = true, fatal = true } }, nil, 10)
		expect(w.indices).toEqual({ 2, 5, 6 })
	end)

	it("filters by a level floor (Explore's `x`)", function()
		local w = Query.apply(MIXED, { merge = false, minLevel = "warn" }, nil, 10)
		expect(w.indices).toEqual({ 2, 3, 5, 6 })
	end)

	it("filters by source set (the pod/container chips)", function()
		local w = Query.apply(MIXED, { merge = false, sources = { [2] = true } }, nil, 10)
		expect(w.indices).toEqual({ 3, 4, 6 })
	end)

	it("searches message, fields and source case-insensitively as plain text", function()
		expect(Query.apply(MIXED, { merge = false, text = "THREE" }, nil, 10).indices).toEqual({ 3 })
		expect(Query.apply(MIXED, { merge = false, text = "/checkout" }, nil, 10).indices).toEqual({ 6 })
		expect(#Query.apply(MIXED, { merge = false, text = "b" }, nil, 10).indices).toBe(3)
		expect(Query.apply(MIXED, { merge = false, text = "(" }, nil, 10).matched).toBe(0)
	end)

	it("only searches kept records: evicted ones are only in Raw", function()
		local s = Store.new(
			{ prefix = false, timestamps = false, follow = false, decode = json.decode },
			{ maxLines = 2, maxBytes = 1e9 }
		)
		for _, l in { "ERROR old", "INFO a", "INFO b" } do
			Store.push(s, l)
		end
		expect(Query.apply(s, { merge = false, levels = { error = true } }, nil, 10).matched).toBe(0)
	end)
end)

describe("logs query: merge by time", function()
	local LINES = {
		"[pod/a/app] 2026-11-02T10:00:01.5Z A1",
		"[pod/a/app] 2026-11-02T10:00:03Z A2",
		"[pod/b/app] 2026-11-02T10:00:02.000000001Z B1",
		"[pod/b/app] 2026-11-02T10:00:03Z B2",
		"[pod/b/app] 2026-11-02T10:00:04.25Z B3",
	}

	it("interleaves sources by kubelet time, stable on equal times", function()
		local s = build(LINES, true, true)
		local w = Query.apply(s, { merge = true }, nil, 10)
		expect(w.indices).toEqual({ 1, 3, 2, 4, 5 })
	end)

	it("compares trimmed nanosecond fractions numerically, not lexically", function()
		expect(Query.sortKey("2026-11-02T10:00:01.5Z")).toBe("2026-11-02T10:00:01.500000000Z")
		expect(Query.sortKey("2026-11-02T10:00:01Z") < Query.sortKey("2026-11-02T10:00:01.000000001Z")).toBe(true)
	end)

	it("normalises offsets to UTC so mixed zones order correctly", function()
		expect(Query.sortKey("2026-11-02T01:30:00+02:00")).toBe("2026-11-01T23:30:00.000000000Z")
		expect(Query.sortKey("2024-02-28T23:00:00.1-01:30")).toBe("2024-02-29T00:30:00.100000000Z")
	end)

	it("keeps arrival order without --timestamps because there is nothing to merge by", function()
		local s = build({ "[pod/b/app] x", "[pod/a/app] y" }, true, false)
		expect(Query.apply(s, { merge = true }, nil, 10).indices).toEqual({ 1, 2 })
	end)

	it("pages the merged order", function()
		local s = build(LINES, true, true)
		expect(Query.apply(s, { merge = true }, 1, 2).indices).toEqual({ 1, 3 })
	end)
end)

describe("logs query: context and jumps", function()
	it("context is the unfiltered window around the record, clipped to kept records", function()
		local s = build({ "1", "2", "3", "4", "5", "6" })
		expect(Query.context(s, 3, 1).indices).toEqual({ 2, 3, 4 })
		expect(Query.context(s, 1, 2).indices).toEqual({ 1, 2, 3 })
		expect(Query.context(s, 6, 20).indices).toEqual({ 1, 2, 3, 4, 5, 6 })
	end)

	it("next/prev error walk records at or above the floor and stop at the ends", function()
		expect(Query.next(MIXED, ALL, 0, 1, "error")).toBe(2)
		expect(Query.next(MIXED, ALL, 2, 1, "error")).toBe(5)
		expect(Query.next(MIXED, ALL, 6, 1, "error")).toBeNil()
		expect(Query.next(MIXED, ALL, 5, -1, "error")).toBe(2)
		expect(Query.next(MIXED, ALL, 2, -1, "error")).toBeNil()
		expect(Query.next(MIXED, ALL, 99, -1, "warn")).toBe(6)
	end)

	it("next honours the active filter so jumps stay inside what is shown", function()
		local f: Query.Filter = { merge = false, sources = { [2] = true } }
		expect(Query.next(MIXED, f, 0, 1, "error")).toBe(6)
	end)
end)

return nil
