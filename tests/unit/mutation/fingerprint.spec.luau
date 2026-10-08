--!strict
-- The fingerprint ties an approval to exactly what was previewed. The shell
-- guard builds the same bytes independently (kube-lens/fp/v1), so the format
-- is pinned here byte for byte; any drift would make every guarded command
-- fail closed, and any field left out would let that input change unnoticed.
local Fingerprint = require("../../../plugin/lib/mutation/fingerprint")
local Plan = require("../../../plugin/lib/mutation/plan")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local SHA_A = string.rep("a", 64)
local SHA_B = string.rep("b", 64)

local function input(): Fingerprint.Input
	return {
		argv = { "kubectl", "apply", "-f", "my app.yaml" },
		context = "kind-dev",
		kubeconfig = "/k/a:/k/b",
		namespace = "apps",
		cwd = "/work",
		files = {
			{ path = "/work/my app.yaml", size = 120, sha256 = SHA_A },
			{ path = "/work/B.yaml", size = 7, sha256 = SHA_B },
		},
	}
end

local function canonical(i: Fingerprint.Input): string
	local text, e = Fingerprint.canonical(i)
	expect(e).toBeNil()
	return text :: string
end

describe("fingerprint canonical form", function()
	it("matches the shared kube-lens/fp/v1 layout exactly", function()
		expect(canonical(input())).toBe(table.concat({
			"kube-lens/fp/v1",
			"argv 4",
			"7:kubectl",
			"5:apply",
			"2:-f",
			"11:my app.yaml",
			"context 8:kind-dev",
			"kubeconfig 9:/k/a:/k/b",
			"namespace 4:apps",
			"cwd 5:/work",
			"files 2",
			"12:/work/B.yaml 7 " .. SHA_B,
			"17:/work/my app.yaml 120 " .. SHA_A,
			"",
		}, "\n"))
	end)

	it("writes absent kubeconfig and namespace the way the shell does", function()
		local i = input()
		i.kubeconfig = nil
		i.namespace = nil
		i.files = {}
		local text = canonical(i)
		expect(text).toContain("\nkubeconfig -\n")
		expect(text).toContain("\nnamespace 0:\n")
		expect(text).toContain("\nfiles 0\n")
		i.kubeconfig = ""
		expect(canonical(i)).toContain("\nkubeconfig -\n")
	end)

	it("sorts files bytewise (uppercase before lowercase) regardless of input order", function()
		local i = input()
		local j = input()
		j.files = { i.files[2], i.files[1] }
		expect(canonical(i)).toBe(canonical(j))
	end)

	it("length-prefixes values so spaces and newlines cannot shift fields", function()
		local a = input()
		a.argv = { "kubectl", "delete", "pod a" }
		local b = input()
		b.argv = { "kubectl", "delete", "pod", "a" }
		expect(canonical(a) ~= canonical(b)).toBe(true)
		local c = input()
		c.argv = { "kubectl", "label", "x\ncontext 3:bad" }
		expect(canonical(c)).toContain("argv 3\n7:kubectl\n5:label\n15:x\ncontext 3:bad\ncontext 8:kind-dev")
	end)

	it("changes when any guarded input changes", function()
		local base = canonical(input())
		local mutations: { (Fingerprint.Input) -> () } = {
			function(i)
				i.argv[4] = "other.yaml"
			end,
			function(i)
				i.context = "prod"
			end,
			function(i)
				i.kubeconfig = "/k/a"
			end,
			function(i)
				i.namespace = "default"
			end,
			function(i)
				i.cwd = "/elsewhere"
			end,
			function(i)
				i.files[1].sha256 = SHA_B
			end,
			function(i)
				i.files[1].size = 121
			end,
			function(i)
				table.remove(i.files)
			end,
		}
		for _, mutate in mutations do
			local i = input()
			mutate(i)
			expect(canonical(i) ~= base).toBe(true)
		end
	end)

	it("lowercases digests so hex case never causes a false mismatch", function()
		local i = input()
		i.files[1].sha256 = string.upper(SHA_A)
		expect(canonical(i)).toBe(canonical(input()))
	end)
end)

describe("fingerprint rejects inputs it cannot represent", function()
	local function bad(mutate: (Fingerprint.Input) -> ()): string
		local i = input()
		mutate(i)
		local text, e = Fingerprint.canonical(i)
		expect(text).toBeNil()
		return e :: string
	end

	it("refuses newline and relative file paths", function()
		expect(bad(function(i)
			i.files[1].path = "/work/a\nb"
		end)).toContain("newline")
		expect(bad(function(i)
			i.files[1].path = "app.yaml"
		end)).toContain("not absolute")
	end)

	it("refuses malformed digests, sizes, duplicates and a missing context", function()
		expect(bad(function(i)
			i.files[1].sha256 = "abc"
		end)).toContain("sha256")
		expect(bad(function(i)
			i.files[1].size = -1
		end)).toContain("size")
		expect(bad(function(i)
			i.files[2].path = i.files[1].path
		end)).toContain("twice")
		expect(bad(function(i)
			i.context = ""
		end)).toContain("context")
	end)
end)

describe("fingerprint digest and comparison", function()
	it("hashes the canonical text with the injected hasher", function()
		local seen: string? = nil
		local digest = Fingerprint.compute(input(), function(text: string): string
			seen = text
			return string.rep("C", 64)
		end)
		expect(digest).toBe(string.rep("c", 64))
		expect(seen).toBe(canonical(input()))
	end)

	it("never computes a digest for an invalid input", function()
		local i = input()
		i.files[1].path = "rel"
		local called = false
		local digest, e = Fingerprint.compute(i, function(_: string): string
			called = true
			return SHA_A
		end)
		expect(digest).toBeNil()
		expect(called).toBe(false)
		expect(e).toContain("not absolute")
	end)

	it("treats missing digests as different", function()
		expect(Fingerprint.equal(nil, nil)).toBe(false)
		expect(Fingerprint.equal("", "")).toBe(false)
		expect(Fingerprint.equal(SHA_A, nil)).toBe(false)
		expect(Fingerprint.equal(SHA_A, string.upper(SHA_A))).toBe(true)
	end)

	it("builds the input from a plan: explicit -n only, environment kubeconfig", function()
		local env: T.Env = { context = "kind-dev", kubeconfig = "/k/config", namespace = "team", cwd = "/work" }
		local p = Plan.fromArgv({ "kubectl", "--kubeconfig", "/other", "apply", "-f", "a.yaml" }, env) :: T.Plan
		local i = Fingerprint.fromPlan(p, {})
		expect(i.argv).toEqual({ "kubectl", "--kubeconfig", "/other", "apply", "-f", "a.yaml" })
		expect(i.kubeconfig).toBe("/k/config")
		expect(i.namespace).toBeNil()
		expect(i.context).toBe("kind-dev")
		expect(i.cwd).toBe("/work")
	end)
end)

return nil
