--!strict
-- Argo CD / Flux awareness. Explore labels objects with the controller that
-- applies them (and its sync/health) and, when the controller's repo is the
-- local checkout, diffs against local files instead of guessing. A wrong
-- attribution sends the user to the wrong source of truth, so attribution is
-- only claimed on evidence the controllers themselves use: Argo's tracking
-- annotation (verified against the object) or instance label of a known
-- Application, Flux's name/namespace labels. Fixtures are real objects from
-- the kind cluster (scripts/fixtures/capture-drift.sh), status emulated.
local Controllers = require("../../../plugin/lib/gitops/controllers")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function load(name: string): any
	return json.decode(fixtures.read("drift/controllers/" .. name .. ".json"))
end

local function world(): Controllers.Set
	return Controllers.parse({
		["applications.argoproj.io"] = load("applications"),
		["kustomizations.kustomize.toolkit.fluxcd.io"] = load("kustomizations"),
		["helmreleases.helm.toolkit.fluxcd.io"] = load("helmreleases"),
		["gitrepositories.source.toolkit.fluxcd.io"] = load("gitrepositories"),
	})
end

local function workload(name: string): any
	for _, item in load("workloads").items do
		if item.metadata.name == name then
			return item
		end
	end
	error("no workload " .. name)
end

local function find(set: Controllers.Set, controller: string, name: string): Controllers.Controller
	for _, c in set.controllers do
		if c.controller == controller and c.name == name then
			return c
		end
	end
	error("no controller " .. name)
end

describe("controllers.queries", function()
	it("lists only controller types the cluster serves", function()
		local names = fixtures.lines("drift/controllers/api-resources.list")
		expect(Controllers.queries(names)).toEqual({
			"applications.argoproj.io",
			"kustomizations.kustomize.toolkit.fluxcd.io",
			"helmreleases.helm.toolkit.fluxcd.io",
			"gitrepositories.source.toolkit.fluxcd.io",
		})
	end)

	it("asks for nothing on clusters without Argo CD or Flux (no loud errors)", function()
		expect(Controllers.queries({ "pods", "deployments.apps", "widgets.lens.example.com" })).toEqual({})
	end)

	it("accepts api-resources lines with surrounding whitespace", function()
		expect(Controllers.queries({ "  kustomizations.kustomize.toolkit.fluxcd.io  " })).toEqual({
			"kustomizations.kustomize.toolkit.fluxcd.io",
		})
	end)
end)

