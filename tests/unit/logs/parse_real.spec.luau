--!strict
-- Every captured `kubectl logs` form (tests/fixtures/real/ns-logs, real
-- kubectl against tk-logmix) through the store as the lens receives it:
-- stderr first (kubectl prints Found/Defaulted before fetching logs), then
-- stdout, then the exit status. Keys are discovered from the embedded files
-- so a recapture with new pod names needs no spec change.
local t = require("../../lib/test")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local runs = require("../../lib/runs")
local Argv = require("../../../plugin/lib/kubectl/argv")
local Parse = require("../../../plugin/lib/logs/parse")
local Store = require("../../../plugin/lib/logs/store")
local T = require("../../../plugin/lib/logs/types")
local describe, it, expect = t.describe, t.it, t.expect

local DIR = "real/ns-logs/"

type Case = {
	key: string,
	inv: any,
	stdout: { string },
	lines: { string },
	status: number,
	store: Store.Store,
}

local function load(key: string): Case
	local base = DIR .. key
	local stdout: { string } = if fixtures.has(base .. ".txt") then fixtures.lines(base .. ".txt") else {}
	local lines: { string } = {}
	if fixtures.has(base .. ".stderr") then
		for _, l in fixtures.lines(base .. ".stderr") do
			table.insert(lines, l)
		end
	end
	for _, l in stdout do
		table.insert(lines, l)
	end
	local f = runs.load("ns-logs/" .. key)
	local inv = Argv.parse(f.run.program, f.run.args)
	local s = Store.new(Parse.optionsFor(inv, json.decode), { maxLines = 1e9, maxBytes = 1e12 })
	for _, l in lines do
		Store.push(s, l)
	end
	Store.finish(s, f.status)
	return { key = key, inv = inv, stdout = stdout, lines = lines, status = f.status, store = s }
end

