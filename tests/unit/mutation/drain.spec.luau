--!strict
-- drain has no -o: the preview of which pods leave the node, which pods
-- kubectl refuses to touch and which a PodDisruptionBudget blocks comes only
-- from these texts (recorded from kind). Pod names with hashes differ per
-- capture, so assertions use the stable names (bare, ed, db-0) and shapes.
local Drain = require("../../../plugin/lib/mutation/drain")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NODE = "tern-kube-dev-control-plane"
local NS = "tern-test-t1"

local function read(path: string): string
	local full = "kubectl/track1/" .. path
	return if fixtures.has(full) then fixtures.read(full) else ""
end

local function parse(name: string): Drain.Facts
	return Drain.parse(read(name .. ".txt"), read(name .. ".stderr"))
end

local function names(refs: { Drain.PodRef }): { string }
	local out = {}
	for _, r in refs do
		expect(r.namespace).toBe(NS)
		table.insert(out, r.name)
	end
	return out
end

local function matching(list: { string }, pattern: string): number
	local n = 0
	for _, s in list do
		if string.match(s, pattern) then
			n += 1
		end
	end
	return n
end

describe("mutation.drain parse", function()
	it("reads the sorted eviction list and warnings of a client dry run", function()
		local f = parse("drain-client-ok")
		expect(f.nodes).toEqual({ NODE })
		local evicted = names(f.evictions)
		expect(#evicted).toBe(6)
		expect(evicted[1]).toBe("bare")
		expect(evicted[2]).toBe("db-0")
		expect(evicted[3]).toBe("ed")
		expect(matching(evicted, "^web%-")).toBe(2)
		expect(names(f.unmanaged)).toEqual({ "bare", "ed" })
		expect(matching(names(f.daemonSetIgnored), "^ds%-")).toBe(1)
		expect(f.preflight).toEqual({})
		expect(f.pdbBlocked).toEqual({})
		expect(f.timedOut).toBe(false)
	end)

	-- kubectl lists every cause inside the aggregated error and again one
	-- per line (with its "cannot delete cannot delete" typo); each category
	-- must come out once with the flag that overrides it.
	it("reads pre-flight refusals with their override flag", function()
		for _, name in { "drain-client-preflight", "drain-server-preflight" } do
			local f = parse(name)
			expect(f.evictions).toEqual({})
			local byCategory: { [string]: Drain.Preflight } = {}
			for _, p in f.preflight do
				expect(byCategory[p.category]).toBeNil()
				byCategory[p.category] = p
			end
			expect(#f.preflight).toBe(3)
			expect(byCategory.unmanaged.flag).toBe("--force")
			expect(names(byCategory.unmanaged.pods)).toEqual({ "bare" })
			expect(byCategory["local-storage"].flag).toBe("--delete-emptydir-data")
			expect(names(byCategory["local-storage"].pods)).toEqual({ "ed" })
			expect(byCategory.daemonset.flag).toBe("--ignore-daemonsets")
			expect(matching(names(byCategory.daemonset.pods), "^ds%-")).toBe(1)
		end
	end)

	-- The server dry run retries blocked pods every 5 s and prints them
	-- again each time; each pod must count once.
	it("reads PodDisruptionBudget refusals and the timeout of a server dry run", function()
		local f = parse("drain-server-pdb-timeout")
		local blocked = names(f.pdbBlocked)
		expect(#blocked).toBe(2)
		expect(matching(blocked, "^web%-")).toBe(2)
		expect(#f.evictions).toBe(6)
		expect(f.timedOut).toBe(true)
		expect(f.preflight).toEqual({})
	end)

	it("reads a clean server dry run", function()
		local f = parse("drain-server-ok")
		expect(#f.evictions).toBe(4)
		expect(f.pdbBlocked).toEqual({})
		expect(f.timedOut).toBe(false)
		expect(parse("drain-server-nopods").nodes).toEqual({ NODE })
	end)

	it("treats a --disable-eviction deadline as a timeout", function()
		local f = parse("drain-server-disable-eviction")
		expect(f.timedOut).toBe(true)
		expect(f.pdbBlocked).toEqual({})
		expect(names(f.unmanaged)).toEqual({ "bare", "ed" })
	end)

	it("reads a single cause that ends in 'continuing command...'", function()
		local f = Drain.parse(
			"",
			'error: unable to drain node "n" due to error: cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore): ns/ds-x, continuing command...\n'
		)
		expect(f.preflight).toEqual({
			{ category = "daemonset", flag = "--ignore-daemonsets", pods = { { namespace = "ns", name = "ds-x" } } },
		})
	end)
end)

describe("mutation.drain merge", function()
	-- Client: complete, deterministic list and policy; server: what only the
	-- Eviction API knows.
	it("keeps the client's list and order and takes budgets and timeout from the server", function()
		local merged = Drain.merge(parse("drain-client-ok"), parse("drain-server-pdb-timeout"))
		local evicted = names(merged.evictions)
		expect(#evicted).toBe(6)
		expect(evicted[1]).toBe("bare")
		expect(#merged.pdbBlocked).toBe(2)
		expect(merged.timedOut).toBe(true)
		expect(merged.nodes).toEqual({ NODE })
		expect(names(merged.unmanaged)).toEqual({ "bare", "ed" })
	end)

	it("works without a server probe (--disable-eviction)", function()
		local client = parse("drain-client-preflight")
		local merged = Drain.merge(client, nil)
		expect(#merged.preflight).toBe(3)
		expect(merged.pdbBlocked).toEqual({})
		expect(merged.timedOut).toBe(false)
		expect(merged.preflight[1].pods == client.preflight[1].pods).toBe(false)
	end)
end)

describe("mutation.drain probe", function()
	-- Leaves 5 s of the preview budget for kubectl itself; at least 5 s so a
	-- budget refusal (retried every 5 s) is observed, at most 15 s.
	it("derives the probe timeout from the preview budget", function()
		expect(Drain.probeTimeoutS(20000)).toBe(15)
		expect(Drain.probeTimeoutS(60000)).toBe(15)
		expect(Drain.probeTimeoutS(15500)).toBe(10)
		expect(Drain.probeTimeoutS(8000)).toBe(5)
	end)

	it("classifies probe exits: a budget block is a finding, other errors fail", function()
		expect(Drain.probeOutcome(0, read("drain-server-ok.txt"), read("drain-server-ok.stderr"))).toBe("ok")
		expect(Drain.probeOutcome(1, read("drain-server-pdb-timeout.txt"), read("drain-server-pdb-timeout.stderr"))).toBe(
			"pdb-blocked"
		)
		expect(Drain.probeOutcome(1, read("drain-server-preflight.txt"), read("drain-server-preflight.stderr"))).toBe(
			"failed"
		)
		expect(Drain.probeOutcome(137, "", "disruption budget")).toBe("failed")
	end)
end)

return nil
