--!strict
-- The `:` prompt grammar: `HEAD [ARG]`. Nothing typed reaches kubectl
-- verbatim, so every ARG is classified here (scope, context, nodes) and
-- anything else is refused with a reason.
local Command = require("../../../plugin/lib/explore/command")
local Discovery = require("../../../plugin/lib/kubectl/discovery")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function keys(rows: { Command.Row }): { string }
	local out = {}
	for _, r in rows do
		table.insert(out, r.key)
	end
	return out
end

describe("Command.parse", function()
	it("reads a kind with an optional namespace scope", function()
		expect(Command.parse("deploy")).toEqual({ t = "kind", head = "deploy" })
		expect(Command.parse("  deploy   foo ")).toEqual({ t = "kind", head = "deploy", arg = "foo" })
		expect(Command.parse("deploy -A")).toEqual({ t = "kind", head = "deploy", all = true })
		expect(Command.parse("deploy *")).toEqual({ t = "kind", head = "deploy", all = true })
	end)

	-- A namespace becomes argv, so only a DNS-1123 label is accepted.
	it("refuses a scope that is not a namespace name", function()
		local bad = Command.parse("ns Bad_Name")
		expect(bad.t).toBe("invalid")
		expect(bad.why).toBe('Not a namespace name: "Bad_Name"')
		expect(Command.parse("po x/y").t).toBe("invalid")
		expect(Command.parse("ns " .. string.rep("a", 64)).t).toBe("invalid")
		expect(Command.parse("ns " .. string.rep("a", 63)).arg).toBe(string.rep("a", 63))
	end)

	it("knows the builtin commands case-insensitively", function()
		expect(Command.parse("ns")).toEqual({ t = "ns", head = "ns" })
		expect(Command.parse("namespace tern-test-apps")).toEqual({
			t = "ns",
			head = "namespace",
			arg = "tern-test-apps",
		})
		expect(Command.parse("NS -A")).toEqual({ t = "ns", head = "NS", all = true })
		expect(Command.parse("ctx").t).toBe("ctx")
		expect(Command.parse("Context kind-dev")).toEqual({ t = "ctx", head = "Context", arg = "kind-dev" })
		expect(Command.parse("contexts").t).toBe("ctx")
		expect(Command.parse("helm").t).toBe("helm")
		expect(Command.parse("hm").t).toBe("helm")
		expect(Command.parse("ev").t).toBe("events")
		expect(Command.parse("event x").arg).toBe("x")
		expect(Command.parse("events").t).toBe("events")
	end)

	-- Context names may contain spaces (`tk spaced`): the rest of the line
	-- is the name, matched exactly against the kubeconfig later.
	it("takes the rest of the line as the context name", function()
		expect(Command.parse("ctx a b")).toEqual({ t = "ctx", head = "ctx", arg = "a b" })
	end)

	-- Flux HelmRelease owns the short name `hr`.
	it("does not claim hr", function()
		expect(Command.parse("hr")).toEqual({ t = "kind", head = "hr" })
	end)

	it("maps top and usage to the usage view, nodes as its argument", function()
		expect(Command.parse("top")).toEqual({ t = "usage", head = "top" })
		expect(Command.parse("usage tern-test-apps")).toEqual({ t = "usage", head = "usage", arg = "tern-test-apps" })
		expect(Command.parse("top nodes")).toEqual({ t = "usage", head = "top", nodes = true })
		expect(Command.parse("top no")).toEqual({ t = "usage", head = "top", nodes = true })
		expect(Command.parse("top -A")).toEqual({ t = "usage", head = "top", all = true })
	end)

	it("refuses more than one argument and reports empty input", function()
		expect(Command.parse("deploy a b")).toEqual({ t = "invalid", head = "deploy", why = "Too many arguments" })
		expect(Command.parse("ns a b").why).toBe("Too many arguments")
		expect(Command.parse("   ")).toEqual({ t = "empty", head = "" })
	end)
end)

describe("Command.rows", function()
	local static = Discovery.staticIndex()

	it("lists matching commands above ranked kinds", function()
		local rows = Command.rows(static, "", true)
		expect(rows[1].key).toBe(":ctx")
		expect(rows[1].cells[1]).toBe("ctx …")
		local ks = keys(rows)
		expect(ks).toContain(":helm")
		expect(ks).toContain("pods")
		local dep = Command.rows(static, "dep", true)
		expect(dep[1].key).toBe("deployments.apps")
		expect(dep[1].cells).toEqual({ "deployments.apps", "deploy, deployment", "Deployment", "namespaced" })
		expect(dep[1].kind ~= nil).toBe(true)
	end)

	-- The helm row only shows when helm was found; `hr` still surfaces it.
	it("shows helm only with helm, and for hr", function()
		expect(keys(Command.rows(static, "", false))).toEqual((function()
			local out = {}
			for _, r in Command.rows(static, "", true) do
				if r.key ~= ":helm" then
					table.insert(out, r.key)
				end
			end
			return out
		end)())
		expect(keys(Command.rows(static, "hr", true))[1]).toBe(":helm")
	end)

	-- Core events / namespaces stay listed under the commands that shadow them.
	it("keeps shadowed resource rows", function()
		local ks = keys(Command.rows(static, "events", true))
		expect(ks[1]).toBe(":events")
		expect(ks).toContain("events")
		expect(keys(Command.rows(static, "ns", true))).toContain("namespaces")
	end)

	it("matches on the first word only and shows cluster scope", function()
		local rows = Command.rows(static, "no -A", true)
		expect(rows[1].key).toBe("nodes")
		expect(rows[1].cells[4]).toBe("cluster")
	end)
end)

describe("Command.complete", function()
	local static = Discovery.staticIndex()

	it("completes the first word to the canonical name and keeps the argument", function()
		local dep = Command.rows(static, "dep", true)[1]
		expect(Command.complete("dep", dep)).toBe("deployments.apps ")
		expect(Command.complete("dep  tern-test-apps", dep)).toBe("deployments.apps tern-test-apps")
		local ctx = Command.rows(static, "co", true)[1]
		expect(ctx.key).toBe(":ctx")
		expect(Command.complete("co", ctx)).toBe("ctx ")
	end)
end)

describe("Command.validNamespace", function()
	it("accepts DNS-1123 labels only", function()
		expect(Command.validNamespace("tern-test-apps")).toBe(true)
		expect(Command.validNamespace("a")).toBe(true)
		expect(Command.validNamespace("-a")).toBe(false)
		expect(Command.validNamespace("a-")).toBe(false)
		expect(Command.validNamespace("A")).toBe(false)
		expect(Command.validNamespace("")).toBe(false)
	end)
end)

return nil
