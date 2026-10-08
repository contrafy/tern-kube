--!strict
-- Audit lines persist on disk indefinitely, so they carry only what is needed
-- to reconstruct who-ran-what-where: never command output (may hold secret
-- values), never environment values, and never credentials typed as flags.
local Audit = require("../../../plugin/lib/mutation/audit")
local Plan = require("../../../plugin/lib/mutation/plan")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV: T.Env = {
	context = "kind-dev",
	contextSource = "chosen",
	kubeconfig = "/k/config",
	namespace = "apps",
	cwd = "/w",
}

local function plan(argv: { string }): T.Plan
	return Plan.fromArgv(argv, ENV) :: T.Plan
end

local EVENT: Audit.Event = {
	mode = "native",
	decision = "executed",
	tier = "typed",
	fingerprint = string.rep("a", 64),
	exitCode = 0,
	previewedAt = 1790000000,
	decidedAt = 1790000005,
	startedAt = 1790000006,
	finishedAt = 1790000007,
}

describe("audit record", function()
	it("serialises a fixed set of fields in a fixed order", function()
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), EVENT))
		expect(line).toBe(
			'{"v":1,"decided_at":1790000005,"decision":"executed","mode":"native","op":"delete","family":"delete",'
				.. '"context":"kind-dev","context_source":"chosen","namespace":"apps","kubeconfig":"/k/config","cwd":"/w",'
				.. '"argv":["kubectl","delete","pod","web"],"tier":"typed","fingerprint":"'
				.. string.rep("a", 64)
				.. '","exit_code":0,"previewed_at":1790000000,"started_at":1790000006,"finished_at":1790000007}\n'
		)
	end)

	it("omits fields that did not happen (a denial never started)", function()
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), {
			mode = "guard",
			decision = "denied",
			decidedAt = 5,
		}))
		expect((string.find(line, "exit_code", 1, true))).toBeNil()
		expect((string.find(line, "started_at", 1, true))).toBeNil()
		expect(line).toContain('"decision":"denied","mode":"guard"')
	end)

	it("drops stdout, stderr and environment even when the caller passes them", function()
		local event: any = table.clone(EVENT)
		event.stdout = "secret-data: c2VjcmV0"
		event.stderr = "token=abc"
		event.env = { AWS_SECRET_ACCESS_KEY = "xyz", KUBECONFIG = "/k/config" }
		local line = Audit.line(Audit.record(plan({ "kubectl", "delete", "pod", "web" }), event))
		for _, leak in { "secret-data", "c2VjcmV0", "token=abc", "AWS_SECRET", "xyz", "stdout", "stderr", '"env"' } do
			expect((string.find(line, leak, 1, true))).toBeNil()
		end
		expect(line).toContain('"kubeconfig":"/k/config"')
	end)

	it("redacts credentials typed as flags in both spellings", function()
		local p = plan({
			"kubectl",
			"--token=s3cr3t",
			"--password",
			"hunter2",
			"--token",
			"other",
			"delete",
			"pod",
			"web",
		})
		local line = Audit.line(Audit.record(p, EVENT))
		expect((string.find(line, "s3cr3t", 1, true))).toBeNil()
		expect((string.find(line, "hunter2", 1, true))).toBeNil()
		expect((string.find(line, "other", 1, true))).toBeNil()
		expect(Audit.redactArgv({ "kubectl", "--token=a", "--password", "b", "--", "--token", "c" })).toEqual({
			"kubectl",
			"--token=<redacted>",
			"--password",
			"<redacted>",
			"--",
			"--token",
			"c",
		})
	end)

	it("escapes JSON so odd argv cannot break the line format", function()
		local p = plan({ "kubectl", "delete", "pod", 'we"b\n\\x\1' })
		local line = Audit.line(Audit.record(p, EVENT))
		expect(line).toContain('"we\\"b\\n\\\\x\\u0001"')
		expect(select(2, string.gsub(line, "\n", ""))).toBe(1)
	end)
end)

return nil
