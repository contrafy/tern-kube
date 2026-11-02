--!strict
-- MutationPlan: family detection, the target a command will hit, and the
-- fail-closed rejections. A command the preview cannot model faithfully must
-- never reach an approval prompt, because approving it would be approving blind.
local Plan = require("../../../plugin/lib/mutation/plan")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV: T.Env = {
	context = "kind-dev",
	contextSource = "chosen",
	kubeconfig = "/k/config",
	namespace = "team",
	cwd = "/work",
}

local function words(line: string): { string }
	return string.split(line, " ")
end

local function plan(line: string, env: T.Env?): T.Plan
	local p, diags = Plan.fromArgv(words(line), env or ENV)
	expect(diags).toEqual({})
	return p :: T.Plan
end

local function rejected(line: string, env: T.Env?): { string }
	local p, diags = Plan.fromArgv(words(line), env or ENV)
	expect(p).toBeNil()
	local codes = {}
	for _, d in diags do
		table.insert(codes, d.severity .. ":" .. d.code)
	end
	return codes
end

local function textOf(line: string): string
	local _, diags = Plan.fromArgv(words(line), ENV)
	return diags[1].text
end

describe("mutation plan families", function()
	it("recognises the four guarded families and the quick-action mutations", function()
		expect(plan("kubectl apply -f app.yaml").family).toBe("apply")
		expect(plan("kubectl delete pod web").family).toBe("delete")
		expect(plan("kubectl rollout restart deployment/web").family).toBe("restart")
		expect(plan("kubectl scale deploy web --replicas=2").family).toBe("scale")
		expect(plan("kubectl debug -it web --image=busybox:1.36").family).toBe("debug-pod")
		expect(plan("kubectl debug node/worker -it --image=busybox:1.36").family).toBe("debug-node")
		expect(plan("kubectl create job nightly-manual-1 --from=cronjob/nightly").family).toBe("cronjob-run")
	end)

	it("lets reads and unguarded verbs pass without approval", function()
		expect(rejected("kubectl get pods")).toEqual({ "info:not-mutation" })
		expect(rejected("kubectl rollout status deployment/web")).toEqual({ "info:not-mutation" })
		expect(rejected("kubectl apply view-last-applied deployment/web")).toEqual({ "info:not-mutation" })
		expect(rejected("kubectl create job x --image=busybox")).toEqual({ "info:not-mutation" })
		expect(rejected("kubectl delete --help")).toEqual({ "info:not-mutation" })
	end)

	it("keeps the exact typed argv and records operation names for the UI", function()
		local p = plan("kubectl rollout restart deployment/web")
		expect(p.argv).toEqual({ "kubectl", "rollout", "restart", "deployment/web" })
		expect(p.operation).toBe("rollout restart")
		expect(p.program).toBe("kubectl")
	end)
end)

