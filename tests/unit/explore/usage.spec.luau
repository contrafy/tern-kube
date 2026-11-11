--!strict
-- Explore's usage views at the state level: `%` opens the usage of what is
-- in view with exactly the pinned reads it needs (context, scope, `-l`, node
-- field selector, constant jsonpath templates); results may come back in any
-- order and stale ones are dropped; without the metrics API the rows still
-- show requests and limits; and the `w` sampling run reads only metrics, on
-- the 15 s cadence, one read at a time, and ends on time, `w`, a route or
-- scope change, or an error. Nothing reads on its own otherwise.
local Explore = require("../../lib/explore")
local Parse = require("../../../plugin/lib/usage/parse")
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local Usage = require("../../../plugin/lib/explore/usage")
local View = require("../../../plugin/lib/usage/view")
local fixtures = require("../../lib/fixtures")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect

local CTX, NS = Explore.CTX, Explore.NS
-- Explore.env() has no KUBECONFIG: the block pins HOME's default file.
local KC = "/home/u/.kube/config"
local NODE = "tern-kube-dev-control-plane"

local function flag(argv: { string }, name: string): string?
	local i = table.find(argv, name)
	return if i then argv[i + 1] else nil
end

local function ok(stdout: string): Explore.Result
	return { status = 0, stdout = stdout, stderr = "", timed_out = false }
end

local FILES: { [string]: string } = {
	pods = "kubectl/usage/pods-A.tsv",
	["pods.metrics.k8s.io"] = "kubectl/usage/podmetrics-A.tsv",
	nodes = "kubectl/usage/nodes.tsv",
	["nodes.metrics.k8s.io"] = "kubectl/usage/nodemetrics.tsv",
}

export type World = { metrics: Explore.Result?, allpods: Explore.Result?, pods: Explore.Result?, extra: string? }

