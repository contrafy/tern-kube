--!strict
-- A reload drops lens state; only the action string survives. These specs
-- pin that every view choice round-trips through it and that strings from
-- other plugin versions still decode.
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function roundTrip(vs: vsm.ViewState): vsm.ViewState
	local action = vsm.action(vs)
	expect(string.sub(action, 1, 2)).toBe("v=")
	return vsm.decode(string.sub(action, 3))
end

describe("lens viewstate", function()
	it("round-trips every field, including separators inside values", function()
		local vs: vsm.ViewState = {
			sort = "CPU(cores)",
			desc = true,
			filters = { "LABELS=app=web,tier=a;b:c%d~e", "STATUS=Running" },
			problems = true,
			open = "apps/Deployment/ns:1/web;x=y",
			full = true,
			page = 3,
			help = true,
		}
		expect(roundTrip(vs)).toEqual(vs)
	end)

	it("default state encodes to an empty value and decodes back", function()
		expect(vsm.encode(vsm.default())).toBe("")
		expect(vsm.decode("")).toEqual(vsm.default())
	end)

	-- Tern splits an action at "=" into act and value; a second "=" would be
	-- ambiguous, so the encoded state must never contain one.
	it("never puts '=' inside the encoded state", function()
		local vs = vsm.toggledFilter(vsm.default(), "LABELS", "app=web")
		vs = vsm.opened(vs, "a=b")
		expect((string.find(vsm.encode(vs), "=", 1, true))).toBeNil()
	end)

	it("ignores unknown fields and malformed values (forward compatible)", function()
		local vs = vsm.decode("sort:AGE;zoom:2;theme:x;page:-1;page:abc;desc:1;garbage;f:noTilde,COL~v")
		expect(vs.sort).toBe("AGE")
		expect(vs.desc).toBe(true)
		expect(vs.page).toBe(0)
		expect(vs.filters).toEqual({ "COL=v" })
	end)

	it("decodes the M0 spike encoding", function()
		local vs = vsm.decode("sort:STATUS;desc:1;open:db-0")
		expect(vs.sort).toBe("STATUS")
		expect(vs.desc).toBe(true)
		expect(vs.open).toBe("db-0")
	end)

	it("drops full view when no row is open", function()
		expect(vsm.decode("full:1").full).toBe(false)
	end)

	it("sorting the same column flips direction, a new column starts ascending", function()
		local a = vsm.sortedBy(vsm.default(), "AGE")
		expect(a.desc).toBe(false)
		local b = vsm.sortedBy(a, "AGE")
		expect(b.desc).toBe(true)
		local c = vsm.sortedBy(b, "NAME")
		expect(c.sort).toBe("NAME")
		expect(c.desc).toBe(false)
	end)

	it("sorting and filtering keep the open row (selection survives)", function()
		local vs = vsm.opened(vsm.default(), "/Pod/ns/db-0")
		expect(vsm.sortedBy(vs, "AGE").open).toBe("/Pod/ns/db-0")
		expect(vsm.toggledFilter(vs, "STATUS", "Running").open).toBe("/Pod/ns/db-0")
		expect(vsm.toggledProblems(vs).open).toBe("/Pod/ns/db-0")
	end)

	it("filters are sorted, deduped and toggle off", function()
		local vs = vsm.toggledFilter(vsm.default(), "STATUS", "Running")
		vs = vsm.toggledFilter(vs, "NAMESPACE", "a")
		expect(vs.filters).toEqual({ "NAMESPACE=a", "STATUS=Running" })
		vs = vsm.toggledFilter(vs, "STATUS", "Running")
		expect(vs.filters).toEqual({ "NAMESPACE=a" })
		expect(vsm.decode("f:A~1,A~1,B~2").filters).toEqual({ "A=1", "B=2" })
	end)

	it("filtering and sorting return to the first page", function()
		local vs = vsm.paged(vsm.default(), 2)
		expect(vsm.toggledFilter(vs, "STATUS", "x").page).toBe(0)
		expect(vsm.sortedBy(vs, "AGE").page).toBe(0)
		expect(vsm.toggledProblems(vs).page).toBe(0)
	end)

	it("clicking the open row closes it; inspect and back keep the row open", function()
		local vs = vsm.opened(vsm.default(), "k")
		expect(vsm.opened(vs, "k").open).toBeNil()
		local full = vsm.inspect(vs, "k")
		expect(full.full).toBe(true)
		local back = vsm.back(full)
		expect(back.full).toBe(false)
		expect(back.open).toBe("k")
	end)

	it("transitions never mutate their input", function()
		local vs = vsm.default()
		vsm.toggledFilter(vs, "STATUS", "Running")
		vsm.sortedBy(vs, "AGE")
		vsm.toggledHelp(vs)
		expect(vs).toEqual(vsm.default())
	end)
end)

return nil