describe("mutation plan rejections", function()
	it("rejects stdin manifests with an actionable message (they cannot be replayed)", function()
		expect(rejected("kubectl apply -f -")).toEqual({ "error:stdin" })
		expect(rejected("kubectl apply --filename=-")).toEqual({ "error:stdin" })
		expect(rejected("kubectl delete -f -")).toEqual({ "error:stdin" })
		expect(textOf("kubectl apply -f -")).toContain("kubectl apply -f <file>")
	end)

	it("rejects remote inputs: they are fetched again at execution", function()
		expect(rejected("kubectl apply -f https://example.com/app.yaml")).toEqual({ "error:remote-input" })
		expect(rejected("kubectl apply -k https://github.com/org/repo//base")).toEqual({ "error:remote-input" })
	end)

	it("fails closed on unknown flags and on flag/value ambiguity", function()
		expect(rejected("kubectl apply -f app.yaml --bogus")).toEqual({ "error:unknown-flag" })
		local codes = rejected("kubectl apply --bogus value -f app.yaml")
		expect(codes).toContain("error:unknown-flag")
		expect(codes).toContain("error:ambiguous")
		expect(rejected("kubectl scale deploy/web --replicas")).toContain("error:ambiguous")
	end)

	it("rejects --raw and interactive deletes", function()
		expect(rejected("kubectl delete --raw /api/v1/namespaces/x")).toContain("error:raw")
		expect(rejected("kubectl delete -i pod web")).toEqual({ "error:interactive" })
	end)

	it("lets dry runs through untouched: they change nothing", function()
		expect(rejected("kubectl apply --dry-run=server -f app.yaml")).toEqual({ "info:dry-run" })
		expect(rejected("kubectl delete pod web --dry-run=client")).toEqual({ "info:dry-run" })
		expect(rejected("kubectl apply --dry-run -f app.yaml")).toEqual({ "info:dry-run" })
		expect(plan("kubectl apply --dry-run=none -f app.yaml").family).toBe("apply")
		expect(rejected("kubectl apply --dry-run=maybe -f app.yaml")).toEqual({ "error:invalid" })
	end)

	it("never waves a dry run through when it also carries an unknown flag", function()
		expect(rejected("kubectl apply --dry-run=server -f app.yaml --bogus")).toEqual({ "error:unknown-flag" })
	end)

	it("rejects commands without a target instead of previewing kubectl's usage error", function()
		expect(rejected("kubectl apply")).toEqual({ "error:missing-target" })
		expect(rejected("kubectl delete pods")).toEqual({ "error:missing-target" })
		expect(rejected("kubectl delete")).toEqual({ "error:missing-target" })
		expect(rejected("kubectl apply -f a.yaml -k dir")).toEqual({ "error:invalid" })
		expect(rejected("kubectl scale deploy/web")).toEqual({ "error:invalid" })
		expect(rejected("kubectl scale deploy/web --replicas=two")).toEqual({ "error:invalid" })
		expect(rejected("kubectl apply set-last-applied -f a.yaml")).toEqual({ "error:unsupported" })
	end)

	it("refuses to plan without a resolved context", function()
		local env = table.clone(ENV)
		env.context = nil
		expect(rejected("kubectl delete pod web", env)).toEqual({ "error:no-context" })
	end)

	it("preserves prune and force for a typed confirmation instead of rejecting them", function()
		expect(plan("kubectl apply -f dir --prune --all").family).toBe("apply")
		expect(plan("kubectl delete pod web --force --grace-period=0").family).toBe("delete")
	end)
end)

describe("mutation plan target", function()
	it("takes the context from --context with flag provenance", function()
		local p = plan("kubectl --context prod delete pod web")
		expect(p.targetContext).toBe("prod")
		expect(p.contextSource).toBe("flag")
	end)

	it("keeps the host's provenance, defaulting to inferred", function()
		expect(plan("kubectl delete pod web").contextSource).toBe("chosen")
		local env = table.clone(ENV)
		env.contextSource = nil
		expect(plan("kubectl delete pod web", env).contextSource).toBe("inferred")
	end)

	it("resolves namespace: -n, else the context default, none with -A", function()
		local p = plan("kubectl delete pod web -n apps")
		expect(p.targetNamespace).toBe("apps")
		expect(p.explicitNamespace).toBe("apps")
		local q = plan("kubectl delete pod web")
		expect(q.targetNamespace).toBe("team")
		expect(q.explicitNamespace).toBeNil()
		expect(plan("kubectl delete pods -l app=web -A").targetNamespace).toBeNil()
		local env = table.clone(ENV)
		env.namespace = nil
		expect(plan("kubectl delete pod web", env).targetNamespace).toBe("default")
	end)

	it("lists named resources with cluster-scoped kinds outside any namespace", function()
		local p = plan("kubectl delete pod/web namespace/old -n apps")
		expect(p.resources).toEqual({
			{
				clusterContext = "kind-dev",
				namespace = "apps",
				kind = "Pod",
				name = "web",
				source = "live",
			},
			{
				clusterContext = "kind-dev",
				kind = "Namespace",
				name = "old",
				source = "live",
			} :: any,
		})
		expect(p.kinds).toEqual({ { kind = "Pod", namespaced = true }, { kind = "Namespace", namespaced = false } })
	end)

	it("records selectors, --all, replicas and file inputs", function()
		local p = plan("kubectl scale deploy --all --replicas=0 -n apps")
		expect(p.all).toBe(true)
		expect(p.replicas).toBe(0)
		local q = plan("kubectl apply -f a.yaml -f dir -R")
		expect(q.filenames).toEqual({ "a.yaml", "dir" })
		expect(q.recursive).toBe(true)
		expect(plan("kubectl apply -k overlay").kustomize).toBe("overlay")
		expect(plan("kubectl delete pods -l app=web").selector).toBe("app=web")
	end)

	it("names the debug and cronjob targets", function()
		expect(plan("kubectl debug node/worker -it --image=busybox").resources[1].name).toBe("worker")
		expect(plan("kubectl debug node/worker -it --image=busybox").resources[1].kind).toBe("Node")
		expect(plan("kubectl debug -it -n apps web --image=busybox").resources[1].namespace).toBe("apps")
		local job = plan("kubectl create job nightly-manual-1 --from=cronjob/nightly").resources[1]
		expect(job.kind).toBe("Job")
		expect(job.name).toBe("nightly-manual-1")
	end)
end)

