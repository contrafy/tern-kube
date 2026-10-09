--!strict
-- What the Explore block shows: an unmistakable live header with the pinned
-- target and its provenance, a keyboard-selectable grid capped like the lens,
-- actionable errors, and a help layer that lists every key.
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local W = require("../../lib/explore")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State

local function view(s: State): Render.View
	return Render.view(s, 160, 50)
end

local function main(s: State): nodes.Node
	return view(s).main :: any
end

describe("explore render: header", function()
	it("shows a Live badge and the fetch age, never a Snapshot badge", function()
		local s = W.open()
		local m = main(s)
		local live = nodes.find(m, nodes.role("tern-kube.live")) :: nodes.Node
		expect((live.p :: any).text).toBe("Live")
		expect((live.p :: any).tone).toBe("accent")
		expect(nodes.text(m)).toContain("fetched just now via " .. W.CTX)
		expect((string.find(nodes.text(m), "Snapshot", 1, true))).toBeNil()
		s.now = W.AT + 125
		expect(nodes.text(main(s))).toContain("fetched 2m ago")
	end)

	it("a context from the command flag is shown as such and confirmed", function()
		local m = main((W.open()))
		expect(nodes.text(m)).toContain("context " .. W.CTX)
		expect(nodes.text(m)).toContain("(command flag)")
		expect(nodes.find(m, nodes.role("tern-kube.inferred"))).toBeNil()
		expect(nodes.actions(m)).toContain("nav=contexts")
	end)

	it("an inferred context carries a warning and a Confirm target action", function()
		local s = W.open({ namespace = W.NS })
		local m = main(s)
		local warning = nodes.find(m, nodes.role("tern-kube.inferred")) :: nodes.Node
		expect((warning.p :: any).tone).toBe("warning")
		expect(nodes.text(m)).toContain("inferred: current-context at 00:16:40 UTC")
		expect(nodes.actions(m)).toContain("confirm")
		local confirmed = W.action(s, "confirm")
		expect(table.find(nodes.actions(main(confirmed)), "confirm")).toBeNil()
	end)

	it("breadcrumbs lead back to every earlier view", function()
		local s = W.keys(W.open(), { "enter", "R" })
		local m = main(s)
		local crumbs = nodes.find(m, nodes.role("tern-kube.breadcrumb")) :: nodes.Node
		expect(nodes.actions(crumbs)).toEqual({ "crumb=1", "crumb=2" })
		expect(nodes.text(crumbs)).toContain("Relations pod/")
	end)

	local function notFound(): State
		local env = W.env()
		env.daemonPath = "/usr/bin:/bin:/usr/sbin:/sbin"
		local s, effects = State.init({ W.link({}) }, nil, W.config(nil), env)
		return (
			W.settle(s, effects, function()
				return nil, "tern.process.run kubectl: No such file or directory (os error 2)"
			end)
		)
	end

	-- The user's report showed the error twice (main and dock) next to a "no
	-- context" badge that only led to another failing kubectl call.
	it("kubectl not found is shown once, as a card with Settings and Retry", function()
		local v = view(notFound())
		local text = nodes.text(v.main :: any)
		local _, count = string.gsub(text, "kubectl not found", "")
		expect(count).toBe(1)
		expect((string.find(text, "no context", 1, true))).toBeNil()
		expect((string.find(text, "stack traceback", 1, true))).toBeNil()
		local card = nodes.find(v.main :: any, nodes.role("tern-kube.explore-error")) :: nodes.Node
		expect(nodes.actions(card)).toEqual({ "settings", "refresh" })
		local dock = nodes.text(v.dock :: any)
		expect((string.find(dock, "not found", 1, true))).toBeNil()
		expect(dock).toContain("kubectl could not run")
	end)

	-- With no resolved context the exec hint printed "on context ?".
	it("the exec hint never names an unknown context", function()
		local env = W.env()
		env.daemonPath = "/usr/bin:/bin:/usr/sbin:/sbin"
		local link = W.link({ namespace = W.NS, kind = "Pod", name = "web-65d7d99975-abcde" })
		local s, effects = State.init({ link }, nil, W.config(nil), env)
		s = W.settle(s, effects, function()
			return nil, "tern.process.run kubectl: No such file or directory (os error 2)"
		end)
		local text = nodes.text(main(s))
		expect((string.find(text, "context ?", 1, true))).toBeNil()
		expect(text).toContain("exec runs a shell inside the container")
	end)

	it("says it is reading the shell's PATH while that is pending", function()
		local env = W.env()
		env.pending = true
		local s = State.init({ W.link({}) }, nil, W.config(nil), env)
		local text = nodes.text(main(s))
		expect(text).toContain("Reading PATH and KUBECONFIG from your login shell")
		expect((string.find(text, "no context", 1, true))).toBeNil()
	end)
end)