describe("controllers.parse", function()
	it("reads Argo CD applications with sync and health", function()
		local app = find(world(), "argocd", "guestbook")
		expect(app.namespace).toBe("tern-test-gitops")
		expect(app.repoURL).toBe("git@github.com:contrafy/tern-kube.git")
		expect(app.path).toBe("tests/integration/manifests/gitops/workloads")
		expect(app.revision).toBe("4f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39")
		expect(app.sync).toBe("Synced")
		expect(app.health).toBe("Healthy")
		expect(app.destinationNamespace).toBe("tern-test-gitops")
	end)

	it("picks the git directory source of a multi-source application", function()
		local app = find(world(), "argocd", "guestbook-drifted")
		expect(#app.sources).toBe(2)
		expect(app.sources[1].chart).toBe("guestbook")
		expect(app.repoURL).toBe("https://github.com/contrafy/tern-kube")
		expect(app.path).toBe("tests/integration/manifests/drift/baseline")
		expect(app.revision).toBe("4f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39")
		expect(app.sync).toBe("OutOfSync")
		expect(app.health).toBe("Degraded")
		expect(app.message).toBe("Deployment web has 0/1 ready replicas")
	end)

	it("has no local path for chart-only applications", function()
		local app = find(world(), "argocd", "charted")
		expect(app.path).toBeNil()
		expect(app.repoURL).toBe("https://charts.example.com")
		expect(app.sync).toBe("Unknown")
		expect(app.health).toBe("Missing")
	end)

	it("resolves Flux Kustomization sources through their GitRepository", function()
		local set = world()
		local apps = find(set, "flux-kustomize", "apps")
		expect(apps.repoURL).toBe("https://github.com/contrafy/tern-kube.git")
		expect(apps.path).toBe("./tests/integration/manifests/gitops/workloads")
		expect(apps.revision).toBe("master@sha1:4f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39")
		expect(apps.sync).toBe("Ready")
		expect(apps.health).toBe("Healthy")
		expect(apps.destinationNamespace).toBe("tern-test-gitops")
		local drift = find(set, "flux-kustomize", "drift")
		expect(drift.sync).toBe("NotReady")
		expect(drift.health).toBe("Unhealthy")
		expect(drift.message).toBe("timeout waiting for: [Deployment/tern-test-drift/web status: 'InProgress']")
		expect(drift.revision).toBe("master@sha1:0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c")
	end)

	it("resolves Flux HelmRelease charts stored in a GitRepository", function()
		local hr = find(world(), "flux-helm", "podinfo")
		expect(hr.repoURL).toBe("https://github.com/contrafy/tern-kube.git")
		expect(hr.path).toBe("./charts/podinfo")
		expect(hr.revision).toBe("6.7.0")
		expect(hr.sync).toBe("Unknown")
		expect(hr.health).toBeNil()
	end)

	it("notes Flux sources it cannot resolve instead of inventing a repo", function()
		local set = Controllers.parse({
			["kustomizations.kustomize.toolkit.fluxcd.io"] = {
				items = {
					{
						kind = "Kustomization",
						metadata = { name = "oci", namespace = "flux-system" },
						spec = { path = "./", sourceRef = { kind = "OCIRepository", name = "x" } },
					},
					{
						kind = "Kustomization",
						metadata = { name = "gone", namespace = "flux-system" },
						spec = { path = "./", sourceRef = { kind = "GitRepository", name = "missing" } },
					},
				},
			},
		})
		expect(find(set, "flux-kustomize", "oci").repoURL).toBeNil()
		expect(find(set, "flux-kustomize", "gone").repoURL).toBeNil()
		expect(set.notes).toEqual({
			"Kustomization flux-system/oci: source OCIRepository/x is not a git repository",
			"Kustomization flux-system/gone: GitRepository flux-system/missing not found",
		})
	end)

	it("tolerates missing lists and malformed items", function()
		local set = Controllers.parse({
			["applications.argoproj.io"] = { items = { 42 :: any, { metadata = {} }, { metadata = { name = "a" } } } },
		})
		expect(#set.controllers).toBe(1)
		expect(set.controllers[1].name).toBe("a")
		expect(set.controllers[1].sources).toEqual({})
		expect(set.controllers[1].repoURL).toBeNil()
		expect(#Controllers.parse({}).controllers).toBe(0)
	end)
end)

describe("controllers.owner", function()
	it("attributes Argo's instance label only to a known Application", function()
		local o = Controllers.owner(workload("argo-label"), world()) :: Controllers.Owner
		expect(o.controller).toBe("argocd")
		expect(o.name).toBe("guestbook")
		expect(o.sync).toBe("Synced")
		expect(o.provenance).toBe("label:app.kubernetes.io/instance")
		expect(o.resolved).toBe(true)
		-- The same label is Helm's standard instance label.
		expect(Controllers.owner(workload("helm-only"), world())).toBeNil()
	end)

	it("trusts Argo's tracking annotation when it names this very object", function()
		local o = Controllers.owner(workload("argo-annotated"), world()) :: Controllers.Owner
		expect(o.controller).toBe("argocd")
		expect(o.name).toBe("guestbook-drifted")
		expect(o.provenance).toBe("annotation:argocd.argoproj.io/tracking-id")
		expect(o.health).toBe("Degraded")
	end)

	it("ignores a tracking annotation copied from another object (Argo does too)", function()
		expect(Controllers.owner(workload("argo-copied"), world())).toBeNil()
	end)

	it("attributes Flux kustomize and helm labels, preferring them over the instance label", function()
		local k = Controllers.owner(workload("flux-kustomized"), world()) :: Controllers.Owner
		expect(k.controller).toBe("flux-kustomize")
		expect(k.name).toBe("apps")
		expect(k.namespace).toBe("tern-test-gitops")
		expect(k.provenance).toBe("label:kustomize.toolkit.fluxcd.io/name")
		local h = Controllers.owner(workload("podinfo"), world()) :: Controllers.Owner
		expect(h.controller).toBe("flux-helm")
		expect(h.name).toBe("podinfo")
		expect(h.path).toBe("./charts/podinfo")
	end)

	it("returns nothing for untracked objects", function()
		expect(Controllers.owner(workload("untracked"), world())).toBeNil()
		expect(Controllers.owner(workload("kube-root-ca.crt"), world())).toBeNil()
	end)

	it("still names the controller when its object is not visible (other namespace, no RBAC)", function()
		local obj = {
			apiVersion = "apps/v1",
			kind = "Deployment",
			metadata = {
				name = "web",
				namespace = "prod",
				labels = {
					["kustomize.toolkit.fluxcd.io/name"] = "infra",
					["kustomize.toolkit.fluxcd.io/namespace"] = "flux-system",
				},
			},
		}
		local o = Controllers.owner(obj, Controllers.parse({})) :: Controllers.Owner
		expect(o.controller).toBe("flux-kustomize")
		expect(o.name).toBe("infra")
		expect(o.namespace).toBe("flux-system")
		expect(o.resolved).toBe(false)
		expect(o.repoURL).toBeNil()
	end)

	it("reads namespaced Argo app names (<ns>_<name>) and cluster-scoped tracking ids", function()
		local set = world()
		local obj = {
			apiVersion = "rbac.authorization.k8s.io/v1",
			kind = "ClusterRole",
			metadata = {
				name = "reader",
				annotations = {
					["argocd.argoproj.io/tracking-id"] = "tern-test-gitops_guestbook:rbac.authorization.k8s.io/ClusterRole:/reader",
				},
			},
		}
		local o = Controllers.owner(obj, set) :: Controllers.Owner
		expect(o.name).toBe("guestbook")
		expect(o.namespace).toBe("tern-test-gitops")
		expect(o.resolved).toBe(true)
		local labelled = {
			kind = "ConfigMap",
			apiVersion = "v1",
			metadata = {
				name = "x",
				namespace = "y",
				labels = { ["app.kubernetes.io/instance"] = "tern-test-gitops_charted" },
			},
		}
		expect((Controllers.owner(labelled, set) :: Controllers.Owner).name).toBe("charted")
	end)
end)

describe("controllers.normalizeRemote", function()
	it("treats ssh, https and .git spellings of one repository as equal", function()
		local want = "github.com/o/r"
		for _, url in
			{
				"git@github.com:o/r.git",
				"git@github.com:o/r",
				"https://github.com/o/r",
				"https://github.com/o/r.git",
				"https://github.com/o/r/",
				"ssh://git@github.com/o/r.git",
				"ssh://git@github.com:22/o/r",
				"https://user:token@GitHub.com/o/r.git",
				"git://github.com/o/r",
				"  https://github.com/o/r.git\n",
			}
		do
			expect(Controllers.normalizeRemote(url)).toBe(want)
		end
	end)

	it("keeps distinct repositories distinct", function()
		expect(Controllers.normalizeRemote("https://gitlab.com/o/r")).toBe("gitlab.com/o/r")
		expect(Controllers.normalizeRemote("https://github.com/o/r2")).toBe("github.com/o/r2")
		expect(Controllers.normalizeRemote("https://github.com/group/sub/r.git")).toBe("github.com/group/sub/r")
	end)

	it("rejects non-git and local URLs", function()
		expect(Controllers.normalizeRemote("")).toBeNil()
		expect(Controllers.normalizeRemote("/srv/repo.git")).toBeNil()
		expect(Controllers.normalizeRemote("https://github.com")).toBeNil()
	end)
end)

describe("controllers.localPath", function()
	local repo = { root = "/home/u/tern-kube", remotes = { "https://github.com/contrafy/tern-kube.git" } }

	it("maps an Argo app on the same repo (ssh vs https) into the checkout", function()
		local app = find(world(), "argocd", "guestbook")
		expect(Controllers.localPath(app, repo)).toBe("/home/u/tern-kube/tests/integration/manifests/gitops/workloads")
	end)

	it("uses the matching git source of a multi-source app", function()
		local app = find(world(), "argocd", "guestbook-drifted")
		expect(Controllers.localPath(app, repo)).toBe("/home/u/tern-kube/tests/integration/manifests/drift/baseline")
	end)

	it("maps Flux paths (./ prefixed) and chart dirs", function()
		local set = world()
		expect(Controllers.localPath(find(set, "flux-kustomize", "apps"), repo)).toBe(
			"/home/u/tern-kube/tests/integration/manifests/gitops/workloads"
		)
		expect(Controllers.localPath(find(set, "flux-helm", "podinfo"), repo)).toBe("/home/u/tern-kube/charts/podinfo")
	end)

	it("works from an owner() result too", function()
		local o = Controllers.owner(workload("argo-label"), world()) :: Controllers.Owner
		expect(Controllers.localPath(o, { root = "/r/", remotes = { "git@github.com:contrafy/tern-kube" } })).toBe(
			"/r/tests/integration/manifests/gitops/workloads"
		)
	end)

	it("returns nil for other repos, chart-only apps and paths escaping the checkout", function()
		local set = world()
		local other = { root = "/r", remotes = { "git@github.com:someone/else.git" } }
		expect(Controllers.localPath(find(set, "argocd", "guestbook"), other)).toBeNil()
		expect(Controllers.localPath(find(set, "argocd", "charted"), repo)).toBeNil()
		local escaping: Controllers.Controller = {
			controller = "argocd",
			name = "x",
			sources = { { repoURL = "https://github.com/contrafy/tern-kube", path = "../../etc" } },
		}
		expect(Controllers.localPath(escaping, repo)).toBeNil()
	end)

	it("maps the repository root for '.' and './' paths", function()
		local root: Controllers.Controller = {
			controller = "flux-kustomize",
			name = "x",
			sources = { { repoURL = "https://github.com/contrafy/tern-kube", path = "./" } },
		}
		expect(Controllers.localPath(root, repo)).toBe("/home/u/tern-kube")
	end)
end)

return nil
