--!strict
-- Real kubectl v1.34 mutation output captured from the kind cluster.
local mutation = require("../../../plugin/lib/parse/mutation")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function summary(verb: string, path: string): { string }
	local out = mutation.parse(verb, fixtures.lines(path))
	expect(out.diagnostics).toEqual({})
	local items = {}
	for _, result in out.results do
		table.insert(
			items,
			string.format(
				"%s|%s|%s|%s|%s|%s",
				result.kind,
				result.group or "",
				result.name,
				result.namespace or "",
				result.action,
				result.dryRun or ""
			)
		)
	end
	return items
end

local function errorsOf(verb: string, path: string): { string }
	local out = mutation.parse(verb, fixtures.lines(path))
	expect(out.results).toEqual({})
	local texts = {}
	for _, diagnostic in out.diagnostics do
		expect(diagnostic.severity).toBe("error")
		table.insert(texts, diagnostic.text)
	end
	return texts
end

describe("mutation.parse real apply", function()
	it("reads a multi-document apply that creates everything", function()
		expect(summary("apply", "real/mutate-create/apply_-f_mutate+app.yaml.txt")).toEqual({
			"configmap||api-config||created|",
			"deployment|apps|api||created|",
			"service||api||created|",
		})
		expect(summary("apply", "real/mutate-create/apply_-f_mutate+scratch-pod.yaml.txt")).toEqual({
			"pod||scratch||created|",
		})
	end)

	it("reads a server dry run of a create", function()
		expect(summary("apply", "real/mutate-create/apply_--dry-run=server_-f_mutate+app.yaml.txt")).toEqual({
			"configmap||api-config||created|server",
			"deployment|apps|api||created|server",
			"service||api||created|server",
		})
	end)

	-- Client dry runs cannot know a server-side no-op, so they claim
	-- "configured" where the server dry run reports "unchanged".
	it("keeps client and server dry-run verdicts distinct", function()
		expect(summary("apply", "real/mutate-configured/apply_--dry-run=client_-f_mutate+app-v2.yaml.txt")).toEqual({
			"configmap||api-config||configured|client",
			"deployment|apps|api||configured|client",
			"service||api||configured|client",
		})
		expect(summary("apply", "real/mutate-configured/apply_--dry-run=server_-f_mutate+app-v2.yaml.txt")).toEqual({
			"configmap||api-config||configured|server",
			"deployment|apps|api||configured|server",
			"service||api||unchanged|server",
		})
	end)

	it("reads configured and unchanged applies", function()
		expect(summary("apply", "real/mutate-configured/apply_-f_mutate+app-v2.yaml.txt")).toEqual({
			"configmap||api-config||configured|",
			"deployment|apps|api||configured|",
			"service||api||unchanged|",
		})
		expect(summary("apply", "real/mutate-unchanged/apply_-f_mutate+app.yaml.txt")).toEqual({
			"configmap||api-config||unchanged|",
			"deployment|apps|api||unchanged|",
			"service||api||unchanged|",
		})
	end)

	it("reports apply failures as errors", function()
		expect(errorsOf("apply", "real/errors/apply_-f_mutate+invalid.yaml.stderr")[1]).toContain(
			'strict decoding error: unknown field "spec.replcas"'
		)
		expect(errorsOf("apply", "real/errors/apply_-f_mutate+broken.yaml.stderr")[1]).toContain(
			"error converting YAML to JSON"
		)
		expect(errorsOf("apply", "real/errors/apply_-f_mutate+does-not-exist.yaml.stderr")).toEqual({
			'error: the path "mutate/does-not-exist.yaml" does not exist',
		})
	end)
end)

describe("mutation.parse real delete, restart and scale", function()
	it("reads the namespaced delete form of kubectl 1.34", function()
		expect(summary("delete", "real/mutate-delete/delete_-f_mutate+app-v2.yaml.txt")).toEqual({
			"configmap||api-config|tern-test-mutate|deleted|",
			"deployment|apps|api|tern-test-mutate|deleted|",
			"service||api|tern-test-mutate|deleted|",
		})
		expect(summary("delete", "real/mutate-ops/delete_pod_scratch.txt")).toEqual({
			"pod||scratch|tern-test-mutate|deleted|",
		})
	end)

	it("reads rollout restart and scale", function()
		expect(summary("rollout", "real/mutate-ops/rollout_restart_deployment+api.txt")).toEqual({
			"deployment|apps|api||restarted|",
		})
		expect(summary("scale", "real/mutate-ops/scale_deployment+api_--replicas=3.txt")).toEqual({
			"deployment|apps|api||scaled|",
		})
	end)

	it("reports each missing object of a failed delete separately", function()
		expect(#errorsOf("delete", "real/errors/delete_-f_mutate+app-v2.yaml.stderr")).toBe(3)
		expect(errorsOf("delete", "real/errors/delete_pod_scratch.stderr")).toEqual({
			'Error from server (NotFound): pods "scratch" not found',
		})
		expect(#errorsOf("scale", "real/errors/scale_deployment+api_--replicas=1.stderr")).toBe(1)
		expect(#errorsOf("rollout", "real/errors/rollout_restart_deployment+api.stderr")).toBe(1)
	end)
end)

return nil
