--!strict
local t = require("../../lib/test")
local argv = require("../../../plugin/lib/kubectl/argv")
local describe, it, expect = t.describe, t.it, t.expect

local function parse(line: string, program: string?)
	local args = {}
	for word in string.gmatch(line, "%S+") do
		table.insert(args, word)
	end
	return argv.parse(program or "kubectl", args)
end

describe("argv.parse global flags", function()
	-- Users put cluster targeting anywhere; the lens must attribute output to
	-- the right context/namespace either way.
	it("accepts global flags before the verb", function()
		local inv = parse("--context prod -n web get pods")
		expect(inv.verb).toBe("get")
		expect(inv.context).toBe("prod")
		expect(inv.namespace).toBe("web")
		expect(inv.resources).toEqual({ { kind = "Pod" } })
		expect(inv.positionals).toEqual({ "pods" })
	end)

	it("accepts global flags after the verb and resource", function()
		local inv = parse("get pods --kubeconfig=/tmp/kc --context=dev --namespace kube-system")
		expect(inv.kubeconfig).toBe("/tmp/kc")
		expect(inv.context).toBe("dev")
		expect(inv.namespace).toBe("kube-system")
	end)

	it("reads attached and equals shorthand values like pflag", function()
		expect(parse("get pods -nfoo").namespace).toBe("foo")
		expect(parse("get pods -n=foo").namespace).toBe("foo")
		expect(parse("get pods -oyaml").output).toBe("yaml")
		expect(parse("get pods -o=json").output).toBe("json")
	end)

	-- pflag lets bool shorthands cluster and lets a value flag end the cluster.
	it("expands shorthand bool clusters ending in a value flag", function()
		local inv = parse("get pods -Aw")
		expect(inv.allNamespaces).toBe(true)
		expect(inv.watch).toBe(true)
		local inv2 = parse("get pods -Aoyaml")
		expect(inv2.allNamespaces).toBe(true)
		expect(inv2.output).toBe("yaml")
	end)

	it("honours explicit false on bool flags", function()
		local inv = parse("get pods --watch=false -A=false --show-labels=true")
		expect(inv.watch).toBe(false)
		expect(inv.allNamespaces).toBe(false)
		expect(inv.showLabels).toBe(true)
	end)

	it("does not let a bool flag swallow the next token", function()
		local inv = parse("get --no-headers pods")
		expect(inv.noHeaders).toBe(true)
		expect(inv.resources).toEqual({ { kind = "Pod" } })
	end)

	-- Bare --dry-run is legal (NoOptDefVal), so the next token stays a positional.
	it("treats optional-value flags as not consuming the next token", function()
		local inv = parse("apply --dry-run -f a.yaml")
		expect(inv.dryRun).toBe("unchanged")
		expect(inv.filenames).toEqual({ "a.yaml" })
		expect(parse("delete pod x --dry-run=server").dryRun).toBe("server")
	end)

	it("keeps everything after -- out of flag parsing", function()
		local inv = parse("exec -n web web-0 -c app -- ls -la /tmp")
		expect(inv.verb).toBe("exec")
		expect(inv.afterDash).toEqual({ "ls", "-la", "/tmp" })
		expect(inv.flags.container).toEqual({ "app" })
		expect(inv.unknownFlags).toEqual({})
		expect(inv.resources).toEqual({ { kind = "Pod", name = "web-0" } })
	end)

	it("keeps repeatable flags as lists and splits comma lists like pflag", function()
		local inv = parse("apply -f a.yaml -f b.yaml,c.yaml -l app=x -l tier=web")
		expect(inv.filenames).toEqual({ "a.yaml", "b.yaml", "c.yaml" })
		expect(inv.flags.filename).toEqual({ "a.yaml", "b.yaml,c.yaml" })
		expect(inv.flags.selector).toEqual({ "app=x", "tier=web" })
		expect(inv.selector).toBe("tier=web")
		expect(parse("apply -R -k ./overlay").kustomize).toBe("./overlay")
		expect(parse("get pods -L app,tier").labelColumns).toEqual({ "app", "tier" })
	end)
end)

