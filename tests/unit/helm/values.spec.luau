--!strict
-- The Values view answers "what did the user change from the chart's
-- defaults?". Helm's stored defaults lie after `upgrade --reuse-values` (F8),
-- so which revision's defaults are trusted is pinned against captured
-- releases, and every row a user sees must be masked like the Secret it
-- usually ends up in.
local HelmTypes = require("../../../plugin/lib/helm/types")
local Redact = require("../../../plugin/lib/model/redact")
local Values = require("../../../plugin/lib/helm/values")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DIR = "helm/captured/"
local SHOWN = table.freeze({ showSecrets = true, strict = false }) :: Redact.Policy

local function shape(_: any): boolean
	return false
end

local function history(release: string): { HelmTypes.Revision }
	local out: { HelmTypes.Revision } = {}
	for _, r in json.decode(fixtures.read(DIR .. "history-" .. release .. ".json")) do
		local name, version = string.match(r.chart, "^(.-)%-(v?%d+%.%d+%.%d+.*)$")
		table.insert(out, {
			revision = r.revision,
			updated = r.updated,
			status = r.status,
			chart = r.chart,
			chartName = name or r.chart,
			chartVersion = version,
			appVersion = r.app_version,
			description = r.description,
		})
	end
	return out
end

local function extras(release: string, revision: number): HelmTypes.Extras
	local raw = json.decode(fixtures.read(string.format("%sextras-%s-r%d.txt", DIR, release, revision)))
	return {
		name = raw.name,
		namespace = raw.namespace,
		revision = raw.revision,
		chart = {
			name = raw.chart.name,
			version = raw.chart.version,
			appVersion = raw.chart.app_version,
			type = raw.chart.type,
			description = raw.chart.description,
			home = raw.chart.home,
			sources = raw.chart.sources,
			dependencies = raw.chart.dependencies,
		},
		defaults = raw.defaults,
		hooks = {},
	}
end

local function values(kind: string, release: string, revision: number): { [string]: any }
	local v = json.decode(fixtures.read(string.format("%s%s-%s-r%d.json", DIR, kind, release, revision)))
	return if v == json.null then {} else v
end

local function rowsByPath(rows: { Values.Row }): { [string]: Values.Row }
	local out: { [string]: Values.Row } = {}
	for _, r in rows do
		if out[r.path] then
			error("duplicate row " .. r.path)
		end
		out[r.path] = r
	end
	return out
end

describe("helm.values flatten", function()
	-- helm replaces lists instead of merging them, so a list is one value;
	-- keys with dots are quoted so a path names exactly one key.
	it("yields leaves with dotted paths, whole lists and quoted odd keys", function()
		local leaves = Values.flatten({
			image = { tag = "1" },
			list = { 1, 2 },
			empty = {},
			annotations = { ["a.b/c"] = "x" },
		})
		local got: { [string]: any } = {}
		for _, l in leaves do
			got[l.path] = l.value
		end
		expect(got).toEqual({
			["image.tag"] = "1",
			list = { 1, 2 },
			empty = {},
			['annotations["a.b/c"]'] = "x",
		})
		expect(leaves[1].path).toBe('annotations["a.b/c"]')
	end)
end)

