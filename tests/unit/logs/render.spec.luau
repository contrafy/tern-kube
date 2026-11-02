--!strict
-- What the logs lens shows (track 2 plan 4.4-4.6): raw whenever kubectl
-- printed only an error or nothing, raw while a follow runs unless the user
-- opted in, otherwise records with counts, chips, an inspector, pages with
-- the newest first and the small context view a jump needs.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Parse = require("../../../plugin/lib/logs/parse")
local Render = require("../../../plugin/lib/logs/render")
local Store = require("../../../plugin/lib/logs/store")
local Viewstate = require("../../../plugin/lib/logs/viewstate")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Store = Store.Store
type LogsView = Viewstate.LogsView

local BIG = { maxLines = 100000, maxBytes = 1e9 }
local POD = "tk-logmix-6856789c59-kh4x5"

local function storeOf(command: string, lines: { string }, status: number?, limits: any?): (Store, any)
	local run = runs.run(command)
	local inv = Argv.parse(run.program, run.args)
	local s = Store.new(Parse.optionsFor(inv, json.decode), limits or BIG)
	for _, l in lines do
		Store.push(s, l)
	end
	if status then
		Store.finish(s, status)
	end
	return s, inv
end

local function fixture(id: string, limits: any?): (Store, any)
	local f = runs.load(id)
	local inv = Argv.parse(f.run.program, f.run.args)
	local s = Store.new(Parse.optionsFor(inv, json.decode), limits or BIG)
	for _, l in f.lines do
		Store.push(s, l)
	end
	Store.finish(s, f.status)
	return s, inv
end

local NO_LINKS: Render.Links = { variants = {} }
local DONE: Render.Options = { pageSize = 500, running = false, streamingView = "raw" }

local function view(s: Store, inv: any, vs: LogsView?, links: Render.Links?, opts: Render.Options?): any
	return Render.render(s, inv, vs or Viewstate.default(), links or NO_LINKS, opts or DONE)
end

local function rendered(s: Store, inv: any, vs: LogsView?, links: Render.Links?, opts: Render.Options?): any
	local node = view(s, inv, vs, links, opts)
	assert(node, "expected the native logs view")
	return node
end

local function decodeAction(a: string?): LogsView
	assert(a and string.sub(a, 1, 3) == "lv=", "not a logs view action: " .. tostring(a))
	return Viewstate.decode(string.sub(a, 4))
end

local function badge(node: any, label: string): any
	local found = nodes.find(node, function(n)
		return n.k == "badge" and string.find(nodes.ownText(n), label, 1, true) == 1
	end)
	assert(found, "no chip " .. label)
	return found
end

local function rows(node: any): { any }
	return nodes.findAll(node, nodes.class("tk-r"))
end

local function cellTexts(row: any): { string }
	local out: { string } = {}
	for _, c in nodes.findAll(row, nodes.class("tk-c")) do
		table.insert(out, nodes.text(c))
	end
	return out
end

local function headers(node: any): { string }
	local out: { string } = {}
	for _, h in nodes.findAll(node, nodes.class("tk-h")) do
		table.insert(out, nodes.text(h))
	end
	return out
end

local function synthetic(n: number, every: number?): { string }
	local lines: { string } = {}
	for i = 1, n do
		if every and i % every == 0 then
			table.insert(lines, string.format('{"level":"error","msg":"boom %d"}', i))
		else
			table.insert(lines, string.format('{"level":"info","msg":"line %d"}', i))
		end
	end
	return lines
end

describe("logs render raw rules (plan 4.6)", function()
	it("kubectl errors with no records stay raw: missing pod, bad container, no previous", function()
		for _, id in
			{
				"ns-logs/logs_nopod",
				"ns-logs/logs_" .. POD .. "_-c_nope",
				"ns-logs/logs_" .. POD .. "_-p_-c_app",
			}
		do
			local s, inv = fixture(id)
			expect(id .. " " .. tostring(view(s, inv))).toBe(id .. " nil")
		end
	end)

	it("too many follow streams is a kubectl error, so raw", function()
		local s, inv = fixture("ns-logs/logs_-f_-l_app=tk-logmix_--all-containers_--prefix")
		expect(view(s, inv)).toBeNil()
	end)

	it("empty output stays raw; a finished run with records is native", function()
		local empty, inv = storeOf("kubectl logs p", {}, 0)
		expect(view(empty, inv)).toBeNil()
		local s, inv2 = fixture("ns-logs/logs_" .. POD .. "_-p_-c_crashy")
		expect(view(s, inv2) ~= nil).toBe(true)
	end)

	-- `logs -p` of a previous instance whose log the kubelet already removed
	-- prints only kubectl's own line, on stdout, with exit 0. A native view
	-- would be an empty grid under a notice; raw is what the terminal shows.
	it("kubectl's own error with exit 0 and no records stays raw", function()
		local s, inv = storeOf("kubectl logs p -p -c crashy", {
			'unable to retrieve container logs for containerd://0123abcd: log "/var/log/pods/x/crashy/3.log" not found',
		}, 0)
		expect(view(s, inv)).toBeNil()
		local defaulted, inv2 = storeOf("kubectl logs p", { 'Defaulted container "app" out of: app, side' }, 0)
		expect(view(defaulted, inv2) ~= nil).toBe(true)
	end)
end)

