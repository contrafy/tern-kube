--!strict
-- The store is built line by line while kubectl runs and rebuilt from the
-- same lines after a reload, so these specs pin the ring, attribution,
-- grouping and the kubectl-line handling a lens relies on.
local t = require("../../lib/test")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local synth = require("../../../scripts/fixtures/synth")
local Store = require("../../../plugin/lib/logs/store")
local T = require("../../../plugin/lib/logs/types")
local describe, it, expect = t.describe, t.it, t.expect

local BIG: T.Limits = { maxLines = 100000, maxBytes = 1e9 }

local function options(over: { [string]: any }?): T.Options
	local o: any = { prefix = false, timestamps = false, follow = false, decode = json.decode }
	if over then
		for k, v in pairs(over) do
			o[k] = v
		end
	end
	return o
end

local function count(s: Store.Store, level: T.Level): number
	return s.counts[level]
end

local function build(lines: { string }, over: { [string]: any }?, limits: T.Limits?, status: number?): Store.Store
	local s = Store.new(options(over), limits or BIG)
	for _, l in lines do
		Store.push(s, l)
	end
	if status then
		Store.finish(s, status)
	end
	return s
end

local function messages(s: Store.Store): { string }
	local out: { string } = {}
	for i = s.first, s.last do
		table.insert(out, s.records[i].message)
	end
	return out
end

local function kinds(s: Store.Store): { string }
	local out: { string } = {}
	for _, n in s.notices do
		table.insert(out, n.kind)
	end
	return out
end

describe("logs store: records", function()
	it("numbers records by arrival so action values can name them", function()
		local s = build({ "a", "b", "c" })
		expect(Store.size(s)).toBe(3)
		expect((Store.get(s, 2) :: T.Record).message).toBe("b")
		expect(Store.get(s, 4)).toBeNil()
	end)

	it("strips a trailing CR but keeps the delivered line for Copy line", function()
		local s = build({ "WARN x\r" })
		expect((Store.get(s, 1) :: T.Record).raw).toBe("WARN x")
	end)

	it("counts levels and remembers the first error for the jump chip", function()
		local s = build({ "INFO a", "WARN b", "ERROR c", "ERROR d" })
		expect(count(s, "info")).toBe(1)
		expect(count(s, "warn")).toBe(1)
		expect(count(s, "error")).toBe(2)
		expect(s.firstError).toBe(3)
	end)

	it("rehydration: the same lines give the same indices and records", function()
		local lines = { "INFO a", "\tat x", '{"level":"error","msg":"m"}', "WARN b" }
		local a = build(lines, nil, nil, 0)
		local b = build(lines, nil, nil, 0)
		expect(b.records).toEqual(a.records)
		expect(b.first).toBe(a.first)
		expect(b.last).toBe(a.last)
	end)
end)

describe("logs store: ring", function()
	it("keeps the newest maxLines records and counts the dropped ones", function()
		local s = build({ "1", "2", "3", "4", "5" }, nil, { maxLines = 3, maxBytes = 1e9 })
		expect(messages(s)).toEqual({ "3", "4", "5" })
		expect(s.dropped).toBe(2)
		expect(Store.get(s, 1)).toBeNil()
		expect((Store.get(s, 5) :: T.Record).index).toBe(5)
		expect(kinds(s)).toEqual({ "dropped" })
		expect(s.notices[1].text).toBe("2 earlier lines only in Raw")
	end)

	it("keeps totals in counts while filters see only kept records", function()
		local s = build({ "ERROR 1", "INFO 2", "INFO 3" }, nil, { maxLines = 2, maxBytes = 1e9 })
		expect(count(s, "error")).toBe(1)
		expect(count(s, "info")).toBe(2)
	end)

	it("caps kept bytes so a few huge lines cannot exhaust memory", function()
		local s = build({ string.rep("a", 40), string.rep("b", 40), string.rep("c", 40) }, nil, {
			maxLines = 100,
			maxBytes = 100,
		})
		expect(Store.size(s)).toBe(2)
		expect(s.bytes).toBe(80)
		expect(s.dropped).toBe(1)
	end)

	it("always keeps the newest record even when it alone exceeds the byte cap", function()
		local s = build({ "x", string.rep("y", 500) }, nil, { maxLines = 100, maxBytes = 100 })
		expect(Store.size(s)).toBe(1)
		expect(s.records[s.last].raw).toBe(string.rep("y", 500))
	end)

	it("moves firstError to the next kept error when the first one is evicted", function()
		local s = build({ "ERROR a", "INFO b", "ERROR c", "INFO d" }, nil, { maxLines = 3, maxBytes = 1e9 })
		expect(s.firstError).toBe(3)
		local none = build({ "ERROR a", "INFO b", "INFO c" }, nil, { maxLines = 2, maxBytes = 1e9 })
		expect(none.firstError).toBeNil()
	end)
end)

