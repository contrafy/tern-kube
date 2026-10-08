--!strict
-- The export planner decides what lands in the user's git repo. Paths must
-- be deterministic (re-export of the same cluster yields the same tree),
-- nothing existing may be replaced without a "modified" status and a diff,
-- unrelated documents/comments in touched files must survive, and Secret
-- values must never be written (nor real Secret manifests replaced by
-- placeholders).
local Clean = require("../../../plugin/lib/gitops/clean")
local Export = require("../../../plugin/lib/gitops/export")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ROOT = "/repo/deploy"

local function obj(apiVersion: string, kind: string, name: string, namespace: string?, extra: { [string]: any }?): any
	local o: { [string]: any } =
		{ apiVersion = apiVersion, kind = kind, metadata = { name = name, namespace = namespace } }
	for k, v in extra or ({} :: { [string]: any }) do
		o[k] = v
	end
	return o
end

local function paths(changes: { Export.FileChange }): { string }
	local out = {}
	for _, c in changes do
		table.insert(out, c.path .. " " .. c.status)
	end
	return out
end

local function byPath(changes: { Export.FileChange }, path: string): Export.FileChange
	for _, c in changes do
		if c.path == path then
			return c
		end
	end
	error("no change for " .. path)
end

local function codes(plan: Export.Plan): { string }
	local out = {}
	for _, n in plan.notes do
		table.insert(out, n.code)
	end
	return out
end

local function layout(style: Export.Style, naming: string?, extra: { [string]: any }?): Export.Layout
	local l: { [string]: any } = { style = style, naming = naming or "<name>", ext = ".yaml", kustomization = false }
	for k, v in extra or ({} :: { [string]: any }) do
		l[k] = v
	end
	return l :: any
end

local web = obj("apps/v1", "Deployment", "web", "apps", { spec = { replicas = 2 }, status = { ready = 2 } })
local svc = obj("v1", "Service", "web", "apps", { spec = { clusterIP = "10.0.0.1", ports = { { port = 80 } } } })
local ns = obj("v1", "Namespace", "apps")
local crb = obj("rbac.authorization.k8s.io/v1", "ClusterRoleBinding", "system:viewer")

