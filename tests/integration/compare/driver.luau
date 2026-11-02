--!strict
-- Headless Explore for run.sh: drives the pure Explore state machine through
-- the compare scenarios below with real kubectl answers. Standalone luau can
-- neither spawn processes nor read files, so run.sh keeps every answer in a
-- generated module (.transcripts/answers.luau, keyed by argv) and calls this
-- driver again until nothing is missing. Each call replays every scenario
-- from init (deterministic) and prints shell lines for run.sh to eval:
--   tk_need KEY TIMEOUT_MS ARGV...   a kubectl run the replay has no answer for
--   tk_ok NAME / tk_fail NAME WHY    assertion results, once nothing is missing
--
--   .tools/bin/luau tests/integration/compare/driver.luau -a <kubeconfig-mc> <kubeconfig-with-unreachable-context>
local Command = require("../../../plugin/lib/kubectl/command")
local Config = require("../../../plugin/lib/config")
local N = require("../../lib/nodes")
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local json = require("../../lib/json")

type State = State.State
type Effect = State.Effect
type Msg = State.Msg
type Answer = { status: number, out: string, err: string, timedOut: boolean }

local args = { ... }
local MC = args[1] :: string
local MC3 = args[2] :: string
assert(MC and MC3, "driver: kubeconfig arguments missing")

local A = "kind-tern-kube-dev"
local B = "kind-tern-kube-dev2"
local DOWN = "kind-tern-kube-down"
local NS = "tern-test-mc"
local AT = 1762000000

local function hex(s: string): string
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

local function unhex(h: string): string
	return (string.gsub(h, "%x%x", function(x: string): string
		return string.char(tonumber(x, 16) :: number)
	end))
end

local answers: { [string]: Answer } = (require :: any)("./.transcripts/answers")

local arrays: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function decode(text: string): any
	local value, tracked = json.decodeTracking(text)
	for t in tracked do
		arrays[t] = true
	end
	return value
end

local function isList(t: { [any]: any }): boolean
	return arrays[t] == true
end

-- One shell command line for run.sh, every word POSIX-quoted.
local function emit(words: { string })
	print(Command.format(words))
end

type Run = { argv: { string }, tag: string? }
type World = { s: State, runs: { Run }, copies: { string }, toasts: { string } }

-- Runs no answer exists for yet, over every scenario of this call.
local needs: { [string]: Effect } = {}

-- Thrown (as a table) once a run has no answer: the replay of that scenario
-- stops; every other run already queued is reported with it.
local MISSING = {}

local function settle(w: World, effects: { Effect })
	local queue = table.clone(effects)
	local guard = 0
	local stop = false
	while #queue > 0 do
		guard += 1
		assert(guard < 1000, "settle: too many effects")
		local e = table.remove(queue, 1) :: Effect
		if e.t == "copy" then
			table.insert(w.copies, e.text or "")
		elseif e.t == "toast" then
			table.insert(w.toasts, e.text or "")
		elseif e.t == "run" then
			local argv = e.argv :: { string }
			local key = hex(table.concat(argv, "\0"))
			local a = answers[key]
			if a == nil then
				needs[key] = e
				stop = true
			elseif not stop then
				table.insert(w.runs, { argv = argv, tag = e.tag })
				local msg: Msg = {
					t = "result",
					tag = e.tag,
					gen = e.gen,
					at = AT,
					now = AT,
					result = { status = a.status, stdout = unhex(a.out), stderr = unhex(a.err), timed_out = a.timedOut },
				}
				local s2, more = State.update(w.s, msg)
				w.s = s2
				for _, m in more do
					table.insert(queue, m)
				end
			end
		end
	end
	if stop then
		error(MISSING, 0)
	end
end

local function key(name: string): Msg
	local k: { [string]: any } = { name = name, ctrl = false, alt = false, shift = false, meta = false }
	if #name == 1 then
		k.text = name
		k.shift = string.upper(name) == name and string.lower(name) ~= name
	end
	return { t = "key", key = k :: any, now = AT }
end

local function press(w: World, names: { string })
	for _, name in names do
		local s2, effects = State.update(w.s, key(name))
		w.s = s2
		settle(w, effects)
	end
end

local function link(params: { [string]: string }): string
	local keys: { string } = {}
	for k in params do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, k .. "=" .. params[k])
	end
	return "tern-kube://explore?" .. table.concat(parts, "&")