local function cases(): { Case }
	local seen: { [string]: boolean } = {}
	local out: { Case } = {}
	for _, path in fixtures.list(DIR .. "logs") do
		local key = string.match(string.sub(path, #DIR + 1), "^(.-)%.[^.]+$") :: string
		if not seen[key] then
			seen[key] = true
			table.insert(out, load(key))
		end
	end
	return out
end

local CASES = cases()

local function has(c: Case, flag: string): boolean
	return c.inv.flags[flag] ~= nil
end

local function each(fn: (Case, T.Record) -> ())
	for _, c in CASES do
		for i = c.store.first, c.store.last do
			fn(c, c.store.records[i])
		end
	end
end

local KUBECTL_STARTS = { "error: ", "Error from server", "Defaulted container", "Found ", "unable to retrieve" }

describe("logs real fixtures", function()
	it("covers the captured logs forms", function()
		expect(#CASES >= 15).toBe(true)
	end)

	it("accounts for every line as a record, a continuation or a kubectl line", function()
		for _, c in CASES do
			local s = c.store
			local extras = 0
			for i = s.first, s.last do
				extras += #(s.records[i].extra or {})
			end
			local kubectl = 0
			for _, l in c.lines do
				local end_ = c.status ~= 0 and Parse.diagnostic(l, "end")
				if Parse.diagnostic(l, "start") or end_ or Parse.isPromptMark(l) then
					kubectl += 1
				end
			end
			if Store.size(s) + extras + kubectl ~= #c.lines then
				error(
					string.format(
						"%s: %d records + %d extra + %d kubectl ~= %d lines",
						c.key,
						Store.size(s),
						extras,
						kubectl,
						#c.lines
					)
				)
			end
			expect(s.lines).toBe(#c.lines)
		end
	end)

	it("never shows a kubectl diagnostic as a record", function()
		each(function(c: Case, r: T.Record)
			for _, p in KUBECTL_STARTS do
				if string.sub(r.raw, 1, #p) == p or string.sub(r.message, 1, #p) == p then
					error(c.key .. ": kubectl line became a record: " .. r.raw)
				end
			end
		end)
	end)

	it('classifies every JSON `"level":"error"` line as error, prefixed and timestamped or not', function()
		local n = 0
		each(function(c: Case, r: T.Record)
			if string.find(r.raw, '"level":"error"', 1, true) then
				n += 1
				if r.level ~= "error" or r.format ~= "json" then
					error(c.key .. ": not a JSON error: " .. r.raw)
				end
			end
		end)
		expect(n > 0).toBe(true)
	end)

	it("parses the sampler's klog, logfmt and Java lines with their structure", function()
		local seen: { [string]: boolean } = {}
		each(function(_c: Case, r: T.Record)
			if r.format == "klog" and r.location == "controller.go:42" then
				expect(r.message).toBe("Starting workers")
				seen.klog = true
			elseif r.format == "logfmt" and r.message == "slow request" then
				expect(r.level).toBe("warn")
				seen.logfmt = true
			elseif string.find(r.message, "IllegalStateException", 1, true) then
				expect(r.level).toBe("error")
				expect(#(r.extra or {})).toBe(2)
				seen.java = true
			end
		end)
		expect(seen).toEqual({ klog = true, logfmt = true, java = true })
	end)

	it("keeps the 3000-char line intact in raw for Copy line", function()
		local n = 0
		for _, c in CASES do
			for _, l in c.stdout do
				if string.find(l, "long: xxxxxxxxxx", 1, true) and #l > 3000 then
					local found = false
					for i = c.store.first, c.store.last do
						if c.store.records[i].raw == l then
							found = true
						end
					end
					if not found then
						error(c.key .. ": long line not kept intact")
					end
					n += 1
				end
			end
		end
		expect(n > 0).toBe(true)
	end)

	it("attributes prefixed forms to the pod/container prefixes kubectl printed", function()
		for _, c in CASES do
			if not has(c, "prefix") or c.status ~= 0 then
				continue
			end
			local pods: { [string]: boolean } = {}
			local containers: { [string]: boolean } = {}
			local expected: { [string]: boolean } = {}
			for _, l in c.stdout do
				local pod, container = Parse.splitPrefix(l)
				if pod and container then
					expected[pod .. "/" .. container] = true
				end
			end
			local got: { [string]: boolean } = {}
			for _, src in c.store.sources do
				got[(src.pod :: string) .. "/" .. (src.container :: string)] = true
				pods[src.pod :: string] = true
				containers[src.container :: string] = true
			end
			expect(got).toEqual(expected)
			local npods, ncontainers = 0, 0
			for _ in pods do
				npods += 1
			end
			for _ in containers do
				ncontainers += 1
			end
			local multi = c.inv.selector ~= nil or has(c, "all-pods")
			local wantPods = if multi then 2 else 1
			local wantContainers = if has(c, "all-containers") then 3 else 1
			expect(c.key .. " pods=" .. npods).toBe(c.key .. " pods=" .. wantPods)
			expect(c.key .. " containers=" .. ncontainers).toBe(c.key .. " containers=" .. wantContainers)
			for i = c.store.first, c.store.last do
				if c.store.records[i].source == 0 then
					error(c.key .. ": unattributed prefixed line " .. c.store.records[i].raw)
				end
			end
		end
	end)

	it("attributes single-pod unprefixed forms to one pod/container source", function()
		local n = 0
		for _, c in CASES do
			if has(c, "prefix") or c.inv.selector or has(c, "all-containers") or Store.size(c.store) == 0 then
				continue
			end
			n += 1
			expect(c.key .. " sources=" .. #c.store.sources).toBe(c.key .. " sources=1")
			local src = c.store.sources[1]
			expect(src.pod ~= nil and src.container ~= nil).toBe(true)
			for i = c.store.first, c.store.last do
				expect(c.store.records[i].source).toBe(1)
			end
		end
		expect(n > 0).toBe(true)
	end)

	it("leaves `-l` without --prefix unattributed and notes the defaulted container once", function()
		for _, c in CASES do
			if c.inv.selector and not has(c, "prefix") and c.status == 0 then
				expect(#c.store.sources).toBe(0)
				local defaulted = 0
				for _, n in c.store.notices do
					if n.kind == "defaulted-container" then
						defaulted += 1
					end
				end
				expect(defaulted).toBe(1)
			end
		end
	end)

	it("turns failed runs into notices only, so the lens falls back to raw", function()
		local n = 0
		for _, c in CASES do
			if c.status ~= 0 then
				n += 1
				expect(c.key .. " records=" .. Store.size(c.store)).toBe(c.key .. " records=0")
				expect(c.store.notices[#c.store.notices].kind).toBe("error")
			end
		end
		expect(n >= 4).toBe(true)
	end)

	-- kind's kubelet answers `-p -c crashy` either with the previous
	-- instance's lines or, on stdout with exit 0, with `unable to retrieve
	-- container logs` (both seen across captures); each must read correctly.
	it("reads -p of a crashed container as its panic or as an error notice", function()
		local n = 0
		for _, c in CASES do
			if string.find(c.key, "_%-p_%-c_crashy$") then
				n += 1
				local panic = false
				for i = c.store.first, c.store.first + Store.size(c.store) - 1 do
					local r = Store.get(c.store, i)
					if r and r.level == "error" and string.find(r.message, "^panic: ") then
						panic = true
					end
				end
				local notice = Store.size(c.store) == 0 and #c.store.notices > 0 and c.store.notices[1].kind == "error"
				expect(c.key .. " " .. tostring(panic or notice)).toBe(c.key .. " true")
			end
		end
		expect(n).toBe(1)
	end)
end)

return nil
