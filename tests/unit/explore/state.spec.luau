--!strict
-- Explore's pure core: keys and pointer actions become routes and effects,
-- the cluster target is resolved once and then pinned, late results are
-- ignored, and nothing the cluster returned is ever persisted.
local State = require("../../../plugin/lib/explore/state")
local W = require("../../lib/explore")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect

local function top(s: State): State.Route
	return s.stack[#s.stack]
end

local function hasContext(e: Effect, ctx: string): boolean
	local argv = e.argv :: { string }
	local i = table.find(argv, "--context")
	return i ~= nil and argv[i + 1] == ctx
end

local function isKubeconfigQuery(e: Effect): boolean
	return table.find(e.argv :: { string }, "config") ~= nil
end

local function effectsOf(list: { Effect }, kind: string): { Effect }
	local out: { Effect } = {}
	for _, e in list do
		if e.t == kind then
			table.insert(out, e)
		end
	end
	return out
end

local function selectedName(s: State): string?
	local item = State.selectedItem(s)
	return if item and item.ref then item.ref.name else nil
end

describe("explore state: target resolution", function()
	it("a context from the lensed command is verified against the kubeconfig before any query", function()
		local s, effects =
			State.init({ W.link({ context = W.CTX, namespace = W.NS, kind = "Pod" }) }, nil, W.config(nil), W.env())
		expect(#effects).toBe(1)
		expect(table.concat(effects[1].argv :: { string }, " ")).toBe(
			"kubectl --kubeconfig /home/u/.kube/config config get-contexts -o name"
		)
		expect(s.target.contextSource).toBe("flag")
		expect(s.target.confirmed).toBe(true)
		local settled, trace = W.settle(s, effects)
		expect(State.resolved(settled)).toBe(true)
		expect(#trace.runs).toBe(2)
		expect(hasContext(trace.runs[2], W.CTX)).toBe(true)
		expect((State.currentLoad(settled) :: State.Load).status).toBe("ok")
	end)

	it("a context missing from the kubeconfig is an error with the chooser open and no cluster query", function()
		local s, trace = W.open({ context = "ghost", kind = "Pod" })
		expect(s.targetError :: string).toContain('Context "ghost" is not in the kubeconfig')
		expect(top(s).kind).toBe("contexts")
		expect(#trace.runs).toBe(1)
		expect(State.resolved(s)).toBe(false)
		local _, after = W.keys(s, { "escape", "r", ":" })
		expect(#after.runs).toBe(0)
	end)

	it("without a context, current-context is inferred, flagged unconfirmed and then pinned", function()
		local s, trace = W.open({ namespace = W.NS })
		expect(table.concat(trace.runs[1].argv :: { string }, " ")).toContain("config current-context")
		expect(s.target.context).toBe(W.CTX)
		expect(s.target.contextSource).toBe("inferred")
		expect(s.target.confirmed).toBe(false)
		expect(s.target.inferredAt).toBe(W.AT)
		expect(hasContext(trace.runs[2], W.CTX)).toBe(true)
		local confirmed = W.action(s, "confirm")
		expect(confirmed.target.confirmed).toBe(true)
	end)

	-- Tern started from the Dock has PATH=/usr/bin:/bin:/usr/sbin:/sbin; the
	-- user saw a Lua traceback and had no idea why kubectl was "missing".
	it("kubectl that is not found names the launch PATH and the setting to fix it", function()
		local env = W.env()
		env.daemonPath = "/usr/bin:/bin:/usr/sbin:/sbin"
		local s, effects = State.init({ W.link({}) }, nil, W.config(nil), env)
		s = W.settle(s, effects, function()
			return nil, "tern.process.run kubectl: No such file or directory (os error 2)"
		end)
		expect(s.targetErrorKind).toBe("spawn")
		expect(s.targetError :: string).toContain(
			"kubectl not found. Tern runs plugins with the PATH it was launched with (/usr/bin:/bin:/usr/sbin:/sbin)"
		)
		expect(s.targetError :: string).toContain('Set "kubectl" to its full path in Tern Kube: Settings')
		expect(top(s).kind).toBe("list")
	end)

	it("kubectl that cannot run for another reason names the program and the reason", function()
		local s, effects = State.init({ W.link({ context = W.CTX }) }, nil, W.config(nil), W.env())
		s = W.settle(s, effects, function()
			return nil, "Permission denied (os error 13)"
		end)
		expect(s.targetError :: string).toContain("Cannot run kubectl (kubectl): Permission denied (os error 13)")
		expect(s.targetErrorKind).toBe("spawn")
	end)

	it(
		"after a spawn failure, retry restarts with the current program and Settings opens the settings block",
		function()
			local s, effects = State.init({ W.link({}) }, nil, W.config(nil), W.env())
			s = W.settle(s, effects, function()
				return nil, "No such file or directory (os error 2)"
			end)
			local _, retry = State.update(s, W.key("r"))
			expect(retry).toEqual({ { t = "restart" } })
			local _, chip = State.update(s, { t = "action", act = "refresh", value = "" })
			expect(chip).toEqual({ { t = "restart" } })
			local _, settings = State.update(s, { t = "action", act = "settings", value = "" })
			expect(settings).toEqual({ { t = "open", url = "tern-kube://settings?key=kubectl" } })
		end
	)

	it("waits for the login shell's PATH instead of running kubectl without it", function()
		local env = W.env()
		env.pending = true
		local s, effects = State.init({ W.link({ context = W.CTX }) }, nil, W.config(nil), env)
		expect(#effects).toBe(0)
		expect(s.envPending).toBe(true)
		expect(s.targetError).toBeNil()
	end)

	it("disabled live queries run nothing", function()
		local s, effects = State.init(
			{ W.link({ context = W.CTX }) },
			nil,
			W.config('{"explore":{"allow_live_queries":false}}'),
			W.env()
		)
		expect(#effects).toBe(0)
		expect(s.targetError :: string).toContain("allow_live_queries")
	end)

	it("every run after resolution pins --context, across every view", function()
		local s, trace = W.open({ context = W.CTX, namespace = W.NS, kind = "Pod" })
		s, trace = W.keys(s, { "j", "enter", "R", "escape", "d", "escape", "L", "escape", "escape" }, trace)
		s, trace = W.keys(s, { "n", "j", "j", "enter", ":", "j", "enter", "r" }, trace)
		local cluster = 0
		for _, run in trace.runs do
			if not isKubeconfigQuery(run) then
				cluster += 1
				expect(hasContext(run, W.CTX)).toBe(true)
			end
		end
		expect(cluster > 8).toBe(true)
	end)

	it("choosing another context re-roots, pins it and needs a fresh confirmation", function()
		local s = W.open()
		local trace
		s, trace = W.keys(s, { "c", "j", "enter" })
		expect(s.target.context).toBe("other")
		expect(s.target.contextSource).toBe("chosen")
		expect(s.target.confirmed).toBe(false)
		expect(#s.stack).toBe(1)
		local runs = effectsOf(trace.effects, "run")
		expect(hasContext(runs[#runs], "other")).toBe(true)
	end)
end)

describe("explore state: keys", function()
	it("j/k move, gg and G jump, unknown keys change nothing", function()
		local s = W.open()
		expect(selectedName(s)).toBe("broken-image-68986f4958-6qp2v")
		s = W.keys(s, { "j", "j", "k" })
		local second = selectedName(s)
		s = W.keys(s, { "G" })
		local last = selectedName(s)
		expect(last ~= second).toBe(true)
		s = W.keys(s, { "g", "g" })
		expect(selectedName(s)).toBe("broken-image-68986f4958-6qp2v")
		local same = State.update(s, W.key("f5"))
		expect(same).toBe(s)
	end)

	it("/ focuses the filter input and typed text narrows the rows", function()
		local s = W.open()
		local s2, effects = State.update(s, W.key("/"))
		expect(s2.editing).toBe(true)
		expect(effects).toEqual({ { t = "focus", id = "main.filter" } })
		s2 = W.keys(s2, { "w", "e", "b", "backspace", "b" })
		expect(s2.filter[State.currentKey(s2)]).toBe("web")
		for _, item in State.items(s2) do
			expect((item.ref :: any).name).toContain("web")
		end
		s2 = W.keys(s2, { "escape" })
		expect(s2.editing).toBe(false)
		expect(s2.filter[State.currentKey(s2)]).toBe("web")
	end)

	it("enter drills in, escape walks back to the root, then clears the filter, then closes", function()
		local s = W.open()
		s = W.keys(s, { "/", "w", "e", "b", "enter", "enter" })
		expect(top(s).kind).toBe("detail")
		expect((top(s).ref :: any).name).toContain("web")
		s = W.keys(s, { "enter" })
		expect(top(s).kind).toBe("relations")
		s = W.keys(s, { "escape", "escape" })
		expect(#s.stack).toBe(1)
		expect(s.filter[State.currentKey(s)]).toBe("web")
		local cleared, none = State.update(s, W.key("escape"))
		expect(cleared.filter[State.currentKey(cleared)]).toBeNil()
		expect(#none).toBe(0)
		local _, exit = State.update(cleared, W.key("escape"))
		expect(exit).toEqual({ { t = "exit" } })
	end)

	-- Explore opened from a lens row lands on the object; its list was never
	-- shown, so walking back must keep the user's place on that row, not
	-- jump to the first one.
	it("escape from an object opened by a link selects that object in its list", function()
		local s = W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment", group = "apps", name = "web" })
		expect(top(s).kind).toBe("detail")
		s = W.keys(s, { "escape" })
		expect(top(s).kind).toBe("list")
		expect(selectedName(s)).toBe("web")
	end)

	it("d, y, L and R open views of the selection; Y copies the view's command", function()
		local s = W.open()
		s = W.keys(s, { "d" })
		expect(top(s).kind).toBe("describe")
		expect((State.currentLoad(s) :: State.Load).status).toBe("ok")
		s = W.keys(s, { "escape", "y" })
		expect(top(s).kind).toBe("detail")
		s = W.keys(s, { "L" })
		expect(top(s).kind).toBe("logs")
		expect(((State.currentLoad(s) :: State.Load).data :: any).lines).toEqual({ "log line 1", "log line 2" })
		local _, effects = State.update(s, W.key("Y"))
		expect(effects[1].t).toBe("copy")
		expect(effects[1].text :: string).toContain(
			"kubectl --kubeconfig /home/u/.kube/config --context kind-tern-kube-dev logs"
		)
	end)

	it("? toggles the help layer and escape closes it before navigating", function()
		local s = W.open()
		s = W.keys(s, { "?" })
		expect(s.help).toBe(true)
		local s2, effects = State.update(s, W.key("escape"))
		expect(s2.help).toBe(false)
		expect(#effects).toBe(0)
	end)
end)

describe("explore state: quick actions", function()
	it("s on a pod opens a shell link pinned to the context", function()
		local s = W.open()
		local _, effects = State.update(s, W.key("s"))
		expect(effects[1].t).toBe("open")
		local url = effects[1].url :: string
		expect(string.sub(url, 1, 22)).toBe("tern-kube://act/shell?")
		expect(url).toContain("context=" .. W.CTX)
	end)

	it("l on a deployment follows logs by its selector; shift+f forwards a declared port", function()
		local s = W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment" })
		s = W.keys(s, { "/", "w", "e", "b", "enter", "enter" })
		expect(top(s).kind).toBe("detail")
		local _, logs = State.update(s, W.key("l"))
		expect(logs[1].t).toBe("open")
		expect(logs[1].url :: string).toContain("logs-follow?")
		expect(logs[1].url :: string).toContain("selector=")
		local _, pf = State.update(s, W.key("F", { text = "F", shift = true }))
		expect(pf[1].url :: string).toContain("port-forward?")
	end)

	it("s on a deployment resolves a ready pod first, then opens its shell", function()
		local s = W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment" })
		s = W.keys(s, { "/", "w", "e", "b", "enter", "enter" })
		local s2, effects = State.update(s, W.key("s"))
		expect(effects[1].t).toBe("run")
		expect(table.concat(effects[1].argv :: { string }, " ")).toContain(
			"get pods -n tern-test-apps -l app=web -o json"
		)
		local _, trace = W.settle(s2, effects)
		local opens = effectsOf(trace.effects, "open")
		expect(#opens).toBe(1)
		expect(opens[1].url :: string).toContain("pod=web-65d7d99975-")
	end)

	-- Explore never mutates by itself: the keys only open the approve block
	-- through a tern-kube://mutate link naming the focused object and the
	-- pinned context, which the block previews before anything runs.
	it("ctrl+d, ctrl+r and shift+s open mutate links for the focused object", function()
		local s = W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment" })
		s = W.keys(s, { "/", "w", "e", "b", "enter", "enter" })
		local _, del = State.update(s, W.key("d", { ctrl = true }))
		expect(del[1].t).toBe("open")
		local url = del[1].url :: string
		expect(string.sub(url, 1, 28)).toBe("tern-kube://mutate?op=delete")
		expect(url).toContain("kind=deployment.apps&name=web&namespace=" .. W.NS)
		expect(url).toContain("context=" .. W.CTX .. "&source=flag")
		local _, restart = State.update(s, W.key("r", { ctrl = true }))
		expect(restart[1].url :: string).toContain("op=restart")
		local _, scale = State.update(s, W.key("S", { text = "S", shift = true }))
		expect(scale[1].url :: string).toContain("op=scale")
		expect((string.find(scale[1].url :: string, "replicas=", 1, true))).toBeNil()
		local _, scale2 = State.update(s, W.key("s", { text = "s", shift = true }))
		expect(scale2[1].url :: string).toContain("op=scale")
	end)

	it("refuses restart and scale on kinds that do not support them", function()
		local s = W.open()
		local _, effects = State.update(s, W.key("r", { ctrl = true }))
		expect(effects[1].t).toBe("toast")
		local _, del = State.update(s, W.key("d", { ctrl = true }))
		expect(del[1].url :: string).toContain("op=delete&kind=pod&")
	end)

	it("offers no mutation when mutations are disabled", function()
		local s = W.open(nil, W.config('{"mutations": {"enabled": false}}'))
		for _, k in { W.key("d", { ctrl = true }), W.key("r", { ctrl = true }), W.key("S", { shift = true }) } do
			local _, effects = State.update(s, k)
			expect(#effects).toBe(1)
			expect(effects[1].t).toBe("toast")
			expect(effects[1].text).toBe("Mutations are disabled")
		end
	end)
end)

describe("explore state: relations", function()
	it("R on a deployment walks owner references down to its pods and enter opens one", function()
		local s = W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment" })
		local trace
		s, trace = W.keys(s, { "/", "w", "e", "b", "enter", "R" })
		expect(top(s).kind).toBe("relations")
		local load = State.currentLoad(s) :: State.Load
		expect(load.status).toBe("ok")
		local graph = (load.data :: State.RelationsData).graph :: any
		local kinds: { [string]: number } = {}
		for _, node in graph.nodes do
			kinds[node.ref.kind] = (kinds[node.ref.kind] or 0) + 1
		end
		expect(kinds.Deployment).toBe(1)
		expect((kinds.ReplicaSet or 0) >= 1).toBe(true)
		expect(kinds.Pod).toBe(2)
		for _, run in trace.runs do
			if not isKubeconfigQuery(run) then
				expect(hasContext(run, W.CTX)).toBe(true)
			end
		end
		s = W.keys(s, { "/", "z", "s", "b", "enter", "enter" })
		expect(top(s).kind).toBe("detail")
		expect((top(s).ref :: any).kind).toBe("Pod")
	end)
end)

describe("explore state: results", function()
	it("a stale result is ignored and the newest one wins", function()
		local s = W.open()
		local s1, first = State.update(s, W.key("r"))
		local s2, second = State.update(s1, W.key("r"))
		expect(first[1].gen ~= second[1].gen).toBe(true)
		local stale = {
			t = "result",
			tag = first[1].tag,
			gen = first[1].gen,
			result = W.fail(1, "error: old"),
			at = W.AT,
		} :: State.Msg
		local s3, none = State.update(s2, stale)
		expect(s3).toBe(s2)
		expect(#none).toBe(0)
		expect((State.currentLoad(s3) :: State.Load).status).toBe("loading")
		local s4 = W.settle(s3, second)
		expect((State.currentLoad(s4) :: State.Load).status).toBe("ok")
	end)

	it("Forbidden, timeouts and unreachable clusters become actionable errors", function()
		local cases: { { any } } = {
			{
				W.fail(1, 'Error from server (Forbidden): pods is forbidden: User "dev" cannot list resource "pods"'),
				"forbidden",
				"RBAC",
			},
			{ { status = -1, stdout = "", stderr = "", timed_out = true }, "timeout", "query_timeout_ms" },
			{
				W.fail(1, "Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused"),
				"unreachable",
				"unreachable",
			},
			{ W.fail(1, 'error: context "x" does not exist'), "context", "Pick another context" },
		}
		for _, case in cases do
			local s = W.open()
			local s2, effects = State.update(s, W.key("r"))
			s2 = W.settle(s2, effects, function()
				return case[1] :: any
			end)
			local load = State.currentLoad(s2) :: State.Load
			expect(load.status).toBe("error")
			expect(load.errorKind).toBe(case[2])
			expect(load.error :: string).toContain(case[3] :: string)
		end
	end)

	it("an empty list loads as ok with no rows", function()
		local s = W.open({ context = W.CTX, namespace = "tern-test-empty", kind = "Pod" })
		local load = State.currentLoad(s) :: State.Load
		expect(load.status).toBe("ok")
		expect(#(load.data :: State.ListData).rows).toBe(0)
	end)

	it("ticks only ask for a render when the shown age changes", function()
		local s = W.open()
		local s1, e1 = State.update(s, { t = "tick", now = W.AT + 2 })
		expect(#e1).toBe(0)
		local _, e2 = State.update(s1, { t = "tick", now = W.AT + 12 })
		expect(e2).toEqual({ { t = "render" } })
	end)
end)

describe("explore state: save", function()
	local function walk(v: any, fn: (string) -> ())
		if type(v) ~= "table" then
			return
		end
		for k, x in v do
			if type(k) == "string" then
				fn(k)
			end
			walk(x, fn)
		end
	end

	it("round-trips navigation and target but never cluster data", function()
		local s = W.open()
		s = W.keys(s, { "j", "/", "w", "e", "b", "enter", "enter", "R" })
		local saved = State.save(s)
		walk(saved, function(k)
			expect(k ~= "cache" and k ~= "items" and k ~= "object" and k ~= "metadata" and k ~= "status").toBe(true)
		end)
		local restored, effects =
			State.init({ W.link({ context = "ignored-by-saved" }) }, saved, W.config(nil), W.env())
		expect(restored.target.context).toBe(W.CTX)
		expect(restored.target.contextSource).toBe("flag")
		expect(#restored.stack).toBe(#s.stack)
		expect(top(restored).kind).toBe("relations")
		expect(restored.filter).toEqual(s.filter)
		expect(restored.sel).toEqual(s.sel)
		expect(next(restored.cache) ~= nil).toBe(true)
		expect(#effects).toBe(1)
		local settled = W.settle(restored, effects)
		expect((State.currentLoad(settled) :: State.Load).status).toBe("ok")
	end)

	it("an inferred context stays pinned after a restore", function()
		local s = W.open({ namespace = W.NS })
		local restored = State.init({ W.link({}) }, State.save(s), W.config(nil), W.env())
		expect(restored.target.context).toBe(W.CTX)
		expect(restored.target.contextSource).toBe("inferred")
		expect(restored.target.confirmed).toBe(false)
	end)
end)

-- An el grid is not a Tern list: nothing scrolls it to the keyboard
-- selection, so the core only renders a window sized from the block height
-- and keeps the selection inside it, vim-style (scrolloff).
describe("explore state: visible window", function()
	-- 22 lines leave room for 3 grid rows: the 7 tern-test-apps pods overflow.
	local function small(): State
		local s = W.open()
		return (State.update(s, { t = "resize", rows = 22 }))
	end

	local function shown(s: State): (number, number)
		local items = State.items(s)
		return State.window(
			State.selectedIndex(s, items),
			#items,
			s.offset[State.currentKey(s)],
			State.viewport(s.rows, s.config.general.max_rendered_rows)
		)
	end

	it("sizes the window from the block height, capped by max_rendered_rows", function()
		expect(State.viewport(22, 500)).toBe(3)
		expect(State.viewport(nil, 500)).toBe(500)
		expect(State.viewport(200, 50)).toBe(50)
	end)

	it("G puts the last row in the window", function()
		local s = W.keys(small(), { "G" })
		local first, last = shown(s)
		expect(last).toBe(7)
		expect(first).toBe(5)
		expect(s.offset[State.currentKey(s)]).toBe(5)
	end)

	it("j and k past the scrolloff edge shift the window by one row", function()
		local s = W.keys(small(), { "j" })
		expect((shown(s))).toBe(1)
		s = W.keys(s, { "j" })
		expect((shown(s))).toBe(2)
		s = W.keys(s, { "j" })
		expect((shown(s))).toBe(3)
		s = W.keys(s, { "k" })
		expect((shown(s))).toBe(2)
		s = W.keys(s, { "k" })
		expect((shown(s))).toBe(1)
	end)

	it("pagedown and pageup move by a window", function()
		local s = W.keys(small(), { "pagedown" })
		expect(State.selectedIndex(s, State.items(s))).toBe(4)
		s = W.keys(s, { "pageup" })
		expect(State.selectedIndex(s, State.items(s))).toBe(1)
		local clicked = W.action(s, "page", "down")
		expect(State.selectedIndex(clicked, State.items(clicked))).toBe(4)
	end)

	it("shrinking the block keeps the selection visible", function()
		local s = W.keys((State.update(W.open(), { t = "resize", rows = 40 })), { "G" })
		expect((shown(s))).toBe(1)
		s = (State.update(s, { t = "resize", rows = 22 }))
		local first, last = shown(s)
		expect(first <= 7 and 7 <= last).toBe(true)
		expect(s.offset[State.currentKey(s)]).toBe(5)
	end)

	it("a new filter starts the window over", function()
		local s = W.keys(small(), { "G" })
		s = W.keys(s, { "/", "e" })
		expect(s.offset[State.currentKey(s)]).toBe(1)
	end)
end)

return nil
