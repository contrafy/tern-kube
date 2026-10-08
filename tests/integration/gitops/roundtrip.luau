--!strict
-- Driver for roundtrip.sh (standalone luau has no file IO, so fixtures come
-- from the embedded table and kubectl output arrives as an argument):
--   roundtrip.luau -a list                    fixture paths with objects
--   roundtrip.luau -a emit <fixture>          cleaned objects as multi-doc YAML
--   roundtrip.luau -a compare <fixture> <json> kubectl's parse == cleaned input
local Clean = require("../../../plugin/lib/gitops/clean")
local Emit = require("../../../plugin/lib/gitops/emit")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")

local PREFIX = "real/json-world/"

local args = { ... }
local mode = args[1]

-- Every quoting/block-scalar edge the emitter handles, parsed by the real
-- kubectl (go-yaml v2) instead of our own expectations.
local EDGE_STRINGS: { string } = {
	"yes",
	"No",
	"ON",
	"off",
	"y",
	"n",
	"true",
	"False",
	"null",
	"~",
	"<<",
	"=",
	"0",
	"8080",
	"-1",
	"+1",
	"0x1F",
	"0o17",
	"0b101",
	"0777",
	"1e3",
	".5",
	"5.",
	"1_000",
	"1.25",
	"1:30",
	"inf",
	"-.Inf",
	"infinity",
	".nan",
	"2026-10-08",
	"2026-10-08T08:10:24Z",
	"-x",
	"?x",
	":x",
	",x",
	"[x",
	"]x",
	"{x",
	"}x",
	"#x",
	"&x",
	"*x",
	"!x",
	"|x",
	">x",
	"'x",
	'"x',
	"%x",
	"@x",
	"`x",
	"a: b",
	"a #b",
	"a:",
	"a#b",
	"a:b",
	"",
	" lead",
	"trail ",
	"a\tb",
	"ctl\1\27",
	"it's",
	'q"\\',
	"line\226\128\168sep",
	"\239\187\191bom",
	"nel\194\133",
	"café ☕ こんにちは",
	"a\nb\n",
	"a\nb",
	"a\n\n",
	"  lead\nnext\n",
	"\nblank first\n",
	"a\n\nb\n",
	"a\r\nb",
	"a \nb",
	"\tx\ny",
	"\n\n",
	"100m",
	"10Gi",
	"v1.25.3",
	"nginx:1.25",
	"http://x:80/a",
}

local function edge(): ({ any }, { [any]: true })
	local data: { [string]: string } = {}
	for i, s in EDGE_STRINGS do
		data[string.format("k%03d", i)] = s
	end
	local emptyList = {}
	local obj = {
		apiVersion = "v1",
		kind = "ConfigMap",
		metadata = {
			name = "tern-kube-emit-edge",
			namespace = "tern-test-gitops",
			labels = { y = "n", ["8080"] = "true" },
			annotations = { ["a: b"] = "x", nested = "l1\nl2\n" },
		},
		data = data,
		extra = {
			emptyMap = {},
			emptyList = emptyList,
			nested = { { "a", { b = "c" } :: any } :: any, "  i\n" },
			num = 0.1,
		},
	}
	return { obj }, { [emptyList] = true }
end

local function cleaned(path: string): ({ any }, { [any]: true })
	if path == "@edge" then
		return edge()
	end
	local list, arrays = json.decodeTracking(fixtures.read(path))
	local out = {}
	for _, item in list.items do
		local obj = Clean.clean(item)
		if obj then
			table.insert(out, obj)
		end
	end
	return out, arrays
end

-- Deep equality that also tells arrays from objects; returns the first
-- differing path.
local function diff(a: any, b: any, aArrays: { [any]: true }, bArrays: { [any]: true }, path: string): string?
	if type(a) ~= type(b) then
		return path .. ": " .. type(a) .. " vs " .. type(b)
	end
	if type(a) ~= "table" then
		return if a == b then nil else string.format("%s: %q vs %q", path, tostring(a), tostring(b))
	end
	if next(a) == nil and next(b) == nil and (aArrays[a] == true) ~= (bArrays[b] == true) then
		return path .. ": [] vs {}"
	end
	for k, v in a do
		local d = diff(v, b[k], aArrays, bArrays, path .. "." .. tostring(k))
		if d then
			return d
		end
	end
	for k in b do
		if a[k] == nil then
			return path .. "." .. tostring(k) .. ": missing in input"
		end
	end
	return nil
end

if mode == "list" then
	for _, path in fixtures.list(PREFIX) do
		if string.find(path, "%-o_json%.txt$") and #(cleaned(path)) > 0 then
			print(path)
		end
	end
elseif mode == "emit" then
	local objects, arrays = cleaned(args[2])
	local opts: Emit.Options = {
		isList = function(t)
			return arrays[t] == true
		end,
	}
	local docs = {}
	for _, obj in objects do
		table.insert(docs, Emit.yaml(obj, opts))
	end
	local text = table.concat(docs, "---\n")
	print(string.sub(text, 1, -2))
elseif mode == "compare" then
	local objects, arrays = cleaned(args[2])
	-- kubectl prints one pretty JSON object per document, each closing with
	-- `}` at column 0.
	local got = {}
	local parsedArrays: { [any]: true } = {}
	for _, chunk in string.split(string.gsub(args[3], "\n}\n", "\n}\n\0"), "\0") do
		if string.find(chunk, "%S") then
			local obj, tracked = json.decodeTracking(chunk)
			for t in tracked do
				parsedArrays[t] = true
			end
			table.insert(got, obj)
		end
	end
	if #got ~= #objects then
		error(string.format("%s: kubectl returned %d objects, expected %d", args[2], #got, #objects), 0)
	end
	for i, obj in objects do
		local d = diff(obj, got[i], arrays, parsedArrays, obj.kind .. "/" .. obj.metadata.name)
		if d then
			error(args[2] .. ": " .. d, 0)
		end
	end
	print(string.format("ok %s (%d objects)", args[2], #objects))
else
	error("usage: roundtrip.luau -a list|emit <fixture>|compare <fixture> <json>", 0)
end

return nil
