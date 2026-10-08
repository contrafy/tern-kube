--!strict
local Selector = require("../../../plugin/lib/explore/selector")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function parsed(text: string): Selector.Selector
	local sel, err = Selector.parse(text)
	if sel == nil then
		error("parse failed: " .. tostring(err))
	end
	return sel
end

local function fromLs(ls: any): Selector.Selector?
	local sel, err = Selector.fromLabelSelector(ls)
	if err ~= nil then
		error("fromLabelSelector failed: " .. err)
	end
	return sel
end

local WEB = { app = "web", tier = "frontend" }

describe("selector.parse", function()
	it("reads every kubectl -l operator", function()
		local sel = parsed("a=b, c!=d,e in (x, y),!f,g notin (z),h,i==j")
		expect(Selector.format(sel)).toBe("a=b,c!=d,e in (x,y),!f,g notin (z),h,i=j")
	end)

	it("treats the empty string as select-everything, like kubectl", function()
		expect(#parsed("").requirements).toBe(0)
		expect(Selector.matches(parsed(""), {})).toBe(true)
	end)

	it("accepts empty values and prefixed keys", function()
		local sel = parsed("lens.example.com/empty=,app.kubernetes.io/name=odd-labels")
		expect(Selector.matches(sel, { ["lens.example.com/empty"] = "", ["app.kubernetes.io/name"] = "odd-labels" })).toBe(
			true
		)
	end)

	it("rejects malformed selectors instead of guessing", function()
		for _, bad in { "a in ()", "a in (b", "a=b,", "a b", "a!b", "-a=b", "a=b=c", "Bad.Prefix/x=y", "a in ((b))" } do
			local sel, err = Selector.parse(bad)
			expect(sel).toBeNil()
			expect(type(err)).toBe("string")
		end
	end)

	it("round-trips its canonical form", function()
		local text = Selector.format(parsed("tier notin (backend,cache),app in (web,api),!legacy"))
		expect(Selector.format(parsed(text))).toBe(text)
	end)
end)

describe("selector.matches", function()
	it("follows apimachinery semantics for absent keys", function()
		expect(Selector.matches(parsed("env!=prod"), WEB)).toBe(true)
		expect(Selector.matches(parsed("env notin (prod)"), WEB)).toBe(true)
		expect(Selector.matches(parsed("env in (prod)"), WEB)).toBe(false)
		expect(Selector.matches(parsed("env=prod"), WEB)).toBe(false)
		expect(Selector.matches(parsed("!env"), WEB)).toBe(true)
		expect(Selector.matches(parsed("app"), WEB)).toBe(true)
		expect(Selector.matches(parsed("!app"), WEB)).toBe(false)
	end)

	it("ANDs every requirement", function()
		expect(Selector.matches(parsed("app=web,tier in (frontend,edge)"), WEB)).toBe(true)
		expect(Selector.matches(parsed("app=web,tier=backend"), WEB)).toBe(false)
	end)

	it("treats missing labels as an empty set", function()
		expect(Selector.matches(parsed("!app"), nil)).toBe(true)
		expect(Selector.matches(parsed("app"), nil)).toBe(false)
	end)

	it("selects nothing for a nil selector", function()
		expect(Selector.matches(nil, WEB)).toBe(false)
	end)
end)

describe("selector.fromLabelSelector", function()
	it("combines matchLabels and matchExpressions", function()
		local sel = fromLs({
			matchLabels = { app = "web" },
			matchExpressions = {
				{ key = "tier", operator = "In", values = { "frontend", "edge" } } :: any,
				{ key = "legacy", operator = "DoesNotExist" },
				{ key = "env", operator = "NotIn", values = { "prod" } },
				{ key = "app", operator = "Exists" },
			},
		})
		expect(Selector.matches(sel, WEB)).toBe(true)
		expect(Selector.matches(sel, { app = "web", tier = "frontend", legacy = "yes" })).toBe(false)
		expect(Selector.matches(sel, { app = "web", tier = "backend" })).toBe(false)
		expect(Selector.matches(sel, { app = "web", tier = "edge", env = "prod" })).toBe(false)
	end)

	it("distinguishes nil (nothing) from empty (everything)", function()
		expect(Selector.matches(fromLs(nil), WEB)).toBe(false)
		expect(Selector.matches(fromLs({}), WEB)).toBe(true)
	end)

	it("reports invalid expressions", function()
		local cases: { any } = {
			{ matchExpressions = { { key = "a", operator = "In", values = {} } } },
			{ matchExpressions = { { key = "a", operator = "Exists", values = { "x" } } } },
			{ matchExpressions = { { key = "a", operator = "Gt", values = { "1" } } } },
			{ matchLabels = { a = 1 } },
		}
		for _, ls in cases do
			local sel, err = Selector.fromLabelSelector(ls)
			expect(sel).toBeNil()
			expect(type(err)).toBe("string")
		end
	end)

	it("formats as a kubectl -l argument that selects the same objects", function()
		local sel = fromLs({
			matchLabels = { app = "web" },
			matchExpressions = { { key = "tier", operator = "NotIn", values = { "db" } } },
		}) :: Selector.Selector
		expect(Selector.format(sel)).toBe("app=web,tier notin (db)")
		expect(Selector.matches(parsed(Selector.format(sel)), WEB)).toBe(true)
	end)
end)

describe("selector.matchesMap", function()
	it("is an equality match on every pair", function()
		expect(Selector.matchesMap({ app = "web" }, WEB)).toBe(true)
		expect(Selector.matchesMap({ app = "web", tier = "db" }, WEB)).toBe(false)
	end)

	it("selects nothing for selector-less Services", function()
		expect(Selector.matchesMap({}, WEB)).toBe(false)
		expect(Selector.matchesMap(nil, WEB)).toBe(false)
	end)

	it("agrees with fromMap + matches for non-empty maps", function()
		expect(Selector.matches(Selector.fromMap({ app = "web" }), WEB)).toBe(true)
		expect(Selector.format(Selector.fromMap({ tier = "frontend", app = "web" }))).toBe("app=web,tier=frontend")
	end)
end)
return nil