describe("explore render: list", function()
	it("renders the pods grid with the keyboard selection marked", function()
		local s = W.keys(W.open(), { "j" })
		local m = main(s)
		local selected = nodes.findAll(m, nodes.class("tk-sel"))
		expect(#selected).toBe(1)
		local key = (selected[1].p :: any).key
		expect(nodes.action(selected[1])).toBe("open=" .. key)
		expect((State.selectedItem(s) :: State.Item).key).toBe(key)
		expect(nodes.find(m, nodes.key("filter")) ~= nil).toBe(true)
		expect(nodes.text(m)).toContain("7 pods")
	end)

	it("caps rendered rows and offers clickable rows above and below", function()
		local s = W.open(nil, W.config('{"general":{"max_rendered_rows":3}}'))
		local m = main(s)
		expect(#nodes.findAll(m, nodes.class("tk-r"))).toBe(3)
		expect(nodes.text(m)).toContain("↓ 4 below")
		expect(nodes.actions(m)).toContain("page=down")
		s = W.keys(s, { "G" })
		m = main(s)
		expect(#nodes.findAll(m, nodes.class("tk-sel"))).toBe(1)
		expect(nodes.text(m)).toContain("↑ 4 above")
		expect(nodes.actions(m)).toContain("page=up")
	end)

	-- Half-width panes truncated names when every relation carried its full
	-- provenance text; the badge keeps it one word with the meaning on hover.
	it("relations show provenance as a compact badge with the full text as tooltip", function()
		local s = W.keys(
			W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment", group = "apps", name = "web" }),
			{ "R" }
		)
		local m = main(s)
		expect(nodes.text(m)).toContain("NAME KIND RELATION VIA STATUS")
		local badge = nodes.find(m, function(n)
			return n.k == "badge" and (n.p :: any).text == "owner"
		end) :: nodes.Node
		expect((badge.p :: any).title).toContain("ownerReference")
		expect((string.find(nodes.text(m), "ownerReference", 1, true))).toBeNil()
	end)

	it("says so when a namespace has no objects", function()
		local m = main((W.open({ context = W.CTX, namespace = "tern-test-empty", kind = "Pod" })))
		expect(nodes.text(m)).toContain("No pods in ns tern-test-empty.")
	end)

	it("shows RBAC errors in the body and the dock", function()
		local s = W.open()
		local s2, effects = State.update(s, W.key("r"))
		s2 = W.settle(s2, effects, function()
			return W.fail(1, 'Error from server (Forbidden): pods is forbidden: User "dev" cannot list resource "pods"')
		end)
		local v = view(s2)
		expect(nodes.text(v.main :: any)).toContain("RBAC: the user of context " .. W.CTX)
		expect(nodes.text(v.dock :: any)).toContain("RBAC")
	end)

	it("a filter with no match explains how to clear it", function()
		local s = W.keys(W.open(), { "/", "z", "z", "z" })
		expect(nodes.text(main(s))).toContain("Nothing matches the filter")
	end)
end)

describe("explore render: other views", function()
	it("an object shows its fields, owners, tree and actions incl. quick actions", function()
		local s = W.keys(W.open(), { "/", "w", "e", "b", "enter", "enter" })
		local m = main(s)
		local text = nodes.text(m)
		expect(text).toContain("Name")
		expect(text).toContain("owner ReplicaSet/web-65d7d99975")
		expect(nodes.find(m, nodes.kind("tree")) ~= nil).toBe(true)
		local actions = nodes.actions(m)
		expect(actions).toContain("quick=shell")
		expect(actions).toContain("quick=logs-follow")
		expect(actions).toContain("nav=describe")
		expect(actions).toContain("copy=exec")
		expect(text).toContain("exec runs a shell inside the container")
	end)

	it("describe reuses the native describe view", function()
		local s = W.keys(W.open(), { "d" })
		expect(nodes.find(main(s), nodes.role("tern-kube.describe")) ~= nil).toBe(true)
	end)

	it("logs show the fetched lines", function()
		local s = W.keys(W.open(), { "L" })
		local code = nodes.find(main(s), nodes.kind("code")) :: nodes.Node
		expect((code.p :: any).text).toBe("log line 1\nlog line 2")
	end)

	it("the context chooser marks the current target", function()
		local s = W.keys(W.open(), { "c" })
		local text = nodes.text(main(s))
		expect(text).toContain("current target")
		expect(nodes.actions(main(s))).toContain("open=other")
	end)

	it("the help layer lists every key", function()
		local s = W.keys(W.open(), { "?" })
		local layer = view(s).layer :: any
		local text = nodes.text(layer)
		for _, k in Render.KEYS do
			expect(text).toContain(k[1])
		end
		expect(view((W.open())).layer).toBeNil()
	end)
end)

describe("explore render: object view redaction", function()
	local SECRET =
		[[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"app-secret","namespace":"tern-test-apps"},"data":{"password":"aHVudGVyMg=="}}]]
	local POD = [[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"envy","namespace":"tern-test-apps"},
		"spec":{"containers":[{"name":"app","env":[{"name":"DB_PASSWORD","value":"hunter2"},{"name":"MODE","value":"fast"}]}]}}]]

	local function respond(argv: { string }): (W.Result?, string?)
		if table.find(argv, "json") and table.find(argv, "app-secret") then
			return { status = 0, stdout = SECRET, stderr = "", timed_out = false }
		elseif table.find(argv, "json") and table.find(argv, "envy") then
			return { status = 0, stdout = POD, stderr = "", timed_out = false }
		end
		return W.responder(argv)
	end

	local function open(kind: string, name: string, cfg: string?): nodes.Node
		local link = W.link({ context = W.CTX, namespace = W.NS, kind = kind, name = name })
		local s, effects = State.init({ link }, nil, W.config(cfg), W.env())
		s = W.settle(s, effects, respond)
		expect(s.stack[#s.stack].kind).toBe("detail")
		return main(s)
	end

	local function notice(m: nodes.Node): string?
		local n = nodes.find(m, nodes.role("tern-kube.sensitive"))
		return if n then nodes.text(n) else nil
	end

	it("masks Secret values by default and says so", function()
		local m = open("Secret", "app-secret")
		expect((string.find(nodes.text(m), "aHVudGVyMg==", 1, true))).toBeNil()
		expect(nodes.text(m)).toContain("<redacted: 12 bytes base64>")
		expect(notice(m)).toContain("masked")
	end)

	it("shows Secret values with a warning when show_secret_values is on", function()
		local m = open("Secret", "app-secret", [[{"security": {"show_secret_values": true}}]])
		expect(nodes.text(m)).toContain("aHVudGVyMg==")
		expect(notice(m)).toBe("Output contains Secret values (security.show_secret_values is on)")
	end)

	it("strict mode masks sensitive env values in the object view", function()
		local strict = open("Pod", "envy", [[{"security": {"sensitive_output_strict_mode": true}}]])
		expect((string.find(nodes.text(strict), "hunter2", 1, true))).toBeNil()
		expect(nodes.text(strict)).toContain("fast")
		expect(notice(strict)).toContain("sensitive_output_strict_mode")
		local plain = open("Pod", "envy")
		expect(nodes.text(plain)).toContain("hunter2")
		expect(notice(plain)).toBeNil()
	end)
end)

describe("explore render: performance", function()
	it("renders a 1000-pod list in < 60 ms", function()
		local s = W.open()
		local key = State.currentKey(s)
		local load = s.cache[key] :: State.Load
		local base = (load.data :: State.ListData).rows
		local rows: { State.Row } = table.create(1000)
		for i = 1, 1000 do
			local r = table.clone(base[(i - 1) % #base + 1])
			r.key = r.key .. "#" .. i
			rows[i] = r
		end
		local data = table.clone(load.data :: State.ListData)
		data.rows = rows
		local big = table.clone(load)
		big.data = data
		local cache = table.clone(s.cache)
		cache[key] = big
		s.cache = cache
		local best = math.huge
		for _ = 1, 5 do
			local t0 = os.clock()
			Render.view(s, 160, 50)
			best = math.min(best, (os.clock() - t0) * 1000)
		end
		expect(best < 60).toBe(true)
		expect(nodes.text(main(s))).toContain("↓ 500 below")
	end)
end)

return nil
