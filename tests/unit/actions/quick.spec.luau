--!strict
-- Quick-action links are clicked from rendered output and reach a handler
-- that launches a terminal command, so a link must never be able to choose
-- the command: decode() accepts only known actions with schema-checked
-- fields, and command() rebuilds the line with POSIX quoting. The target
-- cluster must always be visible: context pinned with --context, or echoed
-- when the lensed command did not pin one.
local Quick = require("../../../plugin/lib/actions/quick")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function ref(kind: string, name: string, namespace: string?, group: string?): any
	return { kind = kind, name = name, namespace = namespace, group = group, source = "snapshot" }
end

local PINNED = { context = "kind-tern-kube-dev", kubeconfig = "/tmp/kube config" }
local UNPINNED = {}

local function ids(actions: { Quick.Action }): { string }
	local out: { string } = {}
	for i, a in actions do
		out[i] = a.id
	end
	return out
end

-- Runs `script` (what follows `sh -c ` in a line) through a shell parser:
-- the line must be one quoted word. Returns the unquoted script.
local function unquoteLine(line: string): string
	local body = string.match(line, "^sh %-c '(.*)'$")
	assert(body, "line is not sh -c '<script>': " .. line)
	body = string.gsub(body, "'\"'\"'", "'")
	return (string.gsub(body, "'\\\\'", "\\"))
end

-- fish (a login shell Tern may run the line with) reads backslash escapes
-- even inside single quotes; the line must hold none there.
local function backslashInQuotes(line: string): boolean
	local quote: string? = nil
	for i = 1, #line do
		local c = string.sub(line, i, i)
		if quote == nil and (c == "'" or c == '"') then
			quote = c
		elseif c == quote then
			quote = nil
		elseif c == "\\" and quote ~= nil then
			return true
		end
	end
	return false
end