describe("mutation plan execution argv", function()
	it("pins kubeconfig, context and the resolved namespace before the typed args", function()
		expect(plan("kubectl delete pod web").execArgv).toEqual({
			"kubectl",
			"--kubeconfig",
			"/k/config",
			"--context",
			"kind-dev",
			"--namespace",
			"team",
			"delete",
			"pod",
			"web",
		})
	end)

	it("does not duplicate pins the command already carries", function()
		expect(plan("kubectl --kubeconfig /x --context prod -n apps delete pod web").execArgv).toEqual({
			"kubectl",
			"--kubeconfig",
			"/x",
			"--context",
			"prod",
			"-n",
			"apps",
			"delete",
			"pod",
			"web",
		})
	end)

	it("never pins a namespace over manifests that declare their own", function()
		expect(plan("kubectl apply -f app.yaml").execArgv).toEqual({
			"kubectl",
			"--kubeconfig",
			"/k/config",
			"--context",
			"kind-dev",
			"apply",
			"-f",
			"app.yaml",
		})
	end)

	it("passes a KUBECONFIG path list through the environment (--kubeconfig takes one file)", function()
		local env = table.clone(ENV)
		env.kubeconfig = "/a:/b"
		local p = plan("kubectl delete pod web", env)
		expect(p.execArgv).toEqual({ "kubectl", "--context", "kind-dev", "--namespace", "team", "delete", "pod", "web" })
		expect(Plan.execEnv(p)).toEqual({ KUBECONFIG = "/a:/b" })
		expect(p.steps[1].env).toEqual({ KUBECONFIG = "/a:/b" })
	end)

	it("keeps kubecolor flags in the executed command (kubecolor needs them)", function()
		local p = plan("kubecolor --force-colors delete pod web")
		expect(p.family).toBe("delete")
		expect(p.execArgv[#p.execArgv - 3]).toBe("--force-colors")
	end)

	it("runs steps with the guard's resolved program but fingerprints argv as typed", function()
		local env = table.clone(ENV)
		env.program = "/opt/bin/kubectl"
		local p = plan("kubectl delete pod web", env)
		expect(p.argv[1]).toBe("kubectl")
		expect(p.execArgv[1]).toBe("/opt/bin/kubectl")
		for _, s in p.steps do
			expect(s.argv[1]).toBe("/opt/bin/kubectl")
		end
	end)

	it("pins kubectl's default kubeconfig without fingerprinting it", function()
		-- With KUBECONFIG unset in the user's shell, kubectl reads
		-- $HOME/.kube/config; previews must not inherit the daemon's KUBECONFIG.
		local env = table.clone(ENV)
		env.kubeconfig = nil
		env.defaultKubeconfig = "/home/me/.kube/config"
		local p = plan("kubectl delete pod web", env)
		expect(p.kubeconfig).toBe("/home/me/.kube/config")
		expect(p.envKubeconfig).toBeNil()
		expect(p.steps[1].argv[2]).toBe("--kubeconfig")
		expect(p.steps[1].argv[3]).toBe("/home/me/.kube/config")
	end)
end)

describe("mutation plan: track 1 guarded verbs", function()
	it("detects every new family and its operation", function()
		local cases = {
			{ "kubectl rollout undo deployment/web", "undo", "rollout undo" },
			{ "kubectl rollout pause deployment/web", "pause", "rollout pause" },
			{ "kubectl rollout resume deployment/web", "resume", "rollout resume" },
			{ "kubectl patch configmap/cm -p {}", "patch", "patch" },
			{ "kubectl label configmap/cm a=b", "label", "label" },
			{ "kubectl annotate configmap/cm a=b", "annotate", "annotate" },
			{ "kubectl cordon n1", "cordon", "cordon" },
			{ "kubectl uncordon n1", "uncordon", "uncordon" },
			{ "kubectl drain n1 --ignore-daemonsets", "drain", "drain" },
		}
		for _, c in cases do
			local p = plan(c[1])
			expect(p.family).toBe(c[2])
			expect(p.operation).toBe(c[3])
		end
	end)

	it("records label edits, --overwrite and drops the edits from the targets", function()
		local p = plan("kubectl label configmap cm a=b old- --overwrite")
		expect(p.edits[1]).toEqual({ key = "a", value = "b", remove = false })
		expect(p.edits[2].key).toBe("old")
		expect(p.edits[2].value).toBeNil()
		expect(p.edits[2].remove).toBe(true)
		expect(#p.edits).toBe(2)
		expect(p.overwrite).toBe(true)
		expect(#p.resources).toBe(1)
		expect(p.resources[1].name).toBe("cm")
	end)

	it("records patch files, the patch type and the undo revision", function()
		local p = plan("kubectl patch widget/w1 --type=merge --patch-file=fix.yaml")
		expect(p.patchFiles).toEqual({ "fix.yaml" })
		expect(p.patchType).toBe("merge")
		expect(plan("kubectl rollout undo deployment/web --to-revision=3").toRevision).toBe(3)
	end)

	it("reads drain options and never pins a namespace for node verbs", function()
		local p = plan("kubectl drain node/n1 --ignore-daemonsets --grace-period=0 --timeout=2m --pod-selector=app=x")
		local d = p.drain :: T.DrainOpts
		expect(d.ignoreDaemonsets).toBe(true)
		expect(d.deleteEmptyDir).toBe(false)
		expect(d.gracePeriod).toBe(0)
		expect(d.timeout).toBe("2m")
		expect(d.podSelector).toBe("app=x")
		expect(p.targetNamespace).toBeNil()
		expect(p.resources[1].kind).toBe("Node")
		expect(p.resources[1].name).toBe("n1")
	end)

	it("lets --local and --list through: they never contact the cluster or change nothing", function()
		expect(rejected("kubectl patch -f cm.yaml -p {} --local")).toEqual({ "info:not-mutation" })
		expect(rejected("kubectl label -f cm.yaml a=b --local")).toEqual({ "info:not-mutation" })
		expect(rejected("kubectl annotate configmap/cm --list")).toEqual({ "info:not-mutation" })
	end)

	it("lets dry runs through for verbs that have one", function()
		expect(rejected("kubectl label configmap/cm a=b --dry-run=server")).toEqual({ "info:dry-run" })
		expect(rejected("kubectl drain n1 --dry-run=client")).toEqual({ "info:dry-run" })
	end)

	it("fails closed on --dry-run for pause, which kubectl does not know", function()
		expect(rejected("kubectl rollout pause deployment/web --dry-run=server")).toEqual({ "error:unknown-flag" })
	end)

	it("needs a patch and a target for patch, and an edit for label", function()
		expect(textOf("kubectl patch configmap/cm")).toContain("-p PATCH or --patch-file")
		expect(rejected("kubectl patch configmap -p {}")).toEqual({ "error:missing-target" })
		expect(textOf("kubectl label configmap/cm")).toContain("KEY=VALUE or KEY-")
		expect(rejected("kubectl label configmap a=b")).toEqual({ "error:missing-target" })
	end)

	it("refuses patch input it cannot fingerprint", function()
		expect(rejected("kubectl patch configmap/cm --patch-file=-")).toEqual({ "error:stdin" })
	end)

	it("limits undo and pause/resume to the kinds kubectl supports", function()
		expect(textOf("kubectl rollout undo configmap/cm")).toContain("deployments, daemonsets and statefulsets")
		expect(textOf("kubectl rollout pause daemonset/ds")).toContain("deployments only")
		expect(rejected("kubectl rollout undo deployment")).toEqual({ "error:missing-target" })
		expect(plan("kubectl rollout undo deployment -l app=web").selector).toBe("app=web")
	end)

	it("takes node names only for cordon, uncordon and drain", function()
		expect(rejected("kubectl cordon")).toEqual({ "error:missing-target" })
		expect(rejected("kubectl cordon pod/x")).toEqual({ "error:invalid" })
		expect(plan("kubectl cordon -l pool=a").selector).toBe("pool=a")
	end)

	it("plans kubectl edit only with an edit request; a plain edit can never be approved", function()
		expect(textOf("kubectl edit configmap/cm")).toContain("approved after you save")
		local env = table.clone(ENV)
		env.edit = { file = "/tmp/kubectl-edit-1.yaml", original = "/tmp/tkube-edit.x/original.yaml" }
		local p = plan("kubectl edit configmap/cm", env)
		expect(p.family).toBe("edit")
		expect(p.edit).toEqual(env.edit)
	end)
end)

return nil
