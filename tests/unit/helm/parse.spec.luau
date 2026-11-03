--!strict
-- Helm output parsers. Everything Explore and the rollback preview show comes
-- through here, so the specs run on real helm 3.22 output (captured fixtures)
-- and pin the quirks: list revisions are strings, three time formats, Go's
-- %+q quoting in the extras template, chart strings that join name and
-- version with a hyphen the name may contain too.
local Parse = require("../../../plugin/lib/helm/parse")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DIR = "helm/captured/"

local function read(name: string): string
	return fixtures.read(DIR .. name)
end

local function must(value: any, err: string?): any
	if value == nil then
		error("expected a value, got error: " .. tostring(err), 2)
	end
	return value
end

describe("helm list", function()
	it("decodes the captured list with numeric revisions and split charts", function()
		local rows = must(Parse.list(read("list.json"), json.decode))
		expect(#rows).toBe(5)
		local byName = {}
		for _, r in rows do
			byName[r.name] = r
		end
		local shop = byName["shop-a"]
		-- helm prints `"revision":"3"`; sorting and "rev N of M" need numbers.
		expect(shop.revision).toBe(3)
		expect(shop.namespace).toBe("tern-test-helm")
		expect(shop.status).toBe("deployed")
		expect(shop.chart).toBe("shop-0.1.0")
		expect(shop.chartName).toBe("shop")
		expect(shop.chartVersion).toBe("0.1.0")
		expect(shop.appVersion).toBe("1.27")
		expect(shop.updated).toBe("2026-01-01T00:03:00Z")
		expect(shop.updatedAt).toBe(1767225600 + 180)
		expect(byName["stuck-d"].status).toBe("pending-upgrade")
		expect(byName["broken-c"].status).toBe("failed")
	end)

	-- Without --time-format helm prints Go's time.String(); the row still
	-- parses and keeps the raw text for display, but has no timestamp.
	it("keeps Go time.String() times as text without a timestamp", function()
		local rows = must(Parse.list(read("list-default-time.json"), json.decode))
		expect(rows[1].updated).toBe("2026-01-01 00:13:00.123456 +0000 UTC")
		expect(rows[1].updatedAt).toBeNil()
	end)

	it("accepts an empty list", function()
		expect(must(Parse.list("[]\n", json.decode))).toEqual({})
	end)

	it("fails loud on non-JSON, non-lists and rows without a name", function()
		local rows, err = Parse.list("Error: boom", json.decode)
		expect(rows).toBeNil()
		expect(err).toContain("helm list")
		rows, err = Parse.list('{"name":"x"}', json.decode)
		expect(rows).toBeNil()
		expect(err).toContain("list")
		rows, err = Parse.list('[{"namespace":"a","revision":"1","status":"deployed","chart":"c-1.0.0"}]', json.decode)
		expect(rows).toBeNil()
		expect(err).toContain("row 1")
		rows, err =
			Parse.list('[{"name":"a","namespace":"a","revision":"x","status":"deployed","chart":"c"}]', json.decode)
		expect(rows).toBeNil()
		expect(err).toContain("revision")
	end)

	-- A newer helm may add statuses; they must not break the list.
	it("maps unknown statuses to unknown", function()
		local rows =
			must(Parse.list('[{"name":"a","namespace":"n","revision":"1","status":"exotic","chart":"c"}]', json.decode))
		expect(rows[1].status).toBe("unknown")
		expect(rows[1].chartName).toBe("c")
		expect(rows[1].chartVersion).toBeNil()
		expect(rows[1].appVersion).toBe("")
		expect(rows[1].updated).toBe("")
	end)
end)

describe("helm history", function()
	it("decodes every captured history", function()
		for _, path in fixtures.list(DIR .. "history-") do
			local revs, err = Parse.history(fixtures.read(path), json.decode)
			if revs == nil then
				error(path .. ": " .. tostring(err))
			end
			expect(#revs > 0).toBe(true)
		end
	end)

	it("keeps order, descriptions and fractional times", function()
		local revs = must(Parse.history(read("history-web-b.json"), json.decode))
		expect(#revs).toBe(3)
		expect(revs[1].revision).toBe(1)
		expect(revs[1].description).toBe("Install complete")
		expect(revs[2].description).toBe("canary rollout")
		expect(revs[2].chartVersion).toBe("0.2.1")
		expect(revs[3].description).toBe("Rollback to 1")
		expect(revs[3].status).toBe("deployed")
		expect(revs[1].updated).toBe("2026-01-01T00:04:00.123456Z")
		expect(math.abs((revs[1].updatedAt :: number) - (1767225600 + 240.123456)) < 1e-3).toBe(true)
	end)

	it("reads the stuck pending-upgrade revision", function()
		local revs = must(Parse.history(read("history-stuck-d.json"), json.decode))
		expect(revs[2].status).toBe("pending-upgrade")
		expect(revs[2].description).toBe("Preparing upgrade")
	end)

	it("rejects rows without a numeric revision", function()
		local revs, err = Parse.history('[{"revision":"two","status":"deployed","chart":"c-1.0.0"}]', json.decode)
		expect(revs).toBeNil()
		expect(err).toContain("revision")
	end)
end)

describe("helm status", function()
	it("decodes every captured status", function()
		for _, path in fixtures.list(DIR .. "status-") do
			local st, err = Parse.status(fixtures.read(path), json.decode)
			if st == nil then
				error(path .. ": " .. tostring(err))
			end
			expect(#st.manifest > 0).toBe(true)
		end
	end)

	it("reads info, user values, notes and manifest", function()
		local st = must(Parse.status(read("status-web-b-r2.json"), json.decode))
		expect(st.name).toBe("web-b")
		expect(st.namespace).toBe("tern-test-helm")
		expect(st.revision).toBe(2)
		expect(st.info.status).toBe("superseded")
		expect(st.info.description).toBe("canary rollout")
		expect(st.info.firstDeployed).toBe("2026-01-01T00:04:00.123456Z")
		expect(st.info.lastDeployed).toBe("2026-01-01T00:07:00.123456Z")
		expect(st.info.notes).toContain("Mode: canary")
		expect(st.user.config.mode).toBe("canary")
		expect(st.manifest).toContain("kind: Secret")
	end)

	-- Releases installed without values have no config; notes are optional.
	it("defaults absent user values and notes to empty", function()
		local st = must(Parse.status(read("status-shop-a-r1.json"), json.decode))
		expect(st.user).toEqual({})
		expect(st.info.notes).toBe("")
	end)

	it("rejects output that is not a release", function()
		local st, err = Parse.status('{"foo":1}', json.decode)
		expect(st).toBeNil()
		expect(err).toContain("helm status")
	end)
end)

describe("helm get values", function()
	it("decodes user and computed values, null as empty", function()
		for _, path in fixtures.list(DIR .. "values-") do
			local v, err = Parse.values(fixtures.read(path), json.decode)
			if v == nil then
				error(path .. ": " .. tostring(err))
			end
		end
		expect(must(Parse.values(read("values-shop-a-r1.json"), json.decode))).toEqual({})
		local web = must(Parse.values(read("values-all-web-b-r1.json"), json.decode))
		expect(web.service.port).toBe(80)
	end)

	it("rejects non-objects", function()
		local v, err = Parse.values("[1]", json.decode)
		expect(v).toBeNil()
		expect(err).toContain("values")
		v, err = Parse.values("nope", json.decode)
		expect(v).toBeNil()
		expect(err).toContain("values")
	end)
end)

describe("Go-quoted JSON", function()
	-- %+q emits escapes JSON lacks; each must decode to the same character.
	it("rewrites \\a \\v \\xHH \\UHHHHHHHH inside strings only", function()
		expect(Parse.goJson('"a\\ab\\vc"')).toBe('"a\\u0007b\\u000bc"')
		expect(Parse.goJson('"\\x00\\x7f"')).toBe('"\\u0000\\u007f"')
		expect(Parse.goJson('"\\U0001f600"')).toBe('"\\ud83d\\ude00"')
		expect(Parse.goJson('"\\U000000e9"')).toBe('"\\u00e9"')
		-- An invalid UTF-8 byte has no character: the replacement char, as helm's JSON.
		expect(Parse.goJson('"\\xff"')).toBe('"\\ufffd"')
		-- Backslash parity: an escaped backslash before `a` is not a bell.
		expect(Parse.goJson('"\\\\a"')).toBe('"\\\\a"')
		expect(Parse.goJson('"\\"\\a"')).toBe('"\\"\\u0007"')
		-- Outside strings nothing changes.
		expect(Parse.goJson('{"k":[1,true,null]}')).toBe('{"k":[1,true,null]}')
		expect(json.decode(Parse.goJson('"\\U0001f600 \\a"'))).toBe(utf8.char(0x1F600) .. " " .. string.char(7))
	end)
end)

describe("helm extras template", function()
	it("decodes every captured extras output", function()
		for _, path in fixtures.list(DIR .. "extras-") do
			if string.sub(path, -4) == ".txt" then
				local ex, err = Parse.extras(fixtures.read(path), json.decode)
				if ex == nil then
					error(path .. ": " .. tostring(err))
				end
			end
		end
	end)

	-- tricky-e r2 stored defaults hold the r1 user value verbatim (--reuse-values);
	-- the Go-quoted copy must decode to exactly what helm's own JSON says.
	it("decodes Go-quoted strings identically to helm's JSON", function()
		local ex = must(Parse.extras(read("extras-tricky-e-r2.txt"), json.decode))
		local st = must(Parse.status(read("status-tricky-e-r2.json"), json.decode))
		expect(ex.defaults.weird).toBe(st.user.weird)
		expect(ex.defaults.list).toEqual(st.user.list)
		expect(ex.defaults.big).toBe(st.user.big)
	end)

	it("reads chart metadata and hooks with last runs", function()
		local ex = must(Parse.extras(read("extras-web-b-r3.txt"), json.decode))
		expect(ex.name).toBe("web-b")
		expect(ex.namespace).toBe("tern-test-helm")
		expect(ex.revision).toBe(3)
		expect(ex.chart.name).toBe("web")
		expect(ex.chart.version).toBe("0.2.0")
		expect(ex.chart.appVersion).toBe("2.0")
		expect(ex.chart.type).toBe("application")
		expect(ex.chart.sources).toEqual({})
		expect(ex.chart.dependencies).toEqual({})
		expect(ex.defaults.service.port).toBe(80)
		expect(#ex.hooks).toBe(2)
		local pre = ex.hooks[1]
		expect(pre.name).toBe("web-b-web-pre-upgrade")
		expect(pre.kind).toBe("ConfigMap")
		expect(pre.path).toBe("web/templates/hooks.yaml")
		expect(pre.weight).toBe(-5)
		expect(pre.events).toEqual({ "pre-upgrade", "pre-rollback" })
		expect(pre.deletePolicies).toEqual({ "before-hook-creation" })
		expect(pre.phase).toBe("Succeeded")
		expect(pre.startedAt).toBe("2026-01-01T00:11:00.123456Z")
		expect(pre.completedAt).toBe("2026-01-01T00:12:00.123456Z")
		expect(pre.manifest).toContain("helm.sh/hook")
	end)

	it("reads dependencies and hooks that never ran", function()
		local text = '{"format":"tern-kube/helm-extras/v1","name":"x","namespace":"n","revision":1,'
			.. '"chart":{"name":"c","version":"1.0.0","app_version":"","type":"","description":"","home":"",'
			.. '"sources":["https://s"],"dependencies":[{"name":"redis","version":"1.2.3","repository":"oci://r","alias":"cache"}]},'
			.. '"defaults":{},"hooks":[{"name":"h","kind":"Job","path":"c/templates/j.yaml","weight":0,"events":["test"],'
			.. '"delete_policies":[],"last_run":{"phase":"","started_at":null,"completed_at":null},"manifest":""}]}'
		local ex = must(Parse.extras(text, json.decode))
		expect(ex.chart.sources).toEqual({ "https://s" })
		expect(ex.chart.dependencies).toEqual({
			{ name = "redis", version = "1.2.3", repository = "oci://r", alias = "cache" },
		})
		expect(ex.hooks[1].phase).toBe("")
		expect(ex.hooks[1].startedAt).toBeNil()
		expect(ex.hooks[1].deletePolicies).toEqual({})
	end)

	-- A template from another plugin version, or helm printing an error,
	-- must not be mistaken for this format.
	it("rejects other formats and garbage", function()
		local ex, err = Parse.extras('{"format":"tern-kube/helm-extras/v0"}', json.decode)
		expect(ex).toBeNil()
		expect(err).toContain("format")
		ex, err = Parse.extras("Error: release: not found", json.decode)
		expect(ex).toBeNil()
		expect(err).toContain("extras")
	end)
end)

describe("chart strings", function()
	it("splits at the first hyphen followed by a semver", function()
		local cases: { { string } } = {
			{ "shop-0.1.0", "shop", "0.1.0" },
			{ "my-chart-1.0.0-rc.1", "my-chart", "1.0.0-rc.1" },
			{ "k8s-1-app-2.0.0", "k8s-1-app", "2.0.0" },
			{ "web-0.2.1", "web", "0.2.1" },
			{ "app-v1.2.3+build.5", "app", "v1.2.3+build.5" },
		}
		for _, c in cases do
			local name, version = Parse.splitChart(c[1])
			expect(name).toBe(c[2])
			expect(version).toBe(c[3])
		end
	end)

	it("keeps the whole string as the name when no version follows", function()
		local name, version = Parse.splitChart("weird")
		expect(name).toBe("weird")
		expect(version).toBeNil()
		name, version = Parse.splitChart("a-1.2")
		expect(name).toBe("a-1.2")
		expect(version).toBeNil()
		name, version = Parse.splitChart("a-1.2.3x")
		expect(name).toBe("a-1.2.3x")
		expect(version).toBeNil()
	end)
end)

describe("times", function()
	it("reads RFC 3339 with and without fraction and with offsets", function()
		expect(Parse.time("2026-01-01T00:03:00Z")).toBe(1767225780)
		expect(Parse.time("2026-01-01T00:03:00.5Z")).toBe(1767225780.5)
		-- Synthetic: captures are UTC, a user's helm prints its local offset.
		expect(Parse.time("2026-10-30T16:23:14-05:00")).toBe(Parse.time("2026-10-30T21:23:14Z"))
	end)

	it("returns nil for Go time.String() and empty text", function()
		expect(Parse.time("2026-10-30 16:23:14.642871 -0500 CDT")).toBeNil()
		expect(Parse.time("2026-01-01 00:13:00.123456 +0000 UTC")).toBeNil()
		expect(Parse.time("")).toBeNil()
	end)
end)

describe("status classification", function()
	it("maps statuses to tones", function()
		expect(Parse.tone("deployed")).toBe("ok")
		expect(Parse.tone("failed")).toBe("error")
		for _, s in { "pending-install", "pending-upgrade", "pending-rollback", "uninstalling" } do
			expect(Parse.tone(s :: any)).toBe("warn")
		end
		for _, s in { "superseded", "uninstalled", "unknown" } do
			expect(Parse.tone(s :: any)).toBe("muted")
		end
	end)

	it("normalizes status text", function()
		expect(Parse.statusOf("pending-upgrade")).toBe("pending-upgrade")
		expect(Parse.statusOf("Deployed")).toBe("unknown")
		expect(Parse.statusOf(nil)).toBe("unknown")
	end)

	-- A pending release past STUCK_AFTER_S blocks every upgrade (F11); only
	-- rollback recovers it, so the views flag it.
	it("flags pending releases older than STUCK_AFTER_S as stuck", function()
		local at = 1000
		local function row(status: string, updatedAt: number?)
			return { status = status :: any, updatedAt = updatedAt }
		end
		expect(Parse.STUCK_AFTER_S).toBe(900)
		expect(Parse.stuck(row("pending-upgrade", at), at + 901)).toBe(true)
		expect(Parse.stuck(row("pending-install", at), at + 900)).toBe(false)
		expect(Parse.stuck(row("deployed", at), at + 10000)).toBe(false)
		expect(Parse.stuck(row("pending-rollback", nil), at + 10000)).toBe(false)
		expect(Parse.stuck(row("pending-upgrade", at), nil)).toBe(false)
	end)
end)

describe("helm error text", function()
	it("classifies failures the views explain differently", function()
		expect(Parse.errorKind('Error: Kubernetes cluster unreachable: context "nope" does not exist')).toBe(
			"unreachable"
		)
		expect(
			Parse.errorKind(
				'Error: Kubernetes cluster unreachable: Get "https://127.0.0.1:1/version": dial tcp 127.0.0.1:1: connect: connection refused'
			)
		).toBe("unreachable")
		expect(
			Parse.errorKind(
				'Error: list: failed to list: secrets is forbidden: User "dev" cannot list resource "secrets" in API group "" in the namespace "kube-system"'
			)
		).toBe("forbidden")
		expect(Parse.errorKind("Error: release: not found")).toBe("not-found")
		expect(Parse.errorKind(read("rollback-dry-run-shop-a-99.txt"))).toBe("not-found")
		expect(Parse.errorKind("Error: unknown flag: --bogus")).toBe("other")
		expect(Parse.errorKind("")).toBe("other")
	end)
end)

return nil
