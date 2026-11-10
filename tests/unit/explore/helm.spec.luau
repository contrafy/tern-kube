--!strict
-- The Helm routes of Explore read releases only when asked, always pin the
-- resolved context (helm's current-context must never pick the cluster),
-- follow the Explore namespace scope, and turn keys into the exact routes
-- and approve-block links the plan names. Late answers of superseded reads
-- must not overwrite newer ones, and the owner lookup of a Helm-managed
-- object runs once per release, not once per render or key press.
local Command = require("../../../plugin/lib/kubectl/command")
local Helm = require("../../../plugin/lib/explore/helm")
local State = require("../../../plugin/lib/explore/state")
local W = require("../../lib/explore")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect

local NS = W.HELM_NS
-- Every helm call pins the resolved context and the one kubeconfig file.
local HELM = "helm --kube-context kind-tern-kube-dev --kubeconfig /home/u/.kube/config"

local function top(s: State): State.Route
	return s.stack[#s.stack]
end

local function line(e: Effect): string
	return table.concat(e.argv :: { string }, " ")
end

local function helmRuns(effects: { Effect }): { Effect }
	local out: { Effect } = {}
	for _, e in effects do
		if e.t == "run" and (e.argv :: { string })[1] == "helm" then
			table.insert(out, e)
		end
	end
	return out
end

local function ofType(effects: { Effect }, kind: string): { Effect }
	local out: { Effect } = {}
	for _, e in effects do
		if e.t == kind then
			table.insert(out, e)
		end
	end
	return out
end

local function keys(s: State): { string }
	local out: { string } = {}
	for _, item in State.items(s) do
		table.insert(out, item.key)
	end
	return out
end

local function params(url: string): { [string]: string }
	local out: { [string]: string } = {}
	for _, p in Command.parseQuery(url) do
		out[p.key] = p.value
	end
	return out
end

-- web-b's release route (revision 3 of 3, notes, hooks, a Secret).
local function webB(): (State, W.Trace)
	local s = W.openHelm()
	s = W.helmAction(s, "sel", NS .. "/web-b")
	return W.helmKeys(s, { "enter" })
end

local function key(name: string, extra: { [string]: any }): State.Msg
	return W.key(name, extra)
end

describe("explore helm: releases", function()
	it("the palette link lists every namespace with -A, pinned to the resolved context", function()
		local s, trace = W.openHelm()
		expect(top(s).kind).toBe("helm-releases")
		local runs = helmRuns(trace.runs)
		expect(#runs).toBe(1)
		expect(line(runs[1])).toBe(
			HELM
				.. " list --deployed --failed --pending --superseded --uninstalled --uninstalling -o json --time-format 2006-01-02T15:04:05Z07:00 --max 1000 -A"
		)
		expect((runs[1].env :: { [string]: string }).HELM_DRIVER).toBe("secret")
		expect(keys(s)).toEqual({
			NS .. "/broken-c",
			NS .. "/shop-a",
			NS .. "/stuck-d",
			NS .. "/tricky-e",
			NS .. "/web-b",
		})
	end)

	it("H from a list opens the releases in the list's namespace scope; n re-reads for the new scope", function()
		local s, effects =
			State.init({ W.link({ context = W.CTX, namespace = W.NS, kind = "Pod" }) }, nil, W.config(nil), W.helmEnv())
		s = W.settle(s, effects, W.helmResponder)
		local trace
		s, trace = W.helmKeys(s, { "H" })
		expect(top(s).kind).toBe("helm-releases")
		expect(line(helmRuns(trace.runs)[1])).toContain(
			" list --deployed --failed --pending --superseded --uninstalled --uninstalling "
		)
		expect(line(helmRuns(trace.runs)[1])).toContain("-n " .. W.NS)
		expect(#keys(s)).toBe(0)
		s, trace = W.helmAction(s, "ns", NS)
		expect(top(s).kind).toBe("helm-releases")
		expect(line(helmRuns(trace.runs)[1])).toContain("-n " .. NS)
		expect(#keys(s)).toBe(5)
	end)

	it("the filter matches name, namespace, status and chart", function()
		local s = W.openHelm()
		local h, ctx = s.helm, State.helmCtx(s)
		local function names(f: string): { string }
			local out: { string } = {}
			for _, r in Helm.releases(h, ctx, top(s), f) do
				table.insert(out, r.name)
			end
			return out
		end
		expect(names("fail")).toEqual({ "broken-c" })
		expect(names("pending")).toEqual({ "stuck-d" })
		expect(names("web-0")).toEqual({ "web-b" })
		expect(#names("tern-test-helm")).toBe(5)
	end)

	it("helm not found: H shows one actionable error and runs nothing", function()
		local s = W.open()
		local s2, effects = State.update(s, W.key("H"))
		expect(#effects).toBe(1)
		expect(effects[1].t).toBe("toast")
		expect(effects[1].level).toBe("error")
		expect(effects[1].sub :: string).toContain("Settings")
		expect(top(s2).kind).toBe("list")
		local linked, trace = W.open({ context = W.CTX, namespace = "*", route = "helm-releases" })
		expect(top(linked).kind).toBe("helm-releases")
		expect(#helmRuns(trace.runs)).toBe(0)
	end)

	it("a late answer of a superseded list read is dropped", function()
		local s, effects = State.init(
			{ W.link({ context = W.CTX, namespace = "*", route = "helm-releases" }) },
			nil,
			W.config(nil),
			W.helmEnv()
		)
		-- Resolve the target; keep the first helm list unanswered.
		local first: Effect? = nil
		local queue = table.clone(effects)
		while #queue > 0 do
			local e = table.remove(queue, 1) :: Effect
			if e.t == "run" and (e.argv :: { string })[1] == "helm" then
				first = e
			elseif e.t == "run" then
				local result = W.helmResponder(e.argv :: { string })
				local more
				s, more = State.update(s, { t = "result", tag = e.tag, gen = e.gen, result = result, at = W.AT })
				for _, m in more do
					table.insert(queue, m)
				end
			end
		end
		local stale = first :: Effect
		local refreshed, again = State.update(s, W.key("r"))
		local second = helmRuns(again)[1]
		expect(second.gen ~= stale.gen).toBe(true)
		local after = State.update(refreshed, {
			t = "result",
			tag = stale.tag,
			gen = stale.gen,
			result = { status = 0, stdout = "[]", stderr = "", timed_out = false },
			at = W.AT,
		})
		local load = Helm.listLoad(after.helm, State.helmCtx(after), top(after)) :: any
		expect(load.status).toBe("loading")
		local settled = W.settle(after, { second }, W.helmResponder)
		expect(#keys(settled)).toBe(5)
	end)
end)

describe("explore helm: release routes and keys", function()
	it("enter opens the release: latest status, history, then that revision's extras", function()
		local s, trace = webB()
		local r = top(s)
		expect(r.kind).toBe("helm-release")
		expect(r.release).toBe("web-b")
		expect(r.namespace).toBe(NS)
		local lines: { string } = {}
		for _, e in helmRuns(trace.runs) do
			table.insert(lines, line(e))
		end
		expect(lines[1]).toBe(HELM .. " status web-b -n tern-test-helm -o json")
		expect(lines[2]).toBe(HELM .. " history web-b -n tern-test-helm -o json --max 256")
		expect(lines[3]).toContain("get all web-b -n tern-test-helm --revision 3 --template ")
		expect(Helm.revisionOf(s.helm, r)).toBe(3)
		expect((Helm.extrasLoad(s.helm, r, 3) :: any).status).toBe("ok")
	end)

	-- The release header summarizes the values (overridden, same as default,
	-- unknown keys); without these reads it would say "loading" forever.
	it("the release route also reads the computed values and the defaults its summary compares", function()
		local s, trace = webB()
		local r = top(s)
		local found = false
		for _, e in helmRuns(trace.runs) do
			if string.find(line(e), "get values web-b -n tern-test-helm --revision 3 --all -o json", 1, true) then
				found = true
			end
		end
		expect(found).toBe(true)
		expect((Helm.defaultsLoad(s.helm, r, 3) :: any).status).toBe("ok")
		expect(Helm.valuesCompare(s.helm, State.helmCtx(s), r) ~= nil).toBe(true)
	end)

	it("h opens the history newest first; shift+h is the global H, not history", function()
		local s = webB()
		local hist = W.helmKeys(s, { "h" })
		expect(top(hist).kind).toBe("helm-history")
		expect(keys(hist)).toEqual({ "3", "2", "1" })
		local shifted = W.settle(State.update(s, key("h", { shift = true, text = "H" })), {}, W.helmResponder)
		expect(top(shifted).kind).toBe("helm-releases")
	end)

	it("v opens values (changed mode); v again cycles the mode in place", function()
		-- The release route already read the computed values; v reuses them.
		local s, trace = W.helmKeys((webB()), { "v" })
		local r = top(s)
		expect(r.kind).toBe("helm-values")
		expect(#helmRuns(trace.runs)).toBe(0)
		expect((Helm.computedLoad(s.helm, r, 3) :: any).status).toBe("ok")
		expect((Helm.defaultsLoad(s.helm, r, 3) :: any).status).toBe("ok")
		expect(Helm.valuesCompare(s.helm, State.helmCtx(s), r) ~= nil).toBe(true)
		local depth = #s.stack
		local cycled = W.helmKeys(s, { "v" })
		expect(#cycled.stack).toBe(depth)
		expect(top(cycled).mode).toBe("user")
	end)

	it("M, N, K and R open manifest, notes, hooks and resources of the release", function()
		local s = webB()
		local routes: { [string]: string } =
			{ M = "helm-manifest", N = "helm-notes", K = "helm-hooks", R = "helm-resources" }
		for name, kind in routes do
			local opened = W.helmKeys(s, { name })
			expect(top(opened).kind).toBe(kind)
			expect(top(opened).release).toBe("web-b")
		end
	end)

	it("resources: manifest objects found live by release annotations, hooks listed separately", function()
		local s, trace = W.helmKeys((webB()), { "R" })
		local reads: { string } = {}
		for _, e in trace.runs do
			if (e.argv :: { string })[1] == "kubectl" then
				table.insert(reads, line(e))
			end
		end
		table.sort(reads)
		expect(reads).toEqual({
			"kubectl --kubeconfig /home/u/.kube/config --context kind-tern-kube-dev get configmap -l app.kubernetes.io/managed-by=Helm -o json -n tern-test-helm",
			"kubectl --kubeconfig /home/u/.kube/config --context kind-tern-kube-dev get deployment.apps -l app.kubernetes.io/managed-by=Helm -o json -n tern-test-helm",
			"kubectl --kubeconfig /home/u/.kube/config --context kind-tern-kube-dev get secret -l app.kubernetes.io/managed-by=Helm -o json -n tern-test-helm",
			"kubectl --kubeconfig /home/u/.kube/config --context kind-tern-kube-dev get service -l app.kubernetes.io/managed-by=Helm -o json -n tern-test-helm",
		})
		local states: { [string]: string } = {}
		for _, row in Helm.resourceRows(s.helm, top(s), nil) do
			states[row.ref.kind .. "/" .. row.ref.name] = row.state
		end
		expect(states).toEqual({
			["Secret/web-b-web-auth"] = "present",
			["ConfigMap/web-b-web-config"] = "present",
			["Service/web-b-web"] = "present",
			["Deployment/web-b-web"] = "present",
			["ConfigMap/web-b-web-pre-upgrade"] = "hook",
			["ConfigMap/web-b-web-post-install"] = "hook",
		})
		-- Other releases' objects in the same kinds are not "extra".
		expect((Helm.resourcesLoad(s.helm, top(s)) :: any).status).toBe("ok")
		s = W.helmAction(s, "sel", "apps/Deployment/" .. NS .. "/web-b-web")
		expect((State.focusRef(s) :: any).name).toBe("web-b-web")
		s = W.helmKeys(s, { "enter" })
		expect(top(s).kind).toBe("detail")
		local obj = State.findObject(s, top(s).ref :: any)
		expect((Helm.owner(s.helm, State.helmCtx(s), obj) :: any).status).toBe("ok")
	end)

	it("= in history diffs the selected revision against the latest, or the one marked with space", function()
		local s = W.helmKeys((webB()), { "h" })
		s = W.helmAction(s, "sel", "1")
		local vsLatest = W.helmKeys(s, { "=" })
		expect(top(vsLatest).kind).toBe("helm-diff")
		expect(top(vsLatest).revision).toBe(1)
		expect(top(vsLatest).against).toBe(3)
		expect((Helm.diffLoad(vsLatest.helm, top(vsLatest)) :: any).status).toBe("ok")
		local marked = W.helmKeys(s, { "space" })
		expect(Helm.mark(marked.helm, top(marked))).toBe(1)
		marked = W.helmAction(marked, "sel", "2")
		marked = W.helmKeys(marked, { "=" })
		expect(top(marked).revision).toBe(1)
		expect(top(marked).against).toBe(2)
	end)

	it("x stays the global key in history: it never marks", function()
		local s = W.helmKeys((webB()), { "h" })
		s = W.helmAction(s, "sel", "1")
		local after = W.helmKeys(s, { "x" })
		expect(Helm.mark(after.helm, top(after))).toBeNil()
	end)

	it("= in a release diffs its revision against the previous one", function()
		local s = W.helmKeys((webB()), { "=" })
		expect(top(s).kind).toBe("helm-diff")
		expect(top(s).revision).toBe(2)
		expect(top(s).against).toBe(3)
	end)

	it("ctrl+r in history opens the approve block for that revision", function()
		local s = W.helmKeys((webB()), { "h" })
		s = W.helmAction(s, "sel", "1")
		local _, effects = State.update(s, key("r", { ctrl = true }))
		local opens = ofType(effects, "open")
		expect(#opens).toBe(1)
		local p = params(opens[1].url :: string)
		expect(string.sub(opens[1].url :: string, 1, 19)).toBe("tern-kube://mutate?")
		expect(p.op).toBe("rollback")
		expect(p.release).toBe("web-b")
		expect(p.namespace).toBe(NS)
		expect(p.revision).toBe("1")
		expect(p.context).toBe(W.CTX)
		expect(p.source).toBe("flag")
		expect(#ofType(effects, "run")).toBe(0)
	end)

	it("ctrl+r in a release rolls back to the highest deployed or superseded revision below the latest", function()
		local s = webB()
		local _, effects = State.update(s, key("r", { ctrl = true }))
		expect(params(ofType(effects, "open")[1].url :: string).revision).toBe("2")
	end)

	it("the default rollback target skips failed and pending revisions", function()
		local function rev(n: number, status: string): any
			return { revision = n, status = status }
		end
		expect(Helm.defaultTarget({ rev(1, "superseded"), rev(2, "failed"), rev(3, "deployed") })).toBe(1)
		local stuck = json.decode(fixtures.read("helm/captured/history-stuck-d.json"))
		expect(Helm.defaultTarget(stuck)).toBe(1)
		expect(Helm.defaultTarget({ rev(1, "deployed") })).toBeNil()
	end)

	it("Y copies the helm command of the view as the user would type it", function()
		local s = W.helmKeys((webB()), { "h" })
		local _, effects = State.update(s, W.key("Y"))
		expect(ofType(effects, "copy")[1].text).toBe(HELM .. " history web-b -n tern-test-helm -o json --max 256")
	end)

	it("r re-reads the release", function()
		local s = webB()
		local _, effects = State.update(s, W.key("r"))
		expect(#helmRuns(effects)).toBe(2)
	end)
end)

describe("explore helm: owners", function()
	local objects = json.decode(fixtures.read("helm/captured/objects.json")).items

	local function ctx(context: string): Helm.Ctx
		local s = W.openHelm()
		local c = State.helmCtx(s)
		c.target = table.clone(c.target)
		c.target.context = context
		return c
	end

	it("one owner lookup per release and context, whatever objects of it are opened", function()
		local h = Helm.new()
		local effects: { Effect } = {}
		local c = ctx(W.CTX)
		for _, obj in objects do
			Helm.noticeObject(h, c, obj, effects)
		end
		local lines: { string } = {}
		for _, e in effects do
			table.insert(lines, line(e))
		end
		table.sort(lines)
		expect(#lines).toBe(5)
		expect(lines[3]).toBe(
			HELM
				.. " list -n tern-test-helm --deployed --failed --pending --superseded --uninstalled --uninstalling -o json --time-format 2006-01-02T15:04:05Z07:00 --filter ^stuck-d$"
		)
		local again: { Effect } = {}
		Helm.noticeObject(h, c, objects[1], again)
		expect(#again).toBe(0)
		Helm.noticeObject(h, ctx("other"), objects[1], again)
		expect(#again).toBe(1)
	end)

	it("the owner answer carries the release's revision and status", function()
		local h = Helm.new()
		local c = ctx(W.CTX)
		local effects: { Effect } = {}
		local deploy = objects[2]
		Helm.noticeObject(h, c, deploy, effects)
		local e = effects[1]
		Helm.onResult(h, c, {
			t = "result",
			tag = e.tag,
			gen = e.gen,
			result = W.helmResponder(e.argv :: { string }),
			at = W.AT,
		}, nil, {})
		local info = Helm.owner(h, c, deploy) :: any
		expect(info.status).toBe("ok")
		expect(info.revision).toBe(3)
		expect(info.release.status).toBe("deployed")
	end)
end)

-- web-b revision 2 was upgraded with --reuse-values: its stored "defaults"
-- hold revision 1's values (F8), so they are only a last resort. A chart
-- directory or a configured chart source is converted to JSON offline with
-- a throwaway chart (F15); files with values are written 0600 and the
-- temporary one is removed again.
describe("explore helm: values defaults fallbacks", function()
	local CONVERTED = '---\n# Source: tk-values/templates/values.yaml\n{"replicaCount":1,"auth":{"password":""}}\n'

	local function responder(seen: { string }): W.Responder
		return function(argv: { string })
			local text = table.concat(argv, " ")
			if argv[1] == "/bin/sh" or argv[1] == "rm" then
				table.insert(seen, text)
				return { status = 0, stdout = "", stderr = "", timed_out = false }
			elseif argv[1] == "helm" and argv[2] == "show" then
				table.insert(seen, text)
				return { status = 0, stdout = "replicaCount: 1\n", stderr = "", timed_out = false }
			elseif argv[1] == "helm" and argv[2] == "template" then
				table.insert(seen, text)
				return { status = 0, stdout = CONVERTED, stderr = "", timed_out = false }
			end
			return W.helmResponder(argv)
		end
	end

	local function valuesOfRevision2(cfgText: string?, seen: { string }): State
		local env = W.helmEnv()
		env.dataDir = "/data"
		env.nonce = function()
			return "n1"
		end
		local link =
			W.link({ context = W.CTX, route = "helm-release", release = "web-b", namespace = NS, revision = "2" })
		local s, effects = State.init({ link }, nil, W.config(cfgText), env)
		s = W.settle(s, effects, responder(seen))
		local s2, more = State.update(s, W.key("v"))
		return (W.settle(s2, more, responder(seen)))
	end

	it("without a chart dir or source the reused record is used, marked suspect", function()
		local seen: { string } = {}
		local s = valuesOfRevision2(nil, seen)
		local load = Helm.defaultsLoad(s.helm, top(s), 2) :: any
		expect(load.status).toBe("ok")
		expect(load.data.source).toBe("record-suspect")
		expect(#seen).toBe(0)
	end)

	it("a configured chart source is fetched with helm show values and converted offline", function()
		local seen: { string } = {}
		local s =
			valuesOfRevision2('{"helm": {"chart_sources": [{"chart": "web", "ref": "oci://reg.example/web"}]}}', seen)
		local load = Helm.defaultsLoad(s.helm, top(s), 2) :: any
		expect(load.status).toBe("ok")
		expect(load.data.source).toBe("chart-source")
		expect(load.data.values.replicaCount).toBe(1)
		local tmp = "/data/tmp/values-1000-n1.yaml"
		expect(seen).toEqual({
			"/bin/sh -c "
				.. require("../../../plugin/lib/explore/gitops").WRITE_SCRIPT
				.. " tern-kube-tmp /data/helm/values-chart/Chart.yaml",
			"/bin/sh -c "
				.. require("../../../plugin/lib/explore/gitops").WRITE_SCRIPT
				.. " tern-kube-tmp /data/helm/values-chart/templates/values.yaml",
			"helm show values oci://reg.example/web --version 0.2.1",
			"/bin/sh -c " .. require("../../../plugin/lib/explore/gitops").WRITE_SCRIPT .. " tern-kube-tmp " .. tmp,
			"helm template tk-values /data/helm/values-chart --no-hooks -f " .. tmp,
			"rm -f -- " .. tmp,
		})
	end)

	it("a chart directory with the release's chart name and version wins over the chart source", function()
		local seen: { string } = {}
		local s = valuesOfRevision2(nil, {})
		local h = Helm.clone(s.helm)
		h.defaults = {}
		local ctx = State.helmCtx(s)
		ctx.chartDirs = {
			{ path = "/repo/charts/web", name = "web", version = "0.2.1", appVersion = nil, valuesFiles = {} },
		}
		local queue: { Effect } = {}
		Helm.enter(h, ctx, top(s), false, queue)
		local respond = responder(seen)
		local guard = 0
		while #queue > 0 do
			guard += 1
			assert(guard < 50, "fallback loops")
			local e = table.remove(queue, 1) :: Effect
			if e.t == "run" then
				local more: { Effect } = {}
				local result = respond(e.argv :: { string })
				Helm.onResult(h, ctx, {
					t = "result",
					tag = e.tag,
					gen = e.gen,
					result = result,
					at = W.AT,
				}, top(s), more)
				Helm.enter(h, ctx, top(s), false, more)
				for _, m in more do
					table.insert(queue, m)
				end
			end
		end
		local load = Helm.defaultsLoad(h, top(s), 2) :: any
		expect(load.data.source).toBe("chart-dir")
		expect(seen[3]).toBe(
			"helm template tk-values /data/helm/values-chart --no-hooks -f /repo/charts/web/values.yaml"
		)
		expect(#seen).toBe(3)
	end)

	it("a failed conversion falls back to the suspect record", function()
		local seen: { string } = {}
		local env = W.helmEnv()
		env.dataDir = "/data"
		local link =
			W.link({ context = W.CTX, route = "helm-release", release = "web-b", namespace = NS, revision = "2" })
		local cfg = W.config('{"helm": {"chart_sources": [{"chart": "web", "ref": "oci://reg.example/web"}]}}')
		local s, effects = State.init({ link }, nil, cfg, env)
		local function failing(argv: { string }): (W.Result?, string?)
			if argv[1] == "helm" and argv[2] == "show" then
				table.insert(seen, "show")
				return W.fail(1, "Error: failed to authorize")
			end
			return responder(seen)(argv)
		end
		s = W.settle(s, effects, failing)
		local s2, more = State.update(s, W.key("v"))
		s2 = W.settle(s2, more, failing)
		expect((Helm.defaultsLoad(s2.helm, top(s2), 2) :: any).data.source).toBe("record-suspect")
		expect(table.find(seen, "show") ~= nil).toBe(true)
	end)
end)

return nil
