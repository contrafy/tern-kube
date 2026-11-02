--!strict
-- Chart auto-detect: which chart directories of the checkout render which
-- deployed releases. A wrong match would compare a release against another
-- chart's templates and report drift that does not exist, so the chart name
-- must match exactly and everything else only orders the candidates; the
-- user's configured gitops.helm entries always win over a guess.
local Detect = require("../../../plugin/lib/helm/detect")
local HelmTypes = require("../../../plugin/lib/helm/types")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type ChartDir = HelmTypes.ChartDir
type ReleaseRow = HelmTypes.ReleaseRow

local function row(name: string, ns: string, chart: string, version: string?, app: string?, status: string?): ReleaseRow
	return {
		name = name,
		namespace = ns,
		revision = 1,
		updated = "2026-01-01T00:00:00Z",
		updatedAt = nil,
		status = (status or "deployed") :: any,
		chart = chart .. "-" .. (version or "?"),
		chartName = chart,
		chartVersion = version,
		appVersion = app or "",
	}
end

local SHOP: ChartDir = {
	path = "/repo/helm/chart",
	name = "shop",
	version = "0.1.0",
	appVersion = "1.27",
	valuesFiles = { "/repo/helm/values-staging.yaml", "/repo/helm/shop-a.yaml", "/repo/helm/notes.yaml" },
}

local function brief(cands: { Detect.Candidate }): { string }
	local out: { string } = {}
	for _, c in cands do
		local v = if c.useDeployedValues then "deployed" else table.concat(c.values or {}, ",")
		table.insert(
			out,
			string.format("%s %s/%s %s %d", c.chart.path, c.release.namespace, c.release.name, v, c.score)
		)
	end
	return out
end

describe("Chart.yaml", function()
	it("reads the captured fixture charts", function()
		expect(Detect.chartYaml(fixtures.read("gitops/helm/chart/Chart.yaml"))).toEqual({
			name = "shop",
			version = "0.1.0",
			appVersion = "1.27",
		})
		expect(Detect.chartYaml(fixtures.read("helm/web/Chart.yaml"))).toEqual({
			name = "web",
			version = "0.2.0",
			appVersion = "2.0",
		})
	end)

	-- YAML turns `version: 1.10` into a number; helm keeps it as written.
	it("keeps quoted and unquoted versions as written and drops comments", function()
		local text = table.concat({
			"# a chart",
			"apiVersion: v2",
			"name: 'my-app'   # the name",
			"version: 1.10",
			'appVersion: "v2.0 # not a comment"',
			"dependencies:",
			"  - name: other",
			"    version: 9.9.9",
		}, "\r\n")
		expect(Detect.chartYaml(text)).toEqual({
			name = "my-app",
			version = "1.10",
			appVersion = "v2.0 # not a comment",
		})
	end)

	-- Nested keys (dependencies, maintainers) must not supply the chart's own.
	it("reads top-level scalars only and needs both name and version", function()
		expect(Detect.chartYaml("dependencies:\n  - name: x\n    version: 1.0.0\n")).toBe(nil)
		expect(Detect.chartYaml("name: x\n")).toBe(nil)
		expect(Detect.chartYaml("name: x\nversion: ~\n")).toBe(nil)
		expect(Detect.chartYaml("name: x\nversion: 1.0.0\nappVersion:\n")).toEqual({
			name = "x",
			version = "1.0.0",
			appVersion = nil,
		})
	end)
end)

