--!strict
-- A quick-action grant token authorizes running a mutation, so it must be
-- unguessable: the window reads it from /dev/urandom through a process
-- (tern.fs.read refuses device files). Anything but exactly 16 random
-- bytes from a clean exit yields no token, and then no grant is minted:
-- fail closed, never a weaker fallback.
local Entropy = require("../../../plugin/lib/env/entropy")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function result(stdout: string, status: number?, timedOut: boolean?): Entropy.Result
	return { status = status or 0, stdout = stdout, timed_out = timedOut == true }
end

describe("Entropy", function()
	it("reads 16 bytes of /dev/urandom through sh and od", function()
		expect(Entropy.ARGV).toEqual({ "/bin/sh", "-c", "od -An -tx1 -N16 /dev/urandom" })
		expect(Entropy.TIMEOUT_MS <= 5000).toBe(true)
	end)

	it("turns od's hex dump into a 32-hex token", function()
		local out = " 3f a0 09 7c 12 ee 45 00 b1 c2 d3 e4 f5 06 17 28\n"
		expect(Entropy.token(result(out))).toBe("3fa0097c12ee4500b1c2d3e4f5061728")
	end)

	it("accepts the dump split over lines (od on other systems)", function()
		local out = "0000000 3f a0 09 7c 12 ee 45 00\n"
		expect(Entropy.token(result(out))).toBeNil()
		expect(Entropy.token(result(" 3f a0 09 7c 12 ee 45 00\n b1 c2 d3 e4 f5 06 17 28\n"))).toBe(
			"3fa0097c12ee4500b1c2d3e4f5061728"
		)
	end)

	it("fails closed on short reads, failures, timeouts and junk", function()
		expect(Entropy.token(nil)).toBeNil()
		expect(Entropy.token(result(" 3f a0 09\n"))).toBeNil()
		expect(Entropy.token(result(" 3f a0 09 7c 12 ee 45 00 b1 c2 d3 e4 f5 06 17 28 99\n"))).toBeNil()
		local good = " 3f a0 09 7c 12 ee 45 00 b1 c2 d3 e4 f5 06 17 28\n"
		expect(Entropy.token(result(good, 1))).toBeNil()
		expect(Entropy.token(result(good, -1, true))).toBeNil()
		expect(Entropy.token(result(" 3F A0 09 7C 12 EE 45 00 B1 C2 D3 E4 F5 06 17 2G\n"))).toBeNil()
		expect(Entropy.token(result(""))).toBeNil()
	end)
end)

return nil
