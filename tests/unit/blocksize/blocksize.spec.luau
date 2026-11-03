--!strict
-- Tern starts every block at 80x24 and, while its window is in the
-- background, sends the pane's real size only once the window is activated
-- (Tern 0.9.8, docs/sdk-capability-matrix.md "Block size"). Taken literally,
-- 80x24 cut Explore's list to 3 rows in a 45-row pane and hid the rows the
-- user was looking for.
local Blocksize = require("../../../plugin/lib/blocksize")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("blocksize", function()
	it("reads Tern's 80x24 spawn size as a pane of Tern's default window", function()
		expect(Blocksize.rows(80, 24)).toBe(Blocksize.DEFAULT_WINDOW_ROWS)
		expect(Blocksize.DEFAULT_WINDOW_ROWS).toBe(45)
	end)

	it("takes every other size as the pane's real height", function()
		expect(Blocksize.rows(78, 45)).toBe(45)
		expect(Blocksize.rows(80, 30)).toBe(30)
		expect(Blocksize.rows(120, 24)).toBe(24)
		expect(Blocksize.rows(160, 12)).toBe(12)
	end)
end)

return nil
