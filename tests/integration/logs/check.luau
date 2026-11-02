--!strict
-- One live `kubectl logs` run through the logs store, as the lens receives
-- it (stderr first: kubectl prints Found/Defaulted before fetching logs).
-- Called by check.sh with the captured text as arguments (standalone luau
-- has no file I/O):
--
--   luau check.luau -a NAME EXPECT STATUS ARGV STDOUT STDERR
--
-- EXPECT: pod | found | prefixed | unattributed | previous | failed.
-- Raises (non-zero exit) with the reason on the first failed assertion.
local json = require("../../lib/json")
local Argv = require("../../../plugin/lib/kubectl/argv")
local Parse = require("../../../plugin/lib/logs/parse")
local Store = require("../../../plugin/lib/logs/store")

local args: { string } = { ... }
local name, expectKind, statusText, argvText, stdout, stderr =
	args[1], args[2], args[3], args[4], args[5] or "", args[6] or ""
assert(name and expectKind and statusText and argvText, "usage: check.luau -a NAME EXPECT STATUS ARGV STDOUT STDERR")
local status = tonumber(statusText) or -1

local function fail(msg: string): never
	error(string.format("FAIL %s: %s", name, msg), 0)
end

local function check(ok: boolean, msg: string)
	if not ok then
		fail(msg)
	end
end

-- Lines as Tern delivers them: no terminators, trailing blank lines dropped.
local function toLines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(out, (string.gsub(line, "\r$", "")))
	end
	while #out > 0 and string.find(out[#out], "^%s*$") do
		table.remove(out)
	end
	return out
end

local words: { string } = {}
for w in string.gmatch(argvText, "%S+") do
	table.insert(words, w)
end
local program = table.remove(words, 1) :: string
local inv = Argv.parse(program, words)
check(inv.verb == "logs", "not a logs command: " .. argvText)

local lines: { string } = {}
for _, l in toLines(stderr) do
	table.insert(lines, l)
end
for _, l in toLines(stdout) do
	table.insert(lines, l)
end

local s = Store.new(Parse.optionsFor(inv, json.decode), { maxLines = 1e9, maxBytes = 1e12 })
for _, l in lines do
	Store.push(s, l)
end
Store.finish(s, status)

local extras, kubectlLines = 0, 0
for i = s.first, s.last do
	extras += #(s.records[i].extra or {})
end
for _, l in lines do
	if Parse.diagnostic(l, "start") or (status ~= 0 and Parse.diagnostic(l, "end")) or Parse.isPromptMark(l) then
		kubectlLines += 1
	end
end
check(
	Store.size(s) + extras + kubectlLines == #lines,
	string.format(
		"%d records + %d continuation + %d kubectl lines ~= %d lines",
		Store.size(s),
		extras,
		kubectlLines,
		#lines
	)
)

local KUBECTL = { "error: ", "Error from server", "Defaulted container", "Found ", "unable to retrieve", "Warning: " }
local jsonErrors = 0
for i = s.first, s.last do
	local r = s.records[i]
	for _, p in KUBECTL do
		check(string.sub(r.raw, 1, #p) ~= p, "kubectl diagnostic parsed as a record: " .. r.raw)
	end
	if string.find(r.raw, '"level":"error"', 1, true) then
		jsonErrors += 1
		check(r.format == "json" and r.level == "error", "JSON error line not classified error: " .. r.raw)
	end
end

local function noticeKinds(): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, n in s.notices do
		set[n.kind] = true
	end
	return set
end

local function distinct(field: "pod" | "container"): number
	local set: { [string]: boolean } = {}
	local n = 0
	for _, src in s.sources do
		local v = src[field]
		if v and not set[v] then
			set[v] = true
			n += 1
		end
	end
	return n
end

if expectKind == "failed" then
	check(status ~= 0, "expected a failing exit status, got " .. status)
	check(Store.size(s) == 0, string.format("failed run left %d records", Store.size(s)))
	check(noticeKinds().error == true, "failed run has no error notice")
else
	check(status == 0, "unexpected exit status " .. status)
end

if expectKind == "pod" or expectKind == "found" then
	check(Store.size(s) > 0, "no records")
	check(jsonErrors > 0, "no JSON error lines seen (tk-logmix prints one every 4 s)")
	check(#s.sources == 1, string.format("expected 1 source, got %d", #s.sources))
	local src = s.sources[1]
	check(src.pod ~= nil and src.container == "app", "source is not <pod>/app")
	for i = s.first, s.last do
		check(s.records[i].source == 1, "unattributed record: " .. s.records[i].raw)
	end
	if inv.flags.container == nil then
		check(noticeKinds()["defaulted-container"] == true, "missing Defaulted container notice")
	end
	if expectKind == "found" then
		check(noticeKinds()["found-pods"] == true, "missing Found N pods notice")
	end
elseif expectKind == "prefixed" then
	check(Store.size(s) > 0, "no records")
	check(jsonErrors > 0, "no JSON error lines seen")
	local wantPods = if inv.selector or inv.flags["all-pods"] then 2 else 1
	local wantContainers = if inv.flags["all-containers"] then 3 else 1
	check(distinct("pod") == wantPods, string.format("expected %d pods, got %d", wantPods, distinct("pod")))
	check(
		distinct("container") == wantContainers,
		string.format("expected %d containers, got %d", wantContainers, distinct("container"))
	)
	check(#s.sources == wantPods * wantContainers, string.format("expected %d sources", wantPods * wantContainers))
	for i = s.first, s.last do
		local r = s.records[i]
		check(r.source ~= 0, "unattributed prefixed record: " .. r.raw)
		check(not s.opts.timestamps or r.ts ~= nil, "record without kubelet time: " .. r.raw)
	end
elseif expectKind == "unattributed" then
	check(Store.size(s) > 0, "no records")
	check(jsonErrors > 0, "no JSON error lines seen")
elseif expectKind == "previous" then
	-- The previous crashy instance's log may already be gone (kubectl then
	-- prints `unable to retrieve container logs` on stdout with exit 0).
	if Store.size(s) == 0 then
		check(noticeKinds().error == true, "no records and no error notice")
	else
		local panic = false
		for i = s.first, s.last do
			local r = s.records[i]
			if string.find(r.message, "^panic: ") then
				panic = true
				check(r.level == "error", "panic line not an error")
			end
		end
		check(panic, "previous crashy log has no panic line")
	end
elseif expectKind ~= "failed" then
	fail("unknown EXPECT " .. expectKind)
end

print(
	string.format(
		"ok   %-40s %4d records %3d sources %d notices%s",
		name,
		Store.size(s),
		#s.sources,
		#s.notices,
		if #s.notices > 0 then " (" .. s.notices[1].kind .. ")" else ""
	)
)
