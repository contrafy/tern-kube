--!strict
-- Driver for check.sh. Standalone luau has no file I/O, so check.sh embeds
-- each live kubectl run (argv one word per line, stdout+stderr as the lens
-- gets them, the stdout tab-expanded, the exit status) with the truth kubectl
-- gave by other means, and calls this function with them.
local Capture = require("../../../plugin/lib/lens/capture")
local Discovery = require("../../../plugin/lib/kubectl/discovery")
local TableParser = require("../../../plugin/lib/parse/table")
local fixtures = require("../../lib/fixtures")
local inspect = require("../../lib/inspect")
local json = require("../../lib/json")

export type Form = {
	name: string,
	command: string,
	status: number,
	text: string,
	expanded: string,
	stdout: string,
	truth: string,
}

local function words(text: string): { string }
	local out: { string } = {}
	for w in string.gmatch(text, "[^\n]+") do
		table.insert(out, w)
	end
	return out
end

local function build(f: Form, text: string): Capture.Capture
	local args = words(f.command)
	return Capture.build(
		{ program = "kubectl", args = args },
		fixtures.toLines(text),
		f.status,
		{ decode = json.decode }
	)
end

local function rows(c: Capture.Capture): { any }
	local out: { any } = {}
	for _, tbl in (if c.snapshot then c.snapshot.tables else {}) :: { any } do
		for _, row in tbl.rows do
			table.insert(out, row)
		end
	end
	return out
end

-- No kubectl message (Warning:, error:, ...) may be a row.
local function messageRows(c: Capture.Capture): { string }
	local out: { string } = {}
	for _, row in rows(c) do
		for _, n in row.rawLines do
			local line = c.lines[n]
			if line and TableParser.classify(line) then
				table.insert(out, line)
			end
		end
	end
	return out
end

local function same(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for i, v in a do
		if b[i] ~= v then
			return false
		end
	end
	return true
end

local function sorted(list: { string }): { string }
	local out = table.clone(list)
	table.sort(out)
	return out
end

local function checkOne(f: Form, fail: (string) -> ())
	local label = f.name .. ": kubectl " .. table.concat(words(f.command), " ")
	local c = build(f, f.text)
	for _, m in messageRows(c) do
		fail(label .. ": kubectl message became a row: " .. m)
	end
	if f.name ~= "cani" and c.unparsed > 0 then
		fail(string.format("%s: %d unparsed lines", label, c.unparsed))
	end
	local truth = words(f.truth)
	if f.name == "history" then
		local revs: { string } = {}
		for _, row in rows(c) do
			table.insert(revs, row.cells[1])
		end
		if c.mode ~= "history" or not same(revs, truth) then
			fail(
				label
					.. ": revisions "
					.. table.concat(revs, ",")
					.. " but ReplicaSets say "
					.. table.concat(truth, ",")
			)
		end
	elseif f.name == "revision" then
		local expanded = build(f, f.expanded)
		local info = c.k9s and c.k9s.revision
		if c.mode ~= "revision" or info == nil then
			fail(label .. ": no revision view")
			return
		end
		if inspect.firstDifference(c.describe, expanded.describe) ~= nil then
			fail(label .. ": raw-tab and tab-expanded output parse differently")
		end
		if not same(info.images, truth) then
			fail(label .. ": images " .. table.concat(info.images, ",") .. " but the ReplicaSet runs " .. f.truth)
		end
		if #c.diagnostics > 0 then
			fail(label .. ": diagnostics " .. c.diagnostics[1].text)
		end
	elseif f.name == "contexts" then
		local names: { string } = {}
		local d = c.k9s
		for _, row in rows(c) do
			local ctx = d and d.contexts and d.contexts[row.key]
			table.insert(names, if ctx then ctx.name else "?")
		end
		if not same(sorted(names), sorted(truth)) then
			fail(label .. ": contexts " .. table.concat(names, "|") .. " but -o name says " .. table.concat(truth, "|"))
		end
	elseif f.name == "apiresources" then
		local names: { string } = {}
		local d = c.k9s
		for _, row in rows(c) do
			local k = d and d.kinds and d.kinds[row.key]
			table.insert(names, if k then k.name else "?")
		end
		if not same(sorted(names), truth) then
			fail(string.format("%s: %d rows, -o name lists %d", label, #names, #truth))
		end
	elseif f.name == "discovery" then
		local parsed = Discovery.parse(f.stdout, nil, f.status)
		local names: { string } = {}
		for _, r in parsed.rows do
			table.insert(names, r.name)
		end
		if not same(sorted(names), truth) or #parsed.diagnostics > 0 then
			fail(
				string.format("%s: Discovery.parse read %d rows, --verbs=list -o name lists %d", label, #names, #truth)
			)
		end
	elseif f.name == "cani" then
		local info = c.k9s and c.k9s.cani
		local got = if info then info.answer.answer else nil
		if got ~= truth[1] then
			fail(label .. ": answered " .. tostring(got) .. ", the exit status says " .. tostring(truth[1]))
		end
	elseif f.name == "canilist" then
		local n = #rows(c)
		if tostring(n) ~= truth[1] then
			fail(string.format("%s: %d rules, --no-headers prints %s", label, n, tostring(truth[1])))
		end
	end
end

return function(forms: { Form })
	local failures: { string } = {}
	local counts: { [string]: number } = {}
	for _, f in forms do
		checkOne(f, function(msg: string)
			table.insert(failures, msg)
		end)
		counts[f.name] = (counts[f.name] or 0) + 1
	end
	local summary: { string } = {}
	for name, n in counts do
		table.insert(summary, name .. "=" .. n)
	end
	table.sort(summary)
	print("k9s check: " .. #forms .. " forms (" .. table.concat(summary, " ") .. "), " .. #failures .. " problems")
	if #failures > 0 then
		error("k9s check failed:\n  " .. table.concat(failures, "\n  "), 0)
	end
end
