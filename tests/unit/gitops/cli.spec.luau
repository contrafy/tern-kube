--!strict
-- The tern-kube-drift command a drift report or matrix copies. Pasted into a
-- shell it must compare exactly what Explore compared (same files, same
-- namespace, same contexts, same unmanaged kinds), or the CI result and the
-- view disagree. Probes behind each rule: local://v12-gitops.md section 1.2.
local Cli = require("../../../plugin/lib/gitops/cli")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local CTX = "kind-tern-kube-dev"

local function dir(files: { string }, recursive: boolean): Cli.Input
	return {
		source = { type = "dir", path = "/repo/apps", files = files, recursive = recursive },
		contexts = { CTX },
		kubeconfig = nil,
		namespace = nil,
		unmanaged = nil,
		helmProgram = nil,
	}
end

describe("cli.argv", function()
	it("a proven directory is -R -f DIR", function()
		local input = dir({ "/repo/apps/web.yaml", "/repo/apps/sub/cm.yaml" }, true)
		input.namespace = "team"
		input.unmanaged = { "configmap", "deployment.apps" }
		expect(Cli.argv(input)).toEqual({
			"tern-kube-drift",
			"-R",
			"-f",
			"/repo/apps",
			"--context",
			CTX,
			"-n",
			"team",
			"--unmanaged",
			"configmap,deployment.apps",
		})
	end)

	-- Explicit files are Explore's diff input by construction.
	it("otherwise one -f per compared file, in order", function()
		expect(Cli.argv(dir({ "/repo/apps/a.yaml", "/repo/apps/b.yaml" }, false))).toEqual({
			"tern-kube-drift",
			"-f",
			"/repo/apps/a.yaml",
			"-f",
			"/repo/apps/b.yaml",
			"--context",
			CTX,
		})
	end)

	it("file and kustomize sources", function()
		local f = dir({}, false)
		f.source = { type = "file", path = "/repo/apps/web.yaml" }
		expect(Cli.argv(f)).toEqual({ "tern-kube-drift", "-f", "/repo/apps/web.yaml", "--context", CTX })
		local k = dir({}, false)
		k.source = { type = "kustomize", path = "/repo/overlays/prod" }
		k.kubeconfig = "/home/u/.kube/config"
		expect(Cli.argv(k)).toEqual({
			"tern-kube-drift",
			"-k",
			"/repo/overlays/prod",
			"--context",
			CTX,
			"--kubeconfig",
			"/home/u/.kube/config",
		})
	end)

	-- --values, not -f: the copy never reads as a manifest source.
	it("helm sources render with --helm, --release and --values", function()
		local h = dir({}, false)
		h.source = {
			type = "helm",
			path = "/repo/chart",
			helm = {
				chart = "/repo/chart",
				release = "web",
				namespace = "shop",
				values = { "/repo/v1.yaml", "/repo/v 2.yaml" },
			},
		}
		h.namespace = "shop"
		expect(Cli.argv(h)).toEqual({
			"tern-kube-drift",
			"--helm",
			"/repo/chart",
			"--release",
			"web",
			"--values",
			"/repo/v1.yaml",
			"--values",
			"/repo/v 2.yaml",
			"--context",
			CTX,
			"-n",
			"shop",
		})
	end)

	it("a matrix keeps its column order, base first", function()
		local m = dir({ "/repo/apps/a.yaml" }, false)
		m.contexts = { "b-ctx", "a-ctx", "c-ctx" }
		local argv = Cli.argv(m)
		expect({ argv[4], argv[5], argv[6], argv[7], argv[8], argv[9] }).toEqual({
			"--context",
			"b-ctx",
			"--context",
			"a-ctx",
			"--context",
			"c-ctx",
		})
	end)

	it("an empty unmanaged list adds no --unmanaged", function()
		local input = dir({ "/repo/apps/a.yaml" }, false)
		input.unmanaged = {}
		expect(table.find(Cli.argv(input), "--unmanaged")).toBeNil()
	end)
end)

describe("cli.format", function()
	it("quotes for every POSIX shell and fish", function()
		local input = dir({ "/r/it's a dir/$HOME/`x`;y.yaml" }, false)
		expect(Cli.format(input)).toBe(
			"tern-kube-drift -f '/r/it'\\''s a dir/$HOME/`x`;y.yaml' --context kind-tern-kube-dev"
		)
	end)

	it("prefixes HELM= only when helm is not the default program", function()
		local h = dir({}, false)
		h.source = { type = "helm", path = "/c", helm = { chart = "/c", release = "r", namespace = nil, values = {} } }
		expect(string.sub(Cli.format(h), 1, 16)).toBe("tern-kube-drift ")
		h.helmProgram = "helm"
		expect(string.sub(Cli.format(h), 1, 16)).toBe("tern-kube-drift ")
		h.helmProgram = "/opt/helm 4/bin/helm"
		expect(Cli.format(h)).toBe(
			"HELM='/opt/helm 4/bin/helm' tern-kube-drift --helm /c --release r --context " .. CTX
		)
		-- Not a helm source: helm is never run, nothing to prefix.
		local d = dir({ "/a.yaml" }, false)
		d.helmProgram = "/opt/helm"
		expect(string.sub(Cli.format(d), 1, 16)).toBe("tern-kube-drift ")
	end)
end)

