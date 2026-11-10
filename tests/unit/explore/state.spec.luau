--!strict
-- Explore's pure core: keys and pointer actions become routes and effects,
-- the cluster target is resolved once and then pinned, late results are
-- ignored, and nothing the cluster returned is ever persisted.
local Blocksize = require("../../../plugin/lib/blocksize")
local State = require("../../../plugin/lib/explore/state")
local Table = require("../../../plugin/lib/render/table")
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

	-- A first Explore landed on "No pods in ns (context default)": a new user
	-- saw nothing (LENS-L12).
	it("a first-ever block starts in all namespaces", function()
		local env = W.env()
		env.lastScope = nil
		local s, effects = State.init({ W.link({}) }, nil, W.config(nil), env)
		s = W.settle(s, effects)
		expect(s.target.allNamespaces).toBe(true)
		expect(table.find((State.currentLoad(s) :: State.Load).argv, "-A") ~= nil).toBe(true)
	end)

	it("a fresh block starts in the scope the last Explore used on the same context", function()
		local env = W.env()
		env.lastScope = { context = W.CTX, namespace = W.NS, all = false }
		local s, effects = State.init({ W.link({}) }, nil, W.config(nil), env)
		s = W.settle(s, effects)
		expect(s.target.namespace).toBe(W.NS)
		expect(s.target.allNamespaces).toBe(false)
	end)

	it("the last scope of another context is not carried over", function()
		local env = W.env()
		env.lastScope = { context = "other", namespace = W.NS, all = false }
		local s, effects = State.init({ W.link({}) }, nil, W.config(nil), env)
		s = W.settle(s, effects)
		expect(s.target.namespace).toBeNil()
		expect(s.target.allNamespaces).toBe(true)
	end)

	it("a namespace named by the link wins over the last scope", function()
		local env = W.env()
		env.lastScope = { context = W.CTX, namespace = "elsewhere", all = false }
		local s, effects = State.init({ W.link({ namespace = W.NS }) }, nil, W.config(nil), env)
		s = W.settle(s, effects)
		expect(s.target.namespace).toBe(W.NS)
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

	it("the filter edits at the caret, with native edits and undo", function()
		local s = W.keys(W.open(), { "/", "w", "b" })
		s = W.keys(s, { "left" })
		s = W.keys(s, { "e" })
		expect(s.filter[State.currentKey(s)]).toBe("web")
		expect((s.input :: any).cursor).toBe(2)
		-- Tern replaced a selection (all of it) and put the caret at the end.
		s = State.update(s, {
			t = "edit",
			id = State.FILTER_INPUT,
			edit = { from = 0, to = 3, text = "db", cursor = 2, len = 3 },
		})
		expect(s.filter[State.currentKey(s)]).toBe("db")
		for _, item in State.items(s) do
			expect((item.ref :: any).name).toContain("db")
		end
		-- One sent with an older text is dropped, not misapplied.
		local stale = State.update(s, {
			t = "edit",
			id = State.FILTER_INPUT,
			edit = { from = 0, to = 3, text = "", cursor = 0, len = 3 },
		})
		expect(stale).toBe(s)
		s = State.update(s, { t = "undo", id = State.FILTER_INPUT })
		expect(s.filter[State.currentKey(s)]).toBe("web")
		s = State.update(s, { t = "undo", id = State.FILTER_INPUT })
		s = State.update(s, { t = "undo", id = State.FILTER_INPUT })
		expect(s.filter[State.currentKey(s)]).toBeNil()
		expect(s.editing).toBe(true)
	end)

	it("leaving the filter gives up its focus, so list keys stay Explore's", function()
		local s = W.keys(W.open(), { "/", "w" })
		local _, effects = State.update(s, W.key("enter"))
		expect(effects).toEqual({ { t = "blur" } })
		local _, cancelled = State.update(s, W.key("escape"))
		expect(cancelled).toEqual({ { t = "blur" } })
	end)

	it("an edit in the filter while the list has the keys starts editing it", function()
		local s = W.keys(W.open(), { "/", "w", "e", "b", "enter" })
		expect(s.editing).toBe(false)
		local s2, effects = State.update(s, {
			t = "edit",
			id = State.FILTER_INPUT,
			edit = { from = 0, to = 0, text = "", cursor = 0, len = 3 },
		})
		expect(s2.editing).toBe(true)
		expect((s2.input :: any).cursor).toBe(0)
		expect(effects).toEqual({ { t = "focus", id = "main.filter" } })
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
		local armed, first = State.update(cleared, W.key("escape"))
		expect(#effectsOf(first, "exit")).toBe(0)
		local _, exit = State.update(armed, W.key("escape"))
		expect(effectsOf(exit, "exit")).toEqual({ { t = "exit" } })
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
		local data = (State.currentLoad(s) :: State.Load).data :: State.LogsData
		expect(data.store.last > 0).toBe(true)
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

	-- Explore runs on the pane's host, the split opens from the window: the
	-- link carries this host's placement and logs tail so a remote host's
	-- config governs its own quick actions.
	it("quick links carry the host's quick_actions placement and logs tail", function()
		local cfg = W.config('{"quick_actions": {"placement": "tab", "logs_tail": 75}}')
		local s = W.open(nil, cfg)
		local _, logs = State.update(s, W.key("l"))
		expect(logs[1].url :: string).toContain("tail=75")
		expect(logs[1].url :: string).toContain("place=tab")
		local _, shell = State.update(s, W.key("s"))
		expect(shell[1].url :: string).toContain("place=tab")
		expect((string.find(shell[1].url :: string, "tail=", 1, true))).toBeNil()
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

	it("t T X U p P open label, annotate, patch and rollout links for the focused workload", function()
		local s = W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment" })
		s = W.keys(s, { "/", "w", "e", "b", "enter", "enter" })
		local cases: { { any } } = {
			{ W.key("t"), "op=label&kind=deployment.apps&name=web" },
			{ W.key("T", { text = "T", shift = true }), "op=annotate&" },
			{ W.key("t", { shift = true }), "op=annotate&" },
			{ W.key("X", { text = "X", shift = true }), "op=patch&" },
			{ W.key("U", { text = "U", shift = true }), "op=undo&" },
			{ W.key("p"), "op=pause&" },
			{ W.key("P", { text = "P", shift = true }), "op=resume&" },
		}
		for _, c in cases do
			local _, effects = State.update(s, c[1])
			expect(effects[1].t).toBe("open")
			expect(effects[1].url :: string).toContain(c[2])
			expect(effects[1].url :: string).toContain("context=" .. W.CTX)
		end
	end)

	-- k9s binds c/r on nodes; here they are the context picker and refresh,
	-- so node operations take C u D. A key on the wrong kind says why.
	it("C u D are node operations and toast on other kinds; shift never falls through to d or c", function()
		local s = W.open()
		local cases: { { any } } = {
			{ W.key("C", { text = "C", shift = true }), "Cannot cordon Pod" },
			{ W.key("u"), "Cannot uncordon Pod" },
			{ W.key("D", { text = "D", shift = true }), "Cannot drain Pod" },
			{ W.key("U", { text = "U", shift = true }), "Cannot undo Pod" },
			{ W.key("p"), "Cannot pause Pod" },
		}
		for _, c in cases do
			local s2, effects = State.update(s, c[1])
			expect(#effects).toBe(1)
			expect(effects[1].t).toBe("toast")
			expect(effects[1].text).toBe(c[2])
			expect(top(s2).kind).toBe(top(s).kind)
		end
		local _, label = State.update(s, W.key("t"))
		expect(label[1].url :: string).toContain("op=label&kind=pod&")
	end)

	it("e opens kubectl edit for the focused object as a quick action", function()
		local s = W.open()
		local _, effects = State.update(s, W.key("e"))
		expect(effects[1].t).toBe("open")
		local url = effects[1].url :: string
		expect(string.sub(url, 1, 21)).toBe("tern-kube://act/edit?")
		expect(url).toContain("kind=Pod&")
		expect(url).toContain("context=" .. W.CTX)
	end)

	it("offers no mutation when mutations are disabled", function()
		local s = W.open(nil, W.config('{"mutations": {"enabled": false}}'))
		for _, k in
			{
				W.key("d", { ctrl = true }),
				W.key("r", { ctrl = true }),
				W.key("S", { shift = true }),
				W.key("e"),
				W.key("t"),
				W.key("X", { text = "X", shift = true }),
				W.key("D", { text = "D", shift = true }),
			}
		do
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

-- Logs and events stay on the el grid: nothing scrolls it to the keyboard
-- selection, so those views build a window sized from the block height.
describe("explore state: grid window (logs, events)", function()
	it("sizes the window from the block height, capped by max_rendered_rows", function()
		expect(State.viewport(22, 500)).toBe(3)
		expect(State.viewport(nil, 500)).toBe(500)
		expect(State.viewport(200, 50)).toBe(50)
	end)

	-- Measured on Tern 0.9.8 with `tern ctl dump` at window heights 600, 800
	-- and 1000 px: blocks of 33, 45 and 58 lines fit 7, 16 and 26 grid rows
	-- under the chrome.
	it("never sizes the window past the rows that fit (measured)", function()
		for _, m in { { 33, 7 }, { 45, 16 }, { 58, 26 } } do
			local size = State.viewport(m[1], 500)
			expect(size <= m[2]).toBe(true)
			expect(size >= m[2] - 1).toBe(true)
		end
	end)

	-- A block opened while the Tern window is in the background still reads
	-- 80x24 (see tests/unit/blocksize): its list gets the rows of Tern's
	-- default window, not the 3-row floor of a 24-line block.
	it("a block still at Tern's 80x24 spawn size keeps a full window", function()
		local size = State.viewport(Blocksize.rows(80, 24), 500)
		expect(size).toBe(State.viewport(45, 500))
		expect(size >= 15).toBe(true)
	end)
end)

-- Lists are native tables: they scroll in their own box and keep the
-- selected row in view, so a short block no longer cuts the list to a few
-- rows (EXP-U3); only general.max_rendered_rows bounds what is sent.
describe("explore state: native list window", function()
	local function capped(rows: number?): State
		local s = W.open(nil, W.config('{"general":{"max_rendered_rows":3}}'))
		return (State.update(s, { t = "resize", rows = rows or 22 }))
	end

	local function shown(s: State): (number, number)
		local items = State.items(s)
		return State.window(State.selectedIndex(s, items), #items, s.offset[State.currentKey(s)], State.windowSize(s))
	end

	it("holds max_rendered_rows rows whatever the block height", function()
		local s = (State.update(W.open(), { t = "resize", rows = 22 }))
		expect(State.windowSize(s)).toBe(500)
		local first, last = shown(s)
		expect(first).toBe(1)
		expect(last).toBe(7)
	end)

	it("G puts the last row in the capped window", function()
		local s = W.keys(capped(), { "G" })
		local first, last = shown(s)
		expect(last).toBe(7)
		expect(first).toBe(5)
	end)

	-- Tern 0.9.14 delivers PageDown/PageUp as `page_down`/`page_up` (logged
	-- live); the 0.9.8 spelling stays accepted. A page is about a screen of
	-- table rows.
	it("page_down and page_up move by a screen of rows, as do pagedown and pageup", function()
		local s = (State.update(W.open(), { t = "resize", rows = 18 }))
		expect(State.pageSize(s)).toBe(3)
		s = W.keys(s, { "page_down" })
		expect(State.selectedIndex(s, State.items(s))).toBe(4)
		s = W.keys(s, { "page_up" })
		expect(State.selectedIndex(s, State.items(s))).toBe(1)
		s = W.keys(s, { "pagedown" })
		expect(State.selectedIndex(s, State.items(s))).toBe(4)
		s = W.keys(s, { "pageup" })
		expect(State.selectedIndex(s, State.items(s))).toBe(1)
	end)

	it("a click on the overflow note moves a whole capped window", function()
		local clicked = W.action(capped(), "page", "down")
		expect(State.selectedIndex(clicked, State.items(clicked))).toBe(4)
	end)

	it("end and home jump like G and gg", function()
		local s = W.keys(capped(), { "end" })
		expect(State.selectedIndex(s, State.items(s))).toBe(7)
		s = W.keys(s, { "home" })
		expect(State.selectedIndex(s, State.items(s))).toBe(1)
	end)

	it("a new filter starts the window over", function()
		local s = W.keys(capped(), { "G" })
		s = W.keys(s, { "/", "e" })
		expect(s.offset[State.currentKey(s)]).toBe(1)
	end)

	it("a table click selects the row and a double click opens it", function()
		local s = W.open()
		local items = State.items(s)
		local picked = W.action(s, "sel", items[3].key)
		expect(State.selectedIndex(picked, State.items(picked))).toBe(3)
		expect(top(picked).kind).toBe("list")
		local opened = W.action(picked, "open", items[3].key)
		expect(top(opened).kind).toBe("detail")
	end)
end)

-- Header clicks sort in the core (typed: counts, quantities, ages), so the
-- keys move through what the table shows.
describe("explore state: header sort", function()
	local function names(s: State): string
		local out = {}
		for _, item in State.items(s) do
			table.insert(out, (item.ref :: any).name)
		end
		return table.concat(out, ",")
	end

	local function colId(s: State, header: string): string
		local data = (State.currentLoad(s) :: State.Load).data :: State.ListData
		return Table.ids(data.headers)[table.find(data.headers, header) :: number]
	end

	it("sorts by name both ways and keys follow the shown order", function()
		local s = W.open()
		local id = colId(s, "NAME")
		local asc = W.action(s, "sort", id .. ":asc")
		local desc = W.action(asc, "sort", id .. ":desc")
		local a = string.split(names(asc), ",")
		local d = string.split(names(desc), ",")
		expect(a[1]).toBe(d[#d])
		local moved = W.keys(desc, { "gg" })
		expect((State.selectedItem(moved) :: any).ref.name).toBe(d[1])
	end)

	it("a first click on a count column sorts largest first", function()
		local s = W.open()
		local sorted = W.action(s, "sort", colId(s, "RESTARTS") .. ":asc")
		expect(sorted.sort[State.currentKey(sorted)].dir).toBe("desc")
		local again = W.action(sorted, "sort", colId(s, "RESTARTS") .. ":asc")
		expect(again.sort[State.currentKey(again)].dir).toBe("asc")
	end)

	it("ignores a sort for a column the list does not have", function()
		local s = W.open()
		local same = State.update(s, { t = "action", act = "sort", value = "nope:asc" })
		expect(same).toBe(s)
	end)
end)

-- MUT-F9: after a mutation this block started succeeded, Explore still showed
-- `replicas: 2` and "Cordon" on a cordoned node.
describe("explore state: refresh after an applied mutation", function()
	it("re-runs the focused view and drops the other cluster views' data", function()
		local s = W.open()
		local listKey = State.currentKey(s)
		s = W.keys(s, { "enter" })
		expect(top(s).kind).toBe("detail")
		local after, effects = State.update(s, { t = "action", act = "applied", value = "" })
		expect(#effectsOf(effects, "run")).toBe(1)
		expect(after.cache[listKey]).toBeNil()
		local back = W.keys(after, { "escape" })
		expect((State.currentLoad(back) :: State.Load).status).toBe("ok")
	end)
end)

-- Lens chips and the palette open Helm views through tern-kube://explore
-- links; a mistyped or hostile link must not reach helm's argv, and the
-- kinds picker is the keyboard way in when helm is installed.
describe("explore state: helm links and picker", function()
	local Command = require("../../../plugin/lib/kubectl/command")
	local Argv = require("../../../plugin/lib/kubectl/argv")

	local function kinds(s: State): { string }
		local out: { string } = {}
		for _, r in s.stack do
			table.insert(out, r.kind)
		end
		return out
	end

	local function initHelm(url: string, saved: any?): State
		local s, effects = State.init({ url }, saved, W.config(nil), W.helmEnv())
		return (W.settle(s, effects, W.helmResponder))
	end

	it("a release link from exploreUrl opens releases > release > history, pinned to its context", function()
		local inv = Argv.parse("kubectl", { "--context", W.CTX, "get", "pods", "-n", "other" })
		local url = Command.exploreUrl(inv, nil, {
			route = "helm-history",
			release = "web-b",
			namespace = W.HELM_NS,
			revision = 2,
		})
		local s = initHelm(url)
		expect(kinds(s)).toEqual({ "helm-releases", "helm-release", "helm-history" })
		expect(s.stack[2].release).toBe("web-b")
		expect(s.stack[2].namespace).toBe(W.HELM_NS)
		expect(s.stack[2].revision).toBe(2)
		expect(s.target.context).toBe(W.CTX)
		expect(State.items(s)[1].key).toBe("3")
	end)

	it("invalid release names and revisions are dropped from links", function()
		local bad =
			initHelm(W.link({ context = W.CTX, route = "helm-release", release = "--all", namespace = W.HELM_NS }))
		expect(kinds(bad)).toEqual({ "helm-releases" })
		local rev = initHelm(
			W.link({ context = W.CTX, route = "helm-release", release = "web-b", namespace = W.HELM_NS, revision = "0" })
		)
		expect(rev.stack[2].revision).toBeNil()
	end)

	it("helm routes survive save and restore", function()
		local s =
			initHelm(W.link({ context = W.CTX, route = "helm-release", release = "web-b", namespace = W.HELM_NS }))
		s = W.helmKeys(s, { "v", "v" })
		local restored = initHelm(W.link(), State.save(s))
		expect(kinds(restored)).toEqual({ "helm-releases", "helm-release", "helm-values" })
		expect(restored.stack[3].mode).toBe("user")
		expect(restored.stack[3].release).toBe("web-b")
	end)

	it("the kinds picker lists `helm releases` first when helm was found; enter opens them", function()
		local s = initHelm(W.link({ context = W.CTX, namespace = "*", kind = "Pod" }))
		s = W.helmKeys(s, { ":" })
		expect(State.items(s)[1].key).toBe(State.HELM_KIND_ROW)
		s = W.helmAction(s, "sel", State.HELM_KIND_ROW)
		local opened, trace = W.helmKeys(s, { "enter" })
		expect(kinds(opened)).toEqual({ "helm-releases" })
		expect(#State.items(opened)).toBe(5)
		expect(#trace.runs).toBe(1)
		local noHelm = W.keys(W.open(), { ":" })
		for _, item in State.items(noHelm) do
			expect(item.key == State.HELM_KIND_ROW).toBe(false)
		end
	end)

	it("a filter `hr` still finds the picker row", function()
		local s = initHelm(W.link({ context = W.CTX, namespace = "*", kind = "Pod" }))
		s = W.helmKeys(s, { ":", "/", "h", "r", "escape" })
		expect(State.items(s)[1].key).toBe(State.HELM_KIND_ROW)
	end)
end)

-- v1.0.1 fixes from the exploratory reports (explore-xexplore B2, B3, B5,
-- explore-xlens D1).
describe("explore state: closing, pickers and context", function()
	local function escAt(s: State, clock: number?): (State, { Effect })
		return State.update(s, { t = "key", key = W.key("escape").key, clock = clock } :: any)
	end

	local function toastTexts(effects: { Effect }): { string }
		local out: { string } = {}
		for _, e in effectsOf(effects, "toast") do
			table.insert(out, e.text :: string)
		end
		return out
	end

	-- One esc too many closed the block and the next keystrokes went to the
	-- shell prompt (B3): closing needs a second esc soon after the first.
	it("esc at the root arms a close; a second esc within 1.5 s closes", function()
		local s = W.open()
		local armed, first = escAt(s, 10000)
		expect(#effectsOf(first, "exit")).toBe(0)
		expect(toastTexts(first)).toEqual({ "esc again to close" })
		local _, second = escAt(armed, 11400)
		expect(effectsOf(second, "exit")).toEqual({ { t = "exit" } })
	end)

	it("a late second esc only arms again, and any other key disarms", function()
		local s = W.open()
		local armed = escAt(s, 10000)
		local late, again = escAt(armed, 11600)
		expect(#effectsOf(again, "exit")).toBe(0)
		expect(toastTexts(again)).toEqual({ "esc again to close" })
		local moved = State.update(late, W.key("j"))
		local _, after = escAt(moved, 11700)
		expect(#effectsOf(after, "exit")).toBe(0)
	end)

	it("backspace walks back but never closes the block", function()
		local s = W.keys(W.open(), { "enter" })
		expect(top(s).kind).toBe("detail")
		s = W.keys(s, { "backspace" })
		expect(top(s).kind).toBe("list")
		for _ = 1, 3 do
			local s2, effects = State.update(s, W.key("backspace"))
			expect(#effectsOf(effects, "exit")).toBe(0)
			expect(#effectsOf(effects, "toast")).toBe(0)
			s = s2
		end
	end)

	-- B2: `n` after `/edge` still read /edge, and `/xexplore` became
	-- /edgexexplore with nothing to pick.
	it("pickers open with an empty filter and / starts a fresh one", function()
		local s = W.keys(W.open(), { "n", "/", "e", "m", "p", "enter", "enter" })
		expect(s.target.namespace).toBe("tern-test-empty")
		s = W.keys(s, { "n" })
		expect(top(s).kind).toBe("namespaces")
		expect(s.filter[State.currentKey(s)]).toBeNil()
		expect(#State.items(s)).toBe(4)
		s = W.keys(s, { "/", "a", "p", "enter" })
		expect(s.filter[State.currentKey(s)]).toBe("ap")
		s = W.keys(s, { "/", "d" })
		expect(s.filter[State.currentKey(s)]).toBe("d")
		s = W.keys(s, { "enter", "escape", ":" })
		expect(s.filter[State.currentKey(s)]).toBeNil()
	end)

	-- B5: re-picking the current context reset the namespace to the
	-- context default and showed an empty list.
	it("picking the current context again keeps the namespace and the route", function()
		local s = W.keys(W.open(), { "enter" })
		expect(top(s).kind).toBe("detail")
		local trace
		s, trace = W.keys(s, { "c", "enter" })
		expect(s.target.context).toBe(W.CTX)
		expect(s.target.namespace).toBe(W.NS)
		expect(s.target.confirmed).toBe(true)
		expect(top(s).kind).toBe("detail")
		expect(#effectsOf(trace.effects, "toast")).toBe(0)
	end)
end)

describe("explore state: restore after a plugin reload", function()
	local POD = { kind = "Pod", name = "web-1", namespace = W.NS }

	local function saved(last: { [string]: any }): any
		local stack: { any } = { { kind = "list", resource = "pods" }, { kind = "detail", ref = POD }, last }
		return {
			v = State.SAVE_VERSION,
			target = { context = W.CTX, contextSource = "flag", namespace = W.NS, confirmed = true },
			stack = stack,
			sel = {},
			filter = {},
		}
	end

	local function restore(last: { [string]: any }): (State, W.Trace)
		local s, effects = State.init({ "palette" }, saved(last), W.config(nil), W.env())
		return W.settle(s, effects)
	end

	-- D1: Tern 0.9.14 reloads a linked plugin on file changes; the manifest
	-- and diff views fell back to the object view.
	it("the manifest route comes back, without opening the file again", function()
		local s, trace = restore({ kind = "manifest", ref = POD })
		expect(top(s).kind).toBe("manifest")
		expect((top(s).ref :: any).name).toBe("web-1")
		expect(#effectsOf(trace.effects, "openfile")).toBe(0)
		expect(State.save(s).stack[3].kind).toBe("manifest")
	end)

	it("the diff route comes back with its manifest choice", function()
		local s = restore({ kind = "diff", ref = POD, doc = 2 })
		expect(top(s).kind).toBe("diff")
		expect(top(s).doc).toBe(2)
		local bad = restore({ kind = "diff", ref = POD, doc = "x; rm" })
		expect(top(bad).doc).toBe(1)
		local noRef = restore({ kind = "diff", doc = 1 })
		expect(top(noRef).kind).toBe("detail")
	end)

	it("a compare route comes back marked reloaded and runs nothing until r", function()
		local s, trace = restore({ kind = "compare", ref = POD, across = "*" })
		expect(top(s).kind).toBe("compare")
		expect(top(s).reloaded).toBe(true)
		for _, run in trace.runs do
			expect((string.find(table.concat(run.argv :: { string }, " "), "config view", 1, true))).toBeNil()
		end
		local _, effects = State.update(s, W.key("r"))
		expect(#effectsOf(effects, "run") > 0).toBe(true)
	end)
end)

return nil
