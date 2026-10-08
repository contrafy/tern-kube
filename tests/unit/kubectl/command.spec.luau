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
		expect(string.sub(url, 1, 20)).toBe("kube-lens://explore?")
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
end)

return nil
