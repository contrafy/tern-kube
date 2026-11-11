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

	-- Y copies the tern-kube-drift command in drift views, so the help must
	-- say so there (and that the matrix keeps Y for its kubectl commands).
	it("the drift section names Y as the CLI copy", function()
		local found: string? = nil
		for _, e in Keys.sections("drift", true)[1].entries do
			if e[1] == "Y" then
				found = e[2]
			end
		end
		expect(found).toContain("tern-kube-drift")
		expect(found).toContain("matrix Y copies the kubectl commands")
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

	-- z only works in a Secret's object view, so it belongs to that view's
	-- section and nowhere else.
	it("the object view lists the Secret decode key first", function()
		local title, what = firstSection("detail")
		expect(title).toBe("This view")
		expect(allStartWith(what, { "Object:" })).toBe(true)
		local z = false
		for _, e in Keys.sections("detail", true)[1].entries do
			z = z or e[1] == "z"
		end
		expect(z).toBe(true)
		expect((firstSection("list"))).toBe("Keys")
	end)

	-- `:` is a prompt now; the help must name what it accepts and its keys.
	it("the `:` row describes the command prompt", function()
		local row: { string }? = nil
		for _, e in Keys.KEYS do
			if e[1] == ":" then
				row = e
			end
		end
		local what = (row :: { string })[2]
		for _, word in { "ns NAME", "ctx NAME", "helm", "events", "tab completes", "esc back" } do
			expect(what).toContain(word)
		end
	end)

	-- `%` works everywhere; `w` (sampling) and enter's drill-in only in the
	-- usage views, so they lead that view's help and no key means two things
	-- there.
	it("the usage views list their keys first, % stays global", function()
		local title, what = firstSection("usage")
		expect(title).toBe("This view")
		expect(allStartWith(what, { "Usage:" })).toBe(true)
		local keys: { [string]: boolean } = {}
		for _, e in Keys.sections("usage", true)[1].entries do
			for key in string.gmatch(e[1], "[^%s/]+") do
				expect(keys[key]).toBeNil()
				keys[key] = true
			end
		end
		expect(keys.w).toBe(true)
		expect(keys.enter).toBe(true)
		local global = false
		for _, e in Keys.sections("list", true)[1].entries do
			global = global or e[1] == "%"
		end
		expect(global).toBe(true)
	end)
end)

return nil
