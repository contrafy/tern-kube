--!strict
-- Independent reader of a guard request (shell/PROTOCOL.md), so the tests
-- check the sh core's JSON escaping and fingerprint against the documented
-- format rather than against itself, and against the plugin's own
-- canonicalisation (plugin/lib/mutation/fingerprint.luau). Usage (args
-- after -a):
--   canon JSON            print the canonical fingerprint string
--   canon-plugin JSON     the same, built by plugin/lib/mutation/fingerprint
--   argv JSON A1 A2 ...   exit 1 unless request.argv equals A1 A2 ...
--   files JSON            print each request.files path
--   field JSON NAME       print a top-level scalar ("null" for null)
--   strict JSON           exit 1 unless JSON is one object with exactly the documented keys
local Fingerprint = require("../../../plugin/lib/mutation/fingerprint")

local NULL = newproxy(false)

local function decode(s: string): any
	local pos = 1
	local function fail(msg: string): never
		error(string.format("json: %s at byte %d", msg, pos))
	end
	local function ws()
		pos = string.find(s, "[^ \t\r\n]", pos) or #s + 1
	end
	local value: () -> any
	local function str(): string
		pos += 1
		local out = {}
		while true do
			local c = string.sub(s, pos, pos)
			if c == "" then
				fail("unterminated string")
			elseif c == '"' then
				pos += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(s, pos + 1, pos + 1)
				local map =
					{ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				if map[e] then
					table.insert(out, map[e])
					pos += 2
				elseif e == "u" then
					local hex = string.sub(s, pos + 2, pos + 5)
					local cp = tonumber(hex, 16)
					if cp == nil or #hex ~= 4 then
						fail("bad \\u escape")
					end
					table.insert(out, utf8.char(cp :: number))
					pos += 6
				else
					fail("bad escape")
				end
			elseif string.byte(c) < 32 then
				fail("raw control byte in string")
			else
				table.insert(out, c)
				pos += 1
			end
		end
	end
	function value(): any
		ws()
		local c = string.sub(s, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			ws()
			if string.sub(s, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				ws()
				if string.sub(s, pos, pos) ~= '"' then
					fail("expected key")
				end
				local k = str()
				ws()
				if string.sub(s, pos, pos) ~= ":" then
					fail("expected colon")
				end
				pos += 1
				if obj[k] ~= nil then
					fail("duplicate key " .. k)
				end
				obj[k] = value()
				ws()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				elseif d ~= "," then
					fail("expected , or }")
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			ws()
			if string.sub(s, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, value())
				ws()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				elseif d ~= "," then
					fail("expected , or ]")
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, pos, pos + 3) == "null" then
			pos += 4
			return NULL
		else
			local num = string.match(s, "^-?%d+", pos)
			if num == nil then
				fail("unexpected token")
			end
			pos += #(num :: string)
			return tonumber(num)
		end
	end
	local v = value()
	ws()
	if pos <= #s then
		fail("trailing data")
	end
	return v
end

local function field(name: string, v: string): string
	return string.format("%s %d:%s\n", name, #v, v)
end

local function canon(r: any): string
	local out = { "tern-kube/fp/v1\n", string.format("argv %d\n", #r.argv) }
	for _, a in r.argv do
		table.insert(out, string.format("%d:%s\n", #a, a))
	end
	table.insert(out, field("context", r.context))
	table.insert(out, if r.kubeconfig == NULL then "kubeconfig -\n" else field("kubeconfig", r.kubeconfig))
	table.insert(out, field("namespace", if r.namespace == NULL then "" else r.namespace))
	table.insert(out, field("cwd", r.cwd))
	type File = { path: string, size: number, sha256: string }
	local files: { File } = table.clone(r.files)
	table.sort(files, function(a: File, b: File): boolean
		return a.path < b.path
	end)
	table.insert(out, string.format("files %d\n", #files))
	for _, f in files do
		table.insert(out, string.format("%d:%s %d %s\n", #f.path, f.path, f.size, f.sha256))
	end
	return table.concat(out)
end

local KEYS = {
	"version",
	"nonce",
	"argv",
	"program",
	"cwd",
	"kubeconfig",
	"context",
	"context_source",
	"namespace",
	"pane",
	"files",
	"fingerprint",
	"created_at",
	"timeout_s",
}

local args = { ... }
local mode, r = args[1], decode(args[2])
if mode == "canon" then
	local c = canon(r)
	print(string.sub(c, 1, -2))
elseif mode == "canon-plugin" then
	local files = {}
	for _, f in r.files do
		table.insert(files, { path = f.path, size = f.size, sha256 = f.sha256 })
	end
	local c, e = Fingerprint.canonical({
		argv = r.argv,
		context = r.context,
		kubeconfig = if r.kubeconfig == NULL then nil else r.kubeconfig,
		namespace = if r.namespace == NULL then nil else r.namespace,
		cwd = r.cwd,
		files = files,
	})
	if c == nil then
		error(e, 0)
	end
	print(string.sub(c, 1, -2))
elseif mode == "argv" then
	if #r.argv ~= #args - 2 then
		error(string.format("argv has %d elements, want %d", #r.argv, #args - 2), 0)
	end
	for i, a in r.argv do
		if a ~= args[i + 2] then
			error(string.format("argv[%d] = %q, want %q", i, a, args[i + 2]), 0)
		end
	end
elseif mode == "files" then
	for _, f in r.files do
		print(f.path)
	end
elseif mode == "field" then
	local v = r[args[3]]
	print(if v == NULL then "null" else tostring(v))
elseif mode == "strict" then
	local n = 0
	for _ in r do
		n += 1
	end
	for _, k in KEYS do
		if r[k] == nil then
			error("missing key " .. k, 0)
		end
	end
	if n ~= #KEYS then
		error("unexpected keys", 0)
	end
else
	error("unknown mode " .. tostring(mode))
end
