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
				"label cm/x a=b",
				"annotate cm/x a=b --overwrite",
				"patch deploy/web -p {}",
				"cordon n1",
				"uncordon n1",
				"rollout undo deploy/web",
				"rollout pause deploy/web",
				"rollout resume deploy/web",
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
			{ "exec web-0 -- ls", "raw" },
			{ "port-forward svc/web 80", "raw" },
			{ "edit deploy/web", "raw" },
			{ "explain pods", "raw" },
			{ "rollout status deploy/web", "rollout status" },
			{ "rollout history deploy/web -o json", "--revision=N" },
			{ "rollout history deploy/web -o yaml", "--revision=N" },
			{ "config view", "kubectl config view" },
			{ "config use-context x", "kubectl config use-context" },
			{ "auth whoami", "kubectl auth whoami" },
			{ "auth reconcile -f x.yaml", "kubectl auth reconcile" },
			{ "api-resources -o json", "use the table or -o wide" },
			{ "api-resources -o yaml", "use the table or -o wide" },
			{ "api-resources --no-headers", "use the table or -o wide" },
			{ "label pods --list", "--list" },
			{ "annotate deploy/web --list", "--list" },
			{ "drain n1 --ignore-daemonsets", "kubectl drain" },
			{ "config", "kubectl config" },
			{ "", "No kubectl command" },
		}
		for _, c in cases do
			local s = support(c[1])
			expect(s.supported).toBe(false)
			expect(s.reason).toContain(c[2])
		end
	end)

	-- Logs get the records view; event listings (including their watches,
	-- which only append rows) the events table. Track 2 plan 4.1.
	it("offers native views for logs and event listings, watches included", function()
		for _, line in
			{
				"logs web-0",
				"logs deploy/web -c app --prefix --timestamps",
				"logs -f -l app=web --all-containers",
				"-n x logs pod get y",
				"events",
				"events -A",
				"events --for pod/x --types=Warning",
				"events -w",
				"get events",
				"get ev -o wide",
				"get events -w",
				"get events --watch-only",
				"get events -w --output-watch-events",
				"get events.events.k8s.io -w",
				"events -o json",
			}
		do
			local s = support(line)
			expect(s.supported).toBe(true)
		end
	end)

	it("keeps other watches raw: their rows are rewritten in place", function()
		for _, line in { "get pods -w", "get events,pods -w", "get event x -w", "get events -w -o json" } do
			local s = support(line)
			expect(s.supported).toBe(false)
			expect(s.reason).toContain("watch")
		end
	end)

	-- v1.2 k9s parity: these four reads get native views (rollout history
	-- list and --revision, get-contexts, api-resources, can-i).
	it("offers native views for rollout history, get-contexts, api-resources and can-i", function()
		for _, line in
			{
				"rollout history deploy/web",
				"rollout history deploy/web --revision=2",
				"rollout history deploy/web --revision=2 -o json",
				"rollout history deploy/web --revision 2 -o yaml",
				"rollout history deploy/web -o name",
				"rollout history deployment -l app=web",
				"config get-contexts",
				"config get-contexts -o name",
				"config get-contexts --no-headers",
				"api-resources",
				"api-resources -o wide",
				"api-resources -o name --namespaced=false",
				"auth can-i get pods",
				"auth can-i --list -n x",
				"--as=system:serviceaccount:a:b auth can-i list pods -q",
			}
		do
			local s = support(line)
			expect(s.supported).toBe(true)
			expect(s.reason).toBeNil()
		end
	end)

	it("names an events listing whatever spelling the type uses", function()
		local function listing(line: string): boolean
			local args = {}
			for word in string.gmatch(line, "%S+") do
				table.insert(args, word)
			end
			return argv.isEventsListing(argv.parse("kubectl", args))
		end
		expect(listing("events -A")).toBe(true)
		expect(listing("get ev")).toBe(true)
		expect(listing("get event")).toBe(true)
		expect(listing("get events.events.k8s.io")).toBe(true)
		expect(listing("get events,pods")).toBe(false)
		expect(listing("get pods")).toBe(false)
		expect(listing("logs pod")).toBe(false)
	end)
end)

return nil
