--!strict
-- Explore compare across contexts (track 5 plan 1, 2, 6): `x` opens a
-- picker over the block kubeconfig's contexts, each side is one pinned
-- kubectl run (same namespace, same apiVersion, absence as `items: []`),
-- results of an older run are dropped, nothing refreshes on its own, and
-- Secret values never reach the view or the state (Secrets are compared on
-- their real values but shown masked).
local Explore = require("../../lib/explore")
local Query = require("../../../plugin/lib/explore/query")
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect

local A, B, DOWN = "kind-tern-kube-dev", "kind-tern-kube-dev2", "kind-tern-kube-down"
local KC = "/tmp/tk-cmp/kubeconfig"
local NS = "tern-test-mc"

local KINDS: { [string]: string } = {
	["deployments.v1.apps"] = "Deployment",
	["deployments.apps"] = "Deployment",
	deployments = "Deployment",
	secrets = "Secret",
	configmaps = "ConfigMap",
	services = "Service",
}

local function flag(argv: { string }, name: string): string?
	local i = table.find(argv, name)
	return if i then argv[i + 1] else nil
end

local function ok(stdout: string): Explore.Result
	return { status = 0, stdout = stdout, stderr = "", timed_out = false }
end

local function side(context: string?): string
	return if context == B then "b" else "a"
end

-- Two (or three, `down` unreachable) contexts holding the section 0 objects.
local function world(three: boolean): Explore.Responder
	local configText = fixtures.read("real/compare/config-view.json")
	local doc = json.decode(configText)
	if three then
		table.insert(doc.clusters, { name = DOWN, cluster = { server = "https://127.0.0.1:1" } })
		table.insert(doc.contexts, { name = DOWN, context = { cluster = DOWN, user = DOWN } })
	end
	return function(argv: { string }): (Explore.Result?, string?)
		local context = flag(argv, "--context")
		local get = table.find(argv, "get")
		if table.find(argv, "view") then
			return ok(Explore.token("@config-view", doc))
		elseif table.find(argv, "get-contexts") then
			return ok(A .. "\n" .. B .. (if three then "\n" .. DOWN else "") .. "\n")
		elseif context == DOWN then
			return Explore.fail(1, "The connection to the server 127.0.0.1:1 was refused: connect: connection refused")
		elseif get then
			local resource = argv[get + 1]
			local selector = flag(argv, "--field-selector")
			local positional = argv[get + 2]
			local single = if positional and string.sub(positional, 1, 1) ~= "-" then positional else nil
			if selector == nil and single == nil then
				return ok(fixtures.read("real/compare/" .. side(context) .. "-deployments-list.json"))
			end
			local name = single or string.match(selector :: string, "^metadata%.name=(.+)$")
			local items: { any } = {}
			for _, item in json.decode(fixtures.read("real/compare/" .. side(context) .. "-mixed-list.json")).items do
				local kind = KINDS[resource] or KINDS[(string.match(resource, "^([^.]+)") or resource) .. "s"]
				if item.kind == kind and item.metadata.name == name then
					table.insert(items, item)
				end
			end
			if single then
				return if items[1]
					then ok(Explore.token("@obj:" .. table.concat(argv, " "), items[1]))
					else Explore.fail(1, "Error from server (NotFound): not found")
			end
			return ok(
				Explore.token("@fs:" .. table.concat(argv, " "), { apiVersion = "v1", kind = "List", items = items })
			)
		end
		return Explore.fail(1, "fake kubectl: unhandled " .. table.concat(argv, " "))
	end
end

local function cfg(extra: string?): any
	return Explore.config(extra or nil)
end

local function open(name: string?, kind: string?, config: any?, three: boolean?): (State, Explore.Trace)
	local params: { [string]: string } = { context = A, namespace = NS, kind = kind or "Deployment", kubeconfig = KC }
	if name then
		params.name = name
	end
	local s, effects = State.init({ Explore.link(params) }, nil, config or cfg(), Explore.env())
	return Explore.settle(s, effects, world(three == true))
end

local function press(s: State, key: string, three: boolean?): (State, Explore.Trace)
	local s2, effects = State.update(s, Explore.key(key))
	return Explore.settle(s2, effects, world(three == true))
end