describe("gitops.export paths", function()
	it("defaults to <ns>/<kind>/<name>.yaml with a kustomization per directory", function()
		local plan = Export.plan({ web, svc, ns, crb }, { dir = ROOT }, {})
		expect(paths(plan.files)).toEqual({
			ROOT .. "/_cluster/clusterrolebinding/system-viewer.yaml new",
			ROOT .. "/apps/deployment/web.yaml new",
			ROOT .. "/apps/namespace/apps.yaml new",
			ROOT .. "/apps/service/web.yaml new",
		})
		-- Sorted by directory: parents before children.
		expect(paths(plan.kustomizationEdits)).toEqual({
			ROOT .. "/kustomization.yaml new",
			ROOT .. "/_cluster/kustomization.yaml new",
			ROOT .. "/_cluster/clusterrolebinding/kustomization.yaml new",
			ROOT .. "/apps/kustomization.yaml new",
			ROOT .. "/apps/deployment/kustomization.yaml new",
			ROOT .. "/apps/namespace/kustomization.yaml new",
			ROOT .. "/apps/service/kustomization.yaml new",
		})
		expect(byPath(plan.kustomizationEdits, ROOT .. "/apps/kustomization.yaml").text).toBe(table.concat({
			"apiVersion: kustomize.config.k8s.io/v1beta1",
			"kind: Kustomization",
			"resources:",
			"  - deployment",
			"  - namespace",
			"  - service",
			"",
		}, "\n"))
	end)

	it("treats an unknown layout as the default but keeps its extension", function()
		local plan = Export.plan({ web }, { dir = ROOT, layout = layout("unknown", nil, { ext = ".yml" }) }, {})
		expect(paths(plan.files)).toEqual({ ROOT .. "/apps/deployment/web.yml new" })
	end)

	it("follows per-kind-dirs with plural directory names and naming tokens", function()
		local l = layout("per-kind-dirs", "<namespace>-<name>", { kindDir = "<plural>" })
		local plan = Export.plan({ web, svc, crb }, { dir = ROOT, layout = l }, {})
		expect(paths(plan.files)).toEqual({
			ROOT .. "/clusterrolebindings/_cluster-system-viewer.yaml new",
			ROOT .. "/deployments/apps-web.yaml new",
			ROOT .. "/services/apps-web.yaml new",
		})
		expect(#plan.kustomizationEdits).toBe(0)
	end)

	it("follows file-per-resource with kind naming", function()
		local plan = Export.plan(
			{ web, svc },
			{ dir = ROOT, layout = layout("file-per-resource", "<kind>-<name>") },
			{}
		)
		expect(paths(plan.files)).toEqual({ ROOT .. "/deployment-web.yaml new", ROOT .. "/service-web.yaml new" })
	end)

	it("puts multi-doc exports in one file in apply order", function()
		local cm = obj("v1", "ConfigMap", "cfg", "apps", { data = { a = "1" } })
		local crd = obj("apiextensions.k8s.io/v1", "CustomResourceDefinition", "widgets.example.com")
		local sa = obj("v1", "ServiceAccount", "runner", "apps")
		local role = obj("rbac.authorization.k8s.io/v1", "Role", "r", "apps")
		local widget = obj("example.com/v1", "Widget", "w", "apps")
		local plan = Export.plan(
			{ widget, web, svc, cm, role, sa, crd, ns },
			{ dir = ROOT, layout = layout("multi-doc", nil, { kustomization = true }) },
			{}
		)
		expect(paths(plan.files)).toEqual({ ROOT .. "/resources.yaml new" })
		local kinds = {}
		for kind in string.gmatch(plan.files[1].text, "\nkind: (%w+)") do
			table.insert(kinds, kind)
		end
		expect(kinds).toEqual({
			"Namespace",
			"CustomResourceDefinition",
			"ServiceAccount",
			"Role",
			"ConfigMap",
			"Service",
			"Deployment",
			"Widget",
		})
		expect(plan.files[1].text).toContain("---\napiVersion")
		expect(paths(plan.kustomizationEdits)).toEqual({ ROOT .. "/kustomization.yaml new" })
	end)

	it("resolves name collisions deterministically with notes", function()
		local a = obj("v1", "ConfigMap", "web", "apps")
		local plan = Export.plan({ svc, a, web }, { dir = ROOT, layout = layout("file-per-resource") }, {})
		expect(paths(plan.files)).toEqual({
			ROOT .. "/web-deployment.yaml new",
			ROOT .. "/web-service.yaml new",
			ROOT .. "/web.yaml new",
		})
		expect(codes(plan)).toContain("collision")
		local again = Export.plan({ web, a, svc }, { dir = ROOT, layout = layout("file-per-resource") }, {})
		expect(paths(again.files)).toEqual(paths(plan.files))
	end)

	it("never takes over an existing file that holds another object", function()
		local existing =
			{ [ROOT .. "/apps/deployment/web.yaml"] = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: other\n" }
		local plan = Export.plan({ web }, { dir = ROOT }, existing)
		expect(paths(plan.files)).toEqual({ ROOT .. "/apps/deployment/web-deployment.yaml new" })
	end)
end)

describe("gitops.export content", function()
	it("emits cleaned objects", function()
		local plan = Export.plan({ web, svc }, { dir = ROOT }, {})
		local text = byPath(plan.files, ROOT .. "/apps/service/web.yaml").text
		expect((string.find(text, "clusterIP", 1, true))).toBeNil()
		expect((string.find(byPath(plan.files, ROOT .. "/apps/deployment/web.yaml").text, "status", 1, true))).toBeNil()
	end)

	it("redacts Secrets with a warning comment and note", function()
		local secret = obj("v1", "Secret", "creds", "apps", { type = "Opaque", data = { password = "aHVudGVyMg==" } })
		local plan = Export.plan({ secret }, { dir = ROOT }, {})
		local text = plan.files[1].text
		expect(string.sub(text, 1, #("# " .. Clean.SECRET_COMMENT) + 1)).toBe("# " .. Clean.SECRET_COMMENT .. "\n")
		expect(text).toContain("password: REPLACE_ME")
		expect((string.find(text, "aHVudGVyMg", 1, true))).toBeNil()
		expect(codes(plan)).toContain("secret-redacted")
	end)

	it("uses the injected list predicate for empty arrays", function()
		local empty = {}
		local o = obj("v1", "ConfigMap", "c", "apps", { list = empty, map = {} })
		local plan = Export.plan({ o }, { dir = ROOT }, {}, {
			isList = function(tbl)
				return tbl == empty
			end,
		})
		expect(plan.files[1].text).toContain("list: []\nmap: {}\n")
	end)

	it("skips server-created objects with a note", function()
		local plan = Export.plan({ obj("v1", "ConfigMap", "kube-root-ca.crt", "apps") }, { dir = ROOT }, {})
		expect(#plan.files).toBe(0)
		expect(#plan.kustomizationEdits).toBe(0)
		expect(codes(plan)).toEqual({ "skipped" })
	end)

	it("exports every real fixture object without error and keys every note", function()
		local objects = {}
		for _, path in fixtures.list("real/json-world/") do
			if string.find(path, "%-o_json%.txt$") then
				for _, item in json.decode(fixtures.read(path)).items do
					table.insert(objects, item)
				end
			end
		end
		local plan = Export.plan(objects, { dir = ROOT }, {})
		expect(#plan.files > 20).toBe(true)
		for _, n in plan.notes do
			expect(n.key ~= nil).toBe(true)
		end
		expect(plan.files[1].diff ~= nil).toBe(true)
	end)
end)

describe("gitops.export existing files", function()
	local path = ROOT .. "/apps.yaml"
	local existingText = table.concat({
		"# hand-written header",
		"apiVersion: v1",
		"kind: ConfigMap",
		"metadata:",
		"  name: keep",
		"  namespace: apps",
		"---",
		"apiVersion: apps/v1",
		"kind: Deployment",
		"metadata:",
		"  name: web",
		"spec:",
		"  replicas: 1",
		"",
	}, "\n")

	it("updates an object in place where the repo already has it, keeping other documents", function()
		local plan = Export.plan({ web }, { dir = ROOT }, { [path] = existingText })
		expect(paths(plan.files)).toEqual({ path .. " modified" })
		local text = plan.files[1].text
		expect(string.sub(text, 1, 22)).toBe("# hand-written header\n")
		expect(text).toContain("  name: keep\n")
		expect(text).toContain("replicas: 2")
		expect((string.find(text, "replicas: 1", 1, true))).toBeNil()
		expect(plan.files[1].diff).toContain("-  replicas: 1\n+  replicas: 2\n")
		expect(#plan.kustomizationEdits).toBe(0)
		expect(codes(plan)).toContain("existing")
	end)

	it("reports unchanged files without a diff", function()
		local first = Export.plan({ web }, { dir = ROOT }, {})
		local p = first.files[1].path
		local again = Export.plan({ web }, { dir = ROOT }, { [p] = first.files[1].text })
		expect(paths(again.files)).toEqual({ p .. " unchanged" })
		expect(again.files[1].diff).toBeNil()
	end)

	it("re-exporting an unchanged object in place leaves the file unchanged", function()
		local cm = obj("v1", "ConfigMap", "keep", "apps", { data = { x = "y" } })
		local first = Export.plan({ cm }, { dir = ROOT }, {})
		local p = first.files[1].path
		local again = Export.plan({ cm }, { dir = ROOT }, { [p] = first.files[1].text })
		expect(again.files[1].status).toBe("unchanged")
	end)

	it("never replaces an existing Secret manifest with placeholders", function()
		local sealed =
			"apiVersion: v1\nkind: Secret\nmetadata:\n  name: creds\n  namespace: apps\nstringData:\n  password: ENC[AES256]\n"
		local secret = obj("v1", "Secret", "creds", "apps", { data = { password = "eA==" } })
		local plan = Export.plan({ secret }, { dir = ROOT }, { [ROOT .. "/s.yaml"] = sealed })
		expect(#plan.files).toBe(0)
		expect(codes(plan)).toContain("secret-kept")
	end)

	it("appends to an existing multi-doc file", function()
		local plan = Export.plan(
			{ svc },
			{ dir = ROOT, layout = layout("multi-doc"), file = "apps.yaml" },
			{ [path] = existingText }
		)
		local text = plan.files[1].text
		expect(string.sub(text, 1, #existingText)).toBe(existingText)
		expect(string.sub(text, #existingText + 1, #existingText + 20)).toBe("---\napiVersion: v1\nk")
	end)
end)

describe("gitops.export kustomization edits", function()
	it("inserts missing entries after the existing list, preserving content and style", function()
		local text = table.concat({
			"apiVersion: kustomize.config.k8s.io/v1beta1",
			"kind: Kustomization",
			"# managed by hand",
			"resources:",
			"- ./deployment",
			"  # comment inside",
			"- 'service'",
			"images:",
			"  - name: nginx",
			"",
		}, "\n")
		expect(Export.addResources(text, { "configmap", "deployment", "service" })).toBe(table.concat({
			"apiVersion: kustomize.config.k8s.io/v1beta1",
			"kind: Kustomization",
			"# managed by hand",
			"resources:",
			"- ./deployment",
			"  # comment inside",
			"- 'service'",
			"- configmap",
			"images:",
			"  - name: nginx",
			"",
		}, "\n"))
	end)

	it("returns the text unchanged when everything is listed", function()
		local text = "resources:\n  - a.yaml # x\n"
		expect(Export.addResources(text, { "a.yaml" })).toBe(text)
	end)

	it("adds a resources list when absent and expands flow lists", function()
		expect(Export.addResources("namespace: x\n", { "a.yaml" })).toBe("namespace: x\nresources:\n  - a.yaml\n")
		expect(Export.addResources("resources: []\nnamespace: x\n", { "a.yaml" })).toBe(
			"resources:\n  - a.yaml\nnamespace: x\n"
		)
		expect(Export.addResources("resources: [b.yaml]\n", { "a.yaml" })).toBe("resources:\n  - b.yaml\n  - a.yaml\n")
	end)

	it("edits an existing kustomization in a dir instead of creating a second one", function()
		local existing = { [ROOT .. "/apps/deployment/Kustomization"] = "resources:\n  - old.yaml\n" }
		local plan = Export.plan({ web }, { dir = ROOT }, existing)
		local edit = byPath(plan.kustomizationEdits, ROOT .. "/apps/deployment/Kustomization")
		expect(edit.status).toBe("modified")
		expect(edit.text).toBe("resources:\n  - old.yaml\n  - web.yaml\n")
		expect(edit.diff).toContain("+  - web.yaml\n")
	end)
end)

describe("gitops.export unified diff", function()
	it("emits hunks with context and correct ranges", function()
		local old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
		local new = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\nk\n"
		expect(Export.unified(old, new, "/p")).toBe(table.concat({
			"--- /p",
			"+++ /p",
			"@@ -2,9 +2,10 @@",
			" b",
			" c",
			" d",
			"-e",
			"+E",
			" f",
			" g",
			" h",
			" i",
			" j",
			"+k",
			"",
		}, "\n"))
	end)

	it("splits distant changes into separate hunks", function()
		local a, b = {}, {}
		for i = 1, 30 do
			table.insert(a, tostring(i))
			table.insert(b, if i == 2 or i == 28 then "x" else tostring(i))
		end
		local d = Export.unified(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", "/p") :: string
		local hunks = {}
		for h in string.gmatch(d, "@@ [^@]+ @@") do
			table.insert(hunks, h)
		end
		expect(hunks).toEqual({ "@@ -1,5 +1,5 @@", "@@ -25,6 +25,6 @@" })
	end)

	it("diffs new files against /dev/null", function()
		expect(Export.unified(nil, "a\n", "/p")).toBe("--- /dev/null\n+++ /p\n@@ -0,0 +1,1 @@\n+a\n")
	end)
end)

return nil
