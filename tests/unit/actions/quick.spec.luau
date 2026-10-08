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

local PINNED = { context = "kind-kube-lens-dev", kubeconfig = "/tmp/kube config" }
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
	return (string.gsub(body, "'\\''", "'"))
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
			expect(ids(Quick.available("Node", ref("Node", "n1"), { allowMutations = true }))).toEqual({ "debug-node" })
			expect(ids(Quick.available("Pod", ref("Pod", "p", "ns"), { allowMutations = true }))).toEqual({
				"shell",
				"logs-follow",
				"port-forward",
				"debug-pod",
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
	end)

	describe("encode/decode", function()
		it("round-trips every field, including spaces and quotes in the context", function()
			local target = { context = "team's ctx @ eu/1", kubeconfig = "/Users/me/my kube/config" }
			local url = Quick.encode("shell", target, ref("Deployment", "web", "apps", "apps"), {
				pod = "web-5f6b8bff9b-djlsb",
				container = "app",
			})
			expect(type(url)).toBe("string")
			expect(string.sub(url :: string, 1, 22)).toBe("kube-lens://act/shell?")
			local req = Quick.decode(url :: string)
			assert(req, "decodes")
			expect(req.action).toBe("shell")
			expect(req.target).toEqual(target)
			expect(req.ref.kind).toBe("Deployment")
			expect(req.ref.group).toBe("apps")
			expect(req.ref.name).toBe("web")
			expect(req.ref.namespace).toBe("apps")
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
			local _, err = Quick.decode("kube-lens://act/rm?kind=Pod&name=p")
			expect(err).toContain("unknown action")
			expect((Quick.decode("kube-lens://explore?kind=Pod&name=p"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell/x?kind=Pod&name=p"))).toBeNil()
			expect((Quick.encode("rm", PINNED, ref("Pod", "p", "ns"), {}))).toBeNil()
		end)

		it("rejects parameters the action does not take", function()
			local _, err = Quick.decode("kube-lens://act/shell?kind=Pod&name=p&cmd=rm")
			expect(err).toContain("does not take cmd")
			_, err = Quick.decode("kube-lens://act/shell?kind=Pod&name=p&line=ls")
			expect(err).toContain("does not take line")
			_, err = Quick.decode("kube-lens://act/logs-follow?kind=Pod&name=p&port=80")
			expect(err).toContain("does not take port")
			_, err = Quick.decode("kube-lens://act/shell?kind=Pod&name=p&image=busybox")
			expect(err).toContain("does not take image")
		end)

		it("rejects duplicates, empty values, fragments and raw characters", function()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&name=q"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name="))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p#x"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p q"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p%2"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&x"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p+q"))).toBeNil()
		end)

		it("rejects shell metacharacters in names, namespaces, containers and pods", function()
			for _, bad in { "p;rm", "p$(id)", "p`id`", "p'q", "p q", "P", "-p", "p-", "a..b", "p\n", "p|x", "p&x" } do
				local enc = string.gsub(bad, "[^%w]", function(c: string): string
					return string.format("%%%02X", string.byte(c))
				end)
				expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=" .. enc))).toBeNil()
				expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&namespace=" .. enc))).toBeNil()
				expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&container=" .. enc))).toBeNil()
				expect((Quick.decode("kube-lens://act/shell?kind=Deployment&name=d&pod=" .. enc))).toBeNil()
				expect((Quick.encode("shell", PINNED, ref("Pod", bad, "ns"), {}))).toBeNil()
			end
		end)

		it("rejects control characters and flag-like values in context and kubeconfig", function()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&context=a%0Ab"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&context=-x"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&kubeconfig=--exec"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&kubeconfig=~%2Fkube"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&context=%1B%5D0%3Bx"))).toBeNil()
		end)

		it("enforces per-action kinds and required fields", function()
			expect((Quick.decode("kube-lens://act/shell?kind=Service&name=web"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Deployment&name=web"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=Pod&name=p&pod=q"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?name=p"))).toBeNil()
			expect((Quick.decode("kube-lens://act/shell?kind=pod&name=p"))).toBeNil()
			expect((Quick.decode("kube-lens://act/logs-follow?kind=Pod&name=p&selector=app%3Dx"))).toBeNil()
			expect((Quick.decode("kube-lens://act/port-forward?kind=Job&name=j&port=80"))).toBeNil()
			expect((Quick.decode("kube-lens://act/port-forward?kind=Pod&name=p&local=80"))).toBeNil()
			expect((Quick.decode("kube-lens://act/debug-node?kind=Node&name=n&namespace=x"))).toBeNil()
			expect((Quick.decode("kube-lens://act/cronjob-run?kind=CronJob&name=c&namespace=b"))).toBeNil()
			expect(Quick.decode("kube-lens://act/cronjob-run?kind=CronJob&name=c&namespace=b&suffix=x1") ~= nil).toBe(
				true
			)
			local long = string.rep("a", 50)
			expect((Quick.decode("kube-lens://act/cronjob-run?kind=CronJob&name=" .. long .. "&suffix=abcdef"))).toBeNil()
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
				"kind-kube-lens-dev",
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
			expect(l.title).toBe("kube-lens shell apps/web-0:app @ kind-kube-lens-dev")
			expect(unquoteLine(l.line)).toBe(
				"printf '\\033]0;%s\\007' 'kube-lens shell apps/web-0:app @ kind-kube-lens-dev'; "
					.. "exec kubectl exec -it --kubeconfig '/tmp/kube config' --context kind-kube-lens-dev -n apps web-0 -c app"
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
				"; printf 'kube-lens: context %s\\n' \"$(kubectl --kubeconfig /k/c config current-context)\"; exec kubectl"
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
			expect(script).toContain("'kube-lens shell ns/p @ it'\\''s $(id) `x`; y'")
			-- The whole script is one single-quoted word: every quote inside is an
			-- escaped `'\''`, so nothing expands in the user's login shell.
			local body = string.match(l.line, "^sh %-c '(.*)'$")
			assert(body, "sh -c line")
			expect((string.find((string.gsub(body, "'\\''", "")), "'", 1, true))).toBeNil()
		end)

		it("follows pod logs across containers unless one is chosen", function()
			local all = Quick.command("logs-follow", PINNED, ref("Pod", "p", "ns"), {})
			assert(all, "builds")
			expect(table.concat(all.argv, " ")).toBe(
				"kubectl logs -f --tail=200 --kubeconfig /tmp/kube config --context kind-kube-lens-dev -n ns p --all-containers --prefix"
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

		it("resolves the first declared port at run time when none is known", function()
			local l = Quick.command("port-forward", PINNED, ref("Deployment", "web", "apps", "apps"), {})
			assert(l, "builds")
			local script = unquoteLine(l.line)
			expect(script).toContain(
				"set -- $(kubectl get --kubeconfig '/tmp/kube config' --context kind-kube-lens-dev -n apps deployment/web -o "
					.. "'jsonpath={.spec.template.spec.containers[*].ports[*].containerPort}')"
			)
			expect(script).toContain(
				"p=${1:-}; case $p in ''|*[!0-9]*) printf 'kube-lens: %s declares no port\\n' deployment/web >&2; exit 1;; esac"
			)
			expect(script).toContain('if [ "$p" -gt 1024 ]; then l=$p; else l=$((8000 + p)); fi')
			expect(script).toContain('deployment/web "$l:$p"')
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
				"debug -it --kubeconfig /tmp/kube config --context kind-kube-lens-dev node/kind-control-plane --image=alpine:3.20"
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
			local chips = Quick.chipsFor("Pod", ref("Pod", "web-0", "apps"), { context = "kind-kube-lens-dev" })
			local labels: { string } = {}
			for i, c in chips do
				labels[i] = c.label
				expect(Quick.decode(c.url) ~= nil).toBe(true)
			end
			expect(labels).toEqual({ "Shell", "Logs", "Port-forward" })
			expect(chips[1].title).toContain("kubectl exec -it --context kind-kube-lens-dev -n apps web-0")
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
end)

return nil
