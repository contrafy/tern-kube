--!strict
-- The help lists the keys of the view in front first, so the section a key
-- lands in must follow the route kinds Explore really pushes (drift, export,
-- git, matrix), not names that are never a route.
local Keys = require("../../../plugin/lib/explore/keys")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function firstSection(kind: string): (string, { string })
	local sec = Keys.sections(kind, true)[1]
	local what: { string } = {}
	for _, e in sec.entries do
		table.insert(what, e[2])
	end
	return sec.title, what
end

local function allStartWith(what: { string }, prefixes: { string }): boolean
	for _, w in what do
		local ok = false
		for _, p in prefixes do
			ok = ok or string.find(w, p, 1, true) ~= nil
		end
		if not ok then
			return false
		end
	end
	return true
end

describe("explore help sections", function()
	it("a list has no view-specific section: every general key comes first", function()
		local title = firstSection("list")
		expect(title).toBe("Keys")
	end)

	it("the drift report lists its Drift keys first", function()
		local title, what = firstSection("drift")
		expect(title).toBe("This view")
		expect(#what > 0).toBe(true)
		expect(allStartWith(what, { "Drift:" })).toBe(true)
	end)

	it("the export and git steps list Export and Git keys first", function()
		for _, kind in { "export", "git" } do
			local title, what = firstSection(kind)
			expect(title).toBe("This view")
			expect(allStartWith(what, { "Export:", "Git:" })).toBe(true)
			expect(#what).toBe(2)
		end
	end)

	-- The drift matrix compares one source across contexts: [ ] and f work
	-- there as in compare.
	it("the drift matrix lists the Drift and Compare keys first", function()
		local title, what = firstSection("matrix")
		expect(title).toBe("This view")
		expect(allStartWith(what, { "Drift:", "Compare:" })).toBe(true)
		local compare = false
		for _, w in what do
			compare = compare or string.find(w, "Compare:", 1, true) ~= nil
		end
		expect(compare).toBe(true)
	end)
end)

return nil
