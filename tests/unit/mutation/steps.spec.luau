--!strict
-- Preview steps per family. Every step pins --context (and --kubeconfig) so a
-- `kubectl config use-context` elsewhere cannot point the preview at another
-- cluster than the one that will be mutated, and replaces any printer or
-- dry-run flag so the output stays kubectl's readable default.
local Plan = require("../../../plugin/lib/mutation/plan")
local Steps = require("../../../plugin/lib/mutation/steps")
local T = require("../../../plugin/lib/mutation/types")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect
local Fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")

local ENV: T.Env = {
	context = "kind-dev",
	contextSource = "chosen",
	kubeconfig = "/k/config",
	namespace = "team",
	cwd = "/work",
	timeoutMs = 15000,
}

local PIN = { "kubectl", "--kubeconfig", "/k/config", "--context", "kind-dev" }

local function plan(line: string): T.Plan
	local p, diags = Plan.fromArgv(string.split(line, " "), ENV)
	expect(diags).toEqual({})
	return p :: T.Plan
end

local function pinned(...: string): { string }
	local out = table.clone(PIN)
	for _, a in { ... } do
		table.insert(out, a)
	end
	return out
end

local function summary(p: T.Plan): { string }
	local out = {}
	for _, s in p.steps do
		table.insert(out, s.id .. ":" .. s.kind)
	end
	return out
end

describe("mutation preview steps: apply", function()
	it("runs a server-side dry run then kubectl diff, both pinned", function()
		local p = plan("kubectl apply -f app.yaml")
		expect(summary(p)).toEqual({ "dry-run:dry-run", "diff:diff" })
		expect(p.steps[1].argv).toEqual(pinned("apply", "--filename=app.yaml", "--dry-run=server"))
		expect(p.steps[2].argv).toEqual(pinned("diff", "--filename=app.yaml"))
	end)

	it("forces kubectl's built-in diff -u -N, the only format diffseg reads", function()
		local p = plan("kubectl apply -f app.yaml")
		expect(p.steps[2].env).toEqual({ KUBECTL_EXTERNAL_DIFF = "" })
		expect(p.steps[1].env).toEqual({})
	end)

	it("carries server-side, field manager, -R and -n; drops the user's printer", function()
		local p = plan("kubectl apply -n apps -f dir -R --server-side --field-manager=me -o yaml")
		expect(p.steps[1].argv).toEqual(
			pinned(
				"--namespace",
				"apps",
				"apply",
				"--field-manager=me",
				"--filename=dir",
				"--recursive=true",
				"--server-side=true",
				"--dry-run=server"
			)
		)
		expect(p.steps[2].argv).toEqual(
			pinned(
				"--namespace",
				"apps",
				"diff",
				"--field-manager=me",
				"--filename=dir",
				"--recursive=true",
				"--server-side=true"
			)
		)
	end)

	it("shows prune deletions in the diff, but only passes flags kubectl diff accepts", function()
		local p = plan("kubectl apply -f dir --prune -l app=web --wait --force")
		expect(p.steps[1].argv).toEqual(
			pinned(
				"apply",
				"--filename=dir",
				"--force=true",
				"--prune=true",
				"--selector=app=web",
				"--wait=true",
				"--dry-run=server"
			)
		)
		expect(p.steps[2].argv).toEqual(pinned("diff", "--filename=dir", "--prune=true", "--selector=app=web"))
	end)

	it("keeps values that start with a dash bound to their flag", function()
		local p = plan("kubectl apply -f -weird.yaml")
		expect(p.steps[1].argv).toEqual(pinned("apply", "--filename=-weird.yaml", "--dry-run=server"))
	end)

	it("pins the kustomize dir the same way", function()
		expect(plan("kubectl apply -k overlay").steps[2].argv).toEqual(pinned("diff", "--kustomize=overlay"))
	end)

	it("uses the configured timeout", function()
		local p = plan("kubectl apply -f app.yaml")
		expect(p.steps[1].timeoutMs).toBe(15000)
		expect(p.steps[2].timeoutMs).toBe(15000)
	end)
end)

