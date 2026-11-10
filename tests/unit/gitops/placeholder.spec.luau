--!strict
-- Export writes REPLACE_ME instead of Secret values. kubectl diff masks
-- Secret values on both sides, so without these checks a re-applied export
-- looks like an ordinary change and a simple confirm would overwrite the
-- live credentials with the placeholder.
local Clean = require("../../../plugin/lib/gitops/clean")
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Placeholder = require("../../../plugin/lib/gitops/placeholder")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("gitops placeholder: objects", function()
	it("finds the keys export replaced, in stringData and base64 in data", function()
		expect(Placeholder.TOKEN).toBe(Clean.PLACEHOLDER)
		local obj = {
			apiVersion = "v1",
			kind = "Secret",
			metadata = { name = "s", namespace = "ns" },
			stringData = { pw = "REPLACE_ME", user = "admin" },
			data = { token = "UkVQTEFDRV9NRQ==", real = "c2VjcmV0" },
		}
		expect(Placeholder.secretKeys(obj)).toEqual({ "pw", "token" })
	end)

	it("an export of a live Secret is detected", function()
		local cleaned = Clean.clean({
			apiVersion = "v1",
			kind = "Secret",
			metadata = { name = "s", namespace = "ns" },
			data = { b = "eA==", a = "eQ==" },
		})
		expect(Placeholder.secretKeys(cleaned)).toEqual({ "a", "b" })
	end)

	it("ignores other kinds and real values", function()
		expect(Placeholder.secretKeys({ apiVersion = "v1", kind = "ConfigMap", data = { a = "REPLACE_ME" } })).toEqual({})
		expect(Placeholder.secretKeys({ apiVersion = "v1", kind = "Secret", stringData = { a = "x" } })).toEqual({})
		expect(Placeholder.secretKeys(nil)).toEqual({})
	end)
end)

describe("gitops placeholder: manifest text", function()
	it("reads block mappings, quoted values and comments", function()
		local text = table.concat({
			"# exported by tern-kube",
			"apiVersion: v1",
			"kind: Secret",
			"metadata:",
			"  name: app",
			"  namespace: ns",
			"stringData:",
			"  pw: REPLACE_ME",
			'  "api-token": "REPLACE_ME"',
			"  user: admin",
			"  note: REPLACE_ME # fill in",
			"data:",
			"  key: UkVQTEFDRV9NRQ==",
			"  real: c2VjcmV0",
			"type: Opaque",
			"",
		}, "\n")
		expect(Placeholder.textKeys(text)).toEqual({ "api-token", "key", "note", "pw" })
	end)

	it("reads flow mappings", function()
		local text = "apiVersion: v1\nkind: Secret\nmetadata: {name: a}\nstringData: {pw: REPLACE_ME, u: x}\n"
		expect(Placeholder.textKeys(text)).toEqual({ "pw" })
	end)

	-- Nested values are not Secret keys (only direct children are).
	it("ignores nested values, other kinds and core-less apiVersions", function()
		expect(Placeholder.textKeys("apiVersion: v1\nkind: ConfigMap\ndata:\n  a: REPLACE_ME\n")).toEqual({})
		expect(Placeholder.textKeys("apiVersion: example.com/v1\nkind: Secret\nstringData:\n  a: REPLACE_ME\n")).toEqual({})
		expect(Placeholder.textKeys("apiVersion: v1\nkind: Secret\nmetadata:\n  labels:\n    a: REPLACE_ME\n")).toEqual({})
	end)
end)

describe("gitops placeholder: diff lines", function()
	it("relabels only the masked added values of the placeholder keys", function()
		local seg = Diffseg.parse(table.concat({
			"diff -u -N /tmp/LIVE-1/v1.Secret.ns.app /tmp/MERGED-2/v1.Secret.ns.app",
			"--- /tmp/LIVE-1/v1.Secret.ns.app\t2026-11-10 10:00:00.000000000 +0000",
			"+++ /tmp/MERGED-2/v1.Secret.ns.app\t2026-11-10 10:00:00.000000000 +0000",
			"@@ -1,5 +1,5 @@",
			" apiVersion: v1",
			" data:",
			"-  pw: '*** (before)'",
			"+  pw: '*** (after)'",
			"-  token: '*** (before)'",
			"+  token: '*** (after)'",
			"",
		}, "\n")).segments[1]
		local marked = Placeholder.markSegment(seg, { "pw" })
		expect(marked.lines).toContain("+  pw: REPLACE_ME (placeholder)")
		expect(marked.lines).toContain("+  token: '*** (after)'")
		expect(marked.lines).toContain("-  pw: '*** (before)'")
		expect(Placeholder.markSegment(seg, {})).toBe(seg)
	end)
end)

return nil
