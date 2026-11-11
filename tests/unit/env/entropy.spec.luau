--!strict
-- A quick-action grant token authorizes running a mutation, so it must be
-- unguessable: the window reads it from /dev/urandom through a process
-- (tern.fs.read refuses device files). The same read yields the run id that
-- ties the approved record to the split's outcome record; it is logged, so
-- it must be independent of the token (separate bytes). Anything but
-- exactly 32 random bytes from a clean exit yields neither, and then no
-- grant is minted: fail closed, never a weaker fallback.
local Entropy = require("../../../plugin/lib/env/entropy")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function result(stdout: string, status: number?, timedOut: boolean?): Entropy.Result
	return { status = status or 0, stdout = stdout, timed_out = timedOut == true }
end

local A = " 3f a0 09 7c 12 ee 45 00 b1 c2 d3 e4 f5 06 17 28\n"
local B = " 01 23 45 67 89 ab cd ef 10 32 54 76 98 ba dc fe\n"

describe("Entropy", function()
	it("reads 32 bytes of /dev/urandom through sh and od", function()
		expect(Entropy.ARGV).toEqual({ "/bin/sh", "-c", "od -An -tx1 -N32 /dev/urandom" })
		expect(Entropy.TIMEOUT_MS <= 5000).toBe(true)
	end)

	it("splits od's dump into a token and a run id, 32 hex each", function()
		local token, run = Entropy.tokens(result(A .. B))
		expect(token).toBe("3fa0097c12ee4500b1c2d3e4f5061728")
		expect(run).toBe("0123456789abcdef1032547698badcfe")
	end)

	it("ignores how od splits lines", function()
		local token, run = Entropy.tokens(result(" 3f a0 09 7c 12 ee 45 00\n b1 c2 d3 e4 f5 06 17 28\n" .. B))
		expect(token).toBe("3fa0097c12ee4500b1c2d3e4f5061728")
		expect(run).toBe("0123456789abcdef1032547698badcfe")
	end)

	it("fails closed on short reads, failures, timeouts and junk", function()
		local function none(r: Entropy.Result?)
			local token, run = Entropy.tokens(r)
			expect(token).toBeNil()
			expect(run).toBeNil()
		end
		none(nil)
		none(result(A))
		none(result(A .. B .. " 99\n"))
		none(result(A .. B, 1))
		none(result(A .. B, -1, true))
		none(result("0000000" .. A .. B))
		none(result(A .. " 01 23 45 67 89 AB CD EF 10 32 54 76 98 BA DC 2G\n"))
		none(result(""))
	end)
end)

return nil