local function top(s: State): any
	return s.stack[#s.stack]
end

local function alltext(s: State): string
	local v = Render.view(s, 200, 60)
	local parts = { nodes.text(v.main) }
	if v.dock then
		table.insert(parts, nodes.text(v.dock))
	end
	return table.concat(parts, "\n")
end

local function argvs(tr: Explore.Trace): { string }
	local out: { string } = {}
	for _, e in tr.runs do
		table.insert(out, table.concat(e.argv :: { string }, " "))
	end
	return out
end

-- Opens the object, presses x and picks the first other context.
local function pairwise(name: string, kind: string?, config: any?): (State, Explore.Trace)
	local s = open(name, kind, config)
	s = press(s, "x")
	return press(s, "enter")
end

describe("compare queries", function()
	it("reads contexts and servers locally, without a context", function()
		expect(table.concat(Query.contextsInfo("kubectl", KC), " ")).toBe(
			"kubectl --kubeconfig " .. KC .. " config view -o json"
		)
	end)

	it("pins the version the object was read at; core kinds stay plain", function()
		local web: any =
			{ kind = "Deployment", group = "apps", version = "v1", name = "w", namespace = NS, source = "live" }
		expect(Query.pinnedResource(web)).toBe("deployments.v1.apps")
		web.version = nil
		expect(Query.pinnedResource(web)).toBe("deployments.apps")
		expect(Query.pinnedResource({ kind = "Secret", version = "v1", name = "s", source = "live" } :: any)).toBe(
			"secrets"
		)
	end)
end)

describe("compare: picking the other side", function()
	it("x on an object opens the picker from one local config view", function()
		local s = open("tkm-web")
		local s2, tr = press(s, "x")
		expect(top(s2).kind).toBe("compare")
		expect(top(s2).across).toBeNil()
		expect(argvs(tr)).toEqual({ "kubectl --kubeconfig " .. KC .. " config view -o json" })
		local text = alltext(s2)
		expect(text).toContain(B)
		expect(text).toContain("All contexts (2)")
	end)

	it("a pick runs both sides with every flag pinned, base refetched too", function()
		local _, tr = pairwise("tkm-web")
		local runs = argvs(tr)
		local function line(context: string): string
			return "kubectl --kubeconfig "
				.. KC
				.. " --context "
				.. context
				.. " -n "
				.. NS
				.. " get deployments.v1.apps --field-selector metadata.name=tkm-web -o json"
		end
		expect(runs).toEqual({ line(A), line(B) })
	end)

	it("All contexts above compare.max_contexts cannot be picked and says why", function()
		local s = open("tkm-web", nil, cfg('{"compare":{"max_contexts":1}}'), true)
		s = press(s, "x", true)
		local text = alltext(s)
		expect(text).toContain("compare.max_contexts (1)")
		s = press(s, "j", true)
		s = press(s, "j", true)
		local s2, tr = press(s, "enter", true)
		expect(#tr.runs).toBe(0)
		expect(top(s2).across).toBeNil()
	end)
end)

describe("compare: one object", function()
	it("shows provenance, the changed paths and the diff of the two sides", function()
		local s = pairwise("tkm-web")
		local text = alltext(s)
		expect(text).toContain("base " .. A)
		expect(text).toContain("other " .. B)
		expect(text).toContain("https://127.0.0.1:59680")
		expect(text).toContain("differs")
		expect(text).toContain("spec.replicas 2 -> 3")
		expect(text).toContain("nginx:1.28-alpine")
	end)

	it("an object absent on the other side is missing there", function()
		expect(alltext((pairwise("tkm-only-a")))).toContain("missing in " .. B)
	end)

	it("identical objects read same", function()
		expect(alltext((pairwise("tkm-api")))).toContain("same")
	end)

	it("Secret values never reach the view or the state; changes still show", function()
		local s = pairwise("tkm-secret", "Secret")
		local text = alltext(s)
		for _, leak in { "s3cret", "czNjcmV0" } do
			expect((string.find(text, leak, 1, true))).toBeNil()
		end
		expect(text).toContain("<redacted, changed>")
		expect(text).toContain("Secret values are masked")
		local seen = false
		local function scan(v: any, depth: number)
			if depth > 40 then
				return
			end
			if type(v) == "string" and (string.find(v, "czNjcmV0", 1, true) or string.find(v, "s3cret", 1, true)) then
				seen = true
			elseif type(v) == "table" then
				for k, x in v do
					scan(k, depth + 1)
					scan(x, depth + 1)
				end
			end
		end
		scan(s.compare, 0)
		expect(seen).toBe(false)
	end)

	it("shows Secret values when security.show_secret_values is on", function()
		local s = pairwise("tkm-secret", "Secret", cfg('{"security":{"show_secret_values":true}}'))
		-- `data` as kubectl prints it: base64 of s3cret-B.
		expect(alltext(s)).toContain("czNjcmV0LUI=")
	end)

	it("All contexts: one row per context, the unreachable one an error", function()
		local s = open("tkm-web", nil, nil, true)
		s = press(s, "x", true)
		s = press(s, "j", true)
		s = press(s, "j", true)
		s = press(s, "enter", true)
		local text = alltext(s)
		expect(text).toContain(DOWN)
		expect(text).toContain("unreachable")
		expect(text).toContain("changed")
		-- enter on the dev2 row: its pairwise diff, no new query.
		s = press(s, "j", true)
		local s2, tr = press(s, "enter", true)
		expect(#tr.runs).toBe(0)
		expect(top(s2).context).toBe(B)
		expect(alltext(s2)).toContain("spec.replicas 2 -> 3")
	end)

	it("compare.max_parallel bounds the runs in flight", function()
		local s = open("tkm-web", nil, cfg('{"compare":{"max_parallel":1}}'), true)
		s = press(s, "x", true)
		s = press(s, "j", true)
		s = press(s, "j", true)
		local _, effects = State.update(s, Explore.key("enter"))
		local runs = 0
		for _, e in effects do
			if e.t == "run" then
				runs += 1
			end
		end
		expect(runs).toBe(1)
	end)
end)

describe("compare: refresh and stale results", function()
	it("r refetches every side; a result of the older run is dropped", function()
		local s = open("tkm-web")
		s = press(s, "x")
		local s1, first = State.update(s, Explore.key("enter"))
		expect(#first).toBe(2)
		local s2, again = State.update(s1, Explore.key("r"))
		local runs: { Effect } = {}
		for _, e in again do
			if e.t == "run" then
				table.insert(runs, e)
			end
		end
		expect(#runs).toBe(2)
		local stale = first[2]
		local result, _ = world(false)(stale.argv :: { string })
		local s3 = State.update(
			s2,
			{ t = "result", tag = stale.tag, gen = stale.gen, result = result, at = Explore.AT } :: any
		)
		expect(s3).toBe(s2)
	end)

	it("ticks never start a query", function()
		local s = pairwise("tkm-web")
		local _, effects = State.update(s, { t = "tick", now = Explore.AT + 120 } :: any)
		for _, e in effects do
			expect(e.t ~= "run").toBe(true)
		end
	end)

	it("Y copies every pinned command, one per line", function()
		local s = pairwise("tkm-web")
		local _, effects = State.update(s, Explore.key("Y"))
		local copied = ""
		for _, e in effects do
			if e.t == "copy" then
				copied = e.text :: string
			end
		end
		local lines = string.split(copied, "\n")
		expect(#lines).toBe(2)
		expect(lines[1]).toContain("--context " .. A)
		expect(lines[2]).toContain("--context " .. B)
	end)
end)

describe("compare: lists", function()
	it("x on a list compares the list; enter on a row diffs it without a new query", function()
		local s = open(nil)
		s = press(s, "x")
		local s1, tr = press(s, "enter")
		local runs = argvs(tr)
		expect(runs[1]).toBe(
			"kubectl --kubeconfig " .. KC .. " --context " .. A .. " get deployments.apps -n " .. NS .. " -o json"
		)
		local text = alltext(s1)
		expect(text).toContain("tkm-only-b")
		expect(text).toContain("extra")
		expect(text).toContain("missing")
		expect(text).toContain("changed")
		-- rows: tkm-api, tkm-only-a, tkm-web (base order), then tkm-only-b.
		local items = State.items(s1)
		local web = 0
		for i, item in items do
			if string.find(item.key, "tkm-web", 1, true) then
				web = i
			end
		end
		local s2 = s1
		for _ = 2, web do
			s2 = press(s2, "j")
		end
		local s3, tr2 = press(s2, "enter")
		expect(#tr2.runs).toBe(0)
		expect(top(s3).item).toBe(items[web].key)
		expect(alltext(s3)).toContain("spec.replicas 2 -> 3")
	end)

	it("f narrows the matrix to objects that differ, then to presence only", function()
		local s = open(nil)
		s = press(s, "x")
		s = press(s, "enter")
		local all = #State.items(s)
		s = press(s, "f")
		local differs = #State.items(s)
		s = press(s, "f")
		local presence = #State.items(s)
		expect(all).toBe(4)
		expect(differs).toBe(3)
		expect(presence).toBe(2)
	end)

	-- Live on Tern 0.9.8 the block's columns did not follow a narrow split and
	-- the grid cut long context names, so heads are short at every width.
	it("heads columns with short labels and a legend naming each context", function()
		local s = open(nil)
		s = press(s, "x")
		s = press(s, "enter")
		for _, cols in { 40, 200 } do
			local main = Render.view(s, cols, 60).main
			local legend = nodes.find(main, nodes.role("tern-kube.compare-legend"))
			assert(legend, "no legend")
			expect(nodes.text(legend)).toContain("dev2 = " .. B)
			local heads: { string } = {}
			for _, h in nodes.findAll(main, nodes.class("tk-h")) do
				table.insert(heads, nodes.ownText(h))
			end
			expect(heads).toEqual({ "OBJECT", "dev", "dev2" })
		end
	end)

	-- A short block must not hide matrix rows: the counts and legend above it
	-- vary, so its window is general.max_rendered_rows, not the height.
	it("shows every row of a short matrix in a short block", function()
		local s = open(nil)
		s = press(s, "x")
		s = press(s, "enter")
		s = State.update(s, { t = "resize", rows = 26 } :: any)
		local main = Render.view(s, 80, 26).main
		local grid = nodes.find(main, nodes.role("tern-kube.compare-matrix")) :: any
		expect(#nodes.findAll(grid, nodes.class("tk-r"))).toBe(4)
		expect(nodes.find(main, nodes.role("tern-kube.overflow"))).toBeNil()
	end)

	it("compare.max_objects refuses a list above it", function()
		local s = open(nil, nil, cfg('{"compare":{"max_objects":2}}'))
		s = press(s, "x")
		s = press(s, "enter")
		expect(alltext(s)).toContain("compare.max_objects (2)")
	end)
end)

describe("compare: guards and wiring", function()
	it("x does nothing live when live queries are off", function()
		local s = open("tkm-web")
		local off = table.clone(s)
		off.config = cfg('{"explore":{"allow_live_queries":false}}')
		local s2, effects = State.update(off, Explore.key("x"))
		for _, e in effects do
			expect(e.t ~= "run").toBe(true)
		end
		expect(top(s2).kind ~= "compare").toBe(true)
	end)

	it("compare views are read-only: mutations and quick actions refuse", function()
		local s = pairwise("tkm-web")
		for _, k in { "ctrl+d", "s", "E" } do
			local msg = if k == "ctrl+d" then Explore.key("d", { ctrl = true }) else Explore.key(k)
			local _, effects = State.update(s, msg)
			local refused = false
			for _, e in effects do
				expect(e.t ~= "open").toBe(true)
				if e.t == "toast" and e.text == "Compare views are read-only" then
					refused = true
				end
			end
			expect(refused).toBe(true)
		end
	end)

	it("x on a compare route picks again", function()
		local s = pairwise("tkm-web")
		s = press(s, "x")
		expect(top(s).kind).toBe("compare")
		expect(top(s).across).toBeNil()
	end)

	it("x on relations compares the selected object", function()
		local s = open("tkm-web")
		s = press(s, "R")
		s = press(s, "x")
		expect(top(s).kind).toBe("compare")
		expect(top(s).ref ~= nil).toBe(true)
	end)

	it("x on a logs route still sets the level floor", function()
		local s = open("tkm-web")
		s = press(s, "L")
		s = press(s, "x")
		expect(top(s).kind).toBe("logs")
		expect(top(s).floor).toBe("warn")
	end)

	it("compare routes are not restored after a reload", function()
		local s = pairwise("tkm-web")
		local saved = State.save(s)
		for _, r in saved.stack do
			expect(r.kind ~= "compare").toBe(true)
		end
	end)

	it("the lens chip's link opens the picker for the row", function()
		local params =
			{ context = A, namespace = NS, kind = "Deployment", name = "tkm-web", kubeconfig = KC, route = "compare" }
		local s, effects = State.init({ Explore.link(params) }, nil, cfg(), Explore.env())
		s = Explore.settle(s, effects, world(false))
		expect(top(s).kind).toBe("compare")
		expect(top(s).ref.name).toBe("tkm-web")
		expect(alltext(s)).toContain(B)
	end)

	it("help and hints name every compare key", function()
		local keys: { string } = {}
		for _, row in Render.KEYS do
			table.insert(keys, row[1])
		end
		local help = table.concat(keys, "\n")
		expect(help).toContain("x")
		expect(help).toContain("[ / ]")
		local s = pairwise("tkm-web")
		local dock = nodes.text(Render.view(s, 200, 60).dock :: any)
		expect(dock).toContain("[ ]")
		expect(dock).toContain("x")
	end)
end)

return nil
