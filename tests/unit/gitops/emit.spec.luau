--!strict
-- Exported YAML is applied by kubectl (go-yaml v2, YAML 1.1 resolution) and
-- read by YAML 1.2 tools (kustomize, editors, linters). A string emitted
-- plain that either version resolves to a bool/number/null/timestamp would
-- silently change the object's type on apply, so the quoting rules are
-- pinned here case by case; the kind round-trip (tests/integration/gitops)
-- proves the whole emitter against the real parser.
local Emit = require("../../../plugin/lib/gitops/emit")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function value(v: any, opts: Emit.Options?): string
	return Emit.yaml({ v = v }, opts)
end

describe("emit.quote", function()
	it("quotes YAML 1.1 and 1.2 bool/null spellings in any case", function()
		for _, s in { "yes", "No", "ON", "off", "y", "N", "true", "False", "null", "NULL", "~", "<<", "=" } do
			expect(Emit.quote(s)).toBe("'" .. s .. "'")
		end
	end)

	it("quotes numbers in every base and form", function()
		for _, s in
			{
				"0",
				"8080",
				"-1",
				"+1",
				"0x1F",
				"0o17",
				"0b101",
				"0777",
				"1e3",
				"1E-3",
				".5",
				"5.",
				"1_000",
				"1.25",
				"1:30",
				"190:20:30.15",
				"0x1p-2",
			}
		do
			expect(Emit.quote(s)).toBe("'" .. s .. "'")
		end
	end)

	it("quotes infinities and NaN with or without dot or sign", function()
		for _, s in { "inf", "-inf", ".inf", "-.Inf", "infinity", "+Infinity", "nan", ".NaN" } do
			expect(Emit.quote(s)).toBe("'" .. s .. "'")
		end
	end)

	it("quotes timestamps", function()
		expect(Emit.quote("2026-10-08")).toBe("'2026-10-08'")
		expect(Emit.quote("2026-10-08T08:10:24Z")).toBe("'2026-10-08T08:10:24Z'")
		expect(Emit.quote("2001-12-14 21:59:43.10 -5")).toBe("'2001-12-14 21:59:43.10 -5'")
	end)

	it("keeps Kubernetes quantities, versions and words plain", function()
		for _, s in { "100m", "10Gi", "v1.25.3", "v1", "nginx:1.25", "app.kubernetes.io/name", "http://x:80/a", "a b" } do
			expect(Emit.quote(s)).toBe(s)
		end
	end)

	it("quotes every special leading indicator", function()
		for _, c in string.split("-?:,[]{}#&*!|>'\"%@`", "") do
			local s = c .. "x"
			local q = Emit.quote(s)
			expect(q == s).toBe(false)
		end
		expect(Emit.quote("-x")).toBe("'-x'")
		expect(Emit.quote("it's")).toBe("it's")
		expect(Emit.quote("'a'")).toBe("'''a'''")
	end)

	it("quotes mapping and comment indicators inside", function()
		expect(Emit.quote("a: b")).toBe("'a: b'")
		expect(Emit.quote("a #b")).toBe("'a #b'")
		expect(Emit.quote("a:")).toBe("'a:'")
		expect(Emit.quote("a#b")).toBe("a#b")
		expect(Emit.quote("a:b")).toBe("a:b")
	end)

	it("quotes empty strings and edge whitespace", function()
		expect(Emit.quote("")).toBe("''")
		expect(Emit.quote(" a")).toBe("' a'")
		expect(Emit.quote("a ")).toBe("'a '")
	end)

	it("double-quotes tabs and control characters with escapes", function()
		expect(Emit.quote("a\tb")).toBe('"a\\tb"')
		expect(Emit.quote("a\0b\27")).toBe('"a\\0b\\e"')
		expect(Emit.quote("x\1")).toBe('"x\\x01"')
		expect(Emit.quote('q"\\')).toBe('q"\\')
		expect(Emit.quote('\tq"\\')).toBe('"\\tq\\"\\\\"')
		expect(Emit.quote("a\226\128\168b")).toBe('"a\\Lb"')
		expect(Emit.quote("\239\187\191a")).toBe('"\\uFEFFa"')
		expect(Emit.quote("a\194\133")).toBe('"a\\N"')
	end)

	it("passes other unicode through unquoted", function()
		expect(Emit.quote("café ☕")).toBe("café ☕")
	end)
end)

