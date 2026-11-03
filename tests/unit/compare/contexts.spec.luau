--!strict
-- The compare picker is built from one local `kubectl config view -o json`:
-- every context with its server (aliases of one cluster are marked, since
-- comparing a cluster with itself proves nothing), a single choice per row,
-- and the max_contexts budget enforced before any query runs.
local Contexts = require("../../../plugin/lib/compare/contexts")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function info(name: string, server: string?): Contexts.ContextInfo
	return { name = name, cluster = name, server = server }
end

local function byId(choices: { Contexts.Choice }, id: string): Contexts.Choice
	for _, c in choices do
		if c.id == id then
			return c
		end
	end
	error("no choice " .. id)
end

describe("compare.contexts parse", function()
	-- kind picks the API server ports at cluster creation; only their shape
	-- is stable across captures.
	it("reads every context with its cluster's server from config view", function()
		local all, err = Contexts.parse(fixtures.read("real/compare/config-view-3.json"), json.decode)
		expect(err).toBeNil()
		local list = all :: { Contexts.ContextInfo }
		expect(#list).toBe(3)
		expect(list[1].name).toBe("kind-tern-kube-dev")
		expect(list[1].cluster).toBe("kind-tern-kube-dev")
		expect(list[2].name).toBe("kind-tern-kube-dev2")
		for i = 1, 2 do
			expect(string.match(list[i].server :: string, "^https://127%.0%.0%.1:%d+$") ~= nil).toBe(true)
		end
		expect(list[1].server ~= list[2].server).toBe(true)
		expect(list[3]).toEqual({
			name = "kind-tern-kube-down",
			cluster = "kind-tern-kube-down",
			server = "https://127.0.0.1:1",
		})
		local two = Contexts.parse(fixtures.read("real/compare/config-view.json"), json.decode) :: { any }
		expect(#two).toBe(2)
	end)

	it("keeps the context's default namespace and tolerates a missing cluster", function()
		local all = Contexts.parse(
			[[{"kind":"Config","contexts":[{"name":"a","context":{"cluster":"gone","namespace":"team"}},{"name":"b"}]}]],
			json.decode
		)
		expect(all).toEqual({ { name = "a", cluster = "gone", namespace = "team" }, { name = "b" } } :: { any })
	end)

	it("reports invalid output instead of an empty picker", function()
		local all, err = Contexts.parse("{", json.decode)
		expect(all).toBeNil()
		expect(err).toContain("invalid JSON")
		local _, other = Contexts.parse('{"kind":"Pod"}', json.decode)
		expect(other).toContain("kubeconfig")
	end)
end)

describe("compare.contexts choices", function()
	it("offers each other context, then all contexts", function()
		local all = Contexts.parse(fixtures.read("real/compare/config-view.json"), json.decode) :: { any }
		local choices = Contexts.choices(all, "kind-tern-kube-dev", {}, 8)
		expect(choices).toEqual({
			{
				id = "=kind-tern-kube-dev2",
				label = "kind-tern-kube-dev2",
				contexts = { "kind-tern-kube-dev2" },
				note = all[2].server,
			},
			{ id = "*", label = "All contexts (2)", contexts = { "kind-tern-kube-dev2" } },
		} :: { any })
	end)

	-- Two names for one API server compare a cluster with itself: still
	-- offered, but marked.
	it("marks contexts with the same server as the base", function()
		local all = { info("prod", "https://p"), info("prod-admin", "https://p"), info("stage", "https://s") }
		local choices = Contexts.choices(all, "prod", {}, 8)
		expect(byId(choices, "=prod-admin").warning).toBe("same server as base")
		expect(byId(choices, "=stage").warning).toBeNil()
		expect(byId(choices, "*").warning).toBe("1 context with the same server as base")
		expect(byId(choices, "*").contexts).toEqual({ "prod-admin", "stage" })
	end)

	it("disables a fan-out above max_contexts with the reason", function()
		local all = { info("a"), info("b"), info("c") }
		local star = byId(Contexts.choices(all, "a", {}, 1), "*")
		expect(star.disabled).toBe("2 other contexts, above compare.max_contexts (1)")
		expect(byId(Contexts.choices({ info("a") }, "a", {}, 8), "*").disabled).toBe("no other context to compare with")
	end)

	-- A typo in compare.contexts must be visible, not silently shrink the set.
	it("lists the configured preset and flags names missing from the kubeconfig", function()
		local all = { info("a"), info("b"), info("c") }
		local preset = byId(Contexts.choices(all, "a", { "c", "a", "prod-eu" }, 8), "@")
		expect(preset.label).toBe("Configured: c, a, prod-eu")
		expect(preset.contexts).toEqual({ "c" })
		expect(preset.warning).toBe("not in this kubeconfig: prod-eu")
		expect(preset.disabled).toBeNil()
		local none = byId(Contexts.choices(all, "a", { "x" }, 8), "@")
		expect(none.disabled).toBe("no other context to compare with")
		local over = byId(Contexts.choices(all, "a", { "b", "c" }, 1), "@")
		expect(over.disabled).toBe("2 other contexts, above compare.max_contexts (1)")
		local choices = Contexts.choices(all, "a", {}, 8)
		expect(choices[#choices].id).toBe("*")
	end)
end)

describe("compare.contexts short", function()
	it("drops the common prefix up to a separator", function()
		expect(Contexts.short({ "kind-tern-kube-dev", "kind-tern-kube-dev2" })).toEqual({
			["kind-tern-kube-dev"] = "dev",
			["kind-tern-kube-dev2"] = "dev2",
		})
		expect(Contexts.short({ "arn:aws:eks:eu-west-1:1:cluster/prod", "arn:aws:eks:eu-west-1:1:cluster/stage" })).toEqual({
			["arn:aws:eks:eu-west-1:1:cluster/prod"] = "prod",
			["arn:aws:eks:eu-west-1:1:cluster/stage"] = "stage",
		})
	end)

	it("keeps full names when nothing is shared or a label would be empty", function()
		expect(Contexts.short({ "prod", "stage" })).toEqual({ prod = "prod", stage = "stage" })
		expect(Contexts.short({ "solo" })).toEqual({ solo = "solo" })
		expect(Contexts.short({ "a-", "a-b" })).toEqual({ ["a-"] = "a-", ["a-b"] = "b" })
	end)
end)

return nil