describe("quick actions", function()
	describe("available", function()
		it("offers shell, logs and port-forward on pods", function()
			expect(ids(Quick.available("Pod", ref("Pod", "web-0", "apps"), { source = "lens" }))).toEqual({
				"shell",
				"logs-follow",
				"port-forward",
			})
		end)

		it("offers a workload shell only once Explore resolved a ready pod", function()
			local d = ref("Deployment", "web", "apps", "apps")
			expect(ids(Quick.available("Deployment", d, { source = "lens" }))).toEqual({ "logs-follow", "port-forward" })
			expect(ids(Quick.available("Deployment", d, { source = "explore", pod = "web-1" }))).toEqual({
				"shell",
				"logs-follow",
				"port-forward",
			})
		end)

		it("hides mutating actions until the M3 confirm tier exists", function()
			expect(ids(Quick.available("Node", ref("Node", "n1"), {}))).toEqual({})
			expect(ids(Quick.available("CronJob", ref("CronJob", "nightly", "b", "batch"), {}))).toEqual({})
			expect(ids(Quick.available("Node", ref("Node", "n1"), { allowMutations = true }))).toEqual({
				"debug-node",
				"edit",
			})
			expect(ids(Quick.available("Pod", ref("Pod", "p", "ns"), { allowMutations = true }))).toEqual({
				"shell",
				"logs-follow",
				"port-forward",
				"debug-pod",
				"edit",
			})
		end)

		it("offers nothing for unknown kinds or a same-named kind in another group", function()
			expect(ids(Quick.available("Widget", ref("Widget", "w", "ns", "lens.example.com"), {}))).toEqual({})
			expect(ids(Quick.available("Deployment", ref("Deployment", "d", "ns", "example.com"), {}))).toEqual({})
		end)

		it("marks mutating actions", function()
			expect(Quick.mutates("debug-pod")).toBe(true)
			expect(Quick.mutates("cronjob-run")).toBe(true)
			expect(Quick.mutates("shell")).toBe(false)
			expect(Quick.mutates("rm")).toBe(false)
		end)

		it("gates mutating actions through the approve block, edit through the guard after saving", function()
			expect(Quick.gate("shell")).toBe("none")
			expect(Quick.gate("debug-pod")).toBe("approve")
			expect(Quick.gate("cronjob-run")).toBe("approve")
			expect(Quick.gate("edit")).toBe("editor")
			expect(Quick.gate("rm")).toBe("none")
		end)
	end)

	-- Edit opens kubectl edit under the shell guard in a split; the guard
	-- asks for approval after the save, so the link only names the object.
	describe("edit", function()
		local CORE = "/plugins/tern kube/shell/tern-kube-guard"
		local SETTINGS = { guardCore = CORE }

		it("offers edit for any named object, custom resources included, except events", function()
			local allow = { allowMutations = true }
			expect(ids(Quick.available("Widget", ref("Widget", "w", "ns", "lens.example.com"), allow))).toEqual({
				"edit",
			})
			expect(ids(Quick.available("ConfigMap", ref("ConfigMap", "c", "ns"), allow))).toEqual({ "edit" })
			expect(ids(Quick.available("Event", ref("Event", "e.1", "ns"), allow))).toEqual({})
			expect(ids(Quick.available("ConfigMap", ref("ConfigMap", "c", "ns"), {}))).toEqual({})
		end)

		it("round-trips the group so the type stays exact, and refuses what kubectl would not address", function()
			local url = Quick.encode("edit", PINNED, ref("Widget", "w", "ns", "lens.example.com")) :: string
			expect(url).toContain("group=lens.example.com")
			local req = Quick.decode(url) :: Quick.Request
			expect((req.ref :: any).group).toBe("lens.example.com")
			expect((Quick.encode("edit", PINNED, ref("ClusterRole", "system:view")) ~= nil)).toBe(true)
			for _, bad in
				{
					"tern-kube://act/edit?kind=ConfigMap&name=c&namespace=ns&confirm=abc",
					"tern-kube://act/edit?kind=Config-Map&name=c",
					"tern-kube://act/edit?kind=Node&name=n&namespace=ns",
					"tern-kube://act/edit?kind=Widget&group=Bad_Group&name=w",
					"tern-kube://act/edit?kind=Event&name=e&namespace=ns",
					"tern-kube://act/edit?kind=ConfigMap&name=-x",
				}
			do
				expect((Quick.decode(bad))).toBeNil()
			end
		end)

		it("runs the guard core with kubectl edit, context pinned and paths quoted", function()
			local launch = Quick.command(
				"edit",
				{ context = "kind-tern-kube-dev", kubeconfig = "/tmp/kube config", program = "/opt/k 8s/bin/kubectl" },
				ref("Deployment", "web", "apps", "apps"),
				{},
				SETTINGS
			) :: Quick.Launch
			expect(launch.argv).toEqual({
				"kubectl",
				"edit",
				"--context",
				"kind-tern-kube-dev",
				"--kubeconfig",
				"/tmp/kube config",
				"-n",
				"apps",
				"deployment.apps/web",
			})
			expect(launch.title).toBe("tern-kube edit apps/web @ kind-tern-kube-dev")
			expect(unquoteLine(launch.line)).toBe(
				"printf '\\033]0;%s\\007' 'tern-kube edit apps/web @ kind-tern-kube-dev'; "
					.. "PATH='/opt/k 8s/bin':$PATH; export PATH; "
					.. "exec '/plugins/tern kube/shell/tern-kube-guard' kubectl edit --context kind-tern-kube-dev "
					.. "--kubeconfig '/tmp/kube config' -n apps deployment.apps/web"
			)
		end)

		it("leaves PATH alone for a bare kubectl and pins no kubeconfig when unknown", function()
			local launch = Quick.command("edit", { context = "c" }, ref("Node", "w1"), {}, SETTINGS) :: Quick.Launch
			expect(unquoteLine(launch.line)).toBe(
				"printf '\\033]0;%s\\007' 'tern-kube edit w1 @ c'; "
					.. "exec '/plugins/tern kube/shell/tern-kube-guard' kubectl edit --context c node/w1"
			)
		end)

		it("refuses without the guard core", function()
			local launch, e = Quick.command("edit", PINNED, ref("ConfigMap", "c", "ns"), {}, {})
			expect(launch).toBeNil()
			expect(e).toBe("shell/tern-kube-guard is missing from the plugin directory")
			expect((Quick.command("edit", PINNED, ref("ConfigMap", "c", "ns"), {}, { guardCore = "rel/core" }))).toBeNil()
		end)

		it("gives an edit chip that names the guard flow", function()
			local chips = Quick.chipsFor("ConfigMap", ref("ConfigMap", "c", "ns"), PINNED, { allowMutations = true })
			expect(#chips).toBe(1)
			expect(chips[1].label).toBe("Edit")
			expect(chips[1].title).toContain("approve block previews")
		end)
	end)

	describe("encode/decode", function()
		it("round-trips every field, including spaces and quotes in the context", function()
			local target = { context = "team's ctx @ eu/1", kubeconfig = "/Users/me/my kube/config" }
			local url = Quick.encode("shell", target, ref("Deployment", "web", "apps", "apps"), {
				pod = "web-5f6b8bff9b-djlsb",
				container = "app",
			})
			expect(type(url)).toBe("string")
			expect(string.sub(url :: string, 1, 22)).toBe("tern-kube://act/shell?")
			local req = Quick.decode(url :: string)
			assert(req, "decodes")
			expect(req.action).toBe("shell")
			expect(req.target).toEqual(target)
			local r = req.ref
			assert(r, "names the object")
			expect(r.kind).toBe("Deployment")
			expect(r.group).toBe("apps")
			expect(r.name).toBe("web")
			expect(r.namespace).toBe("apps")
			expect(req.opts.pod).toBe("web-5f6b8bff9b-djlsb")
			expect(req.opts.container).toBe("app")
		end)

		it("round-trips ports as numbers and selectors with set operators", function()
			local url =
				Quick.encode("port-forward", PINNED, ref("Service", "web", "apps"), { port = 80, localPort = 9080 })
			local req = Quick.decode(url :: string)
			assert(req, "decodes")
			expect(req.opts.port).toBe(80)
			expect(req.opts.localPort).toBe(9080)
			local sel = "app=web,tier in (a, b),!canary"
			local lurl = Quick.encode("logs-follow", PINNED, ref("Deployment", "web", "apps"), { selector = sel })
			local lreq = Quick.decode(lurl :: string)
			assert(lreq, "decodes")
			expect(lreq.opts.selector).toBe(sel)
		end)

		it("omits an unpinned context so the window echoes the effective one", function()
			local url = Quick.encode("logs-follow", UNPINNED, ref("Pod", "p", "ns"), {}) :: string
			expect((string.find(url, "context=", 1, true))).toBeNil()
			local req = Quick.decode(url)
			assert(req, "decodes")
			expect(req.target.context).toBeNil()
		end)

		it("rejects unknown actions and non-act links", function()
			local _, err = Quick.decode("tern-kube://act/rm?kind=Pod&name=p")
			expect(err).toContain("unknown action")
			expect((Quick.decode("tern-kube://explore?kind=Pod&name=p"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell/x?kind=Pod&name=p"))).toBeNil()
			expect((Quick.encode("rm", PINNED, ref("Pod", "p", "ns"), {}))).toBeNil()
		end)

		it("rejects parameters the action does not take", function()
			local _, err = Quick.decode("tern-kube://act/shell?kind=Pod&name=p&cmd=rm")
			expect(err).toContain("does not take cmd")
			_, err = Quick.decode("tern-kube://act/shell?kind=Pod&name=p&line=ls")
			expect(err).toContain("does not take line")
			_, err = Quick.decode("tern-kube://act/logs-follow?kind=Pod&name=p&port=80")
			expect(err).toContain("does not take port")
			_, err = Quick.decode("tern-kube://act/shell?kind=Pod&name=p&image=busybox")
			expect(err).toContain("does not take image")
		end)

		it("rejects duplicates, empty values, fragments and raw characters", function()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&name=q"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name="))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p#x"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p q"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p%2"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&x"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p+q"))).toBeNil()
		end)

		it("rejects shell metacharacters in names, namespaces, containers and pods", function()
			for _, bad in { "p;rm", "p$(id)", "p`id`", "p'q", "p q", "P", "-p", "p-", "a..b", "p\n", "p|x", "p&x" } do
				local enc = string.gsub(bad, "[^%w]", function(c: string): string
					return string.format("%%%02X", string.byte(c))
				end)
				expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=" .. enc))).toBeNil()
				expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&namespace=" .. enc))).toBeNil()
				expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&container=" .. enc))).toBeNil()
				expect((Quick.decode("tern-kube://act/shell?kind=Deployment&name=d&pod=" .. enc))).toBeNil()
				expect((Quick.encode("shell", PINNED, ref("Pod", bad, "ns"), {}))).toBeNil()
			end
		end)

		it("rejects control characters and flag-like values in context and kubeconfig", function()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&context=a%0Ab"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&context=-x"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&kubeconfig=--exec"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&kubeconfig=~%2Fkube"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&context=%1B%5D0%3Bx"))).toBeNil()
		end)

		it("enforces per-action kinds and required fields", function()
			expect((Quick.decode("tern-kube://act/shell?kind=Service&name=web"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Deployment&name=web"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&pod=q"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?name=p"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?kind=pod&name=p"))).toBeNil()
			expect((Quick.decode("tern-kube://act/logs-follow?kind=Pod&name=p&selector=app%3Dx"))).toBeNil()
			expect((Quick.decode("tern-kube://act/port-forward?kind=Job&name=j&port=80"))).toBeNil()
			expect((Quick.decode("tern-kube://act/port-forward?kind=Pod&name=p&local=80"))).toBeNil()
			expect((Quick.decode("tern-kube://act/debug-node?kind=Node&name=n&namespace=x"))).toBeNil()
			-- A chip carries no suffix (the approve block names the job), but
			-- no command line can be built without one.
			expect(Quick.decode("tern-kube://act/cronjob-run?kind=CronJob&name=c&namespace=b") ~= nil).toBe(true)
			expect((Quick.command("cronjob-run", {}, ref("CronJob", "c", "b", "batch"), {}))).toBeNil()
			expect(Quick.decode("tern-kube://act/cronjob-run?kind=CronJob&name=c&namespace=b&suffix=x1") ~= nil).toBe(
				true
			)
			local long = string.rep("a", 50)
			expect((Quick.decode("tern-kube://act/cronjob-run?kind=CronJob&name=" .. long .. "&suffix=abcdef"))).toBeNil()
		end)
	end)

	describe("command", function()
		it("builds the shell line from the contract, pinned and titled", function()
			local l = Quick.command("shell", PINNED, ref("Pod", "web-0", "apps"), { container = "app" })
			assert(l, "builds")
			expect(l.argv).toEqual({
				"kubectl",
				"exec",
				"-it",
				"--kubeconfig",
				"/tmp/kube config",
				"--context",
				"kind-tern-kube-dev",
				"-n",
				"apps",
				"web-0",
				"-c",
				"app",
				"--",
				"sh",
				"-c",
				"command -v bash >/dev/null 2>&1 && exec bash || exec sh",
			})
			expect(l.title).toBe("tern-kube shell apps/web-0:app @ kind-tern-kube-dev")
			expect(unquoteLine(l.line)).toBe(
				"printf '\\033]0;%s\\007' 'tern-kube shell apps/web-0:app @ kind-tern-kube-dev'; "
					.. "exec kubectl exec -it --kubeconfig '/tmp/kube config' --context kind-tern-kube-dev -n apps web-0 -c app"
					.. " -- sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
			)
		end)

		it("execs into the resolved pod of a workload", function()
			local l = Quick.command("shell", PINNED, ref("Deployment", "web", "apps", "apps"), { pod = "web-abc" })
			assert(l, "builds")
			expect(l.argv[10]).toBe("web-abc")
		end)

		it("echoes the effective context first when the target is not pinned", function()
			local l = Quick.command("logs-follow", { kubeconfig = "/k/c" }, ref("Pod", "p", "ns"), {})
			assert(l, "builds")
			local script = unquoteLine(l.line)
			expect(script).toContain(
				"; printf 'tern-kube: context %s\\n' \"$(kubectl --kubeconfig /k/c config current-context)\"; kubectl logs"
			)
			expect(l.title).toContain("@ current context")
			local pinned = Quick.command("logs-follow", PINNED, ref("Pod", "p", "ns"), {})
			assert(pinned, "builds")
			expect((string.find(pinned.line, "current-context", 1, true))).toBeNil()
		end)

		it("quotes every field that reaches the shell", function()
			local target =
				{ context = "it's $(id) `x`; y", kubeconfig = "/tmp/a b/c'd", program = "/opt/k bin/kubectl" }
			local l = Quick.command("shell", target, ref("Pod", "p", "ns"), {})
			assert(l, "builds")
			local script = unquoteLine(l.line)
			expect(script).toContain("'/opt/k bin/kubectl' exec -it --kubeconfig '/tmp/a b/c'\\''d'")
			expect(script).toContain("--context 'it'\\''s $(id) `x`; y'")
			expect(script).toContain("'tern-kube shell ns/p @ it'\\''s $(id) `x`; y'")
			-- The whole script is one word: every quote or backslash inside is
			-- written between single-quoted runs (`'"'"'`, `'\\'`), so nothing
			-- expands in the user's login shell.
			local body = string.match(l.line, "^sh %-c '(.*)'$")
			assert(body, "sh -c line")
			local rest = string.gsub(string.gsub(body, "'\"'\"'", ""), "'\\\\'", "")
			expect((string.find(rest, "'", 1, true))).toBeNil()
		end)

		it("follows pod logs across containers unless one is chosen", function()
			local all = Quick.command("logs-follow", PINNED, ref("Pod", "p", "ns"), {})
			assert(all, "builds")
			expect(table.concat(all.argv, " ")).toBe(
				"kubectl logs -f --tail=200 --kubeconfig /tmp/kube config --context kind-tern-kube-dev -n ns p --all-containers --prefix"
			)
			local one = Quick.command("logs-follow", PINNED, ref("Pod", "p", "ns"), { container = "app" })
			assert(one, "builds")
			expect(table.concat(one.argv, " ", 9)).toBe("-n ns p -c app")
		end)

		it("follows workload logs by selector when known, else by type/name", function()
			local sel =
				Quick.command("logs-follow", UNPINNED, ref("Deployment", "web", "apps"), { selector = "app=web" })
			assert(sel, "builds")
			expect(table.concat(sel.argv, " ")).toBe(
				"kubectl logs -f --tail=200 -n apps -l app=web --prefix --max-log-requests=10 --all-containers"
			)
			local plain = Quick.command("logs-follow", UNPINNED, ref("StatefulSet", "db", "apps"), {})
			assert(plain, "builds")
			expect(table.concat(plain.argv, " ")).toBe("kubectl logs -f --tail=200 -n apps statefulset/db")
		end)

		it("maps privileged remote ports to 8000+port and keeps unprivileged ones", function()
			expect(Quick.localPort(80)).toBe(8080)
			expect(Quick.localPort(443)).toBe(8443)
			expect(Quick.localPort(1024)).toBe(9024)
			expect(Quick.localPort(1025)).toBe(1025)
			expect(Quick.localPort(8080)).toBe(8080)
			local svc = Quick.command("port-forward", UNPINNED, ref("Service", "web", "apps"), { port = 80 })
			assert(svc, "builds")
			expect(table.concat(svc.argv, " ")).toBe("kubectl port-forward -n apps service/web 8080:80")
			local pod =
				Quick.command("port-forward", UNPINNED, ref("Pod", "p", "apps"), { port = 8080, localPort = 18080 })
			assert(pod, "builds")
			expect(pod.argv[#pod.argv]).toBe("18080:8080")
		end)

		-- MUT-F7: a second shift+f on the same workload ran 8080:8080 again and
		-- failed with "address already in use".
		it("forwards the suggested local port only when it is free, else lets kubectl pick one", function()
			local svc = Quick.command("port-forward", UNPINNED, ref("Service", "web", "apps"), { port = 80 })
			assert(svc, "builds")
			local script = unquoteLine(svc.line)
			expect(script).toContain("p=80; l=8080; ")
			expect(script).toContain(
				"if ! command -v lsof >/dev/null 2>&1; then a=:$p; why='lsof is not installed'; "
					.. 'elif lsof -nP -iTCP:"$l" -sTCP:LISTEN >/dev/null 2>&1; then a=:$p; why="localhost:$l is in use"; '
					.. "else a=$l:$p; fi"
			)
			expect(script).toContain(
				"printf 'tern-kube: %s; kubectl picks a free local port (see Forwarding from below)\\n' \"$why\""
			)
			expect(script).toContain('kubectl port-forward -n apps service/web "$a"')
			-- A local port the link names is used as given.
			local fixed =
				unquoteLine(
					(Quick.command(
						"port-forward",
						UNPINNED,
						ref("Pod", "p", "apps"),
						{ port = 8080, localPort = 18080 }
					) :: any).line
				)
			expect(fixed).toContain("p=8080; l=18080; a=$l:$p; ")
			expect((string.find(fixed, "lsof", 1, true))).toBeNil()
		end)

		-- MUT-T: Tern 0.9.14 shows a "Shell exited with 1" modal and a red tab
		-- for a pane whose command fails; Ctrl-C is how logs and port-forwards
		-- are stopped, so it must not look like a failure.
		it("follow-logs and port-forward splits exit 0 on Ctrl-C, other failures keep their status", function()
			local cases: { { action: string, opts: Quick.Opts } } = {
				{ action = "logs-follow", opts = {} },
				{ action = "port-forward", opts = { port = 80 } },
				{ action = "port-forward", opts = {} },
			}
			for _, case in cases do
				local l = Quick.command(case.action, PINNED, ref("Deployment", "web", "apps", "apps"), case.opts)
				assert(l, "builds")
				local script = unquoteLine(l.line)
				expect(script).toContain("; trap 'exit 0' INT; ")
				expect((string.find(script, "exec ", 1, true))).toBeNil()
			end
			local sh = unquoteLine((Quick.command("shell", PINNED, ref("Pod", "p", "ns"), {}) :: any).line)
			expect((string.find(sh, "trap", 1, true))).toBeNil()
		end)

		it("resolves the first declared port at run time when none is known", function()
			local l = Quick.command("port-forward", PINNED, ref("Deployment", "web", "apps", "apps"), {})
			assert(l, "builds")
			local script = unquoteLine(l.line)
			expect(script).toContain(
				"set -- $(kubectl get --kubeconfig '/tmp/kube config' --context kind-tern-kube-dev -n apps deployment/web -o "
					.. "'jsonpath={.spec.template.spec.containers[*].ports[*].containerPort}')"
			)
			expect(script).toContain(
				"p=${1:-}; case $p in ''|*[!0-9]*) printf 'tern-kube: %s declares no port\\n' deployment/web >&2; exit 1;; esac"
			)
			expect(script).toContain('if [ "$p" -gt 1024 ]; then l=$p; else l=$((8000 + p)); fi')
			expect(script).toContain('deployment/web "$a"')
			local svc =
				unquoteLine((Quick.command("port-forward", PINNED, ref("Service", "web", "apps"), {}) :: any).line)
			expect(svc).toContain("jsonpath={.spec.ports[*].port}")
		end)

		it("builds the mutating commands for the M3 confirm tier", function()
			local dp = Quick.command("debug-pod", UNPINNED, ref("Pod", "p", "ns"), { container = "app" })
			assert(dp, "builds")
			expect(table.concat(dp.argv, " ")).toBe("kubectl debug -it -n ns p --image=busybox:1.36 --target=app")
			local dn = Quick.command("debug-node", PINNED, ref("Node", "kind-control-plane"), { image = "alpine:3.20" })
			assert(dn, "builds")
			expect(table.concat(dn.argv, " ", 2)).toBe(
				"debug -it --kubeconfig /tmp/kube config --context kind-tern-kube-dev node/kind-control-plane --image=alpine:3.20"
			)
			local cj =
				Quick.command("cronjob-run", UNPINNED, ref("CronJob", "nightly", "b", "batch"), { suffix = "k3x9" })
			assert(cj, "builds")
			expect(table.concat(cj.argv, " ")).toBe(
				"kubectl create job -n b nightly-manual-k3x9 --from=cronjob/nightly"
			)
			-- One-shot: the pane stays until Enter so the result is readable.
			expect(unquoteLine(cj.line)).toContain("read -r _")
		end)

		it("re-validates instead of trusting its caller", function()
			local l, err = Quick.command("shell", PINNED, ref("Pod", "p;reboot", "ns"), {})
			expect(l).toBeNil()
			expect(err).toContain("DNS-1123")
			expect((Quick.command("shell", PINNED, ref("Pod", "p", "ns"), { port = 80 }))).toBeNil()
		end)

		it("rebuilds the same line from a decoded link", function()
			local r = ref("Pod", "web-0", "apps")
			local url = Quick.encode("port-forward", PINNED, r, { port = 8080 }) :: string
			local req = Quick.decode(url)
			assert(req, "decodes")
			local direct = Quick.command("port-forward", PINNED, r, { port = 8080 })
			local rebuilt = Quick.command(req.action, req.target, req.ref, req.opts)
			assert(direct and rebuilt, "builds")
			expect(rebuilt.line).toBe(direct.line)
		end)
	end)

	-- Explore's selector-only logs route and the lens's `-l` commands have no
	-- object to name: the selector and namespace alone pick the pods.
	describe("selector-only follow", function()
		it("round-trips a link without kind or name", function()
			local url = Quick.encode("logs-follow", PINNED, nil, { selector = "app=web", namespace = "apps" }) :: string
			expect((string.find(url, "kind=", 1, true))).toBeNil()
			expect(url).toContain("namespace=apps")
			local req = Quick.decode(url) :: Quick.Request
			expect(req.ref).toBeNil()
			expect(req.opts.selector).toBe("app=web")
			expect(req.opts.namespace).toBe("apps")
		end)

		it("follows every pod of the selector across containers, or the chosen one", function()
			local all =
				Quick.command("logs-follow", UNPINNED, nil, { selector = "app=web", namespace = "apps" }) :: Quick.Launch
			expect(table.concat(all.argv, " ")).toBe(
				"kubectl logs -f --tail=200 -n apps -l app=web --prefix --max-log-requests=10 --all-containers"
			)
			expect(all.title).toBe("tern-kube logs -l app=web -n apps @ current context")
			local one = Quick.command(
				"logs-follow",
				PINNED,
				nil,
				{ selector = "app=web", namespace = "apps", container = "app" }
			) :: Quick.Launch
			expect(table.concat(one.argv, " ", 9)).toBe("-n apps -l app=web --prefix --max-log-requests=10 -c app")
		end)

		it("needs a selector when there is no object, and only logs go without one", function()
			local _, e = Quick.encode("logs-follow", PINNED, nil, { namespace = "apps" })
			expect(e).toBe("logs-follow needs kind and name, or a selector")
			expect((Quick.decode("tern-kube://act/logs-follow?namespace=apps"))).toBeNil()
			expect((Quick.decode("tern-kube://act/logs-follow?name=web&selector=app%3Dweb"))).toBeNil()
			expect((Quick.decode("tern-kube://act/shell?selector=app%3Dweb"))).toBeNil()
			expect((Quick.encode("port-forward", PINNED, nil, { selector = "app=web" }))).toBeNil()
		end)
	end)

	-- "Run in split": a one-shot logs variant typed into a new interactive
	-- split so the lens renders it (Tern only lenses commands typed at a
	-- prompt). The line passes through the user's interactive shell, which
	-- may be zsh, bash or fish: only words every one of them reads literally
	-- inside single quotes are typed; anything else is copied instead.
	describe("logs (typed split)", function()
		local POD = ref("Pod", "web-0", "apps")

		it("is the only typed action, never mutates and has no Explore key", function()
			expect(Quick.typed("logs")).toBe(true)
			expect(Quick.typed("logs-follow")).toBe(false)
			expect(Quick.typed("shell")).toBe(false)
			expect(Quick.gate("logs")).toBe("none")
			local spec = Quick.spec("logs") :: Quick.Action
			expect(spec.label).toBe("Run in split")
			expect(spec.key).toBeNil()
			expect(spec.mutates).toBe(false)
			-- Lens variants offer it; resource chips and Explore keys do not.
			expect(ids(Quick.available("Pod", POD, { allowMutations = true }))).toEqual({
				"shell",
				"logs-follow",
				"port-forward",
				"debug-pod",
				"edit",
			})
		end)

		it("round-trips every variant field, the lensed program included", function()
			local opts = {
				container = "side",
				previous = true,
				since = "1h30m",
				tail = "-1",
				timestamps = true,
				prefix = true,
				program = "kubecolor",
			}
			local url = Quick.encode("logs", PINNED, POD, opts) :: string
			expect(url).toContain("previous=1")
			expect(url).toContain("program=kubecolor")
			local req = Quick.decode(url) :: Quick.Request
			expect(req.action).toBe("logs")
			expect(req.target).toEqual(PINNED)
			expect(req.opts.container).toBe("side")
			expect(req.opts.previous).toBe(true)
			expect(req.opts.since).toBe("1h30m")
			expect(req.opts.tail).toBe("-1")
			expect(req.opts.timestamps).toBe(true)
			expect(req.opts.prefix).toBe(true)
			expect(req.opts.program).toBe("kubecolor")
			local all = Quick.decode(
				Quick.encode("logs", UNPINNED, nil, { selector = "app=web", namespace = "apps", allContainers = true }) :: string
			) :: Quick.Request
			expect(all.ref).toBeNil()
			expect(all.opts.allContainers).toBe(true)
		end)

		it("rejects values a typed line could misread", function()
			for _, bad in
				{
					"tern-kube://act/logs?kind=Pod&name=p&previous=yes",
					"tern-kube://act/logs?kind=Pod&name=p&since=5m%3Brm",
					"tern-kube://act/logs?kind=Pod&name=p&since=" .. string.rep("1", 17),
					"tern-kube://act/logs?kind=Pod&name=p&tail=ten",
					"tern-kube://act/logs?kind=Pod&name=p&tail=" .. string.rep("1", 11),
					"tern-kube://act/logs?kind=Pod&name=p&program=sh",
					"tern-kube://act/logs?kind=Pod&name=p&program=%2Fbin%2Fkubectl",
					"tern-kube://act/logs?kind=Pod&name=p&container=a&allcontainers=1",
					"tern-kube://act/logs?kind=Pod&name=p&selector=app%3Dx",
					"tern-kube://act/logs?kind=Service&name=s",
					"tern-kube://act/logs?kind=Pod&name=p&port=80",
					"tern-kube://act/logs?kind=Pod&name=p&confirm=abc",
					"tern-kube://act/logs?namespace=apps",
				}
			do
				expect((Quick.decode(bad))).toBeNil()
			end
			-- program is a logs field; other actions keep using the window's.
			expect((Quick.decode("tern-kube://act/logs-follow?kind=Pod&name=p&program=kubectl"))).toBeNil()
		end)

		it("types the verb first so the lens claims the line, flags after the source", function()
			local l = Quick.typedLine(PINNED, POD, {
				container = "side",
				previous = true,
				since = "5m",
				tail = "100",
				timestamps = true,
				prefix = true,
				program = "kubecolor",
			}) :: Quick.TypedLaunch
			expect(l.refusal).toBeNil()
			expect(l.argv).toEqual({
				"kubecolor",
				"logs",
				"--kubeconfig",
				"/tmp/kube config",
				"--context",
				"kind-tern-kube-dev",
				"-n",
				"apps",
				"web-0",
				"-c",
				"side",
				"--previous",
				"--since=5m",
				"--tail=100",
				"--timestamps",
				"--prefix",
			})
			expect(l.line).toBe(
				"kubecolor logs --kubeconfig '/tmp/kube config' --context kind-tern-kube-dev -n apps web-0 -c side"
					.. " --previous --since=5m --tail=100 --timestamps --prefix"
			)
			expect(l.title).toBe("tern-kube logs apps/web-0:side @ kind-tern-kube-dev")
		end)

		it("names workloads by type and selectors by -l, all containers on request", function()
			local d = Quick.typedLine(UNPINNED, ref("Deployment", "web", "apps", "apps"), {}) :: Quick.TypedLaunch
			expect(d.line).toBe("kubectl logs -n apps deployment/web")
			expect(d.title).toBe("tern-kube logs deployment apps/web @ current context")
			local s = Quick.typedLine(
				UNPINNED,
				nil,
				{ selector = "app=web,tier in (a, b),!canary", namespace = "apps", allContainers = true, prefix = true }
			) :: Quick.TypedLaunch
			expect(s.line).toBe("kubectl logs -n apps -l 'app=web,tier in (a, b),!canary' --all-containers --prefix")
		end)

		it("single-quotes words with shell syntax so no shell expands them", function()
			local l = Quick.typedLine({ context = "ctx $(id) `x`; y", kubeconfig = "=cfg" }, POD, {}) :: Quick.TypedLaunch
			expect(l.refusal).toBeNil()
			-- zsh expands a leading `=word` to a command path.
			expect(l.line).toBe("kubectl logs --kubeconfig '=cfg' --context 'ctx $(id) `x`; y' -n apps web-0")
		end)

		it("refuses to type a quote or backslash, offering a POSIX copy instead", function()
			-- fish reads \' and \\ as escapes even inside single quotes, so no
			-- quoting works in every shell: the line is copied, not typed.
			local targets: { Quick.Target } = {
				{ kubeconfig = "/tmp/it's/config" },
				{ context = "dom\\user" },
			}
			for _, target in targets do
				local l, e = Quick.typedLine(target, POD, {})
				assert(l, "builds a copyable line")
				expect(e).toBeNil()
				expect(l.refusal).toContain("cannot be typed")
				expect(l.line).toContain("kubectl logs")
			end
			local q = Quick.typedLine({ kubeconfig = "/tmp/it's/config" }, POD, {}) :: Quick.TypedLaunch
			expect(q.line).toBe("kubectl logs --kubeconfig '/tmp/it'\\''s/config' -n apps web-0")
		end)

		it("never builds a line from control characters or invalid fields", function()
			local targets: { Quick.Target } =
				{ { context = "a\nb" }, { context = "a\tb" }, { kubeconfig = "/k\27]0;x" } }
			for _, target in targets do
				expect((Quick.typedLine(target, POD, {}))).toBeNil()
			end
			expect((Quick.typedLine(UNPINNED, ref("Pod", "p;rm", "ns"), {}))).toBeNil()
			expect((Quick.typedLine(UNPINNED, POD, { since = "$(id)" }))).toBeNil()
			expect((Quick.typedLine(UNPINNED, POD, { program = "bash" }))).toBeNil()
			expect((Quick.typedLine(UNPINNED, nil, {}))).toBeNil()
		end)

		it("has no sh -c form: command() refuses and points to the typed launch", function()
			local l, e = Quick.command("logs", PINNED, POD, {})
			expect(l).toBeNil()
			expect(e).toBe("logs is typed into an interactive split")
		end)
	end)

	describe("placement", function()
		it("maps config values and defaults anything else to a right split", function()
			expect(Quick.placement("right")).toEqual({ how = "split", dir = "right" })
			expect(Quick.placement("down")).toEqual({ how = "split", dir = "down" })
			expect(Quick.placement("tab")).toEqual({ how = "tab" })
			expect(Quick.placement(nil)).toEqual({ how = "split", dir = "right" })
			expect(Quick.placement("left")).toEqual({ how = "split", dir = "right" })
		end)
	end)

	describe("chipsFor", function()
		it("gives lens pods three chips whose links decode", function()
			local chips = Quick.chipsFor("Pod", ref("Pod", "web-0", "apps"), { context = "kind-tern-kube-dev" })
			local labels: { string } = {}
			for i, c in chips do
				labels[i] = c.label
				expect(Quick.decode(c.url) ~= nil).toBe(true)
			end
			expect(labels).toEqual({ "Shell", "Logs", "Port-forward" })
			expect(chips[1].title).toContain("kubectl exec -it --context kind-tern-kube-dev -n apps web-0")
		end)

		it("forwards a service's first declared port", function()
			local chips = Quick.chipsFor("Service", ref("Service", "web", "apps"), {}, { ports = { 80, 443 } })
			expect(#chips).toBe(1)
			expect(chips[1].url).toContain("port=80")
		end)

		it("gives no chips when the target cannot be encoded", function()
			expect(#Quick.chipsFor("Pod", ref("Pod", "p", "ns"), { kubeconfig = "~/k" })).toBe(0)
		end)
	end)

	-- quick_actions config reaches command() as settings, never through a
	-- URL; config words are local input but still must not be re-parsed by
	-- the pane's shell.
	describe("settings", function()
		local POD = ref("Pod", "web-0", "apps")
		it("runs the configured shell command after --, each word quoted", function()
			local l = Quick.command("shell", PINNED, POD, {}, { shellCommand = { "bash", "-l" } }) :: Quick.Launch
			expect(l.argv[#l.argv - 2]).toBe("--")
			expect(l.argv[#l.argv - 1]).toBe("bash")
			expect(l.argv[#l.argv]).toBe("-l")
			expect(unquoteLine(l.line)).toContain(" -- bash -l")
		end)
		it("keeps hostile shell words inert inside the sh -c script", function()
			local words = { "sh", "-c", "echo 'a b' $(x)" }
			local l = Quick.command("shell", PINNED, POD, {}, { shellCommand = words }) :: Quick.Launch
			expect(unquoteLine(l.line)).toContain(" -- sh -c 'echo '\\''a b'\\'' $(x)'")
			expect(l.argv[#l.argv]).toBe("echo 'a b' $(x)")
		end)
		it("falls back to the default shell for an empty command list", function()
			local a = Quick.command("shell", PINNED, POD, {}, { shellCommand = {} }) :: Quick.Launch
			local b = Quick.command("shell", PINNED, POD, {}) :: Quick.Launch
			expect(a.line).toBe(b.line)
		end)
		it("tails the configured number of log lines, defaulting on invalid values", function()
			local l = Quick.command("logs-follow", PINNED, POD, {}, { logsTail = 50 }) :: Quick.Launch
			expect(l.argv).toContain("--tail=50")
			for _, bad in { 0, -3, 1.5 } do
				local d = Quick.command("logs-follow", PINNED, POD, {}, { logsTail = bad }) :: Quick.Launch
				expect(d.argv).toContain("--tail=" .. Quick.TAIL)
			end
		end)
		it("uses the configured debug image unless the link names a valid one", function()
			local s = { debugImage = "nicolaka/netshoot:v0.13" }
			local p = Quick.command("debug-pod", PINNED, POD, {}, s) :: Quick.Launch
			expect(p.argv).toContain("--image=nicolaka/netshoot:v0.13")
			local n = Quick.command("debug-node", PINNED, ref("Node", "n1"), {}, s) :: Quick.Launch
			expect(n.argv).toContain("--image=nicolaka/netshoot:v0.13")
			local o = Quick.command("debug-pod", PINNED, POD, { image = "alpine:3" }, s) :: Quick.Launch
			expect(o.argv).toContain("--image=alpine:3")
			local bad = Quick.command("debug-pod", PINNED, POD, {}, { debugImage = "$(x)" }) :: Quick.Launch
			expect(bad.argv).toContain("--image=" .. Quick.DEFAULT_IMAGE)
		end)
		it("keeps every default when settings are nil", function()
			local l = Quick.command("logs-follow", PINNED, POD, {}) :: Quick.Launch
			expect(l.argv).toContain("--tail=200")
			local d = Quick.command("debug-pod", PINNED, POD, {}) :: Quick.Launch
			expect(d.argv).toContain("--image=busybox:1.36")
			local s = Quick.command("shell", PINNED, POD, {}) :: Quick.Launch
			expect(s.argv[#s.argv]).toBe("command -v bash >/dev/null 2>&1 && exec bash || exec sh")
		end)
	end)

	-- On a remote host the split runs there, so the host's quick_actions
	-- config must govern it: the host half writes placement and the logs
	-- tail into the link (`place`, `tail`), validated like every field. The
	-- shell command stays window-scoped: a URL never supplies a command.
	describe("host settings in links", function()
		local POD = ref("Pod", "web-0", "apps")
		it("round-trips place on every action", function()
			for _, action in { "shell", "logs-follow", "edit" } do
				local url = Quick.encode(action, PINNED, POD, { place = "tab" }) :: string
				expect(url).toContain("place=tab")
				expect((Quick.decode(url) :: Quick.Request).opts.place).toBe("tab")
			end
		end)
		it("rejects a place outside right, down and tab", function()
			for _, bad in { "left", "tab%3Bid", "" } do
				expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&place=" .. bad))).toBeNil()
			end
		end)
		it("takes a logs-follow tail of 1 to 100000 lines and runs it over the window's", function()
			local url = Quick.encode("logs-follow", PINNED, POD, { tail = "500" }) :: string
			local req = Quick.decode(url) :: Quick.Request
			expect(req.opts.tail).toBe("500")
			local l = Quick.command("logs-follow", PINNED, POD, req.opts, { logsTail = 50 }) :: Quick.Launch
			expect(l.argv).toContain("--tail=500")
			for _, bad in { "0", "-1", "100001", "1e9", "5%3Bid" } do
				expect((Quick.decode("tern-kube://act/logs-follow?kind=Pod&name=p&tail=" .. bad))).toBeNil()
			end
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&tail=5"))).toBeNil()
		end)
		it("keeps the logs variant's own tail meaning (-1 = all)", function()
			expect(Quick.decode("tern-kube://act/logs?kind=Pod&name=p&tail=-1") ~= nil).toBe(true)
		end)
		it("quotes the line so fish reads it like sh: no backslash inside single quotes", function()
			local target = { context = "it's $(id) `x`; y", kubeconfig = "/tmp/a b/c'd\\e" }
			for _, action in { "shell", "logs-follow", "port-forward", "edit" } do
				local l = Quick.command(action, target, POD, {}, { guardCore = "/g/tern-kube-guard" }) :: Quick.Launch
				expect(backslashInQuotes(l.line)).toBe(false)
				expect(unquoteLine(l.line)).toContain("'it'\\''s $(id) `x`; y'")
			end
		end)
		it("never takes a shell command from a URL", function()
			expect((Quick.decode("tern-kube://act/shell?kind=Pod&name=p&command=bash"))).toBeNil()
		end)
		it("withHost writes place and, for logs-follow, tail from host settings", function()
			local s: Quick.Settings = { placement = "down", logsTail = 75 }
			expect(Quick.withHost("logs-follow", {}, s)).toEqual({ place = "down", tail = "75" })
			expect(Quick.withHost("shell", { container = "c" }, s)).toEqual({ container = "c", place = "down" })
			expect(Quick.withHost("logs-follow", { tail = "9" }, s).tail).toBe("9")
			expect(Quick.withHost("shell", {}, { placement = "left" :: any, logsTail = 0 })).toEqual({})
			expect(Quick.withHost("shell", {}, nil)).toEqual({})
		end)
		it("chipsFor carries the host settings in every link", function()
			local chips = Quick.chipsFor("Pod", POD, PINNED, nil, { placement = "tab", logsTail = 50 })
			expect(#chips).toBe(3)
			for _, c in chips do
				expect(c.url).toContain("place=tab")
			end
			expect(chips[2].url).toContain("tail=50")
			for _, c in Quick.chipsFor("Pod", POD, PINNED) do
				expect((string.find(c.url, "place=", 1, true))).toBeNil()
			end
		end)
	end)

	-- A remote pane's split runs in that host's login shell: its KUBECONFIG
	-- is not the one a local pane record would pin, and port-forward listens
	-- on the remote loopback. The split says so instead of implying local.
	describe("remote panes", function()
		local POD = ref("Pod", "web-0", "apps")
		local REMOTE: Quick.Settings = { remote = { name = "tk@localhost:2222", ssh = "-p 2222 tk@localhost" } }
		it("says the kubeconfig comes from the remote login environment when the link has none", function()
			local l = Quick.command("logs-follow", { context = "c" }, POD, {}, REMOTE) :: Quick.Launch
			expect(unquoteLine(l.line)).toContain(
				"printf 'tern-kube: %s: kubeconfig from the login environment\\n' tk@localhost:2222"
			)
			local p = Quick.command("logs-follow", PINNED, POD, {}, REMOTE) :: Quick.Launch
			expect((string.find(p.line, "login environment", 1, true))).toBeNil()
			local loc = Quick.command("logs-follow", { context = "c" }, POD, {}) :: Quick.Launch
			expect((string.find(loc.line, "login environment", 1, true))).toBeNil()
		end)
		it("keeps the program bare so the remote PATH resolves it", function()
			local l = Quick.command("shell", { context = "c", program = "kubectl" }, POD, {}, REMOTE) :: Quick.Launch
			expect(l.argv[1]).toBe("kubectl")
		end)
		it("prints where a known port-forward listens and the ssh tunnel to reach it", function()
			local l = Quick.command("port-forward", PINNED, POD, { port = 80 }, REMOTE) :: Quick.Launch
			local script = unquoteLine(l.line)
			expect(script).toContain("p=80; l=8080; ")
			expect(script).toContain(
				'printf \'tern-kube: forwarding localhost:%s -> %s on %s\\n\' "$l" "$p" tk@localhost:2222'
			)
			expect(script).toContain(
				"printf 'tern-kube: from this machine: ssh -N -L %s:localhost:%s %s\\n' \"$l\" \"$l\" '-p 2222 tk@localhost'"
			)
			expect(script).toContain("on %s; kubectl picks a free local port")
		end)
		it("prints the hint with the port resolved at run time", function()
			local l = Quick.command("port-forward", PINNED, POD, {}, REMOTE) :: Quick.Launch
			local script = unquoteLine(l.line)
			expect(script).toContain(
				'printf \'tern-kube: forwarding localhost:%s -> %s on %s\\n\' "$l" "$p" tk@localhost:2222'
			)
			expect(script).toContain('ssh -N -L %s:localhost:%s %s\\n\' "$l" "$l" \'-p 2222 tk@localhost\'')
			expect((string.find(script, "printf 'tern-kube: forwarding localhost:%s -> %s\\n'", 1, true))).toBeNil()
		end)
		it("omits the ssh line when the host name is not an ssh destination", function()
			local s: Quick.Settings = { remote = { name = "tk@9831a117" } }
			local l = Quick.command("port-forward", PINNED, POD, { port = 80 }, s) :: Quick.Launch
			expect(unquoteLine(l.line)).toContain('on %s\\n\' "$l" "$p" tk@9831a117')
			expect((string.find(l.line, "ssh -N", 1, true))).toBeNil()
		end)
		it("quotes a hostile host name", function()
			local s: Quick.Settings = { remote = { name = "x'; id" } }
			local l = Quick.command("logs-follow", { context = "c" }, POD, {}, s) :: Quick.Launch
			expect(unquoteLine(l.line)).toContain("environment\\n' 'x'\\''; id'")
		end)
		it("runs edit through the remote host's guard, not this machine's path", function()
			local s: Quick.Settings = { guardCore = "/Users/me/tern/plugins/tern-kube/shell/tern-kube-guard" }
			s.remote = REMOTE.remote
			local l = Quick.command("edit", PINNED, POD, {}, s) :: Quick.Launch
			local script = unquoteLine(l.line)
			expect((string.find(script, "/Users/me", 1, true))).toBeNil()
			expect(script).toContain('exec "$TKUBE_GUARD_CORE" kubectl edit')
			expect(script).toContain('[ -x "${TKUBE_GUARD_CORE:-}" ]')
		end)
	end)

	-- EXP-B4: `m` opened the manifest in an editor split that took the focus,
	-- so the next Explore keys edited the YAML. Explore asks the window to
	-- open the file without focus through a tern-kube://file link, which any
	-- program could also send: only manifest files, by absolute path.
	describe("file links", function()
		it("round-trips an absolute manifest path and line", function()
			local url = Quick.fileUrl("/repo/my apps/web.yaml", 12) :: string
			expect(string.sub(url, 1, #Quick.FILE_SCHEME)).toBe(Quick.FILE_SCHEME)
			local f = Quick.decodeFile(url)
			assert(f, "decodes")
			expect(f.path).toBe("/repo/my apps/web.yaml")
			expect(f.line).toBe(12)
			local noLine = Quick.decodeFile(Quick.fileUrl("/repo/kustomization.yml", nil) :: string)
			assert(noLine, "decodes")
			expect(noLine.line).toBeNil()
		end)

		it("refuses relative paths, other file types, control characters and bad lines", function()
			for _, path in { "repo/web.yaml", "/Applications/Evil.app", "/tmp/run.command", "/repo/web.yaml\n.sh" } do
				expect(Quick.fileUrl(path, 1)).toBeNil()
			end
			for _, url in
				{
					Quick.FILE_SCHEME .. "?path=%2Ftmp%2Fx.sh",
					Quick.FILE_SCHEME .. "?path=%2Frepo%2Fw.yaml&line=0",
					Quick.FILE_SCHEME .. "?path=%2Frepo%2Fw.yaml&line=1e3",
					Quick.FILE_SCHEME .. "?line=3",
					"tern-kube://explore?path=%2Frepo%2Fw.yaml",
				}
			do
				expect(Quick.decodeFile(url)).toBeNil()
			end
		end)
	end)
end)

return nil
