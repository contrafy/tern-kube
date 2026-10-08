--!strict
-- Checks bin/kube-lens-drift's awk segmenter against the plugin's
-- diffseg.parse on the same `kubectl diff` output, so the CI report and the
-- Tern views never disagree about which object a line belongs to or whether
-- it is a create, modify or delete. Usage (args after -a):
--   compare DIFF JSON   DIFF = raw diff text + "\n#END" sentinel (keeps
--                       trailing blank lines through `$(cat ...)`),
--                       JSON = the CLI's --format json output.
-- Prints one line per mismatch; exit 1 on any. The one deliberate
-- difference: the CLI redacts the last-applied-configuration line of core
-- Secrets (it holds the applied data in clear); `expected` mirrors that.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Json = require("../../lib/json")

local args = { ... }
local REDACTED = "*** (last-applied-configuration redacted by kube-lens-drift)"

local function expected(seg: Diffseg.Segment): string
	if seg.kind ~= "Secret" or seg.group ~= nil then
		return Diffseg.text(seg)
	end
	local out = {}
	for _, line in seg.lines do
		local c = string.sub(line, 1, 1)
		local header = string.sub(line, 1, 4) == "--- " or string.sub(line, 1, 4) == "+++ "
		local secret = string.find(line, '"kind":"Secret"', 1, true)
			or string.find(line, '\\"kind\\":\\"Secret\\"', 1, true)
		if (c == " " or c == "+" or c == "-") and secret and not header then
			line = c .. (string.match(string.sub(line, 2), "^ *") :: string) .. REDACTED
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n")
end

local failures: { string } = {}

local function check(what: string, want: any, got: any)
	if want ~= got then
		table.insert(failures, string.format("%s: diffseg=%s cli=%s", what, tostring(want), tostring(got)))
	end
end

local raw = args[1]
local sentinel = "\n#END"
assert(string.sub(raw, -#sentinel) == sentinel, "diff argument lacks the #END sentinel")
local text = string.sub(raw, 1, -#sentinel - 1)

local want = Diffseg.parse(text)
local got = Json.decode(args[2])

check("segment count", #want.segments, #got.resources)
check("create", want.create, got.summary.create)
check("modify", want.modify, got.summary.modify)
check("delete", want.delete, got.summary.delete)
check("unknown", want.unknown, got.summary.unknown)
check("added", want.added, got.summary.added)
check("removed", want.removed, got.summary.removed)
check("drift", #want.segments > 0, got.drift)

for i, w in want.segments do
	local g = got.resources[i]
	if g == nil then
		break
	end
	local p = string.format("segment %d (%s)", i, w.key)
	check(p .. " key", w.key, g.key)
	check(p .. " group", w.group, g.group)
	check(p .. " version", w.version, g.version)
	check(p .. " kind", w.kind, g.kind)
	check(p .. " namespace", w.namespace, g.namespace)
	check(p .. " name", w.name, g.name)
	check(p .. " action", w.action, g.action)
	check(p .. " added", w.added, g.added)
	check(p .. " removed", w.removed, g.removed)
	check(p .. " binary", w.binary, g.binary)
	check(p .. " lineCount", #w.lines, g.lineCount)
	check(p .. " truncated", false, g.truncated)
	check(p .. " text", expected(w), table.concat(g.lines, "\n"))
end

check("note count", #want.notes, #got.notes)
for i, n in want.notes do
	check(string.format("note %d", i), n, got.notes[i])
end

for _, f in failures do
	print(f)
end
if #failures > 0 then
	error(string.format("%d mismatch(es)", #failures), 0)
end