describe("argv.parse output formats", function()
	it("classifies every -o form and keeps its spec", function()
		local cases: { { line: string, format: string, spec: string? } } = {
			{ line = "get pods", format = "table" },
			{ line = "get pods -o wide", format = "wide" },
			{ line = "get pods -o name", format = "name" },
			{
				line = "get pods -o custom-columns=NAME:.metadata.name",
				format = "custom-columns",
				spec = "NAME:.metadata.name",
			},
			{ line = "get pods -o custom-columns-file=cols.txt", format = "custom-columns-file", spec = "cols.txt" },
			{
				line = "get pods -o jsonpath={.items[*].metadata.name}",
				format = "jsonpath",
				spec = "{.items[*].metadata.name}",
			},
			{ line = "get pods -o go-template={{.kind}}", format = "go-template", spec = "{{.kind}}" },
			{ line = "get pods -o template --template={{.kind}}", format = "template", spec = "{{.kind}}" },
			{ line = "get pods --template={{.kind}}", format = "template", spec = "{{.kind}}" },
			{ line = "get pods -o kyaml", format = "other", spec = "kyaml" },
		}
		for _, c in cases do
			local inv = parse(c.line)
			expect(inv.output).toBe(c.format)
			expect(inv.outputSpec).toBe(c.spec)
		end
	end)

	it("uses the last -o like kubectl", function()
		expect(parse("get pods -o json -o yaml").output).toBe("yaml")
	end)
end)

describe("argv.parse resources", function()
	it("normalizes short names and comma lists", function()
		expect(parse("get po").resources).toEqual({ { kind = "Pod" } })
		expect(parse("get pods,svc").resources).toEqual({ { kind = "Pod" }, { kind = "Service" } })
	end)

	it("expands TYPE NAME NAME into one resource per name", function()
		local inv = parse("get pod x y")
		expect(inv.names).toEqual({ "x", "y" })
		expect(inv.resources).toEqual({ { kind = "Pod", name = "x" }, { kind = "Pod", name = "y" } })
	end)

	it("reads TYPE/NAME including group-qualified types", function()
		expect(parse("get pod/x").resources).toEqual({ { kind = "Pod", name = "x" } })
		expect(parse("rollout restart deployment.apps/web").resources).toEqual({
			{ kind = "Deployment", group = "apps", name = "web" },
		})
		expect(parse("get deployments.v1.apps").resources).toEqual({ { kind = "Deployment", group = "apps" } })
	end)

	it("marks `get all` as the all category", function()
		expect(parse("get all -A").resources).toEqual({ { kind = "all" } })
	end)

	-- CRDs are unknown to the static table but must still be addressable.
	it("keeps CRD plurals with their group", function()
		expect(parse("get certificates.cert-manager.io").resources).toEqual({
			{ kind = "certificates", group = "cert-manager.io" },
		})
		expect(parse("get widgets").resources).toEqual({ { kind = "widgets" } })
	end)

	it("skips label edits when finding resource names", function()
		local inv = parse("label pods web-0 app=x tier-")
		expect(inv.names).toEqual({ "web-0" })
	end)
end)

