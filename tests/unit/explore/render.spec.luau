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

	-- Tern draws the caret where the `cursor` prop says, in UTF-16 units.
	it("draws the filter caret where the user put it", function()
		local s = W.keys(W.open(), { "/", "w", "b", "left" })
		local filter = nodes.find(main(s), nodes.key("filter")) :: nodes.Node
		expect((filter.p :: any).text).toBe("wb")
		expect((filter.p :: any).cursor).toBe(1)
		s = W.keys(s, { "enter" })
		filter = nodes.find(main(s), nodes.key("filter")) :: nodes.Node
		expect((filter.p :: any).cursor).toBe(2)
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

	it("an object offers the guarded verbs that fit its kind and state, with their keys", function()
		local s = W.keys(W.open({ context = W.CTX, namespace = W.NS, kind = "Deployment" }), {
			"/",
			"w",
			"e",
			"b",
			"enter",
			"enter",
		})
		local m = main(s)
		local actions = nodes.actions(m)
		for _, a in { "quick=edit", "mutate=label", "mutate=annotate", "mutate=patch", "mutate=undo", "mutate=pause" } do
			expect(actions).toContain(a)
		end
		-- The loaded Deployment is not paused: resume would only make kubectl exit 1.
		expect(table.find(actions, "mutate=resume")).toBeNil()
		expect(table.find(actions, "mutate=cordon")).toBeNil()
		local text = nodes.text(m)
		for _, label in { "Edit (e)", "Label (t)", "Annotate (T)", "Patch (X)", "Undo (U)", "Pause (p)" } do
			expect(text).toContain(label)
		end
	end)

	it("hides the edit chip with the other mutations when mutations are disabled", function()
		local s = W.keys(W.open(nil, W.config('{"mutations": {"enabled": false}}')), { "enter" })
		local actions = nodes.actions(main(s))
		expect(table.find(actions, "quick=edit")).toBeNil()
		expect(table.find(actions, "mutate=label")).toBeNil()
	end)

	it("describe reuses the native describe view", function()
		local s = W.keys(W.open(), { "d" })
		expect(nodes.find(main(s), nodes.role("tern-kube.describe")) ~= nil).toBe(true)
	end)

	it("logs show parsed records with a level badge, not a raw text dump", function()
		local s = W.keys(W.open(), { "L" })
		local m = main(s)
		expect(nodes.find(m, nodes.role("tern-kube.level")) ~= nil).toBe(true)
		expect(nodes.find(m, nodes.kind("code"))).toBeNil()
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

	-- One key, one meaning outside the route-local views (whose rows say
	-- which view they belong to; inside those views their keys win).
	it("binds no global key twice", function()
		local seen: { [string]: string } = {}
		for _, k in Render.KEYS do
			local desc = k[2]
			-- Route-local rows (GitOps views, logs and events, Helm views,
			-- compare views) may reuse keys: inside their view they win.
			if
				string.find(desc, "^Drift:")
				or string.find(desc, "^Export:")
				or string.find(desc, "^Git:")
				or string.find(desc, "^Logs:")
				or string.find(desc, "^Helm:")
				or string.find(desc, "^Compare:")
			then
				continue
			end
			for key in string.gmatch(k[1], "[^%s,/]+") do
				expect(seen[key]).toBeNil()
				seen[key] = desc
			end
		end
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

-- Helm ------------------------------------------------------------------------

-- Every string a view carries (texts, titles, actions, code and diff
-- bodies), so a value leaking through any prop is caught.
local function strings(node: any, out: { string })
	if type(node) == "string" then
		table.insert(out, node)
	elseif type(node) == "table" then
		for _, v in node do
			strings(v, out)
		end
	end
end

local function allText(v: Render.View): string
	local out: { string } = {}
	strings(v.main, out)
	strings(v.dock, out)
	strings(v.layer, out)
	return table.concat(out, "\n")
end

local function route(s: State): string
	return s.stack[#s.stack].kind
end

local function openRelease(name: string, cfg: any?): State
	local s = W.openHelm(nil, cfg)
	s = W.helmAction(s, "sel", W.HELM_NS .. "/" .. name)
	s = W.helmKeys(s, { "enter" })
	expect(route(s)).toBe("helm-release")
	return s
end

describe("explore render: helm", function()
	it("lists releases with status, chart, version and app version", function()
		local s = W.openHelm()
		local m = main(s)
		local text = nodes.text(m)
		expect(text).toContain("NAME NAMESPACE REV STATUS CHART VERSION APP VERSION UPDATED")
		for _, name in { "shop-a", "web-b", "broken-c", "stuck-d", "tricky-e" } do
			expect(text).toContain(name)
		end
		expect(text).toContain("5 releases")
		-- broken-c failed and stuck-d is pending: both need attention.
		expect(text).toContain("2 need attention")
		expect(#nodes.findAll(m, nodes.class("tk-helm-error"))).toBe(1)
		expect(nodes.text(view(s).dock :: any)).toContain("enter open")
		expect(Render.title(s)).toContain("Helm releases")
	end)

	-- F11: a SIGKILLed upgrade stays pending-upgrade forever; the age is the
	-- only signal that nobody is still running it.
	it("labels a release pending for more than 15 minutes as stuck", function()
		local s = W.openHelm()
		s.now = 1767225600 + 86400 -- 2026-01-02T00:00:00Z, a day after the capture
		expect(nodes.text(main(s))).toContain("pending-upgrade (stuck?)")
		s.now = 1767225600 + 16 * 60 -- stuck-d was updated at 00:15, one minute earlier
		expect((string.find(nodes.text(main(s)), "(stuck?)", 1, true))).toBeNil()
	end)

	it("the release view shows status, revision of latest, chart and the release chips", function()
		local s = openRelease("web-b")
		local m = main(s)
		local text = nodes.text(m)
		expect(text).toContain("rev 3 of 3")
		expect(text).toContain("web-0.2.0")
		expect(text).toContain("Rollback to 1")
		local status = nodes.find(m, nodes.role("tern-kube.helm-status")) :: nodes.Node
		expect((status.p :: any).text).toBe("deployed")
		local actions = nodes.actions(m)
		for _, a in { "helm-nav=history", "helm-nav=values", "helm-nav=manifest", "helm-rollback", "copy=cmd" } do
			expect(actions).toContain(a)
		end
		local crumbs = nodes.find(m, nodes.role("tern-kube.breadcrumb")) :: nodes.Node
		expect(nodes.text(crumbs)).toContain("Helm releases")
		expect(nodes.text(crumbs)).toContain("release tern-test-helm/web-b")
	end)

	it("hides the rollback chip when mutations are disabled", function()
		local s = openRelease("web-b", W.config('{"mutations": {"enabled": false}}'))
		expect(table.find(nodes.actions(main(s)), "helm-rollback")).toBeNil()
	end)

	it("history marks the latest and the running revision, newest first", function()
		local s = W.helmKeys(openRelease("shop-a"), { "h" })
		expect(route(s)).toBe("helm-history")
		local text = nodes.text(main(s))
		expect(text).toContain("3 revisions")
		local first = string.find(text, "3 deployed", 1, true)
		local last = string.find(text, "1 superseded", 1, true)
		expect(first ~= nil and last ~= nil and (first :: number) < (last :: number)).toBe(true)
		expect(text).toContain("latest running")
		expect(nodes.text(view(s).dock :: any)).toContain("space mark")
	end)

	-- shop-a r3 was upgraded with --reuse-values, so its stored "defaults"
	-- hold r2's values (F8): replicaCount must read as an override.
	it("values compare against trustworthy defaults and cycle modes with v", function()
		local s = W.helmKeys(openRelease("shop-a"), { "v" })
		expect(route(s)).toBe("helm-values")
		local m = main(s)
		expect(nodes.text(m)).toContain("PATH STATE DEFAULT USER COMPUTED")
		expect(nodes.text(m)).toContain("replicaCount override")
		expect(nodes.actions(m)).toContain("helm-mode=diff")
		s = W.helmKeys(s, { "v" })
		expect(s.stack[#s.stack].mode).toBe("user")
		expect(nodes.find(main(s), nodes.kind("code")) ~= nil).toBe(true)
	end)

	it("a history diff shows per-object segments with create/modify/delete counts", function()
		local s = W.helmKeys(openRelease("shop-a"), { "h" })
		s = W.helmAction(s, "sel", "1")
		s = W.helmKeys(s, { "=" })
		expect(route(s)).toBe("helm-diff")
		local m = main(s)
		local text = nodes.text(m)
		expect(text).toContain("Revision 1 → 3")
		expect(text).toContain("2 modify")
		expect(#nodes.findAll(m, nodes.role("tern-kube.gitops-diff"))).toBe(2)
	end)

	-- shop-a r1 had no user values; r3 sets plain ones. A value that is
	-- shown as it is must not be labelled masked (only secrets are).
	it("the user values diff marks only masked values as masked", function()
		local s = W.helmKeys(openRelease("shop-a"), { "h" })
		s = W.helmAction(s, "sel", "1")
		s = W.helmKeys(s, { "=" })
		local text = nodes.text(main(s))
		expect(text).toContain("replicaCount")
		expect((string.find(text, "values changed (masked)", 1, true))).toBeNil()
	end)

	it("resources list manifest objects with their live state and open them", function()
		local s = W.helmKeys(openRelease("shop-a"), { "R" })
		expect(route(s)).toBe("helm-resources")
		local m = main(s)
		expect(nodes.text(m)).toContain("KIND NAME NAMESPACE STATE SOURCE")
		expect(nodes.text(m)).toContain("present")
		expect(nodes.actions(m)).toContain("open=apps/Deployment/" .. W.HELM_NS .. "/shop-a-shop")
	end)

	it("an object managed by Helm names its release in the object and relations views", function()
		local s = W.helmKeys(openRelease("shop-a"), { "R" })
		s = W.helmAction(s, "sel", "apps/Deployment/" .. W.HELM_NS .. "/shop-a-shop")
		s = W.helmKeys(s, { "enter" })
		expect(route(s)).toBe("detail")
		local line = nodes.find(main(s), nodes.role("tern-kube.helm-owner")) :: nodes.Node
		expect(nodes.text(line)).toContain("Managed by Helm release " .. W.HELM_NS .. "/shop-a rev 3")
		expect(nodes.actions(line)).toContain("helm-open=" .. W.HELM_NS .. "/shop-a")
		s = W.helmKeys(s, { "R" })
		expect(route(s)).toBe("relations")
		expect(nodes.find(main(s), nodes.role("tern-kube.helm-owner")) ~= nil).toBe(true)
	end)
end)

-- Plan §5 rule 9: the capture uses fake values ending in REDACTME; no Helm
-- view may show one unless the user turned show_secret_values on.
describe("explore render: helm masking sweep", function()
	local MODES = 5

	-- Every Helm route of every captured release: each values mode, manifest,
	-- notes, hooks, resources, history, every revision and both diff kinds.
	local function sweep(cfg: any?): { [string]: string }
		local seen: { [string]: string } = {}
		local function record(s: State, label: string)
			seen[label] = allText(view(s))
		end
		local releases = W.openHelm(nil, cfg)
		record(releases, "releases")
		for _, name in { "shop-a", "web-b", "broken-c", "stuck-d", "tricky-e" } do
			local s = W.helmAction(releases, "sel", W.HELM_NS .. "/" .. name)
			s = W.helmKeys(s, { "enter" })
			record(s, name .. " release")
			local values = W.helmKeys(s, { "v" })
			for i = 1, MODES do
				record(values, name .. " values " .. (values.stack[#values.stack].mode or "changed"))
				if i < MODES then
					values = W.helmKeys(values, { "v" })
				end
			end
			for _, k in { "M", "N", "K", "R", "=" } do
				record(W.helmKeys(s, { k }), name .. " " .. k)
			end
			local history = W.helmKeys(s, { "h" })
			record(history, name .. " history")
			for _, item in State.items(history) do
				local diff = W.helmKeys(W.helmAction(history, "sel", item.key), { "=" })
				record(diff, name .. " diff " .. item.key)
				local rev = W.helmKeys(W.helmAction(history, "sel", item.key), { "enter" })
				record(rev, name .. " revision " .. item.key)
				record(W.helmKeys(rev, { "M" }), name .. " manifest " .. item.key)
				record(W.helmKeys(rev, { "N" }), name .. " notes " .. item.key)
				record(W.helmKeys(rev, { "K" }), name .. " hooks " .. item.key)
			end
		end
		return seen
	end

	it("no Helm view shows a REDACTME value by default", function()
		local seen = sweep(nil)
		local views = 0
		for label, text in seen do
			views += 1
			if string.find(text, "REDACTME", 1, true) then
				error("REDACTME visible in " .. label, 0)
			end
		end
		-- Masked, not merely absent: the views did render web-b's values.
		expect(seen["web-b values user"]).toContain("<redacted:")
		expect(seen["web-b M"]).toContain("<redacted:")
		expect(seen["web-b M"]).toContain("postgres://app:<redacted")
		expect(views > 60).toBe(true)
	end)

	it("show_secret_values shows them, with the warning", function()
		local seen = sweep(W.config('{"security": {"show_secret_values": true}}'))
		for _, label in { "web-b values user", "web-b M", "web-b notes 2" } do
			expect(seen[label]).toContain("REDACTME")
			expect(seen[label]).toContain("Output contains Secret values")
		end
	end)
end)

return nil