describe("emit.yaml scalars", function()
	it("emits numbers without float noise and integers exactly", function()
		expect(value(5432)).toBe("v: 5432\n")
		expect(value(0.5)).toBe("v: 0.5\n")
		expect(value(0.1)).toBe("v: 0.1\n")
		expect(value(-3)).toBe("v: -3\n")
		expect(value(1e21)).toBe("v: 1e+21\n")
	end)

	it("emits booleans and the injected null", function()
		local null = table.freeze({})
		expect(Emit.yaml({ a = true, b = false, c = null }, { null = null })).toBe("a: true\nb: false\nc: null\n")
	end)

	it("uses clip literal blocks for text ending in one newline", function()
		expect(value("a\nb\n")).toBe("v: |\n  a\n  b\n")
	end)

	it("uses strip and keep chomping to preserve trailing newlines exactly", function()
		expect(value("a\nb")).toBe("v: |-\n  a\n  b\n")
		expect(value("a\n\n")).toBe("v: |+\n  a\n\n")
	end)

	it("adds an indentation indicator when the text starts with spaces or a blank line", function()
		expect(value("  a\nb\n")).toBe("v: |2\n    a\n  b\n")
		expect(value("\na\n")).toBe("v: |2\n\n  a\n")
	end)

	it("keeps empty lines inside literal blocks unindented", function()
		expect(value("a\n\nb\n")).toBe("v: |\n  a\n\n  b\n")
	end)

	it("falls back to double quotes when a literal block cannot round-trip", function()
		expect(value("a\r\nb")).toBe('v: "a\\r\\nb"\n')
		expect(value("a \nb")).toBe('v: "a \\nb"\n')
		expect(value("\tx\ny")).toBe('v: "\\tx\\ny"\n')
		expect(value("\n\n")).toBe('v: "\\n\\n"\n')
	end)

	it("quotes keys with the same rules as values", function()
		expect(Emit.yaml({ y = 1, ["8080"] = "x", ["a: b"] = "c" })).toBe("'8080': x\n'a: b': c\n'y': 1\n")
	end)
end)

describe("emit.yaml structure", function()
	it("orders top-level and metadata keys like hand-written manifests", function()
		local obj = {
			zeta = 1,
			data = { b = "2", a = "1" },
			spec = { x = 1 },
			metadata = { annotations = { a = "b" }, labels = { l = "v" }, uid = "u", namespace = "ns", name = "cfg" },
			kind = "ConfigMap",
			apiVersion = "v1",
			alpha = 1,
		}
		expect(Emit.yaml(obj)).toBe(table.concat({
			"apiVersion: v1",
			"kind: ConfigMap",
			"metadata:",
			"  name: cfg",
			"  namespace: ns",
			"  labels:",
			"    l: v",
			"  annotations:",
			"    a: b",
			"  uid: u",
			"spec:",
			"  x: 1",
			"data:",
			"  a: '1'",
			"  b: '2'",
			"alpha: 1",
			"zeta: 1",
			"",
		}, "\n"))
	end)

	it("emits lists of maps in dash style with name first", function()
		local obj = { containers = { { image = "nginx", name = "web", ports = { { containerPort = 80 } } } } }
		expect(Emit.yaml(obj)).toBe(table.concat({
			"containers:",
			"  - name: web",
			"    image: nginx",
			"    ports:",
			"      - containerPort: 80",
			"",
		}, "\n"))
	end)

	it("emits nested lists and block scalars inside lists", function()
		expect(Emit.yaml({ x = { { "a", "b" } :: any, "l1\nl2\n", "  i\n" } })).toBe(table.concat({
			"x:",
			"  - - a",
			"    - b",
			"  - |",
			"    l1",
			"    l2",
			"  - |2",
			"      i",
			"",
		}, "\n"))
	end)

	it("emits empty maps as {} and empty lists as [] when the injected predicate says so", function()
		local list = {}
		local opts: Emit.Options = {
			isList = function(tbl)
				return tbl == list
			end,
		}
		expect(Emit.yaml({ a = {}, b = list }, opts)).toBe("a: {}\nb: []\n")
		expect(Emit.yaml({ x = { {} } })).toBe("x:\n  - {}\n")
	end)

	it("prefixes comment lines", function()
		expect(Emit.yaml({ a = 1 }, { comments = { "hello", "" } })).toBe("# hello\n#\na: 1\n")
	end)

	it("is deterministic regardless of table insertion order", function()
		local a = { metadata = { name = "x" }, kind = "K", apiVersion = "v1" }
		local b = { apiVersion = "v1", kind = "K", metadata = { name = "x" } }
		expect(Emit.yaml(a)).toBe(Emit.yaml(b))
	end)
end)

return nil