describe("helm.values pristine defaults", function()
	-- shop-a r2 and r3 were `upgrade --reuse-values`; r3's stored defaults
	-- hold replicaCount 2 from r2's user values. Revision 1 of the same chart
	-- version is the only trustworthy record.
	it("uses the first revision of the same chart version for shop-a r3", function()
		local h = history("shop-a")
		expect(Values.needs(h, 3)).toEqual({ extras = { 1, 3 }, users = {} })
		local rev, source = Values.pristine(h, { [1] = extras("shop-a", 1), [3] = extras("shop-a", 3) }, {}, 3)
		expect(rev).toBe(1)
		expect(source).toBe("record-earliest")
		local rev1, source1 = Values.pristine(h, { [1] = extras("shop-a", 1) }, {}, 1)
		expect(rev1).toBe(1)
		expect(source1).toBe("record")
	end)

	-- web-b r2 is the first revision of web-0.2.1 and was upgraded with
	-- --reuse-values: its defaults contain r1's password, so they are suspect.
	it("flags web-b r2 defaults that contain the previous user values", function()
		local h = history("web-b")
		expect(Values.needs(h, 2)).toEqual({ extras = { 2 }, users = { 1 } })
		local e = { [2] = extras("web-b", 2) }
		local rev, source = Values.pristine(h, e, { [1] = values("values", "web-b", 1) }, 2)
		expect(rev).toBe(2)
		expect(source).toBe("record-suspect")
		-- Without values to reuse there is no sign of --reuse-values.
		local rev2, source2 = Values.pristine(h, e, { [1] = {} }, 2)
		expect(rev2).toBe(2)
		expect(source2).toBe("record")
		-- A chart default that differs from the old user value is the chart's own.
		local rev3, source3 = Values.pristine(h, e, { [1] = { auth = { password = "other" } } }, 2)
		expect(rev3).toBe(2)
		expect(source3).toBe("record")
	end)

	it("follows a rollback to the revision that installed its chart", function()
		local h = history("web-b")
		local rev, source = Values.pristine(h, { [1] = extras("web-b", 1), [3] = extras("web-b", 3) }, {}, 3)
		expect(rev).toBe(1)
		expect(source).toBe("record-earliest")
	end)

	-- Missing inputs must never make reused values look like chart defaults.
	it("falls back to suspect or unavailable when inputs are missing", function()
		local h = history("web-b")
		local rev, source = Values.pristine(h, { [2] = extras("web-b", 2) }, {}, 2)
		expect(rev).toBe(2)
		expect(source).toBe("record-suspect")
		local none, unavailable = Values.pristine(h, {}, {}, 2)
		expect(none).toBeNil()
		expect(unavailable).toBe("unavailable")
		local rev3, source3 = Values.pristine(h, { [3] = extras("web-b", 3) }, {}, 3)
		expect(rev3).toBe(3)
		expect(source3).toBe("record-suspect")
	end)

	it("explains every source except a plain record", function()
		expect(Values.note("record", 3, 3)).toBeNil()
		expect(Values.note("record-earliest", 3, 1)).toContain("revision 1")
		expect(Values.note("record-suspect", 2, 2)).toContain("--reuse-values")
		expect(Values.note("chart-dir", 2, nil)).toContain("chart directory")
		expect(Values.note("chart-source", 2, nil)).toContain("helm show values")
		expect(Values.note("unavailable", 2, nil)).toContain("unavailable")
	end)
end)