describe("mutation preview steps: delete", function()
	it("resolves targets with get -o json, then a server dry run", function()
		local p = plan("kubectl delete pod web -n apps")
		expect(summary(p)).toEqual({ "targets:targets", "dry-run:dry-run" })
		expect(p.steps[1].argv).toEqual(pinned("--namespace", "apps", "get", "pod", "web", "-o", "json"))
		expect(p.steps[2].argv).toEqual(pinned("--namespace", "apps", "delete", "pod", "web", "--dry-run=server"))
	end)

	it("pins the context's default namespace so the preview and the delete agree", function()
		local p = plan("kubectl delete pods -l app=web")
		expect(p.steps[1].argv).toEqual(
			pinned("--namespace", "team", "get", "pods", "--selector=app=web", "-o", "json")
		)
	end)

	it("resolves --all by listing the type (get has no --all) and keeps -A", function()
		local p = plan("kubectl delete pods --all -A --grace-period=0 --force")
		expect(p.steps[1].argv).toEqual(pinned("get", "pods", "--all-namespaces=true", "-o", "json"))
		expect(p.steps[2].argv).toEqual(
			pinned(
				"delete",
				"pods",
				"--all=true",
				"--all-namespaces=true",
				"--force=true",
				"--grace-period=0",
				"--dry-run=server"
			)
		)
	end)

	it("resolves -f targets from the same files", function()
		local p = plan("kubectl delete -f app.yaml --ignore-not-found")
		expect(p.steps[1].argv).toEqual(pinned("get", "--filename=app.yaml", "--ignore-not-found=true", "-o", "json"))
	end)
end)

describe("mutation preview steps: scale, restart, quick actions", function()
	it("scale reads current replicas then dry-runs, keeping --current-replicas", function()
		local p = plan("kubectl scale deploy/web --replicas=3 --current-replicas=2 -n apps")
		expect(p.steps[1].argv).toEqual(pinned("--namespace", "apps", "get", "deploy/web", "-o", "json"))
		expect(p.steps[2].argv).toEqual(
			pinned(
				"--namespace",
				"apps",
				"scale",
				"deploy/web",
				"--current-replicas=2",
				"--replicas=3",
				"--dry-run=server"
			)
		)
	end)

	it("rollout restart only resolves targets: kubectl v1.34 has no restart --dry-run", function()
		local p = plan("kubectl rollout restart deployment web -n apps")
		expect(summary(p)).toEqual({ "targets:targets" })
		expect(p.steps[1].argv).toEqual(pinned("--namespace", "apps", "get", "deployment", "web", "-o", "json"))
	end)

	it("debug node reads the node without a namespace", function()
		local p = plan("kubectl debug node/worker -it --image=busybox:1.36")
		expect(p.steps[1].argv).toEqual(pinned("get", "node", "worker", "-o", "json"))
	end)

	it("debug pod reads the pod in its namespace", function()
		local p = plan("kubectl debug -it -n apps web --image=busybox:1.36 --target=web")
		expect(p.steps[1].argv).toEqual(pinned("--namespace", "apps", "get", "pod", "web", "-o", "json"))
	end)

	it("cronjob run reads the CronJob and dry-runs the job creation", function()
		local p = plan("kubectl create job nightly-manual-1 --from=cronjob/nightly -n batch")
		expect(p.steps[1].argv).toEqual(pinned("--namespace", "batch", "get", "cronjob", "nightly", "-o", "json"))
		expect(p.steps[2].argv).toEqual(
			pinned(
				"--namespace",
				"batch",
				"create",
				"job",
				"nightly-manual-1",
				"--from=cronjob/nightly",
				"--dry-run=server"
			)
		)
	end)

	it("pins the context in every step of every family", function()
		for _, line in
			{
				"kubectl apply -f a.yaml",
				"kubectl delete pod web",
				"kubectl scale deploy/web --replicas=1",
				"kubectl rollout restart deploy/web",
				"kubectl debug node/n1 --image=busybox",
				"kubectl debug web --image=busybox",
				"kubectl create job j --from=cronjob/c",
			}
		do
			for _, s in plan(line).steps do
				expect(s.argv[4]).toBe("--context")
				expect(s.argv[5]).toBe("kind-dev")
			end
		end
	end)
end)

