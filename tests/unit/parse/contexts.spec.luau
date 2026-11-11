--!strict
-- `kubectl config get-contexts` from a multi-context kubeconfig with a
-- spaced name and an EKS ARN (capture-k9s.sh). Every form the lens claims
-- must yield the same names, and the `*` must stay the kubeconfig's
-- current-context.
local Contexts = require("../../../plugin/lib/parse/contexts")
local k9s = require("../../lib/k9s")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NAMES = {
	"arn:aws:eks:us-east-1:123456789012:cluster/prod",
	"kind-tern-kube-dev",
	"tk spaced",
	"tk-apps",
	"tk-broken",
}

local function names(p: Contexts.ContextsParse): { string }
	local out: { string } = {}
	for _, r in p.rows do
		table.insert(out, r.name)
	end
	return out
end

describe("parse.contexts", function()
	it("reads the table with spaced and ARN names intact", function()
		local p = Contexts.parse(k9s.stdout("ctx-default"), "table")
		expect(p.diagnostics).toEqual({})
		expect(p.headers).toEqual({ "CURRENT", "NAME", "CLUSTER", "AUTHINFO", "NAMESPACE" })
		expect(names(p)).toEqual(NAMES)
		local apps = p.rows[4]
		expect(apps.current).toBe(false)
		expect(apps.cluster).toBe("kind-tern-kube-dev")
		expect(apps.namespace).toBe("tern-test-apps")
		expect(p.rows[1].namespace).toBeNil()
		expect(p.rows[2].current).toBe(true)
		expect(p.rows[5].cluster).toBe("nowhere")
		expect(p.rows[5].authinfo).toBe("nobody")
	end)

	it("keeps the star on the kubeconfig's current-context under --context", function()
		local p = Contexts.parse(k9s.stdout("ctx-flag-context"), "table")
		expect(p.rows[2].name).toBe("kind-tern-kube-dev")
		expect(p.rows[2].current).toBe(true)
		expect(p.rows[4].current).toBe(false)
	end)

	it("reads --no-headers by its marker field", function()
		local p = Contexts.parse(k9s.stdout("ctx-noheaders"), "noheaders")
		expect(p.diagnostics).toEqual({})
		expect(names(p)).toEqual(NAMES)
		expect(p.rows[2].current).toBe(true)
		expect(p.rows[4].namespace).toBe("tern-test-apps")
		expect(p.rows[3].cells).toEqual({ "", "tk spaced", "kind-tern-kube-dev", "kind-tern-kube-dev", "" })
	end)

	it("-o name gives names and leaves current unknown", function()
		local p = Contexts.parse(k9s.stdout("ctx-name"), "name")
		expect(p.headers).toEqual({ "NAME" })
		expect(names(p)).toEqual(NAMES)
		expect(p.rows[1].current).toBeNil()
	end)

	it("a missing context is an error after the bare header; an empty kubeconfig has no rows", function()
		local f = k9s.load("ctx-missing")
		local p = Contexts.parse(f.lines, "table")
		expect(#p.rows).toBe(0)
		expect(p.diagnostics[1].text).toBe("error: context nope not found")
		expect(#Contexts.parse(k9s.stdout("ctx-empty"), "table").rows).toBe(0)
	end)

	it("a --no-headers name with a double space is a diagnostic, not a guess", function()
		local p = Contexts.parse({ "      a  b   c   u   ns" }, "noheaders")
		expect(#p.rows).toBe(0)
		expect(#p.diagnostics).toBe(1)
	end)
end)

return nil
