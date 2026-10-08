--!strict
local mutation = require("../../../plugin/lib/parse/mutation")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("mutation.parse apply", function()
	-- Each applied object becomes one result so the lens can link every touched
	-- resource; the printed resource token carries the API group.
	it("reports created, configured and unchanged objects of a multi-doc apply", function()
		local out = mutation.parse("apply", {
			"namespace/demo unchanged",
			"deployment.apps/web configured",
			"service/web created",
		})
		expect(out.diagnostics).toEqual({})
		expect(out.results).toEqual({
			{ kind = "namespace", name = "demo", action = "unchanged", line = 1 },
			{ kind = "deployment", group = "apps", name = "web", action = "configured", line = 2 },
			{ kind = "service", name = "web", action = "created", line = 3 },
		})
	end)

	-- A dry-run must never be presented as a change that happened.
	it("marks server and client dry runs", function()
		local out = mutation.parse("apply", {
			"deployment.apps/web created (server dry run)",
			"configmap/cfg configured (dry run)",
		})
		expect(out.results[1].dryRun).toBe("server")
		expect(out.results[1].action).toBe("created")
		expect(out.results[2].dryRun).toBe("client")
		expect(out.results[2].action).toBe("configured")
	end)

	it("keeps server-side apply and prune actions", function()
		local out = mutation.parse("apply", {
			"deployment.apps/web serverside-applied",
			"configmap/old pruned",
			"customresourcedefinition.apiextensions.k8s.io/widgets.example.com created",
		})
		expect(out.results[1].action).toBe("serverside-applied")
		expect(out.results[2].action).toBe("pruned")
		expect(out.results[3].group).toBe("apiextensions.k8s.io")
		expect(out.results[3].name).toBe("widgets.example.com")
	end)

	-- `-o name` prints only the object; the verb tells what happened to it.
	it("derives the action from the verb for name-only output", function()
		local out = mutation.parse("delete", { "pod/web-1" })
		expect(out.results[1]).toEqual({ kind = "pod", name = "web-1", action = "deleted", line = 1 })
	end)
end)

describe("mutation.parse errors", function()
	-- Partial failure is common: successful objects stay linkable and failures
	-- surface as errors on the line where kubectl printed them.
	it("classifies kubectl and server errors and keeps successes", function()
		local out = mutation.parse("apply", {
			"service/web unchanged",
			'Error from server (NotFound): error when creating "x.yaml": namespaces "nope" not found',
			"error: no objects passed to apply",
		})
		expect(#out.results).toBe(1)
		expect(out.diagnostics).toEqual({
			{
				line = 2,
				severity = "error",
				text = 'Error from server (NotFound): error when creating "x.yaml": namespaces "nope" not found',
			},
			{ line = 3, severity = "error", text = "error: no objects passed to apply" },
		})
	end)

	-- Validation errors list each invalid field on its own line; splitting them
	-- into unrelated diagnostics would lose which object they belong to.
	it("folds continuation lines into the preceding invalid-object error", function()
		local out = mutation.parse("apply", {
			'The Deployment "web" is invalid: ',
			"* spec.replicas: Invalid value: -1: must be greater than or equal to 0",
			"* spec.template.spec.containers[0].image: Required value",
		})
		expect(#out.results).toBe(0)
		expect(#out.diagnostics).toBe(1)
		expect(out.diagnostics[1].severity).toBe("error")
		expect(out.diagnostics[1].line).toBe(1)
		expect(out.diagnostics[1].text).toContain("spec.replicas")
		expect(out.diagnostics[1].text).toContain("containers[0].image")
	end)

	it("reports warnings, including klog-style ones", function()
		local out = mutation.parse("apply", {
			"Warning: resource deployments/web is missing the kubectl.kubernetes.io/last-applied-configuration annotation",
			"W1008 10:00:00.123456   12345 warnings.go:70] spec.template: deprecated",
			"deployment.apps/web configured",
		})
		expect(out.diagnostics[1].severity).toBe("warning")
		expect(out.diagnostics[2].severity).toBe("warning")
		expect(out.results[1].line).toBe(3)
	end)

	it("never raises on unrecognised text and reports it as info", function()
		local out = mutation.parse("apply", { "No resources found in default namespace.", "" })
		expect(out.results).toEqual({})
		expect(out.diagnostics).toEqual({
			{ line = 1, severity = "info", text = "No resources found in default namespace." },
		})
	end)
end)

describe("mutation.parse delete", function()
	it("parses the quoted delete form", function()
		local out =
			mutation.parse("delete", { 'deployment.apps "web" deleted', 'pod "web-1" deleted (server dry run)' })
		expect(out.results[1]).toEqual({
			kind = "deployment",
			group = "apps",
			name = "web",
			action = "deleted",
			line = 1,
		})
		expect(out.results[2].dryRun).toBe("server")
	end)

	-- kubectl >= 1.33 names the namespace, which lets the lens build an exact
	-- reference without trusting the invocation's namespace flags.
	it("captures the namespace of the newer delete form", function()
		local out = mutation.parse("delete", {
			'pod "web-1" deleted from default namespace',
			'service "web" deleted from demo namespace (dry run)',
		})
		expect(out.results[1]).toEqual({
			kind = "pod",
			name = "web-1",
			namespace = "default",
			action = "deleted",
			line = 1,
		})
		expect(out.results[2].namespace).toBe("demo")
		expect(out.results[2].dryRun).toBe("client")
	end)

	it("parses force deletion as its own action", function()
		local out = mutation.parse("delete", { 'pod "web-1" force deleted from default namespace' })
		expect(out.results[1].action).toBe("force deleted")
		expect(out.results[1].namespace).toBe("default")
	end)

	-- `delete --interactive` lists candidates as kind/name before asking; those
	-- were not deleted yet and must not be reported as deleted.
	it("does not treat the interactive confirmation list as deletions", function()
		local out = mutation.parse("delete", {
			"You are about to delete the following 2 resource(s):",
			"pod/web-1",
			"pod/web-2",
			"Do you want to continue? (y/N): y",
			'pod "web-1" deleted from default namespace',
		})
		expect(#out.results).toBe(1)
		expect(out.results[1].line).toBe(5)
		expect(#out.diagnostics).toBe(4)
		expect(out.diagnostics[2]).toEqual({ line = 2, severity = "info", text = "pod/web-1" })
	end)
end)

describe("mutation.parse rollout restart and scale", function()
	it("parses restarted and scaled objects", function()
		expect(mutation.parse("rollout", { "deployment.apps/web restarted" }).results[1].action).toBe("restarted")
		local scaled = mutation.parse("scale", { "statefulset.apps/db scaled (dry run)" }).results[1]
		expect(scaled.kind).toBe("statefulset")
		expect(scaled.action).toBe("scaled")
		expect(scaled.dryRun).toBe("client")
	end)

	it("parses 1000 results well within the lens budget", function()
		local lines: { string } = {}
		for i = 1, 1000 do
			lines[i] = string.format('pod "web-%d" deleted from default namespace', i)
		end
		local started = os.clock()
		local out = mutation.parse("delete", lines)
		local elapsed = os.clock() - started
		expect(#out.results).toBe(1000)
		expect(elapsed < 0.2).toBe(true)
	end)
end)

return nil