describe("mutation step outcomes", function()
	local function step(kind: T.StepKind): T.Step
		return { id = kind, kind = kind, label = "Step", argv = {}, env = {}, timeoutMs = 1000 }
	end

	it("reads kubectl diff exit codes: 0 no diff, 1 diff, >1 error", function()
		expect(Steps.outcome(step("diff"), { code = 0 }).status).toBe("no-changes")
		expect(Steps.outcome(step("diff"), { code = 1 }).status).toBe("changes")
		expect(Steps.outcome(step("diff"), { code = 1 }).ok).toBe(true)
		local bad = Steps.outcome(step("diff"), { code = 2, stderr = "\nerror: x is invalid\n" })
		expect(bad.ok).toBe(false)
		expect(bad.text).toBe("Step failed (exit 2): error: x is invalid")
	end)

	it("treats any non-zero dry run or targets exit as a failed preview", function()
		expect(Steps.outcome(step("dry-run"), { code = 0 }).ok).toBe(true)
		expect(Steps.outcome(step("dry-run"), { code = 1 }).ok).toBe(false)
		expect(Steps.outcome(step("targets"), { code = 1 }).status).toBe("failed")
	end)

	it("treats timeouts and missing exit codes as failures", function()
		expect(Steps.outcome(step("diff"), { code = nil, timedOut = true }).status).toBe("timeout")
		expect(Steps.outcome(step("diff"), { code = nil }).ok).toBe(false)
	end)
end)

