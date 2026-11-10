--!strict
-- Copied commands are pasted into a shell: quoting must survive spaces and
-- single quotes, and they must target the snapshot's cluster, not whatever
-- context is current at paste time.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Command = require("../../../plugin/lib/kubectl/command")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function ref(kind: string, name: string, namespace: string?, group: string?): any
	return { kind = kind, name = name, namespace = namespace, group = group, source = "snapshot" }
end

describe("kubectl command", function()
	it("leaves plain words unquoted", function()
		expect(Command.format({ "kubectl", "get", "pods", "-n", "kube-system", "-o", "yaml" })).toBe(
			"kubectl get pods -n kube-system -o yaml"
		)
		expect(Command.quote("deployment.apps/web")).toBe("deployment.apps/web")
	end)

	it("single-quotes spaces, empty words and shell metacharacters", function()
		expect(Command.quote("my context")).toBe("'my context'")
		expect(Command.quote("")).toBe("''")
		expect(Command.quote("$(rm -rf ~)")).toBe("'$(rm -rf ~)'")
		expect(Command.quote("a;b")).toBe("'a;b'")
	end)

	it("escapes single quotes POSIX-style", function()
		expect(Command.quote("it's")).toBe("'it'\\''s'")
	end)

	it("describe carries --kubeconfig, --context and the row's namespace", function()
		local inv =
			Argv.parse("kubectl", { "--context", "team's cluster", "--kubeconfig", "/tmp/my kube", "get", "pods" })
		local text = Command.copyText("describe", inv, ref("Pod", "db-0", "apps"))
		expect(text).toBe(
			"kubectl --kubeconfig '/tmp/my kube' --context 'team'\\''s cluster' describe pod db-0 -n apps"
		)
	end)

	it("get -o yaml uses kind.group for grouped kinds", function()
		local inv = Argv.parse("kubectl", { "get", "all" })
		expect(Command.copyText("get-yaml", inv, ref("Deployment", "web", "apps", "apps"))).toBe(
			"kubectl get deployment.apps web -n apps -o yaml"
		)
		expect(Command.copyText("describe", inv, ref("widgets", "gizmo", "crd", "lens.example.com"))).toBe(
			"kubectl describe widgets.lens.example.com gizmo -n crd"
		)
	end)

	it("cluster-scoped objects get no -n", function()
		local inv = Argv.parse("kubectl", { "get", "nodes" })
		expect(Command.copyText("describe", inv, ref("Node", "n1"))).toBe("kubectl describe node n1")
	end)

	it("logs only for pods, --all-containers when the pod has several", function()
		local inv = Argv.parse("kubectl", { "-n", "x", "get", "pods" })
		expect(Command.copyText("logs", inv, ref("Pod", "p", "x"))).toBe("kubectl logs p -n x")
		expect(Command.copyText("logs", inv, ref("Pod", "p", "x"), { containers = 2 })).toBe(
			"kubectl logs p -n x --all-containers"
		)
		expect(Command.copyText("logs", inv, ref("Deployment", "web", "x", "apps"))).toBeNil()
	end)

	it("copies name and qualified id", function()
		local inv = Argv.parse("kubectl", { "get", "pods" })
		expect(Command.copyText("name", inv, ref("Pod", "db-0", "apps"))).toBe("db-0")
		expect(Command.copyText("id", inv, ref("Deployment", "web", "apps", "apps"))).toBe(
			"deployment.apps/web -n apps"
		)
	end)

	it("explore URL round-trips names with spaces, quotes and separators", function()
		local inv = Argv.parse("kubectl", { "--context", "a&b=c d", "--kubeconfig", "/k/it's", "get", "pods" })
		local url = Command.exploreUrl(inv, ref("Pod", "db-0", "apps"))
		expect(string.sub(url, 1, 20)).toBe("tern-kube://explore?")
		local params: { [string]: string } = {}
		for _, p in Command.parseQuery(url) do
			params[p.key] = p.value
		end
		expect(params).toEqual({
			kind = "Pod",
			name = "db-0",
			namespace = "apps",
			context = "a&b=c d",
			kubeconfig = "/k/it's",
		})
	end)

	local function params(url: string): { [string]: string }
		local out: { [string]: string } = {}
		for _, p in Command.parseQuery(url) do
			out[p.key] = p.value
		end
		return out
	end

	local function inv(line: string)
		local args = {}
		for word in string.gmatch(line, "%S+") do
			table.insert(args, word)
		end
		return Argv.parse("kubectl", args)
	end

	-- The Explore logs/events routes (track 2) open from lens chips; Explore
	-- validates every parameter, so only set ones travel.
	it("explore URL carries the logs and events route parameters", function()
		local url = Command.exploreUrl(inv("--context kind get pods"), ref("Pod", "p", "x"), {
			route = "logs",
			container = "app",
			previous = true,
			since = "5m",
			tail = "100",
			search = true,
		})
		expect(params(url)).toEqual({
			kind = "Pod",
			name = "p",
			namespace = "x",
			context = "kind",
			route = "logs",
			container = "app",
			previous = "1",
			since = "5m",
			tail = "100",
			search = "1",
		})
		local warnings = Command.exploreUrl(inv("events -n x"), ref("Pod", "p", "x"), {
			route = "events",
			types = "Warning",
			previous = false,
			search = false,
		})
		expect(params(warnings)).toEqual({
			kind = "Pod",
			name = "p",
			namespace = "x",
			route = "events",
			types = "Warning",
		})
	end)

	it("explore URL without an object is scoped to the command's namespace, * for -A", function()
		expect(params(Command.exploreUrl(inv("events -n web"), nil, { route = "events" }))).toEqual({
			namespace = "web",
			route = "events",
		})
		expect(params(Command.exploreUrl(inv("events -A"), nil, { route = "events" }))).toEqual({
			namespace = "*",
			route = "events",
		})
		expect(params(Command.exploreUrl(inv("logs -l app=x -n web"), nil, { route = "logs", selector = "app=x" }))).toEqual({
			namespace = "web",
			route = "logs",
			selector = "app=x",
		})
	end)

	-- The lens "Filter in Explore" chip: the same list (type, namespace or -A,
	-- -l, pinned target) with Explore's text filter open.
	it("filter URL reopens the listed type in Explore with its filter focused", function()
		expect(params(Command.exploreFilterUrl(inv("--context kind get deploy -n web -l app=x")) :: string)).toEqual({
			kind = "Deployment",
			group = "apps",
			namespace = "web",
			context = "kind",
			selector = "app=x",
			search = "1",
		})
		expect(params(Command.exploreFilterUrl(inv("get widgets.lens.example.com -A")) :: string)).toEqual({
			kind = "widgets",
			group = "lens.example.com",
			namespace = "*",
			search = "1",
		})
		expect(Command.exploreFilterUrl(inv("get pods,svc"))).toBeNil()
		expect(Command.exploreFilterUrl(inv("get all"))).toBeNil()
		expect(Command.exploreFilterUrl(inv("get pod db-0"))).toBeNil()
		expect(Command.exploreFilterUrl(inv("describe pods"))).toBeNil()
	end)

	-- Lens chips on Helm-managed objects open the release in Explore: the
	-- release namespace must win over the lensed command's -n (a describe
	-- in another namespace still names the release's own).
	it("explore URL names a Helm release with its own namespace and pins the target", function()
		local url = Command.exploreUrl(inv("--context kind --kubeconfig /k/c get pods -n other"), nil, {
			route = "helm-release",
			release = "shop-a",
			namespace = "tern-test-helm",
			revision = 3,
		})
		expect(params(url)).toEqual({
			namespace = "tern-test-helm",
			context = "kind",
			kubeconfig = "/k/c",
			route = "helm-release",
			release = "shop-a",
			revision = "3",
		})
		expect(url).toBe(
			"tern-kube://explore?namespace=tern-test-helm&context=kind&kubeconfig=%2Fk%2Fc&route=helm-release&release=shop-a&revision=3"
		)
	end)

	it("logsSource reads the pod, TYPE/NAME or selector and the flags a rerun keeps", function()
		local pod = Command.logsSource(inv("--context kind logs p -n x -c app -p --since=5m --tail=20 --timestamps"))
		expect(pod.ref and pod.ref.kind).toBe("Pod")
		expect(pod.ref and pod.ref.name).toBe("p")
		expect(pod.ref and pod.ref.namespace).toBe("x")
		expect(pod.ref and pod.ref.clusterContext).toBe("kind")
		expect(pod.container).toBe("app")
		expect(pod.previous).toBe(true)
		expect(pod.since).toBe("5m")
		expect(pod.tail).toBe("20")
		expect(pod.timestamps).toBe(true)
		expect(pod.prefix).toBe(false)
		expect(pod.selector).toBeNil()

		local deploy = Command.logsSource(inv("logs deploy/web --all-containers --prefix -c app"))
		expect(deploy.ref and deploy.ref.kind).toBe("Deployment")
		expect(deploy.ref and deploy.ref.group).toBe("apps")
		expect(deploy.allContainers).toBe(true)
		-- --all-containers wins over -c in kubectl, so a rerun must not pin one.
		expect(deploy.container).toBeNil()
		expect(deploy.prefix).toBe(true)

		local sel = Command.logsSource(inv("logs -l app=web -f"))
		expect(sel.ref).toBeNil()
		expect(sel.selector).toBe("app=web")
		expect(sel.previous).toBe(false)
	end)
end)

return nil