describe("cli.recursive", function()
	local compared = { "/repo/apps/a.yaml", "/repo/apps/sub/b.yml" }

	it("holds when git lists exactly the compared files (probe G1/G2)", function()
		expect(Cli.recursive("/repo/apps", compared, { "/repo/apps/sub/b.yml", "/repo/apps/a.yaml" })).toBe(true)
	end)

	-- kubectl -R reads every .json/.yaml/.yml under the directory.
	it("fails on any extra file kubectl -R would read (probes A-D, G4)", function()
		for _, extra in
			{
				"/repo/apps/kustomization.yaml",
				"/repo/apps/chart/Chart.yaml",
				"/repo/apps/values-prod.yaml",
				"/repo/apps/cm.json",
				"/repo/apps/ignored.yaml",
			}
		do
			local listed = table.clone(compared)
			table.insert(listed, extra)
			expect(Cli.recursive("/repo/apps", compared, listed)).toBe(false)
		end
	end)

	it("ignores files kubectl never reads", function()
		local listed = table.clone(compared)
		table.insert(listed, "/repo/apps/README.md")
		table.insert(listed, "/repo/apps/a.YAML")
		expect(Cli.recursive("/repo/apps", compared, listed)).toBe(true)
	end)

	it("is false without a listing (not git, still running, too large) or a compared file outside it", function()
		expect(Cli.recursive("/repo/apps", compared, nil)).toBe(false)
		expect(Cli.recursive("/repo/apps", { "/repo/apps/a.yaml" }, { "/repo/apps/a.yaml", "/repo/other.yaml" })).toBe(
			true
		)
		expect(Cli.recursive("/repo/apps", compared, { "/repo/apps/a.yaml" })).toBe(false)
		expect(Cli.recursive("/repo/apps", {}, {})).toBe(false)
		expect(Cli.recursive("/repo/apps", { "/repo/x.yaml" }, { "/repo/x.yaml" })).toBe(false)
	end)
end)

describe("cli.listed", function()
	it("parses git ls-files -z relative to the root", function()
		expect(Cli.listed("/repo", "apps/a.yaml\0apps/we'ird dir/b.yaml\0apps/README.md\0")).toEqual({
			"/repo/apps/a.yaml",
			"/repo/apps/we'ird dir/b.yaml",
			"/repo/apps/README.md",
		})
		expect(Cli.listed("/repo", "")).toEqual({})
	end)

	it("treats a listing above LIST_MAX paths as unknown", function()
		local parts = table.create(Cli.LIST_MAX + 1, "x.yaml")
		expect(Cli.listed("/repo", table.concat(parts, "\0") .. "\0")).toBeNil()
	end)
end)

describe("cli.namespaceArg", function()
	local function doc(ns: string?, inferred: boolean, kind: string?): Cli.NamespaceDoc
		return {
			ref = { kind = kind or "ConfigMap", name = "x", namespace = ns, source = "live" },
			namespaceInferred = inferred,
		}
	end

	it("no -n when every namespaced document names its namespace", function()
		expect((Cli.namespaceArg({ doc("a", false), doc("b", false) }, "a"))).toBeNil()
	end)

	-- Probe E/F: without -n they land in the kubeconfig's namespace.
	it("-n TARGET when namespace-less documents exist and the rest agree", function()
		expect((Cli.namespaceArg({ doc(nil, true), doc("team", false), doc(nil, false, "Namespace") }, "team"))).toBe(
			"team"
		)
	end)

	it("mixed: no -n and a note (kubectl refuses -n with other namespaces)", function()
		local ns, note = Cli.namespaceArg({ doc(nil, true), doc(nil, true), doc("other", false) }, "team")
		expect(ns).toBeNil()
		expect(note).toBe(
			"2 documents without a namespace are compared in the kubeconfig's namespace: "
				.. "kubectl cannot combine -n with documents of other namespaces"
		)
	end)

	it("no target namespace: nothing to pin", function()
		expect((Cli.namespaceArg({ doc(nil, true) }, nil))).toBeNil()
	end)
end)

return nil
