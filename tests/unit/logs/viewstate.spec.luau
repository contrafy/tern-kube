--!strict
-- A reloaded logs lens keeps only the clicked action value, so the whole
-- view choice must survive `lv=<parts>` and strings from other plugin
-- versions must still decode.
local t = require("../../lib/test")
local vs = require("../../../plugin/lib/logs/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function roundTrip(v: vs.LogsView): vs.LogsView
	local action = vs.action(v)
	expect(string.sub(action, 1, 3)).toBe("lv=")
	return vs.decode(string.sub(action, 4))
end

describe("logs viewstate", function()
	it("round-trips every part", function()
		local v: vs.LogsView = {
			levels = { "error", "warn", "none" },
			sources = { 0, 1, 3 },
			wrap = true,
			time = false,
			merge = true,
			page = 4,
			open = 1234,
			ctx = 1200,
			help = true,
		}
		expect(roundTrip(v)).toEqual(v)
		expect(vs.encode(v)).toBe(
			"lvl:error,warn,none;src:0,1,3;wrap:1;time:0;merge:1;page:4;open:1234;ctx:1200;help:1"
		)
	end)

	it("encodes the default state as nothing so plain links stay short", function()
		expect(vs.encode(vs.default())).toBe("")
		expect(vs.decode("")).toEqual(vs.default())
	end)

	it("keeps `time` three-valued: unset means automatic", function()
		local on = vs.default()
		on.time = true
		expect(roundTrip(on).time).toBe(true)
		expect(roundTrip(vs.default()).time).toBeNil()
	end)

	it("normalises level and source order so equal views encode equally", function()
		local v = vs.default()
		v.levels = { "warn", "error", "warn" }
		v.sources = { 3, 1, 3 }
		expect(vs.encode(v)).toBe("lvl:error,warn;src:1,3")
	end)

	it("ignores unknown parts, unknown levels and malformed numbers", function()
		local v = vs.decode("future:9;lvl:error,loud;src:1,x,-2,1.5;page:abc;open:0;ctx:7;wrap:1;garbage")
		expect(v.levels).toEqual({ "error" })
		expect(v.sources).toEqual({ 1 })
		expect(v.page).toBeNil()
		expect(v.open).toBeNil()
		expect(v.ctx).toBe(7)
		expect(v.wrap).toBe(true)
	end)

	it("percent-decodes values like the get lens so escaped parts from encoders still read", function()
		local v = vs.decode("lvl:err%6Fr")
		expect(v.levels).toEqual({ "error" })
	end)

	-- Tern splits an action at "=" into act and value.
	it("never puts '=' inside the encoded state", function()
		local v = vs.default()
		v.levels = { "fatal", "error", "warn", "info", "debug", "trace", "none" }
		v.page = 3
		expect((string.find(vs.encode(v), "=", 1, true))).toBeNil()
	end)

	it("turns the view into a query filter: empty sets mean everything", function()
		local f = vs.filterOf(vs.default())
		expect(f.levels).toBeNil()
		expect(f.sources).toBeNil()
		expect(f.merge).toBe(false)
		local v = vs.default()
		v.levels = { "error", "fatal" }
		v.sources = { 2 }
		v.merge = true
		local g = vs.filterOf(v)
		expect(g.levels).toEqual({ error = true, fatal = true })
		expect(g.sources).toEqual({ [2] = true })
		expect(g.merge).toBe(true)
	end)
end)

return nil