describe("logs render running policy", function()
	local RAW: Render.Options = { pageSize = 500, running = true, streamingView = "raw" }
	local NATIVE: Render.Options = { pageSize = 500, running = true, streamingView = "native" }

	-- Plan F3: plugin lenses get lines late, so a live native view of a
	-- follow would trail what the terminal shows.
	it("a running follow is raw by default, native with a trailing note when opted in", function()
		local s, inv = storeOf("kubectl logs -f p", synthetic(20))
		expect(view(s, inv, nil, nil, RAW)).toBeNil()
		local node = rendered(s, inv, nil, nil, NATIVE)
		expect(nodes.text(nodes.find(node, nodes.role("tern-kube.note")) :: any)).toBe(Render.TRAILS)
		expect(nodes.ownText(badge(node, "Live"))).toBe("Live")
	end)

	it("a running non-follow command renders natively (lines arrive in bursts)", function()
		local s, inv = storeOf("kubectl logs p", synthetic(20))
		local node = rendered(s, inv, nil, nil, RAW)
		expect(nodes.find(node, nodes.role("tern-kube.note"))).toBeNil()
	end)

	it("a follow stopped with Ctrl-C is native with every line and says stopped", function()
		local lines = synthetic(6)
		table.insert(lines, "^C%")
		local s, inv = storeOf("kubectl logs -f p", lines, 1)
		local node = rendered(s, inv)
		expect(nodes.text(nodes.find(node, nodes.role("tern-kube.stopped")) :: any)).toBe("stopped (Ctrl-C)")
		expect(nodes.find(node, nodes.role("tern-kube.exit"))).toBeNil()
		expect(#rows(node)).toBe(6)
		expect(nodes.find(node, nodes.hasText("^C"))).toBeNil()
	end)
end)

describe("logs render header and body", function()
	it("names the command and counts lines, errors and warnings", function()
		local s, inv = fixture("ns-logs/logs_" .. POD .. "_-c_app")
		local node = rendered(s, inv)
		expect(node.p.role).toBe("tern-kube.logs")
		local header = nodes.find(node, nodes.role("tern-kube.header")) :: any
		expect(nodes.text(header)).toContain("kubectl logs " .. POD)
		local counts = nodes.text(nodes.find(header, nodes.role("tern-kube.counts")) :: any)
		expect(counts).toBe(Render.countsText(s))
		local c: any = s.counts
		expect(counts).toContain(c.error + c.fatal .. " errors")
		expect(counts).toContain(c.warn .. " warnings")
	end)

	it("one source: LEVEL and MESSAGE columns, no SOURCE; level badges toned", function()
		local s, inv = fixture("ns-logs/logs_" .. POD .. "_-c_app")
		local node = rendered(s, inv, nil, nil, { pageSize = 100000, running = false, streamingView = "raw" })
		expect(headers(node)).toEqual({ "TIME", "LEVEL", "MESSAGE" })
		local first = rows(node)[1]
		expect(cellTexts(first)[2]).toBe("INFO")
		expect(cellTexts(first)[3]).toBe("server started port=8080")
		local klog = rows(node)[2]
		expect(cellTexts(klog)[3]).toContain("controller.go:42")
		local java = nodes.find(node, function(n)
			return n.k == "text" and string.find(nodes.ownText(n), "IllegalStateException", 1, true) ~= nil
		end) :: any
		expect(nodes.ownText(java)).toContain("+2 lines")
	end)

	it("error and warning rows carry the level row classes", function()
		local s, inv = fixture("ns-logs/logs_" .. POD .. "_-c_app")
		local node = rendered(s, inv, nil, nil, { pageSize = 100000, running = false, streamingView = "raw" })
		local classes: { [string]: boolean } = {}
		for _, r in rows(node) do
			classes[r.p.class] = true
		end
		expect(classes["tk-r tk-lvl-error"]).toBe(true)
		expect(classes["tk-r tk-lvl-warn"]).toBe(true)
	end)

	it("Found/Defaulted lines are notices, never rows", function()
		local s, inv = fixture("ns-logs/logs_deploy+tk-logmix")
		local node = rendered(s, inv, nil, nil, { pageSize = 100000, running = false, streamingView = "raw" })
		local notices = nodes.text(nodes.find(node, nodes.role("tern-kube.notices")) :: any)
		expect(notices).toContain("Found 2 pods")
		expect(notices).toContain('Defaulted container "app"')
		for _, r in rows(node) do
			local msg = cellTexts(r)[#cellTexts(r)]
			expect((string.find(msg, "^Found %d+ pods"))).toBeNil()
			expect((string.find(msg, "^Defaulted container"))).toBeNil()
		end
	end)

	it("several sources: SOURCE column, source chips with counts, By time chip", function()
		local s, inv = fixture("ns-logs/logs_-l_app=tk-logmix_--all-containers_--prefix_--timestamps")
		local node = rendered(s, inv)
		expect(headers(node)).toEqual({ "TIME", "SOURCE", "LEVEL", "MESSAGE" })
		local sources = nodes.find(node, nodes.key("sources")) :: any
		expect(#nodes.findAll(sources, nodes.kind("badge"))).toBe(#s.sources)
		local merge = badge(node, "By time")
		expect(decodeAction(nodes.action(merge)).merge).toBe(true)
		expect(Render.countsText(s)).toContain("2 pods")
		expect(Render.countsText(s)).toContain("3 containers")
	end)

	it("By time is disabled without --timestamps, and says why", function()
		local s, inv = fixture("ns-logs/logs_-l_app=tk-logmix_-c_app_--prefix")
		local node = rendered(s, inv)
		local merge = badge(node, "By time")
		expect(nodes.action(merge)).toBeNil()
		expect(merge.p.title).toContain("--timestamps")
	end)

	it("unprefixed multi-pod output says it cannot be attributed", function()
		local s, inv = fixture("ns-logs/logs_-l_app=tk-logmix")
		local node = rendered(s, inv)
		expect(nodes.text(node)).toContain(Render.UNATTRIBUTED)
	end)

	it("Errors chip keeps error and fatal lines only, and carries the rest of the state", function()
		local s, inv = fixture("ns-logs/logs_" .. POD .. "_-c_app")
		local vs = Viewstate.default()
		vs.wrap = true
		local node = rendered(s, inv, vs)
		local next = decodeAction(nodes.action(badge(node, "Errors")))
		expect(next.levels).toEqual({ "fatal", "error" })
		expect(next.wrap).toBe(true)
		local filtered = rendered(s, inv, next)
		for _, r in rows(filtered) do
			expect(string.find(r.p.class, "tk-lvl-error", 1, true) ~= nil).toBe(true)
		end
		local off = decodeAction(nodes.action(badge(filtered, "Errors")))
		expect(off.levels).toEqual({})
	end)

	it("Wrap toggles the wrap class on the grid", function()
		local s, inv = fixture("ns-logs/logs_" .. POD .. "_-c_app")
		local node = rendered(s, inv)
		local grid = nodes.find(node, nodes.class("tk-grid")) :: any
		expect((string.find(grid.p.class, "tk-lwrap", 1, true))).toBeNil()
		local wrapped = rendered(s, inv, decodeAction(nodes.action(badge(node, "Wrap"))))
		expect((nodes.find(wrapped, nodes.class("tk-lwrap")) :: any) ~= nil).toBe(true)
	end)

	it("caps a long cell but keeps the whole line for the inspector and Copy line", function()
		local long = string.rep("x", 3000)
		local s, inv = storeOf("kubectl logs p", { "long: " .. long }, 0)
		local node = rendered(s, inv)
		local cell = cellTexts(rows(node)[1])
		expect(#cell[#cell] <= Render.CELL_CAP + #"…").toBe(true)
		expect(Render.copyText(s, 1, "line")).toBe("long: " .. long)
	end)
end)

describe("logs render inspector and copies", function()
	it("a row click opens the inspector with fields and copy chips", function()
		local s, inv = fixture("ns-logs/logs_" .. POD .. "_-c_app")
		local all: Render.Options = { pageSize = 100000, running = false, streamingView = "raw" }
		local node = rendered(s, inv, nil, nil, all)
		local open = decodeAction(nodes.action(rows(node)[1]))
		expect(open.open).toBe(1)
		local insp = nodes.find(rendered(s, inv, open, nil, all), nodes.role("tern-kube.inspector")) :: any
		expect(nodes.text(insp)).toContain("port")
		expect(nodes.action(badge(insp, "Copy line"))).toBe("copy-line=1")
		expect(nodes.action(badge(insp, "Copy JSON"))).toBe("copy-json=1")
		expect(nodes.action(badge(insp, "Explore pod"))).toBe("explore-pod=1")
		expect(decodeAction(nodes.action(badge(insp, "Close"))).open).toBeNil()
	end)

	it("Copy line keeps prefix and time; Copy JSON is the payload only", function()
		local s = fixture("ns-logs/logs_-l_app=tk-logmix_--all-containers_--prefix_--timestamps")
		local idx: number? = nil
		for i = s.first, s.last do
			if s.records[i].format == "json" then
				idx = i
				break
			end
		end
		assert(idx, "a JSON record")
		local line = Render.copyText(s, idx, "line") :: string
		expect(string.sub(line, 1, 5)).toBe("[pod/")
		local payload = Render.copyText(s, idx, "json") :: string
		expect(string.sub(payload, 1, 1)).toBe("{")
		expect(json.decode(payload) ~= nil).toBe(true)
	end)

	it("Copy message includes the stack; Copy JSON only applies to JSON lines", function()
		local s = storeOf("kubectl logs p", {
			"2026-10-30 10:00:05,123 ERROR [main] java.lang.IllegalStateException: bad",
			"\tat com.example.Main.run(Main.java:10)",
		}, 0)
		expect(Render.copyText(s, 1, "msg")).toContain("\tat com.example.Main.run")
		expect(Render.copyText(s, 1, "json")).toBeNil()
		expect(Render.copyText(s, 99, "line")).toBeNil()
	end)

	it("the pod of a record comes from its prefix or the command", function()
		local s = fixture("ns-logs/logs_-l_app=tk-logmix_--all-containers_--prefix_--timestamps")
		expect(string.sub(Render.podOf(s, s.first) :: string, 1, 10)).toBe("tk-logmix-")
		local single = storeOf("kubectl logs mypod", { "hello" }, 0)
		expect(Render.podOf(single, 1)).toBe("mypod")
	end)

	-- kubectl prints no Defaulted line for a single-container pod, so the
	-- container is unknown; the inspector names what is known instead of
	-- showing a placeholder that reads like data.
	it("the inspector names the pod alone when the container is unknown", function()
		local s, inv = storeOf("kubectl logs big-0", { '{"level":"info","msg":"hello"}' }, 0)
		local all: Render.Options = { pageSize = 100000, running = false, streamingView = "raw" }
		local open = decodeAction(nodes.action(rows(rendered(s, inv, nil, nil, all))[1]))
		local insp = nodes.find(rendered(s, inv, open, nil, all), nodes.role("tern-kube.inspector")) :: any
		local text = nodes.text(insp)
		expect(text).toContain("pod/big-0")
		expect((string.find(text, "?", 1, true))).toBeNil()
	end)
end)

describe("logs render pages and context", function()
	it("shows the newest page by default, earlier pages one click away", function()
		local s, inv = storeOf("kubectl logs p", synthetic(1200), 0)
		local node = rendered(s, inv, nil, nil, { pageSize = 500, running = false, streamingView = "raw" })
		local pages = nodes.find(node, nodes.role("tern-kube.pages")) :: any
		expect(nodes.text(pages)).toContain("Lines 1001-1200 of 1200")
		local r = rows(node)
		expect(#r).toBe(200)
		expect(cellTexts(r[#r])[2]).toBe("line 1200")
		local first = decodeAction(nodes.action(badge(pages, "1")))
		expect(first.page).toBe(1)
		local p1 = rendered(s, inv, first)
		expect(cellTexts(rows(p1)[1])[2]).toBe("line 1")
	end)

	it("says when the ring dropped lines that only Raw still has", function()
		local s, inv = storeOf("kubectl logs p", synthetic(300), 0, { maxLines = 100, maxBytes = 1e9 })
		local node = rendered(s, inv)
		expect(nodes.text(nodes.find(node, nodes.role("tern-kube.notices")) :: any)).toContain(
			"200 earlier lines only in Raw"
		)
	end)

	-- A lens cannot scroll its pane; a jump renders few enough lines that the
	-- target is on screen whatever the scroll position.
	it("First error opens a small context view with prev/next error", function()
		local s, inv = storeOf("kubectl logs p", synthetic(200, 50), 0)
		local node = rendered(s, inv)
		local jump = decodeAction(nodes.action(badge(node, "First error")))
		expect(jump.ctx).toBe(50)
		expect(jump.open).toBe(50)
		local ctx = rendered(s, inv, jump)
		expect(#rows(ctx)).toBe(2 * Render.CONTEXT_RADIUS + 1)
		expect(nodes.find(ctx, nodes.role("tern-kube.pages"))).toBeNil()
		local nav = nodes.find(ctx, nodes.role("tern-kube.context")) :: any
		expect(nodes.find(nav, nodes.hasText("◂ Prev error"))).toBeNil()
		local nxt = decodeAction(nodes.action(badge(nav, "Next error ▸")))
		expect(nxt.ctx).toBe(100)
		local back = decodeAction(nodes.action(badge(nav, "All lines")))
		expect(back.ctx).toBeNil()
		expect(nodes.find(ctx, nodes.role("tern-kube.inspector")) ~= nil).toBe(true)
	end)
end)

describe("logs render actions", function()
	local LINKS: Render.Links = {
		follow = "tern-kube://act/logs-follow?x",
		explore = "tern-kube://explore?route=logs",
		search = "tern-kube://explore?route=logs&search=1",
		variants = {
			{ label = "side", url = "tern-kube://act/logs?c=side", title = "kubectl logs p -c side" },
			{ label = "--previous", url = "tern-kube://act/logs?p=1", title = "kubectl logs p --previous" },
		},
	}

	it("offers follow, Explore, Search and the variants as pointer chips", function()
		local s, inv = storeOf("kubectl logs p", synthetic(3), 0)
		local node = rendered(s, inv, nil, LINKS)
		local actions = nodes.find(node, nodes.role("tern-kube.logs-actions")) :: any
		expect(nodes.action(badge(actions, "Follow in split"))).toBe("act=" .. (LINKS.follow :: string))
		expect(nodes.action(badge(actions, "Open in Explore"))).toBe("explore-logs=open")
		expect(nodes.action(badge(actions, "Search…"))).toBe("explore-logs=search")
		local side = badge(actions, "▸ side")
		expect(nodes.action(side)).toBe("act=tern-kube://act/logs?c=side")
		expect(side.p.title).toBe("kubectl logs p -c side")
		expect(nodes.text(actions)).toContain("Run in split")
	end)

	it("caps the variants and sends unknown containers to Explore", function()
		local many: { Render.Variant } = {}
		for i = 1, 9 do
			table.insert(many, { label = "v" .. i, url = "tern-kube://act/logs?" .. i, title = "t" })
		end
		local s, inv = storeOf("kubectl logs p -c app", synthetic(3), 0)
		local capped = rendered(s, inv, nil, { variants = many, explore = "x" })
		expect(#nodes.findAll(capped, nodes.role("tern-kube.quick"))).toBe(Render.MAX_VARIANTS)
		local other = rendered(s, inv, nil, { variants = {}, explore = "x", otherContainers = true })
		expect(nodes.action(badge(other, "▸ other container…"))).toBe("explore-logs=open")
	end)
end)

describe("logs render helpers", function()
	it("clock reads kubelet, ISO and klog times to milliseconds", function()
		expect(Render.clock("2026-11-02T16:44:30.597267795Z")).toBe("16:44:30.597")
		expect(Render.clock("2026-10-30T10:00:04Z")).toBe("10:00:04")
		expect(Render.clock("1030 10:00:01.123456")).toBe("10:00:01.123")
		expect(Render.clock("2026-10-30 10:00:05,123")).toBe("10:00:05.123")
		expect(Render.clock("1730282400")).toBeNil()
	end)

	it("source labels drop what every source shares", function()
		local one = fixture("ns-logs/logs_" .. POD .. "_--all-containers_--prefix_--timestamps")
		expect(Render.sourceLabel(one, 1)).toBe(one.sources[1].container)
		local multi = fixture("ns-logs/logs_-l_app=tk-logmix_--all-containers_--prefix_--timestamps")
		expect(Render.sourceLabel(multi, 1)).toContain("·")
		expect(Render.sourceLabel(multi, 0)).toBe("unattributed")
	end)
end)

return nil