describe("candidates", function()
	-- The captured cluster: shop-a, broken-c, stuck-d, tricky-e run chart
	-- shop-0.1.0; web-b runs web.
	it("offers each matching release with deployed values and with each proposed values file", function()
		local releases = {
			row("shop-a", "tern-test-helm", "shop", "0.1.0", "1.27"),
			row("web-b", "tern-test-helm", "web", "0.2.0", "2.0"),
		}
		local cands = Detect.candidates({ SHOP }, releases, {}, "/repo")
		expect(brief(cands)).toEqual({
			"/repo/helm/chart tern-test-helm/shop-a /repo/helm/shop-a.yaml 4",
			"/repo/helm/chart tern-test-helm/shop-a deployed 3",
			"/repo/helm/chart tern-test-helm/shop-a /repo/helm/values-staging.yaml 3",
		})
		expect(cands[2].reasons).toEqual({ "name", "version", "app version" })
		expect(cands[1].reasons).toEqual({ "name", "version", "app version", "values file name" })
		expect(Detect.note(cands[2])).toBe("auto: name+version+app version match")
	end)

	it("never matches on anything but the chart name", function()
		local cands = Detect.candidates(
			{ SHOP },
			{ row("web-b", "tern-test-helm", "web", "0.1.0", "1.27") },
			{},
			"/repo"
		)
		expect(#cands).toBe(0)
	end)

	it("keeps other versions of the chart, ranked below the exact one", function()
		local cands = Detect.candidates({
			{ path = "/repo/old", name = "shop", version = "0.0.9", appVersion = nil, valuesFiles = {} },
			{ path = "/repo/new", name = "shop", version = "0.1.0", appVersion = nil, valuesFiles = {} },
		}, { row("shop-a", "apps", "shop", "0.1.0", "1.27") }, {}, "/repo")
		expect(brief(cands)).toEqual({ "/repo/new apps/shop-a deployed 2", "/repo/old apps/shop-a deployed 0" })
		expect(Detect.note(cands[2])).toBe("auto: name match")
	end)

	-- A repo laid out per environment says which namespace a chart serves.
	it("scores the release namespace as a path segment and in a values file name", function()
		local chart: ChartDir = {
			path = "/repo/envs/prod/shop",
			name = "shop",
			version = "0.1.0",
			appVersion = nil,
			valuesFiles = { "/repo/envs/prod/values-staging.yaml", "/repo/envs/prod/values-prod.yaml" },
		}
		local cands = Detect.candidates({ chart }, { row("shop-a", "prod", "shop", "0.1.0") }, {}, "/repo")
		expect(brief(cands)).toEqual({
			"/repo/envs/prod/shop prod/shop-a /repo/envs/prod/values-prod.yaml 4",
			"/repo/envs/prod/shop prod/shop-a deployed 3",
			"/repo/envs/prod/shop prod/shop-a /repo/envs/prod/values-staging.yaml 3",
		})
		expect(cands[1].reasons).toEqual({ "name", "version", "namespace in path", "values file name" })
	end)

	-- Parent-dir files that neither look like values files nor name the
	-- release are someone else's (another release's overrides, notes).
	it("proposes only values* files and files naming the release", function()
		local cands = Detect.candidates({ SHOP }, { row("shop-z", "x", "shop", "0.1.0", "1.27") }, {}, "/repo")
		expect(brief(cands)).toEqual({
			"/repo/helm/chart x/shop-z deployed 3",
			"/repo/helm/chart x/shop-z /repo/helm/values-staging.yaml 3",
		})
	end)

	-- Their objects are gone (or going): drift would list everything as missing.
	it("skips uninstalled and uninstalling releases", function()
		local cands = Detect.candidates({ SHOP }, {
			row("gone", "x", "shop", "0.1.0", nil, "uninstalled"),
			row("going", "x", "shop", "0.1.0", nil, "uninstalling"),
		}, {}, "/repo")
		expect(#cands).toBe(0)
	end)

	it("lets a configured gitops.helm entry for the same chart and release win", function()
		local releases = {
			row("shop-a", "tern-test-helm", "shop", "0.1.0", "1.27"),
			row("shop-b", "tern-test-helm", "shop", "0.1.0", "1.27"),
		}
		local configured = {
			{ chart = "helm/chart", release = "shop-a", namespace = "tern-test-helm", values = {} },
			{ chart = "/repo/helm/chart", release = "shop-b", namespace = "elsewhere", values = {} },
		}
		local names: { string } = {}
		for _, c in Detect.candidates({ SHOP }, releases, configured, "/repo") do
			table.insert(names, c.release.name)
		end
		-- shop-b is configured for another namespace: the guess still applies.
		expect(names).toEqual({ "shop-b", "shop-b" })
	end)

	it("orders by score, then release, then chart path", function()
		local a: ChartDir = { path = "/repo/b", name = "shop", version = "1", appVersion = nil, valuesFiles = {} }
		local b: ChartDir = { path = "/repo/a", name = "shop", version = "1", appVersion = nil, valuesFiles = {} }
		local cands = Detect.candidates(
			{ a, b },
			{ row("r2", "ns", "shop", "1"), row("r1", "ns", "shop", "1") },
			{},
			"/repo"
		)
		expect(brief(cands)).toEqual({
			"/repo/a ns/r1 deployed 2",
			"/repo/b ns/r1 deployed 2",
			"/repo/a ns/r2 deployed 2",
			"/repo/b ns/r2 deployed 2",
		})
	end)
end)

describe("matchChart", function()
	-- The values view's fallback for pristine chart defaults: only an exact
	-- name+version chart has the defaults the release was installed with.
	it("finds the chart dir with the release's name and version", function()
		local old: ChartDir =
			{ path = "/repo/old", name = "shop", version = "0.0.9", appVersion = nil, valuesFiles = {} }
		expect(Detect.matchChart({ old, SHOP }, "shop", "0.1.0")).toBe(SHOP)
		expect(Detect.matchChart({ old, SHOP }, "shop", "0.2.0")).toBe(nil)
		expect(Detect.matchChart({ old, SHOP }, "web", "0.1.0")).toBe(nil)
	end)
end)

return nil