describe("mutation targets from get -o json", function()
	it("reads lists and single objects", function()
		local list = {
			kind = "List",
			items = {
				{ apiVersion = "v1", kind = "Pod", metadata = { name = "a", namespace = "x" } },
				{ apiVersion = "apps/v1", kind = "Deployment", metadata = { name = "b", namespace = "y" } },
				{ kind = "Broken" } :: any,
			},
		}
		local refs = Steps.targets(list)
		expect(#refs).toBe(2)
		expect(refs[2].group).toBe("apps")
		expect(#Steps.targets({ apiVersion = "v1", kind = "Node", metadata = { name = "n1" } })).toBe(1)
		expect(Steps.targets("nope")).toEqual({})
	end)
end)

local NS = { "--namespace", "team" }

local function withNs(...: string): { string }
	local out = pinned(table.unpack(NS))
	for _, a in { ... } do
		table.insert(out, a)
	end
	return out
end

local function results(map: { [string]: string }): { [string]: Steps.StepResult }
	local out: { [string]: Steps.StepResult } = {}
	for id, text in map do
		out[id] = { ok = true, code = 0, stdout = text, stderr = "" }
	end
	return out
end

describe("mutation preview steps: track 1 verbs", function()
	it("label reads the objects without the edit tokens, then dry-runs the label with -o json", function()
		local p = plan("kubectl label configmap cm a=b old- --overwrite")
		expect(summary(p)).toEqual({ "targets:targets", "after:after" })
		expect(p.steps[1].argv).toEqual(withNs("get", "configmap", "cm", "-o", "json"))
		expect(p.steps[2].argv).toEqual(
			withNs("label", "configmap", "cm", "a=b", "old-", "--overwrite=true", "--dry-run=server", "-o", "json")
		)
	end)

	it("label with a selector keeps -l and -A for the read", function()
		local p = plan("kubectl annotate pods -l app=web -A note=x")
		expect(p.steps[1].argv).toEqual(
			pinned("get", "pods", "--all-namespaces=true", "--selector=app=web", "-o", "json")
		)
	end)

	it("patch dry-runs the exact patch and keeps its type and file", function()
		local p = plan('kubectl patch widget/w1 --type=merge -p {"spec":{"size":4}}')
		expect(summary(p)).toEqual({ "targets:targets", "after:after" })
		expect(p.steps[2].argv).toEqual(
			withNs(
				"patch",
				"widget/w1",
				'--patch={"spec":{"size":4}}',
				"--type=merge",
				"--dry-run=server",
				"-o",
				"json"
			)
		)
	end)

	it("rollout undo reads the workloads, their history and dry-runs the undo", function()
		local p = plan("kubectl rollout undo deployment/web --to-revision=1")
		expect(summary(p)).toEqual({ "targets:targets", "history:history", "dry-run:dry-run" })
		expect(p.steps[1].argv).toEqual(withNs("get", "deployment/web", "-o", "json"))
		expect(p.steps[2].argv).toEqual(withNs("rollout", "history", "deployment/web"))
		expect(p.steps[3].argv).toEqual(
			withNs("rollout", "undo", "deployment/web", "--to-revision=1", "--dry-run=server")
		)
	end)

	it("pause and resume only read the deployments: kubectl has no dry run for them", function()
		expect(summary(plan("kubectl rollout pause deployment/web"))).toEqual({ "targets:targets" })
		expect(summary(plan("kubectl rollout resume deployment/web"))).toEqual({ "targets:targets" })
	end)

	it("cordon reads the nodes and dry-runs without a namespace pin", function()
		local p = plan("kubectl cordon node/n1")
		expect(p.steps[1].argv).toEqual(pinned("get", "nodes", "n1", "-o", "json"))
		expect(p.steps[2].argv).toEqual(pinned("cordon", "node/n1", "--dry-run=server"))
		expect(plan("kubectl uncordon -l pool=a").steps[1].argv).toEqual(
			pinned("get", "nodes", "--selector=pool=a", "-o", "json")
		)
	end)

	it("drain runs a client dry run and a bounded server probe instead of the user's timeout", function()
		local p = plan("kubectl drain n1 --ignore-daemonsets --timeout=2m")
		expect(summary(p)).toEqual({ "targets:targets", "dry-run:dry-run", "evict:evict" })
		expect(p.steps[2].argv).toEqual(pinned("drain", "n1", "--ignore-daemonsets=true", "--dry-run=client"))
		-- ENV preview budget 15 s: 10 s probe, 5 s left for kubectl itself.
		expect(p.steps[3].argv).toEqual(
			pinned("drain", "n1", "--ignore-daemonsets=true", "--dry-run=server", "--timeout=10s")
		)
		expect(p.steps[3].timeoutMs).toBe(15000)
	end)

	it("drain --disable-eviction has no eviction probe: it would wait for deletions until timeout", function()
		expect(summary(plan("kubectl drain n1 --disable-eviction"))).toEqual({ "targets:targets", "dry-run:dry-run" })
	end)

	it("edit converts both files offline and reads the live objects", function()
		local env = table.clone(ENV)
		env.edit = { file = "/t/kubectl-edit-1.yaml", original = "/t/d/original.yaml" }
		local p = Plan.fromArgv({ "kubectl", "edit", "widget/w1" }, env) :: T.Plan
		expect(summary(p)).toEqual({ "convert-original:convert", "convert-edited:convert", "targets:targets" })
		expect(p.steps[1].argv).toEqual({
			"kubectl",
			"patch",
			"--local",
			"--type=merge",
			"-p",
			"{}",
			"-f",
			"/t/d/original.yaml",
			"-o",
			"json",
		})
		expect(p.steps[1].env).toEqual({})
		expect(p.steps[2].soft).toBe(true)
		expect(p.steps[3].argv).toEqual(pinned("get", "-f", "/t/d/original.yaml", "-o", "json"))
	end)
end)

describe("mutation preview stage 2", function()
	local LIVE = Fixtures.read("kubectl/track1/get-deploy-web-json.txt")
	local HISTORY = Fixtures.read("kubectl/track1/rollout-history-deploy.txt")

	it("undo reads the previous revision of each workload by its full type", function()
		local p = plan("kubectl rollout undo deployment/web")
		local more, err = Steps.followUp(p, results({ targets = LIVE, history = HISTORY }), 15000, json.decode)
		expect(err).toBeNil()
		local steps = more :: { T.Step }
		expect(#steps).toBe(1)
		expect(steps[1].id).toBe("revision:apps.v1.Deployment.tern-test-t1.web")
		expect(steps[1].object).toBe("apps.v1.Deployment.tern-test-t1.web")
		expect(steps[1].argv).toEqual(
			pinned(
				"rollout",
				"history",
				"Deployment.v1.apps/web",
				"--namespace",
				"tern-test-t1",
				"--revision=1",
				"-o",
				"json"
			)
		)
	end)

	it("undo honours --to-revision and fails on a revision the history lacks", function()
		local p = plan("kubectl rollout undo deployment/web --to-revision=2")
		local more = Steps.followUp(p, results({ targets = LIVE, history = HISTORY }), 15000, json.decode)
		expect(((more :: { T.Step })[1].argv)[11]).toBe("--revision=2")
		local _, err = Steps.followUp(
			plan("kubectl rollout undo deployment/web --to-revision=9"),
			results({ targets = LIVE, history = HISTORY }),
			15000,
			json.decode
		)
		expect(err).toContain("revision 9 is not in the rollout history")
	end)

	it("caps stage 2 at 20 objects", function()
		local items: { string } = {}
		for i = 1, 21 do
			table.insert(
				items,
				string.format(
					'{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"d%d","namespace":"a"}}',
					i
				)
			)
		end
		local list = '{"kind":"List","items":[' .. table.concat(items, ",") .. "]}"
		local _, err = Steps.followUp(
			plan("kubectl rollout undo deployment -l app=x"),
			results({ targets = list, history = HISTORY }),
			15000,
			json.decode
		)
		expect(err).toBe("preview covers at most 20 objects; narrow the command")
	end)

	it("edit dry-runs one merge patch per changed object, soft so a rejection stays approvable", function()
		local env = table.clone(ENV)
		env.edit = { file = "/t/e.yaml", original = "/t/o.yaml" }
		local p = Plan.fromArgv({ "kubectl", "edit", "widget/w1", "--field-manager=me" }, env) :: T.Plan
		local more, err = Steps.followUp(
			p,
			results({
				["convert-original"] = Fixtures.read("kubectl/track1/convert-original.txt"),
				["convert-edited"] = Fixtures.read("kubectl/track1/convert-edited.txt"),
			}),
			15000,
			json.decode
		)
		expect(err).toBeNil()
		local s = (more :: { T.Step })[1]
		expect(s.id).toBe("after:lens.example.com.v1alpha1.Widget.tern-test-t1.w1")
		expect(s.soft).toBe(true)
		expect(s.argv[6]).toBe("patch")
		expect(s.argv[7]).toBe("Widget.v1alpha1.lens.example.com/w1")
		expect(table.find(s.argv, "--type=merge") ~= nil).toBe(true)
		expect(table.find(s.argv, "--field-manager=me") ~= nil).toBe(true)
		expect(s.argv[table.find(s.argv, "-p") :: number + 1]).toContain('"size":4')
	end)

	it("edit has no stage 2 when kubectl could not read the edited file", function()
		local env = table.clone(ENV)
		env.edit = { file = "/t/e.yaml", original = "/t/o.yaml" }
		local p = Plan.fromArgv({ "kubectl", "edit", "widget/w1" }, env) :: T.Plan
		local r = results({ ["convert-original"] = Fixtures.read("kubectl/track1/convert-original.txt") })
		r["convert-edited"] = { ok = false, code = 1, stdout = "", stderr = "error: bad" }
		local more, err = Steps.followUp(p, r, 15000, json.decode)
		expect(more).toBeNil()
		expect(err).toBeNil()
	end)

	it("other families have no stage 2; only undo re-reads at confirm", function()
		expect((Steps.followUp(plan("kubectl label configmap/cm a=b"), {}, 15000, json.decode))).toBeNil()
		expect(#Steps.verifySteps(plan("kubectl label configmap/cm a=b"))).toBe(0)
		local again = Steps.verifySteps(plan("kubectl rollout undo deployment/web"))
		expect(again[1].id).toBe("history")
	end)

	it("reads a drain probe that ends on a disruption budget as a finding", function()
		local evict: T.Step = { id = "evict", kind = "evict", label = "Probe", argv = {}, env = {}, timeoutMs = 1000 }
		local blocked = Steps.outcome(evict, {
			code = 1,
			stdout = Fixtures.read("kubectl/track1/drain-server-pdb-timeout.txt"),
			stderr = Fixtures.read("kubectl/track1/drain-server-pdb-timeout.stderr"),
		})
		expect(blocked.ok).toBe(true)
		local broken = Steps.outcome(evict, { code = 1, stderr = 'error: nodes "x" not found' })
		expect(broken.ok).toBe(false)
	end)
end)

return nil