describe("logs store: continuation", function()
	it("groups a Java stack as one record `+2 lines` that keeps the exception's level", function()
		local s = build({
			"2026-10-30 10:00:05,123 ERROR [main] java.lang.IllegalStateException: bad",
			"\tat com.example.Main.run(Main.java:10)",
			"\tat com.example.Main.main(Main.java:3)",
			"INFO next",
		})
		expect(Store.size(s)).toBe(2)
		local r = Store.get(s, 1) :: T.Record
		expect(r.level).toBe("error")
		expect(r.extra).toEqual({ "\tat com.example.Main.run(Main.java:10)", "\tat com.example.Main.main(Main.java:3)" })
	end)

	it("attaches continuations to the previous record of the same source across interleaved prefixes", function()
		local s = build({
			"[pod/p1/app] java.lang.RuntimeException: x",
			"[pod/p2/app] INFO other pod",
			"[pod/p1/app] \tat A.b(A.java:1)",
			"[pod/p2/app] \tat C.d(C.java:2)",
		}, { prefix = true })
		expect(Store.size(s)).toBe(2)
		expect((Store.get(s, 1) :: T.Record).extra).toEqual({ "\tat A.b(A.java:1)" })
		expect((Store.get(s, 2) :: T.Record).extra).toEqual({ "\tat C.d(C.java:2)" })
	end)

	it("joins indented lines only right after a line of the same source", function()
		local s = build({
			"Traceback (most recent call last):",
			'  File "/app/m.py", line 3, in <module>',
			"    raise ValueError('boom')",
			"ValueError: boom",
			"INFO later",
			"    indented after another line",
		})
		expect(messages(s)).toEqual({
			"Traceback (most recent call last):",
			"ValueError: boom",
			"INFO later",
		})
		expect(#((Store.get(s, 1) :: T.Record).extra :: { string })).toBe(2)
		expect((Store.get(s, 3) :: T.Record).extra).toEqual({ "    indented after another line" })
	end)

	it("starts a record when the continuation has no record to join", function()
		local s = build({ "\tat orphan" })
		expect(Store.size(s)).toBe(1)
	end)

	it("caps continuation lines at 200 and counts the rest", function()
		local lines = { "java.lang.Error: deep" }
		for i = 1, 250 do
			table.insert(lines, "\tat f" .. i)
		end
		local s = build(lines)
		local r = Store.get(s, 1) :: T.Record
		expect(#(r.extra :: { string })).toBe(200)
		expect(r.more).toBe(50)
	end)
end)

describe("logs store: sources", function()
	it("creates one source per prefixed pod/container with counts", function()
		local s = build({ "[pod/a/app] x", "[pod/b/app] y", "[pod/a/side] z", "[pod/a/app] w" }, { prefix = true })
		expect(s.sources).toEqual({
			{ pod = "a", container = "app" },
			{ pod = "b", container = "app" },
			{ pod = "a", container = "side" },
		})
		expect(s.sourceCounts[1]).toBe(2)
		expect(s.sourceCounts[2]).toBe(1)
	end)

	it("attributes unprefixed lines to the pod and -c container of the invocation", function()
		local s = build({ "x" }, { pod = "web-1", container = "app" })
		expect(s.sources).toEqual({ { pod = "web-1", container = "app" } })
		expect((Store.get(s, 1) :: T.Record).source).toBe(1)
	end)

	it("learns pod and container from Found/Defaulted for `logs deploy/x`", function()
		local s = build({
			"Found 2 pods, using pod/web-1",
			'Defaulted container "app" out of: app, side',
			"x",
		})
		expect(s.sources).toEqual({ { pod = "web-1", container = "app" } })
		expect((Store.get(s, 1) :: T.Record).source).toBe(1)
	end)

	it("leaves `-l` output without --prefix unattributed: pods are sequential blocks", function()
		local s = build({ 'Defaulted container "app" out of: app, side', "x" }, { multiPod = true })
		expect(#s.sources).toBe(0)
		expect((Store.get(s, 1) :: T.Record).source).toBe(0)
	end)
end)

describe("logs store: kubectl lines", function()
	it("diagnostics only as notices, deduplicated, at any position", function()
		local s = build({
			'Defaulted container "app" out of: app, side, crashy',
			"x",
			'Defaulted container "app" out of: app, side, crashy',
			"y",
		}, { multiPod = true }, nil, 0)
		expect(messages(s)).toEqual({ "x", "y" })
		expect(kinds(s)).toEqual({ "defaulted-container" })
	end)

	it("turns `unable to retrieve container logs` into an error notice even with exit 0", function()
		local s = build({ "unable to retrieve container logs for containerd://abc" }, nil, nil, 0)
		expect(Store.size(s)).toBe(0)
		expect(kinds(s)).toEqual({ "error" })
	end)

	it("status 1 with a trailing kubectl error: the error is a notice, not a record", function()
		local s = build({ 'error: error from server (NotFound): pods "nopod" not found in namespace "x"' }, nil, nil, 1)
		expect(Store.size(s)).toBe(0)
		expect(count(s, "error")).toBe(0)
		expect(s.firstError).toBeNil()
		expect(kinds(s)).toEqual({ "error" })
		expect(s.stopped).toBe(false)
	end)

	it("status 0 keeps a program line that starts with `error: `", function()
		local s = build({ "error: from the app" }, nil, nil, 0)
		expect(Store.size(s)).toBe(1)
		expect(#s.notices).toBe(0)
	end)

	it("^C% after a follow with status 1 means stopped by you, not a failure", function()
		local s = build({ "INFO a", "WARN b", "^C%" }, { follow = true }, nil, 1)
		expect(messages(s)).toEqual({ "INFO a", "WARN b" })
		expect(s.stopped).toBe(true)
		expect(kinds(s)).toEqual({ "interrupted" })
		expect(count(s, "none")).toBe(0)
	end)

	it("drops a lone `%` final line (partial last line) without any notice", function()
		local s = build({ "INFO a", "partial", "%" }, nil, nil, 0)
		expect(messages(s)).toEqual({ "INFO a", "partial" })
		expect(#s.notices).toBe(0)
		expect(s.stopped).toBe(false)
	end)

	it("keeps trailing kubectl errors in their order when several close a failed run", function()
		local s = build({ "INFO a", "Warning: w", "error: e" }, nil, nil, 1)
		expect(messages(s)).toEqual({ "INFO a" })
		expect(kinds(s)).toEqual({ "warning", "error" })
	end)
end)

describe("logs store: synthetic mix", function()
	it("the generator is deterministic: it reproduces the embedded samples byte for byte", function()
		expect(table.concat(synth.logLines(200, 20261102, false), "\n") .. "\n").toBe(
			fixtures.read("logs/mixed-200.txt")
		)
		expect(table.concat(synth.logLines(200, 20261102, true), "\n") .. "\n").toBe(
			fixtures.read("logs/prefixed-200.txt")
		)
	end)

	it("20 000 prefixed lines: every record attributed, stacks grouped, JSON errors are errors", function()
		local lines = synth.logLines(20000, 7, true)
		local s = build(lines, { prefix = true, timestamps = true }, nil, 0)
		expect(#s.sources).toBe(6)
		local extras = 0
		for i = s.first, s.last do
			local r = s.records[i]
			extras += #(r.extra or {})
			expect(r.source ~= 0 and r.ts ~= nil).toBe(true)
			if string.find(r.raw, '"level":"error"', 1, true) then
				expect(r.level).toBe("error")
			end
			if string.find(r.message, "^Traceback") then
				expect(#(r.extra or {})).toBe(2)
			end
		end
		expect(Store.size(s) + extras).toBe(20000)
		expect(count(s, "error") > 1000).toBe(true)
	end)
end)

return nil
