--!strict
local t = require("../../lib/test")
local argv = require("../../../plugin/lib/kubectl/argv")
local describe, it, expect = t.describe, t.it, t.expect

local function support(line: string)
	local args = {}
	for word in string.gmatch(line, "%S+") do
		table.insert(args, word)
	end
	return argv.lensSupport(argv.parse("kubectl", args))
end

describe("argv.lensSupport", function()
	it("offers a native view for reads and the guarded mutations", function()
		for _, line in
			{
				"get pods",
				"get pods -o wide",
				"get pods -o json",
				"get pods -o yaml",
				"get pods -o name",
				"get pods -o custom-columns=NAME:.metadata.name",
				"get all -A",
				"describe pod x",
				"top pods",
				"top node",
				"apply -f x.yaml",
				"delete pod x",
				"rollout restart deploy/web",
				"scale deploy/web --replicas=2",
			}
		do
			local s = support(line)
			expect(s.supported).toBe(true)
			expect(s.reason).toBeNil()
		end
	end)

	-- Free-form or streaming output cannot be mapped to rows; the user needs
	-- to know why and what to run instead.
	it("falls back to raw output with an actionable reason", function()
		local cases = {
			{ "get pods -w", "-w" },
			{ "get pods --watch-only", "watch" },
			{ "get pods -o jsonpath={.items}", "-o json" },
			{ "get pods -o go-template={{.kind}}", "-o json" },
			{ "get pods --template={{.kind}}", "-o json" },
			{ "get pods -o custom-columns-file=c.txt", "custom-columns=" },
			{ "get --raw /healthz", "--raw" },
			{ "logs web-0", "raw" },
			{ "exec web-0 -- ls", "raw" },
			{ "port-forward svc/web 80", "raw" },
			{ "edit deploy/web", "raw" },
			{ "explain pods", "raw" },
			{ "rollout status deploy/web", "rollout status" },
			{ "config view", "kubectl config" },
			{ "", "No kubectl command" },
		}
		for _, c in cases do
			local s = support(c[1])
			expect(s.supported).toBe(false)
			expect(s.reason).toContain(c[2])
		end
	end)
end)

return nil