describe("argv.parse verbs", function()
	it("resolves top subcommands including aliases", function()
		local inv = parse("top pods -A")
		expect(inv.verb).toBe("top")
		expect(inv.subverb).toBe("pod")
		expect(inv.positionals).toEqual({})
		expect(parse("top pod web-0").resources).toEqual({ { kind = "Pod", name = "web-0" } })
		expect(parse("top no").subverb).toBe("node")
	end)

	it("resolves rollout subcommands and their flags", function()
		for _, sub in { "restart", "status", "undo", "history", "pause", "resume" } do
			local inv = parse("rollout " .. sub .. " deploy/web")
			expect(inv.subverb).toBe(sub)
			expect(inv.resources).toEqual({ { kind = "Deployment", group = "apps", name = "web" } })
		end
		expect(parse("rollout undo deploy/web --to-revision 2").flags["to-revision"]).toEqual({ "2" })
	end)

	it("finds the verb past command-local flags placed before it", function()
		local inv = parse("-o yaml get pods")
		expect(inv.verb).toBe("get")
		expect(inv.output).toBe("yaml")
	end)

	it("parses the remaining verbs", function()
		expect(parse("scale deploy/web --replicas=3").flags.replicas).toEqual({ "3" })
		expect(parse("delete -f x.yaml --cascade=foreground").flags.cascade).toEqual({ "foreground" })
		expect(parse("create deployment web --image=nginx").subverb).toBe("deployment")
		expect(parse("create deploy web --image nginx").flags.image).toEqual({ "nginx" })
		expect(parse("create -f x.yaml").subverb).toBeNil()
		expect(parse("config use-context kind").subverb).toBe("use-context")
		expect(parse("logs -f web-0 -c app").resources).toEqual({ { kind = "Pod", name = "web-0" } })
		expect(parse("logs deploy/web").resources).toEqual({ { kind = "Deployment", group = "apps", name = "web" } })
		expect(parse("port-forward svc/web 8080:80").positionals).toEqual({ "svc/web", "8080:80" })
		expect(parse("patch deploy web -p {}").flags.patch).toEqual({ "{}" })
		expect(parse("api-resources --namespaced=true").flags.namespaced).toEqual({ "true" })
		expect(parse("version").verb).toBe("version")
		expect(parse("explain pods.spec").verb).toBe("explain")
		expect(parse("diff -f x.yaml").filenames).toEqual({ "x.yaml" })
		expect(parse("").verb).toBeNil()
	end)
end)

describe("argv.parse unknown flags", function()
	-- kubectl would reject these; we cannot know their arity, so we keep the
	-- next token as positional and say so instead of guessing silently.
	it("records an ambiguity when the next token could be a value", function()
		local inv = parse("get --frobnicate pods")
		expect(inv.unknownFlags).toEqual({ "--frobnicate" })
		expect(#inv.ambiguities).toBe(1)
		expect(inv.ambiguities[1]).toContain("pods")
		expect(inv.resources).toEqual({ { kind = "Pod" } })
	end)

	it("does not report ambiguity when the value is inline or another flag follows", function()
		local inv = parse("get pods --frob=1 -Z -A")
		expect(inv.unknownFlags).toEqual({ "--frob", "-Z" })
		expect(inv.ambiguities).toEqual({})
		expect(inv.flags.frob).toEqual({ "1" })
	end)

	it("reports a value flag with no value left", function()
		expect(parse("get pods -n").ambiguities[1]).toContain("-n")
	end)
end)

describe("argv.parse kubecolor", function()
	it("strips kubecolor-only flags but keeps kubectl ones", function()
		local inv = parse(
			"--plain get pods --light-background --force-colors --kubecolor-theme=dark --kubecolor-theme light -n x",
			"kubecolor"
		)
		expect(inv.verb).toBe("get")
		expect(inv.unknownFlags).toEqual({})
		expect(inv.positionals).toEqual({ "pods" })
		expect(inv.namespace).toBe("x")
		expect(parse("--kubecolor-version", "/opt/bin/kubecolor").verb).toBeNil()
	end)

	it("treats kubecolor flags as unknown for real kubectl", function()
		expect(parse("get pods --plain").unknownFlags).toEqual({ "--plain" })
	end)
end)

describe("argv.parse performance", function()
	it("parses 1000 invocations well within the lens budget", function()
		local start = os.clock()
		for _ = 1, 1000 do
			parse("--context prod get pods,svc -n web -l app=x -o wide --sort-by=.metadata.name -Aw")
		end
		expect(os.clock() - start < 0.2).toBe(true)
	end)
end)

return nil
