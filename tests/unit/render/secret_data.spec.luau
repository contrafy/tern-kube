--!strict
-- The Decoded values card is display-only: it must say so, show each key
-- in a form that cannot disguise itself (escaped text, hex for binary) and
-- carry no action that could copy or persist a decoded value.
local SecretData = require("../../../plugin/lib/model/secretdata")
local SecretDataView = require("../../../plugin/lib/render/secret_data")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Node = nodes.Node

local PEM = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n"

-- base64 of the fake values (generated once with `base64`).
local PAIRS: { SecretData.Pair } = {
	{ key = "password", value = "aHVudGVyMi1mYWtl" }, -- hunter2-fake
	{ key = "tls.crt", value = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJmYWtlCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K" },
	{ key = "blob.bin", value = "AAEC//6JUE5HDQoaCg==" },
	{ key = "ansi", value = "dXNlcj1hZG1pbiAbXTA7cHduZWQHG1szMW1yZWQgdGV4dCBoZXJlIGFuZCBtb3Jl" },
	{ key = "empty", value = "" },
	{ key = "broken", value = "bm90*" },
}

local function render(): Node
	return SecretDataView.card(SecretData.entries(PAIRS), { key = "decoded", hint = "z / Hide decoded" })
end

local function entryNode(root: Node, key: string): Node
	return nodes.find(root, nodes.key("e-" .. key)) :: Node
end

describe("secret_data card", function()
	it("is a display-only card with a banner saying so", function()
		local root = render()
		local card = nodes.find(root, nodes.role("tern-kube.secret-decoded")) :: Node
		expect(card ~= nil).toBe(true)
		expect(nodes.text(card)).toContain("Decoded values")
		local banner = nodes.find(root, nodes.role("tern-kube.secret-decoded-banner")) :: Node
		expect(nodes.text(banner)).toContain("display only: not copied, saved or logged")
		expect(nodes.text(banner)).toContain("z / Hide decoded hides them")
	end)

	-- No copy chip by design; a click action would carry its text into
	-- action strings Tern may log.
	it("carries no actions", function()
		expect(#nodes.actions(render())).toBe(0)
	end)

	it("shows key, size and kind for every value", function()
		local root = render()
		local password = nodes.text(entryNode(root, "password"))
		expect(password).toContain("password")
		expect(password).toContain("12 bytes")
		expect(password).toContain("text")
		expect(password).toContain("hunter2-fake")
		expect(nodes.text(entryNode(root, "empty"))).toContain("(empty)")
	end)

	it("puts multi-line values in a code block", function()
		local code = nodes.find(entryNode(render(), "tls.crt"), nodes.kind("code")) :: Node
		expect((code.p :: any).text).toBe(PEM)
	end)

	it("shows binary as a hex dump", function()
		local blob = entryNode(render(), "blob.bin")
		expect(nodes.text(blob)).toContain("binary")
		local code = nodes.find(blob, nodes.kind("code")) :: Node
		expect((code.p :: any).text).toContain("|......PNG....|")
	end)

	it("never puts a raw control byte on screen", function()
		local ansi = entryNode(render(), "ansi")
		local text = nodes.text(ansi)
		expect(text).toContain("text (escaped)")
		expect(text).toContain("\\x1b]0;pwned")
		expect((string.find(text, "\27", 1, true))).toBeNil()
	end)

	it("warns about invalid base64 and shows it as printed", function()
		local text = nodes.text(entryNode(render(), "broken"))
		expect(text).toContain("invalid base64")
		expect(text).toContain("bm90*")
	end)

	it("says when a value is too large to decode", function()
		local big = string.rep("A", (SecretData.MAX_VALUE // 3 + 1) * 4)
		local root = SecretDataView.card(SecretData.entries({ { key = "big", value = big } }), { hint = "x" })
		expect(nodes.text(root)).toContain("too large to decode here (Raw shows base64)")
	end)

	it("labels the toggle by state", function()
		expect(SecretDataView.label(false, "z")).toBe("Decode values (z)")
		expect(SecretDataView.label(true, "z")).toBe("Hide decoded (z)")
		expect(SecretDataView.label(false, nil)).toBe("Decode values")
	end)
end)

return nil