end

local function open(params: { [string]: string }, configText: string?): World
	local cfg = Config.parse(configText, json.decode)
	local s, effects = State.init({ link(params) }, nil, cfg, {
		kubeconfig = nil,
		home = "/nonexistent",
		kubectl = "kubectl",
		decode = decode,
		now = AT,
		isList = isList,
		null = json.null,
	})
	local w: World = { s = s, runs = {}, copies = {}, toasts = {} }
	settle(w, effects)
	return w
end

local function viewText(w: World): string
	return N.text(Render.view(w.s, 160, 48).main)
end

-- Text of the largest node that mentions `name` and none of `others`: a row
-- of a table or matrix, whatever its node structure.
local function rowText(w: World, name: string, others: { string }): string?
	local best: string? = nil
	N.walk(Render.view(w.s, 160, 48).main, function(n)
		local t = N.text(n)
		if not string.find(t, name, 1, true) then
			return
		end
		for _, o in others do
			if string.find(t, o, 1, true) then
				return
			end
		end
		if best == nil or #t > #(best :: string) then
			best = t
		end
	end)
	return best
end

local function argvText(argv: { string }): string
	return Command.format(argv)
end

local function ran(w: World, argv: { string }): boolean
	local want = argvText(argv)
	for _, r in w.runs do
		if argvText(r.argv) == want then
			return true
		end
	end
	return false
end

-- Scenarios ------------------------------------------------------------------

type Check = { fails: { string } }

local function check(c: Check, ok: boolean, what: string)
	if not ok then
		table.insert(c.fails, what)
	end
end

local function has(c: Check, text: string?, needle: string, what: string)
	check(
		c,
		text ~= nil and string.find(text, needle, 1, true) ~= nil,
		what .. ": " .. string.format("%q", needle) .. " not in: " .. string.sub(text or "(no text)", 1, 600)
	)
end

local function lacks(c: Check, text: string, needle: string, what: string)
	check(
		c,
		string.find(text, needle, 1, true) == nil,
		what .. ": " .. string.format("%q", needle) .. " must not appear"
	)
end

local function objectArgv(kubeconfig: string, ctx: string, resource: string, name: string): { string }
	return {
		"kubectl",
		"--kubeconfig",
		kubeconfig,
		"--context",
		ctx,
		"-n",
		NS,
		"get",
		resource,
		"--field-selector",
		"metadata.name=" .. name,
		"-o",
		"json",
	}
end

local function objectLink(kubeconfig: string, kind: string, name: string): { [string]: string }
	return { context = A, kubeconfig = kubeconfig, namespace = NS, kind = kind, name = name }
end

