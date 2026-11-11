--!strict
-- What the lens block shows for each kind of run: native view with a
-- snapshot header, or nil so Tern shows the raw output.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Capture = require("../../../plugin/lib/lens/capture")
local Command = require("../../../plugin/lib/kubectl/command")
local Header = require("../../../plugin/lib/render/header")
local HelmChip = require("../../../plugin/lib/render/helm_chip")
local View = require("../../../plugin/lib/lens/view")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local vsm = require("../../../plugin/lib/lens/viewstate")
local describe, it, expect = t.describe, t.it, t.expect

local function build(id: string): Capture.Capture
	local f = runs.load(id)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function fromLines(command: string, lines: { string }, status: number?): Capture.Capture
	return Capture.build(runs.run(command), lines, status, { decode = json.decode })
end

local function header(node: any): any
	return nodes.find(node, nodes.role("tern-kube.header"))
end

describe("lens view", function()
	it("unsupported commands render nil (raw), whatever their output", function()
		expect(View.render(fromLines("kubectl get pods -w", { "NAME   READY", "a      1/1" }, 130), vsm.default())).toBeNil()
		expect(View.render(fromLines("kubectl get pods -o jsonpath={.x}", { "a b" }, 0), vsm.default())).toBeNil()
		-- Over-claimed by `kubectl -* get *`: logs output stays raw.
		expect(View.render(fromLines("kubectl -n x logs pod get", { "hello" }, 0), vsm.default())).toBeNil()
	end)

	it("empty output renders nil", function()
		expect(View.render(fromLines("kubectl get secrets", {}, 0), vsm.default())).toBeNil()
	end)

	-- LENS-L4: a 30k-line `-o yaml` fell back to raw with no hint why.
	it("output over the native limits says why and shows a preview", function()
		local r = runs.run("kubectl get cm -n big -o yaml")
		local inv = Argv.parse(r.program, r.args)
		local node = View.renderOverflow(inv, {
			lines = 30214,
			bytes = 900000,
			maxLines = 20000,
			maxBytes = 16777216,
			preview = { "apiVersion: v1", "items:" },
		})
		local text = nodes.text(node)
		expect(text).toContain("30214 lines")
		expect(text).toContain("general.max_rows")
		expect(text).toContain("Raw")
		expect(text).toContain("kubectl get cm -o yaml")
		expect((nodes.find(node, nodes.kind("code")) :: any).p.text).toBe("apiVersion: v1\nitems:")
		local bytes = nodes.text(View.renderOverflow(inv, {
			lines = 10,
			bytes = 70000,
			maxLines = 20000,
			maxBytes = 65536,
			preview = {},
		}))
		expect(bytes).toContain("general.max_capture_bytes")
	end)

	it("every native mode gets the snapshot header", function()
		for _, id in
			{
				"ns-apps/get_pods",
				"ns-apps/get_pods_-o_json",
				"ns-apps/get_pods_-o_name",
				"ns-apps/get_pods_-o_yaml",
				"ns-apps/describe_pod_crashloop",
				"mutate-ops/scale_deployment+api_--replicas=3",
				"cluster/top_nodes",
			}
		do
			local node = View.render(build(id), vsm.default())
			assert(node, id .. " rendered nil")
			local h = header(node)
			expect(h ~= nil).toBe(true)
			expect(nodes.text(h)).toContain("Snapshot")
		end
	end)

	it("header names the command, target and counts", function()
		local node = View.render(build("ns-apps/get_pods"), vsm.default()) :: any
		local text = nodes.text(header(node))
		expect(text).toContain("kubectl get pods")
		expect(text).toContain("ns: tern-test-apps")
		expect(text).toContain("context: current context at run time")
		expect(text).toContain("7 rows")
		local allNs = nodes.text(header(View.render(build("all-namespaces/get_pods_-A"), vsm.default())))
		expect(allNs).toContain("ns: all")
	end)

	it("header shows the explicit context and filtered counts", function()
		local c = fromLines(
			"kubectl --context prod get pods",
			{ "NAME   READY   STATUS", "a      1/1     Running", "b      0/1     Pending" },
			0
		)
		local vs = vsm.toggledFilter(vsm.sortedBy(vsm.default(), "NAME"), "STATUS", "Running")
		local text = nodes.text(header(View.render(c, vs)))
		expect(text).toContain("context: prod")
		expect(text).toContain("1 of 2 rows")
		expect(text).toContain("sorted by NAME")
	end)

	-- `top --sum` prints a separator and a totals row: the header counts pods.
	it("top --sum: the header counts pods only and the totals read as a footer", function()
		local c = fromLines("kubectl top pods --sum", {
			"NAME    CPU(cores)   MEMORY(bytes)   ",
			"a       1m           2Mi             ",
			"b       3m           4Mi             ",
			"        ________     ________        ",
			"        4m           6Mi             ",
		}, 0)
		local node = View.render(c, vsm.default()) :: any
		expect(nodes.text(header(node))).toContain("2 rows")
		expect(nodes.text(node)).toContain("Total 4m CPU · 6Mi memory")
	end)

	it("error-only output shows the kubectl error and exit status natively", function()
		local node = View.render(build("errors/get_foos"), vsm.default()) :: any
		expect(node ~= nil).toBe(true)
		expect(nodes.find(node, nodes.role("tern-kube.exit")) ~= nil).toBe(true)
		local diag = nodes.find(node, nodes.role("tern-kube.diagnostics")) :: any
		expect(nodes.text(diag)).toContain("the server doesn't have a resource type")
		expect(diag.p.collapsed).toBe(false)
	end)

	it("missing context error shows natively too", function()
		local node = View.render(build("errors-context/get_pods"), vsm.default()) :: any
		expect(nodes.text(node)).toContain("does-not-exist")
	end)

	-- kubectl 1.34 with a kubeconfig path prints this instead of `error:`;
	-- the lens showed it as an unrecognised line instead of an error.
	it("an unknown context in the kubeconfig is a kubectl error", function()
		local c = fromLines(
			"kubectl --context nonexistent get pods",
			{ "Error in configuration: context was not found for specified context: nonexistent" },
			1
		)
		local diag = nodes.find(View.render(c, vsm.default()) :: any, nodes.role("tern-kube.diagnostics")) :: any
		expect(nodes.text(diag)).toContain("1 error")
		expect(c.unparsed).toBe(0)
	end)

	-- LENS-L10: an unreachable server printed 5 identical memcache.go klog
	-- lines before the one sentence that explains it ("6 errors").
	it("collapses repeated klog errors and leads with kubectl's own sentence", function()
		local klog =
			'E1110 11:06:29.65%d   60233 memcache.go:265] "Unhandled Error" err="couldn\'t get current server API group list"'
		local lines: { string } = {}
		for i = 1, 5 do
			table.insert(lines, string.format(klog, i))
		end
		table.insert(
			lines,
			"The connection to the server 127.0.0.1:1 was refused - did you specify the right host or port?"
		)
		local diag = nodes.find(
			View.render(fromLines("kubectl get pods", lines, 1), vsm.default()) :: any,
			nodes.role("tern-kube.diagnostics")
		) :: any
		local text = nodes.text(diag)
		expect(text).toContain("2 errors")
		expect(string.find(text, "The connection to the server", 1, true) < string.find(text, "memcache", 1, true)).toBe(
			true
		)
		expect(text).toContain("×5")
		local _, copies = string.gsub(text, "memcache", "")
		expect(copies).toBe(1)
	end)

	-- LENS-L6: `-l app=web` and `--previous` views looked identical to the
	-- unfiltered and current ones.
	it("the command summary keeps the flags that change what is shown", function()
		local function summary(line: string): string
			local r = runs.run(line)
			return Header.commandSummary(Argv.parse(r.program, r.args))
		end
		expect(summary("kubectl get pods -l app=web --field-selector status.phase=Running -n x")).toBe(
			"kubectl get pods -l app=web --field-selector status.phase=Running"
		)
		expect(summary("kubectl logs web-1 -c app --previous -n x")).toBe("kubectl logs web-1 -c app --previous")
		expect(summary("kubectl logs -l app=tk-logmix --all-containers --prefix")).toBe(
			"kubectl logs -l app=tk-logmix --all-containers"
		)
		expect(summary("kubectl get events -w")).toBe("kubectl get events -w")
	end)

	-- LENS-L7: `ns: default for context` on nodes, CRDs and namespaces meant
	-- nothing.
	it("cluster-scoped kinds show no namespace", function()
		local function target(line: string): string
			local r = runs.run(line)
			return nodes.spansText(Header.target(Argv.parse(r.program, r.args)))
		end
		for _, line in
			{ "kubectl get nodes", "kubectl describe nodes", "kubectl top nodes", "kubectl get crds", "kubectl get ns" }
		do
			expect((string.find(target(line), "ns:", 1, true))).toBeNil()
		end
		expect(target("kubectl get pods")).toContain("ns:")
		expect(target("kubectl get nodes,pods")).toContain("ns:")
	end)

	-- Live: a failed `kubectl scale` showed the error twice (header
	-- diagnostics and the mutation error card) and "exit 1" twice.
	it("failed mutations show the error and exit status once, in the result view", function()
		local node = View.render(build("errors/scale_deployment+api_--replicas=1"), vsm.default()) :: any
		expect(nodes.find(node, nodes.role("tern-kube.error")) ~= nil).toBe(true)
		expect(nodes.find(header(node), nodes.role("tern-kube.diagnostics"))).toBeNil()
		expect(nodes.find(header(node), nodes.role("tern-kube.exit"))).toBeNil()
		local _, count = string.gsub(nodes.text(node), "exit 1", "")
		expect(count).toBe(1)
	end)

	it("No resources found reads as a note, not an error", function()
		local node = View.render(build("ns-empty/get_pods"), vsm.default()) :: any
		expect(nodes.text(node)).toContain("No resources found")
		expect(nodes.find(node, nodes.role("tern-kube.exit"))).toBeNil()
		expect(nodes.find(node, nodes.role("tern-kube.diagnostics"))).toBeNil()
	end)

	it("partial captures say how many lines were not understood", function()
		local c = fromLines("kubectl get pods", { "NAME   READY", "a      1/1", "   stray  text  here" }, 0)
		local node = View.render(c, vsm.default()) :: any
		expect(nodes.text(nodes.find(node, nodes.role("tern-kube.partial")) :: any)).toBe("partial: 1 unparsed line")
	end)

	it("warns when raw output holds Secret data", function()
		local text = [[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s","namespace":"n"},"data":{"k":"dg=="}}]]
		local node = View.render(fromLines("kubectl get secret s -n n -o json", { text }, 0), vsm.default()) :: any
		expect(nodes.find(node, nodes.role("tern-kube.sensitive")) ~= nil).toBe(true)
	end)

	local function sensitiveText(c: Capture.Capture): string?
		local node = nodes.find(View.render(c, vsm.default()) :: any, nodes.role("tern-kube.sensitive"))
		return if node then nodes.text(node) else nil
	end

	-- The masking banner would be false once values are shown; the warning
	-- that the block holds Secret values must stay.
	it("swaps the masking banner for a warning when Secret values are shown", function()
		local text = [[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s","namespace":"n"},"data":{"k":"dg=="}}]]
		local run = runs.run("kubectl get secret s -n n -o json")
		local masked = Capture.build(run, { text }, 0, { decode = json.decode })
		expect(sensitiveText(masked)).toBe("Raw output contains Secret data; native view masks it")
		local shown = Capture.build(run, { text }, 0, {
			decode = json.decode,
			policy = { showSecrets = true, strict = false },
		})
		expect(sensitiveText(shown)).toBe("Output contains Secret values (security.show_secret_values is on)")
	end)

	it("notes strict-mode masking of non-Secret output", function()
		local lines = { "Name:  web-1", "Namespace:  apps", "Environment:", "  DB_PASSWORD:  hunter2" }
		local run = runs.run("kubectl describe pod web-1 -n apps")
		local strict =
			Capture.build(run, lines, 0, { decode = json.decode, policy = { showSecrets = false, strict = true } })
		expect(sensitiveText(strict)).toContain("sensitive_output_strict_mode")
		expect((string.find(nodes.text(View.render(strict, vsm.default()) :: any), "hunter2", 1, true))).toBeNil()
		expect(sensitiveText(Capture.build(run, lines, 0, { decode = json.decode }))).toBeNil()
	end)

	it("the ? chip toggles the cheat sheet and keeps the rest of the state", function()
		local vs = vsm.sortedBy(vsm.default(), "AGE")
		local node = View.render(build("ns-apps/get_pods"), vs) :: any
		expect(nodes.find(node, nodes.role("tern-kube.help"))).toBeNil()
		local chip = nodes.find(node, nodes.key("help-chip")) :: any
		local next = vsm.decode(string.sub(nodes.action(chip) :: string, 3))
		expect(next.help).toBe(true)
		expect(next.sort).toBe("AGE")
		local withHelp = View.render(build("ns-apps/get_pods"), next) :: any
		expect(nodes.text(nodes.find(withHelp, nodes.role("tern-kube.help")) :: any)).toContain("Click a column header")
	end)

	-- Track 2 plan 5: event listings render through the table pipeline. The
	-- Warning count is the TYPE facet chip (a summary badge repeated it).
	it("kubectl events renders natively with ×N notes and a Warning count", function()
		local node = View.render(build("ns-apps/events"), vsm.default()) :: any
		assert(node, "events rendered nil")
		local text = nodes.text(node)
		expect(text).toContain("×12 over 4h30m")
		expect(nodes.find(node, nodes.role("tern-kube.summary"))).toBeNil()
		expect(nodes.find(node, nodes.key("TYPE=Warning")) ~= nil).toBe(true)
	end)

	-- A watch ends in Ctrl-C (status 130): that is how the user stops it, not
	-- a failure.
	it("a watch stopped with Ctrl-C says stopped instead of exit 130", function()
		local f = runs.load("ns-logs/get_events_-w_--request-timeout=8s")
		local lines = table.clone(f.lines)
		table.insert(lines, "^C")
		local node = View.render(Capture.build(f.run, lines, 130, { decode = json.decode }), vsm.default()) :: any
		local h = header(node)
		expect(nodes.find(h, nodes.role("tern-kube.exit"))).toBeNil()
		expect(nodes.text(nodes.find(h, nodes.role("tern-kube.stopped")) :: any)).toBe("stopped (Ctrl-C)")
	end)

	it("header notes appear under the bar", function()
		local node = View.render(build("ns-apps/events"), vsm.default(), { notes = { "trails" } }) :: any
		expect(nodes.text(nodes.find(header(node), nodes.role("tern-kube.note")) :: any)).toBe("trails")
	end)

	-- Plan 4.4/5 running policy: while an event watch runs Raw is live and a
	-- plugin view trails it (Tern hands lines over late), so raw is the default.
	it("event watches stay raw while running unless streaming_view is native", function()
		local function inv(line: string)
			local r = runs.run(line)
			return Argv.parse(r.program, r.args)
		end
		expect(View.rawWhileRunning(inv("kubectl get events -w"), "raw")).toBe(true)
		expect(View.rawWhileRunning(inv("kubectl events -w -n x"), "raw")).toBe(true)
		expect(View.rawWhileRunning(inv("kubectl get events -w"), "native")).toBe(false)
		expect(View.rawWhileRunning(inv("kubectl get events"), "raw")).toBe(false)
		expect(View.rawWhileRunning(inv("kubectl get pods"), "raw")).toBe(false)
	end)

	-- Plan 7: describe, JSON and YAML of a Helm-managed object link its
	-- release. Tern rebuilds a lens block by replaying the recorded lines, and
	-- the chip comes from those lines alone (no helm query), so the
	-- rehydrated block shows the same chip with the same link.
	it("Helm release chips survive rehydration with the same Explore link", function()
		local describeLines = {
			"Name:         shop-a-shop",
			"Namespace:    tern-test-helm",
			"Annotations:  deployment.kubernetes.io/revision: 3",
			"              meta.helm.sh/release-name: shop-a",
			"              meta.helm.sh/release-namespace: tern-test-helm",
			"Replicas:     2 desired | 2 updated | 2 total | 2 available | 0 unavailable",
		}
		local yamlLines = {
			"apiVersion: apps/v1",
			"kind: Deployment",
			"metadata:",
			"  annotations:",
			"    meta.helm.sh/release-name: shop-a",
			"    meta.helm.sh/release-namespace: tern-test-helm",
			"  name: shop-a-shop",
			"  namespace: tern-test-helm",
		}
		local key = "apps/Deployment/tern-test-helm/shop-a-shop"
		local ctx = "kubectl --context kind-tern-kube-dev -n tern-test-helm "
		local cases: { { command: string, lines: { string }, vs: vsm.ViewState } } = {
			{ command = ctx .. "describe deploy shop-a-shop", lines = describeLines, vs = vsm.default() },
			{
				command = ctx .. "get deployments,services,configmaps,secrets -o json",
				lines = fixtures.lines("helm/captured/objects.json"),
				vs = vsm.opened(vsm.default(), key),
			},
			{ command = ctx .. "get deploy shop-a-shop -o yaml", lines = yamlLines, vs = vsm.default() },
		}
		for _, case in cases do
			local function chips(): { string }
				local node = View.render(fromLines(case.command, case.lines, 0), case.vs) :: any
				local out: { string } = {}
				for _, chip in nodes.findAll(node, nodes.role(HelmChip.ROLE)) do
					table.insert(out, nodes.text(chip) .. " " .. (nodes.action(chip) :: string))
				end
				return out
			end
			local first = chips()
			expect(first).toEqual({ "Helm release tern-test-helm/shop-a helm-release=tern-test-helm/shop-a" })
			expect(chips()).toEqual(first)
			local inv = fromLines(case.command, case.lines, 0).invocation
			local url = HelmChip.url(inv, "tern-test-helm/shop-a") :: string
			local params: { [string]: string } = {}
			for _, kv in Command.parseQuery(url) do
				params[kv.key] = kv.value
			end
			expect(params).toEqual({
				route = "helm-release",
				release = "shop-a",
				namespace = "tern-test-helm",
				context = "kind-tern-kube-dev",
			})
		end
	end)
end)

return nil