-- The jsonpath reads answered from the golden TSVs, filtered like the API
-- would (-n, metadata.name, spec.nodeName); everything else as usual.
local function world(w: World?): Explore.Responder
	local o: World = w or {}
	return function(argv: { string }): (Explore.Result?, string?)
		local out = flag(argv, "-o")
		if out == nil or string.sub(out, 1, 9) ~= "jsonpath=" then
			return Explore.responder(argv)
		end
		local get = table.find(argv, "get") :: number
		local resource = argv[get + 1]
		if string.find(resource, "metrics", 1, true) and o.metrics then
			return o.metrics
		end
		if resource == "pods" and table.find(argv, "-A") and o.allpods then
			return o.allpods
		elseif resource == "pods" and o.pods then
			return o.pods
		end
		local ns = flag(argv, "-n")
		local fs = flag(argv, "--field-selector") or ""
		local name = string.match(fs, "^metadata%.name=(.+)$")
		local node = string.match(fs, "^spec%.nodeName=(.+)$")
		local text = fixtures.read(FILES[resource])
		if resource == "pods.metrics.k8s.io" and o.extra then
			text ..= o.extra
		end
		local lines: { string } = {}
		for _, line in fixtures.toLines(text) do
			local f = string.split(line, "\t")
			local namespaced = resource == "pods" or resource == "pods.metrics.k8s.io"
			local keep = true
			if namespaced and ns and f[1] ~= ns then
				keep = false
			end
			if namespaced and name and f[2] ~= name then
				keep = false
			end
			if resource == "pods" and node and f[3] ~= node then
				keep = false
			end
			if keep then
				table.insert(lines, line)
			end
		end
		return ok(table.concat(lines, "\n") .. (if #lines > 0 then "\n" else ""))
	end
end

local function settle(s: State, effects: { Effect }, w: World?, trace: Explore.Trace?): (State, Explore.Trace)
	return Explore.settle(s, effects, world(w), trace)
end

local function press(s: State, key: string, w: World?, extra: { [string]: any }?): (State, Explore.Trace)
	local s2, effects = State.update(s, Explore.key(key, extra))
	return settle(s2, effects, w)
end

local function act(s: State, a: string, value: string?, w: World?): (State, Explore.Trace)
	local s2, effects = State.update(s, { t = "action", act = a, value = value })
	return settle(s2, effects, w)
end

local function open(params: { [string]: string }?, cfg: any?, w: World?): (State, Explore.Trace)
	local p = params or { context = CTX, namespace = NS, kind = "Pod" }
	local s, effects = State.init({ Explore.link(p) }, nil, cfg or Explore.config(nil), Explore.env())
	return settle(s, effects, w)
end

local function top(s: State): any
	return s.stack[#s.stack]
end

local function data(s: State): Usage.Data
	local load = State.currentLoad(s)
	assert(load and load.status == "ok", "usage load not ok: " .. tostring(load and (load.error or load.status)))
	return load.data :: Usage.Data
end

local function rowByKey(s: State, key: string): View.URow
	for _, r in data(s).rows do
		if r.key == key then
			return r
		end
	end
	error("no row " .. key)
end

local function argvs(tr: Explore.Trace): { string }
	local out: { string } = {}
	for _, r in tr.runs do
		table.insert(out, table.concat(r.argv :: { string }, " "))
	end
	return out
end

local function toasts(tr: Explore.Trace): { string }
	local out: { string } = {}
	for _, e in tr.effects do
		if e.t == "toast" then
			table.insert(out, e.text or "")
		end
	end
	return out
end

local function viewText(s: State): string
	local v = Render.view(s, 200, 60)
	local parts = { nodes.text(v.main) }
	if v.dock then
		table.insert(parts, nodes.text(v.dock))
	end
	return table.concat(parts, "\n")
end

local function stats(s: State): { [string]: any }
	local v = Render.view(s, 200, 60)
	local found = nodes.find(v.main, nodes.kind("stats"))
	assert(found, "no stats tiles")
	local out: { [string]: any } = {}
	for _, item in (found.p :: any).items do
		out[item.label[1].t] = item
	end
	return out
end

local POD_JP = "jsonpath=" .. Parse.POD_JP
local PODM_JP = "jsonpath=" .. Parse.PODM_JP

describe("explore usage: entry points", function()
	it("% on a pods list reads that scope's pods and metrics, pinned, and selects the row", function()
		local s = open()
		s = press(s, "j")
		local selected = (State.selectedItem(s) :: any).ref
		local s2, tr = press(s, "%", nil)
		expect(top(s2).kind).toBe("usage")
		expect(#tr.runs).toBe(2)
		expect(tr.runs[1].argv).toEqual({
			"kubectl",
			"--kubeconfig",
			KC,
			"--context",
			CTX,
			"get",
			"pods",
			"-n",
			NS,
			"-o",
			POD_JP,
		})
		expect(tr.runs[2].argv).toEqual({
			"kubectl",
			"--kubeconfig",
			KC,
			"--context",
			CTX,
			"get",
			"pods.metrics.k8s.io",
			"-n",
			NS,
			"-o",
			PODM_JP,
		})
		expect((State.selectedItem(s2) :: any).key).toBe(NS .. "/" .. selected.name)
		expect(viewText(s2)).toContain("usage · pods · ns " .. NS)
	end)

	it("% on a deployment row reads its pods by the deployment's selector", function()
		local s = open({ context = CTX, namespace = NS, kind = "Deployment" })
		local ref = State.focusRef(s) :: any
		local _, tr = press(s, "%")
		local argv = tr.runs[1].argv :: { string }
		expect(flag(argv, "-n")).toBe(ref.namespace)
		expect(flag(argv, "-l") ~= nil).toBe(true)
		expect(flag(tr.runs[2].argv :: { string }, "-l")).toBe(flag(argv, "-l"))
	end)

	it("% on a pod's object view opens its containers", function()
		local s = open()
		s = press(s, "enter")
		local name = (top(s).ref :: any).name
		local s2, tr = press(s, "%")
		expect(top(s2).ref.name).toBe(name)
		expect(flag(tr.runs[1].argv :: { string }, "--field-selector")).toBe("metadata.name=" .. name)
	end)

	it("% on nodes reads nodes, node metrics and every pod; % again switches to pods", function()
		local s = open({ context = CTX, namespace = NS, kind = "Node" })
		local s2, tr = press(s, "%")
		expect(top(s2).resource).toBe("nodes")
		expect(#tr.runs).toBe(3)
		local words = argvs(tr)
		expect(words[1]).toContain("get nodes -o jsonpath=")
		expect(words[2]).toContain("get nodes.metrics.k8s.io -o jsonpath=")
		expect(words[3]).toContain("get pods -A -o jsonpath=")
		expect(rowByKey(s2, NODE).cells[9]).toBe("35/110")
		local s3 = press(s2, "%")
		expect(top(s3).resource).toBe("pods")
		expect(#s3.stack).toBe(#s2.stack)
	end)

	it("the count-row chip and the palette open usage too", function()
		local s = open()
		local s2 = act(s, "usage-key", "%")
		expect(top(s2).kind).toBe("usage")
		local s3 = act(s, "palette-route", "usage")
		expect(top(s3).resource).toBe("nodes")
	end)

	it("lens links: pods of the scope, a pod's containers, a node's pods, the palette's nodes", function()
		local s = open({ context = CTX, namespace = NS, kind = "Pod", route = "usage", selector = "app=web" })
		expect(#s.stack).toBe(1)
		expect(top(s).selector).toBe("app=web")
		local c = open({ context = CTX, namespace = NS, kind = "Pod", name = "db-0", route = "usage" })
		expect(#c.stack).toBe(2)
		expect(top(c).ref.name).toBe("db-0")
		expect(viewText(c)).toContain("usage · pod/db-0")
		local n = open({ context = CTX, kind = "Node", name = NODE, route = "usage" })
		expect(top(n).node).toBe(NODE)
		expect(flag(State.usageSubs(n, top(n))[1].argv, "--field-selector")).toBe("spec.nodeName=" .. NODE)
		local p = open({ route = "usage" })
		expect(top(p).resource).toBe("nodes")
		local bad = open({ context = CTX, kind = "Node", name = "Bad_Node", route = "usage" })
		expect(#bad.stack).toBe(1)
	end)

	it("with live queries off % only says so", function()
		local s = open(nil, Explore.config('{"explore":{"allow_live_queries":false}}'))
		local s2, tr = press(s, "%")
		expect(#tr.runs).toBe(0)
		expect(toasts(tr)).toEqual({ "Live queries are disabled" })
		expect(top(s2).kind).toBe(top(s).kind)
	end)
end)

describe("explore usage: loads", function()
	local function usage(w: World?): State
		local s = open(nil, nil, w)
		return (press(s, "%", w))
	end

	it("shows tiles, toned rows and the metrics time", function()
		local s = usage()
		local tiles = stats(s)
		expect(tiles.Pods.value[1].t).toBe("4 / 7")
		expect(tiles["Near limits"].value[1].t).toBe("0")
		local text = viewText(s)
		expect(text).toContain("metrics ")
		expect(text).toContain(View.NO_METRICS)
		expect(text).toContain("w sample 2 min")
	end)

	it("enter on a pod shows its containers without a new read; esc goes back to it", function()
		local s = usage()
		local key = NS .. "/db-0"
		s = act(s, "sel", key)
		local s2, tr = press(s, "enter")
		expect(#tr.runs).toBe(0)
		expect(top(s2).ref.name).toBe("db-0")
		expect(data(s2).rows[1].cells[1]).toBe("db")
		local s3 = press(s2, "escape")
		expect((State.selectedItem(s3) :: any).key).toBe(key)
	end)

	it("enter on a node lists its pods in every namespace", function()
		local s = open({ context = CTX, kind = "Node", route = "usage" })
		local s2, tr = press(s, "enter")
		expect(top(s2).node).toBe(NODE)
		expect(table.find(tr.runs[1].argv :: { string }, "-A") ~= nil).toBe(true)
		expect(#data(s2).rows).toBe(39)
	end)

	it("r reads every sub-query again", function()
		local s = usage()
		local _, tr = press(s, "r")
		expect(#tr.runs).toBe(2)
	end)

	it("x is not available; Y copies every pinned read, one per line", function()
		local s = usage()
		local _, tr = press(s, "x")
		expect(toasts(tr)).toEqual({ Usage.NOT_HERE })
		local _, tr2 = press(s, "Y")
		local copied: string? = nil
		for _, e in tr2.effects do
			if e.t == "copy" then
				copied = e.text
			end
		end
		local lines = string.split(copied :: string, "\n")
		expect(#lines).toBe(2)
		expect(lines[1]).toContain("kubectl --kubeconfig " .. KC .. " --context " .. CTX .. " get pods -n " .. NS)
		expect(lines[2]).toContain("get pods.metrics.k8s.io")
	end)

	it("results in any order build one table; a stale generation is dropped", function()
		local s = open()
		local s2, effects = State.update(s, Explore.key("%"))
		local runs: { Effect } = {}
		for _, e in effects do
			if e.t == "run" then
				table.insert(runs, e)
			end
		end
		local respond = world()
		local function answer(st: State, e: Effect, gen: number?): State
			local result = respond(e.argv :: { string })
			local next = State.update(st, {
				t = "result",
				tag = e.tag,
				gen = gen or e.gen,
				result = result,
				at = Explore.AT,
			})
			return next
		end
		s2 = answer(s2, runs[2])
		expect((State.currentLoad(s2) :: any).status).toBe("loading")
		local before = s2
		local after = answer(s2, runs[1], (runs[1].gen :: number) - 1)
		expect(after).toBe(before)
		s2 = answer(s2, runs[1])
		expect(#data(s2).rows).toBe(7)
	end)

	it("without the metrics API the rows keep requests and say why", function()
		local s = usage({ metrics = Explore.fail(1, 'error: the server doesn\'t have a resource type "pods"') })
		expect(#data(s).rows).toBe(7)
		expect(viewText(s)).toContain("Metrics API not available")
	end)

	it("Forbidden metrics name the permission", function()
		local s = usage({
			metrics = Explore.fail(
				1,
				'Error from server (Forbidden): pods.metrics.k8s.io is forbidden: User "u" cannot list'
			),
		})
		expect(viewText(s)).toContain("needs list on pods.metrics.k8s.io")
	end)

	it("nodes without access to every pod show <forbidden> requested columns", function()
		local s = open({ context = CTX, kind = "Node", route = "usage" }, nil, {
			allpods = Explore.fail(
				1,
				'Error from server (Forbidden): pods is forbidden: User "u" cannot list resource "pods"'
			),
		})
		expect(rowByKey(s, NODE).cells[5]).toBe(View.FORBIDDEN)
		expect(viewText(s)).toContain("Requested and limits unknown")
	end)

	it("a failed pods read fails the view", function()
		local s = open(nil, nil, nil)
		local s2 = press(s, "%", { pods = Explore.fail(1, "Unable to connect to the server: dial tcp: i/o timeout") })
		local load = State.currentLoad(s2) :: any
		expect(load.status).toBe("error")
		expect(load.error).toContain("unreachable")
	end)

	it("save keeps the route, never the trends or a sampling run", function()
		local s = usage()
		s = press(s, "w")
		expect(s.usage.sampling ~= nil).toBe(true)
		local saved = State.save(s)
		local restored = State.init({}, saved, Explore.config(nil), Explore.env())
		expect(top(restored).kind).toBe("usage")
		expect(restored.usage.sampling).toBeNil()
		expect((next(restored.usage.store))).toBeNil()
	end)

	it("a header click sorts by a column, never by a trend", function()
		local s = usage()
		local s2 = act(s, "sort", "cpu:desc")
		expect(s2.sort[State.currentKey(s2)].col).toBe("CPU")
		local _, effects = State.update(s, { t = "action", act = "sort", value = "cpu-9:asc" })
		expect(#effects).toBe(0)
	end)
end)

describe("explore usage: sampling", function()
	local function at(s: State, now: number, w: World?): (State, Explore.Trace)
		local s2, effects = State.update(s, { t = "tick", now = now })
		return settle(s2, effects, w)
	end

	local function sampling(w: World?): State
		local s = open(nil, nil, w)
		s = press(s, "%", w)
		s = at(s, 2000, w)
		return s
	end

	local function metricsRuns(tr: Explore.Trace): number
		local n = 0
		for _, r in tr.runs do
			expect(table.find(r.argv :: { string }, "pods.metrics.k8s.io") ~= nil).toBe(true)
			n += 1
		end
		return n
	end

	it("ticks without a run read nothing", function()
		local s = sampling()
		local _, tr = at(s, 2100)
		expect(#tr.runs).toBe(0)
	end)

	it("w reads metrics at once, again after 15 s, not before", function()
		local s = sampling()
		local s2, tr = press(s, "w")
		expect(metricsRuns(tr)).toBe(1)
		expect(viewText(s2)).toContain("Sampling 2:00 · w stops")
		local _, tr14 = at(s2, 2014)
		expect(#tr14.runs).toBe(0)
		local s3, tr15 = at(s2, 2015)
		expect(metricsRuns(tr15)).toBe(1)
		expect(s3.usage.sampling ~= nil).toBe(true)
	end)

	it("never has two reads in flight", function()
		local s = sampling()
		local s2, effects = State.update(s, Explore.key("w"))
		expect(#effects).toBe(1)
		local s3, more = State.update(s2, { t = "tick", now = 2030 })
		for _, e in more do
			expect(e.t).toBe("render")
		end
		expect(s3.usage.sampling ~= nil).toBe(true)
	end)

	it("ends after two minutes, at most 8 reads", function()
		local s = sampling()
		s = press(s, "w")
		local reads = 1
		for now = 2002, 2130, 2 do
			local tr
			s, tr = at(s, now)
			reads += #tr.runs
		end
		expect(reads).toBe(8)
		expect(s.usage.sampling).toBeNil()
		expect(viewText(s)).toContain("w sample 2 min")
	end)

	it("w again, esc, a namespace change and a failed read stop it", function()
		local s = sampling()
		local on = press(s, "w")
		expect(press(on, "w").usage.sampling).toBeNil()
		expect(press(on, "escape").usage.sampling).toBeNil()
		local ns = act(on, "ns", "tern-test-empty")
		expect(ns.usage.sampling).toBeNil()
		local failing: World = { metrics = Explore.fail(1, "Unable to connect to the server: dial tcp: i/o timeout") }
		local s2 = sampling()
		local _, effects = State.update(s2, Explore.key("w"))
		local s3, tr = settle((State.update(s2, Explore.key("w"))), effects, failing)
		expect(s3.usage.sampling).toBeNil()
		expect(toasts(tr)).toEqual({ "Sampling stopped" })
	end)

	it("moves only the trends: rows, numbers and order stay until r", function()
		local later = "tern-test-apps\tweb-65d7d99975-6jsgc\t2026-11-11T16:14:20Z\t15s\tweb=5000000n,999Ki;\n"
			.. "tern-test-apps\tnew-pod\t2026-11-11T16:14:20Z\t15s\tapp=1n,1Ki;\n"
		local s = sampling()
		local before = data(s)
		local s2 = press(s, "w", { extra = later })
		local after = data(s2)
		expect(after).toBe(before)
		expect(s2.usage.rev > s.usage.rev).toBe(true)
		expect(viewText(s2)).toContain("1 pods not in the last read; r includes them")
		local cell = View.withTrends(
			after.built :: View.Built,
			rowByKey(s2, NS .. "/web-65d7d99975-6jsgc"),
			{ store = s2.usage.store, clock = tostring, off = false }
		)
		expect(#cell[9].spark.values).toBe(2)
	end)
end)

return nil