local SCENARIOS: { { name: string, run: (c: Check) -> () } } = {
	{
		-- Section 0: tkm-web differs in replicas, image and label tier; both
		-- sides are refetched with the same version-pinned, name-selected get.
		name = "object-differs",
		run = function(c)
			local w = open(objectLink(MC, "Deployment", "tkm-web"))
			press(w, { "x" })
			has(c, viewText(w), B, "picker offers the other context")
			press(w, { "enter" })
			local text = viewText(w)
			has(c, text, "differs", "status line")
			has(c, text, "spec.replicas 2 -> 3", "differences list")
			has(c, text, "nginx:1.27-alpine -> nginx:1.28-alpine", "differences list")
			has(c, text, "tier", "differences list")
			has(c, text, A, "base provenance")
			has(c, text, B, "other provenance")
			for _, ctx in { A, B } do
				local argv = objectArgv(MC, ctx, "deployments.v1.apps", "tkm-web")
				check(c, ran(w, argv), "pinned object query not run: " .. argvText(argv))
			end
			local before = #w.copies
			press(w, { "Y" })
			local copied = w.copies[before + 1] or ""
			has(c, copied, "--context " .. A, "Y copies the base command")
			has(c, copied, "--context " .. B, "Y copies the other command")
		end,
	},
	{
		name = "object-same",
		run = function(c)
			local w = open(objectLink(MC, "Deployment", "tkm-api"))
			press(w, { "x", "enter" })
			local text = viewText(w)
			has(c, text, "same", "status line")
			lacks(c, text, "differs", "identical objects (uid, resourceVersion, status differ only)")
		end,
	},
	{
		name = "object-service-same",
		run = function(c)
			local w = open(objectLink(MC, "Service", "tkm-web"))
			press(w, { "x", "enter" })
			local text = viewText(w)
			has(c, text, "same", "clusterIP is noise")
			lacks(c, text, "differs", "clusterIP is noise")
		end,
	},
	{
		name = "object-missing",
		run = function(c)
			local w = open(objectLink(MC, "Deployment", "tkm-only-a"))
			press(w, { "x", "enter" })
			has(c, viewText(w), "missing in " .. B, "status line")
		end,
	},
	{
		name = "configmap-differs",
		run = function(c)
			local w = open(objectLink(MC, "ConfigMap", "tkm-config"))
			press(w, { "x", "enter" })
			local text = viewText(w)
			has(c, text, "differs", "status line")
			has(c, text, "LOG_LEVEL", "differences list")
		end,
	},
	{
		-- Secret values never reach the view: neither raw, base64, nor via
		-- last-applied-configuration; key names stay visible.
		name = "secret-masked",
		run = function(c)
			local w = open(objectLink(MC, "Secret", "tkm-secret"))
			press(w, { "x", "enter" })
			local text = viewText(w)
			has(c, text, "<redacted, changed>", "changed value marker")
			has(c, text, "password", "key name")
			for _, leak in { "s3cret", "czNjcmV0", "last-applied-configuration" } do
				lacks(c, text, leak, "secret leak")
			end
		end,
	},
	{
		-- List compare: states from the two fetched lists; drilling into a
		-- row runs nothing new.
		name = "list-matrix",
		run = function(c)
			local w = open({ context = A, kubeconfig = MC, namespace = NS, kind = "Deployment" })
			press(w, { "x", "enter" })
			local names = { "tkm-api", "tkm-web", "tkm-only-a", "tkm-only-b" }
			local want =
				{ ["tkm-api"] = "same", ["tkm-web"] = "changed", ["tkm-only-a"] = "missing", ["tkm-only-b"] = "extra" }
			for _, name in names do
				local others: { string } = {}
				for _, o in names do
					if o ~= name and not string.find(o, name, 1, true) and not string.find(name, o, 1, true) then
						table.insert(others, o)
					end
				end
				has(c, rowText(w, name, others), want[name], "row " .. name)
			end
			local runs = #w.runs
			press(w, { "enter" })
			check(c, #w.runs == runs, string.format("enter on a matrix row ran %d new queries", #w.runs - runs))
			local text = viewText(w)
			check(
				c,
				string.find(text, "same", 1, true) ~= nil
					or string.find(text, "differs", 1, true) ~= nil
					or string.find(text, "missing in", 1, true) ~= nil,
				"enter opens a pairwise status: " .. string.sub(text, 1, 400)
			)
		end,
	},
	{
		-- All contexts with an unreachable third one: an error row, the
		-- reachable side still compared. "All contexts" is the picker's last
		-- row when no compare.contexts preset is configured.
		name = "all-contexts-unreachable",
		run = function(c)
			local w = open(objectLink(MC3, "Deployment", "tkm-web"))
			press(w, { "x" })
			has(c, viewText(w), "All contexts (3)", "picker row")
			press(w, { "G", "enter" })
			has(c, rowText(w, DOWN, { B }), "error", "unreachable context row")
			has(c, rowText(w, B, { DOWN }), "changed", "reachable context row")
		end,
	},
}

local results: { { name: string, fails: { string } } } = {}
for _, sc in SCENARIOS do
	local c: Check = { fails = {} }
	local ok, err = pcall(function(): any
		sc.run(c)
		return nil
	end)
	if not ok and err ~= MISSING then
		table.insert(c.fails, "error: " .. tostring(err))
	end
	table.insert(results, { name = sc.name, fails = c.fails })
end

if next(needs) ~= nil then
	local keys: { string } = {}
	for k in needs do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		local e = needs[k]
		local words: { string } = { "tk_need", k, tostring(e.timeout_ms or 0) }
		for _, a in e.argv :: { string } do
			table.insert(words, a)
		end
		emit(words)
	end
	return nil
end

for _, r in results do
	if #r.fails == 0 then
		emit({ "tk_ok", r.name })
	else
		for _, f in r.fails do
			emit({ "tk_fail", r.name, f })
		end
	end
end
return nil