describe("helm.values compare", function()
	it("marks shop-a r3 replicaCount as an override against pristine defaults", function()
		local user = values("values", "shop-a", 3)
		local computed = values("values-all", "shop-a", 3)
		local rows = rowsByPath(Values.compare(extras("shop-a", 1).defaults, user, computed, {}, shape, Redact.DEFAULT))
		expect(rows.replicaCount.state).toBe("override")
		expect(rows.replicaCount.default).toBe(1)
		expect(rows.replicaCount.user).toBe(2)
		expect(rows.replicaCount.computed).toBe(2)
		expect(rows["config.mode"].state).toBe("override")
		expect(rows["image.tag"].state).toBe("override")
		expect(rows["image.repository"].state).toBe("default")
		expect(rows["service.port"].state).toBe("default")
		-- The reused record would hide the user's replica setting.
		local suspect =
			rowsByPath(Values.compare(extras("shop-a", 3).defaults, user, computed, {}, shape, Redact.DEFAULT))
		expect(suspect.replicaCount.state).toBe("same-as-default")
	end)

	it("returns rows sorted by path and counts every state", function()
		local rows = Values.compare(
			extras("shop-a", 1).defaults,
			values("values", "shop-a", 3),
			values("values-all", "shop-a", 3),
			{},
			shape,
			Redact.DEFAULT
		)
		local paths: { string } = {}
		for _, r in rows do
			table.insert(paths, r.path)
		end
		expect(paths).toEqual({ "config.mode", "image.repository", "image.tag", "replicaCount", "service.port" })
		expect(Values.counts(rows)).toEqual({
			override = 3,
			["same-as-default"] = 0,
			["unknown-key"] = 0,
			subchart = 0,
			default = 2,
			removed = 0,
			user = 0,
		})
	end)

	-- A key the chart never declares is never read: most likely a typo.
	-- Adding entries under a declared empty map is normal chart usage.
	it("detects unknown keys but accepts entries under declared maps", function()
		local defaults = { replicaCount = 1, podAnnotations = {}, resources = { limits = { cpu = "1" } } }
		local user = { replicaCont = 3, podAnnotations = { team = "a" }, resources = {} }
		local rows = rowsByPath(Values.compare(defaults, user, nil, {}, shape, Redact.DEFAULT))
		expect(rows.replicaCont.state).toBe("unknown-key")
		expect(rows["podAnnotations.team"].state).toBe("override")
		expect(rows.resources.state).toBe("override")
	end)

	-- Subchart defaults are not in the stored chart (F9); their keys are not
	-- typos, and `global` is read by every subchart.
	it("attributes dependency and global keys to subcharts", function()
		local deps: { HelmTypes.Dependency } = {
			{ name = "redis", version = "1", repository = "", alias = "" },
			{ name = "postgresql", version = "1", repository = "", alias = "db" },
		}
		local user = { redis = { replicas = 2 }, db = { size = "1Gi" }, global = { registry = "r" }, typo = 1 }
		local computed =
			{ redis = { replicas = 2, port = 6379 }, db = { size = "1Gi" }, global = { registry = "r" }, typo = 1 }
		local rows = rowsByPath(Values.compare({}, user, computed, deps, shape, Redact.DEFAULT))
		expect(rows["redis.replicas"].state).toBe("subchart")
		expect(rows["db.size"].state).toBe("subchart")
		expect(rows["global.registry"].state).toBe("subchart")
		expect(rows.typo.state).toBe("unknown-key")
		expect(rows["redis.port"].state).toBe("default")
		local alone = rowsByPath(Values.compare({}, { global = { registry = "r" } }, nil, {}, shape, Redact.DEFAULT))
		expect(alone["global.registry"].state).toBe("unknown-key")
	end)

	it("compares lists whole", function()
		local defaults = { args = { "a", "b" }, hosts = { "x" } }
		local rows = rowsByPath(
			Values.compare(defaults, { args = { "a", "b" }, hosts = { "x", "y" } }, nil, {}, shape, Redact.DEFAULT)
		)
		expect(rows.args.state).toBe("same-as-default")
		expect(rows.hosts.state).toBe("override")
		expect(rows.hosts.user).toEqual({ "x", "y" })
		-- An empty list default replaced by an empty map changes the type helm sees.
		local list = {}
		local function tagged(x: any): boolean
			return x == list
		end
		local typed =
			rowsByPath(Values.compare({ tolerations = list }, { tolerations = {} }, nil, {}, tagged, Redact.DEFAULT))
		expect(typed.tolerations.state).toBe("override")
	end)

	-- Decoded JSON drops null members, so `--set key=null` is only visible as
	-- a default missing from the computed values.
	it("reports defaults removed by a null as removed", function()
		local defaults = { ingress = { enabled = false, host = "a" }, service = { port = 80 } }
		local computed = { ingress = { host = "a" }, service = { port = 80 } }
		local rows = rowsByPath(Values.compare(defaults, {}, computed, {}, shape, Redact.DEFAULT))
		expect(rows["ingress.enabled"].state).toBe("removed")
		expect(rows["ingress.enabled"].default).toBe(false)
		expect(rows["ingress.host"].state).toBe("default")
	end)

	it("lists user values without a verdict when defaults are unavailable", function()
		local rows = rowsByPath(
			Values.compare(nil, { replicaCount = 2 }, { replicaCount = 2, x = 1 }, {}, shape, Redact.DEFAULT)
		)
		expect(rows.replicaCount.state).toBe("user")
		expect(rows.x.state).toBe("default")
	end)

	-- Rows compare raw values (a rotated password is still an override) and
	-- show only masks, so web-b's fake secrets never reach the view.
	it("masks secrets on every side while keeping the raw verdict", function()
		local user = values("values", "web-b", 2)
		local computed = values("values-all", "web-b", 2)
		local rows = Values.compare(extras("web-b", 2).defaults, user, computed, {}, shape, Redact.DEFAULT)
		local byPath = rowsByPath(rows)
		local password = byPath["auth.password"]
		expect(password.state).toBe("same-as-default")
		expect(password.masked).toBe(true)
		expect(password.user).toBe("<redacted: 16 bytes>")
		expect(password.default).toBe("<redacted: 16 bytes>")
		expect(byPath["config.mode"].masked).toBe(false)
		for _, r in rows do
			for _, v in { r.default, r.user, r.computed } do
				if type(v) == "string" and string.find(v, "REDACTME", 1, true) then
					error("secret leaked in row " .. r.path)
				end
			end
		end
		local rotated = rowsByPath(
			Values.compare(
				extras("web-b", 2).defaults,
				{ auth = { password = "hunter3-REDACTME" } },
				nil,
				{},
				shape,
				Redact.DEFAULT
			)
		)
		expect(rotated["auth.password"].state).toBe("override")
		expect(rotated["auth.password"].user).toBe(rotated["auth.password"].default)
		local shown = rowsByPath(Values.compare(extras("web-b", 2).defaults, user, computed, {}, shape, SHOWN))
		expect(shown["auth.password"].user).toBe("hunter2-REDACTME")
		expect(shown["auth.password"].masked).toBe(false)
	end)
end)

describe("helm.values yaml", function()
	it("renders values as block YAML", function()
		expect(Values.yaml({ replicaCount = 2, image = { tag = "1.27" }, empty = {} }, shape)).toBe(
			"empty: {}\nimage:\n  tag: '1.27'\nreplicaCount: 2\n"
		)
	end)
end)

return nil
