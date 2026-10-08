--!strict
-- Deliberately failing tests; tests/selfcheck/check.sh asserts the runner
-- reports each of them and exits nonzero. Not matched by *.spec.luau.
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("selfcheck", function()
	it("passing control", function()
		expect(true).toBe(true)
	end)

	it("fails toBe", function()
		expect("actual-value").toBe("expected-value")
	end)

	it("fails toEqual deep", function()
		expect({ spec = { replicas = 2 } }).toEqual({ spec = { replicas = 3 } })
	end)

	it("fails toThrow", function()
		expect(function() end).toThrow()
	end)

	it("raises a runtime error", function()
		local value: any = nil
		print(value.field)
	end)
end)

return nil
