--!strict
-- Compare pairs objects across contexts by identity (never by version),
-- classifies every pair (same / changed / missing / extra), names the
-- differences a user can act on, and never shows a Secret value or, in
-- strict mode, a sensitive-looking value, while still telling a changed
-- hidden value from an equal one. Fan-out stays inside max_parallel.
local Model = require("../../../plugin/lib/compare/model")
local Objdiff = require("../../../plugin/lib/mutation/objdiff")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local HIDE = { showSecrets = false, strict = false }
local SHOW = { showSecrets = true, strict = false }
local STRICT = { showSecrets = false, strict = true }
local LABELS = { "kind-tern-kube-dev", "kind-tern-kube-dev2" }

local function load(name: string): any
	return json.decode(fixtures.read("real/compare/" .. name))
end

local function text(result: Objdiff.Result?): string
	local out = {}
	for _, seg in (result :: Objdiff.Result).summary.segments do
		table.insert(out, table.concat(seg.lines, "\n"))
	end
	return table.concat(out, "\n")
end

local function has(s: string, needle: string): boolean
	return string.find(s, needle, 1, true) ~= nil
end

local function column(context: string, status: any?): Model.Column
	return { context = context, label = context, status = status or "ok" }
end

local function deploy(name: string, replicas: number, apiVersion: string?): any
	return {
		apiVersion = apiVersion or "apps/v1",
		kind = "Deployment",
		metadata = { name = name, namespace = "ns" },
		spec = { replicas = replicas },
	}
end

describe("compare.model pair", function()
	-- The same object served as apps/v1 and apps/v1beta2 is one object.
	it("pairs by group, kind, namespace and name, ignoring the version", function()
		local pairs = Model.pair(
			{ deploy("web", 1), deploy("api", 1) },
			{ deploy("web", 2, "apps/v1beta2"), deploy("db", 1) }
		)
		expect(#pairs).toBe(3)
		expect(pairs[1].key).toBe("apps/Deployment/ns/web")
		expect((pairs[1].a :: any).spec.replicas).toBe(1)
		expect((pairs[1].b :: any).spec.replicas).toBe(2)
		expect(pairs[2].key).toBe("apps/Deployment/ns/api")
		expect(pairs[2].b).toBeNil()
		expect(pairs[3].key).toBe("apps/Deployment/ns/db")
		expect(pairs[3].a).toBeNil()
	end)
end)

describe("compare.model paths", function()
	it("names exactly the replicas, image and label differences of tkm-web", function()
		local a, b = load("a-deployment-tkm-web.json"), load("b-deployment-tkm-web.json")
		local cell = Model.objectDiff(a, b, { labels = LABELS, policy = HIDE, null = json.null })
		expect(cell.paths).toEqual({
			"metadata.labels.tier frontend -> (absent)",
			"spec.replicas 2 -> 3",
			"spec.template.spec.containers[web].image nginx:1.27-alpine -> nginx:1.28-alpine",
		})
		expect(cell.total).toBe(3)
	end)

	it("addresses unnamed list items by index and quotes dotted keys", function()
		local a = { metadata = { annotations = { ["example.com/x"] = "1" } }, spec = { args = { "a", "b" } } }
		local b = { metadata = { annotations = { ["example.com/x"] = "2" } }, spec = { args = { "a", "c", "d" } } }
		local paths, total = Model.paths(a, b, 10, HIDE)
		expect(paths).toEqual({
			'metadata.annotations["example.com/x"] 1 -> 2',
			"spec.args[1] b -> c",
			"spec.args[2] (absent) -> d",
		})
		expect(total).toBe(3)
		local first, all = Model.paths(a, b, 1, HIDE)
		expect(first).toEqual({ 'metadata.annotations["example.com/x"] 1 -> 2' })
		expect(all).toBe(3)
	end)

	it("summarizes multi-line and long values", function()
		local paths = Model.paths({ data = { f = "a\nb\n" } }, { data = { f = string.rep("x", 80) } }, 5, HIDE)
		expect(paths).toEqual({ "data.f (2 lines) -> " .. string.rep("x", 57) .. "..." })
	end)
end)

describe("compare.model objectDiff", function()
	it("diffs base against other with both contexts in the headers", function()
		local cell, result = Model.objectDiff(
			load("a-deployment-tkm-web.json"),
			load("b-deployment-tkm-web.json"),
			{ labels = LABELS, policy = HIDE, null = json.null }
		)
		expect(cell.state).toBe("changed")
		expect(cell.added).toBe(2)
		expect(cell.removed).toBe(3)
		local seg = (result :: Objdiff.Result).summary.segments[1]
		expect(seg.lines[1]).toBe("--- kind-tern-kube-dev/apps.v1.Deployment.tern-test-mc.tkm-web")
		expect(seg.lines[2]).toBe("+++ kind-tern-kube-dev2/apps.v1.Deployment.tern-test-mc.tkm-web")
		expect(seg.name).toBe("tkm-web")
		local diff = text(result)
		expect(has(diff, "-  replicas: 2")).toBe(true)
		expect(has(diff, "+  replicas: 3")).toBe(true)
		expect(has(diff, "uid")).toBe(false)
		expect(has(diff, "resourceVersion")).toBe(false)
	end)

	it("reports identical objects of two clusters as same", function()
		for _, name in { "deployment-tkm-api.json", "service-tkm-web.json" } do
			local cell, result =
				Model.objectDiff(load("a-" .. name), load("b-" .. name), { labels = LABELS, policy = HIDE })
			expect(cell).toEqual({ state = "same" })
			expect(#(result :: Objdiff.Result).summary.segments).toBe(0)
		end
	end)

	it("classifies a one-sided pair as missing or extra and keeps its YAML", function()
		local only = load("a-configmap-tkm-flags.json")
		local missing, result = Model.objectDiff(only, nil, { labels = LABELS, policy = HIDE })
		expect(missing.state).toBe("missing")
		expect((result :: Objdiff.Result).summary.delete).toBe(1)
		expect(has(text(result), "ROLLOUT: canary")).toBe(true)
		local extra, created = Model.objectDiff(nil, only, { labels = LABELS, policy = HIDE })
		expect(extra.state).toBe("extra")
		expect((created :: Objdiff.Result).summary.create).toBe(1)
		local absent, none = Model.objectDiff(nil, nil, { labels = LABELS, policy = HIDE })
		expect(absent).toEqual({ state = "absent" })
		expect(none).toBeNil()
	end)

	-- Raw values (s3cret-A/B, their base64 and the last-applied JSON) must
	-- never reach the view; the changed key stays visible.
	it("masks Secret values but tells changed from equal", function()
		local cell, result = Model.objectDiff(
			load("a-secret-tkm-secret.json"),
			load("b-secret-tkm-secret.json"),
			{ labels = LABELS, policy = HIDE }
		)
		expect(cell.state).toBe("changed")
		expect(cell.paths).toEqual({ "data.password changed" })
		local diff = text(result)
		for _, leak in { "s3cret", "czNjcmV0", "YWRtaW4", "last-applied" } do
			expect(has(diff, leak)).toBe(false)
		end
		expect(has(diff, "password: " .. Objdiff.REDACTED_CHANGED)).toBe(true)
		expect(has(diff, "username: " .. Objdiff.REDACTED)).toBe(true)
	end)

	it("shows Secret values when show_secret_values is on", function()
		local cell, result = Model.objectDiff(
			load("a-secret-tkm-secret.json"),
			load("b-secret-tkm-secret.json"),
			{ labels = LABELS, policy = SHOW }
		)
		expect(cell.paths).toEqual({ "data.password czNjcmV0LUE= -> czNjcmV0LUI=" })
		expect(has(text(result), "+  password: czNjcmV0LUI=")).toBe(true)
	end)

	it("masks sensitive-looking values in strict mode on both sides", function()
		local function cm(token: string, level: string): any
			return {
				apiVersion = "v1",
				kind = "ConfigMap",
				metadata = { name = "c", namespace = "ns" },
				data = { api_token = token, level = level },
			}
		end
		local function pod(pw: string): any
			return {
				apiVersion = "v1",
				kind = "Pod",
				metadata = { name = "p", namespace = "ns" },
				spec = { containers = { { name = "c", env = { { name = "DB_PASSWORD", value = pw } } } } },
			}
		end
		local cell, result =
			Model.objectDiff(cm("tok-aaaa", "x"), cm("tok-bbbb", "y"), { labels = LABELS, policy = STRICT })
		expect(cell.paths).toEqual({ "data.api_token changed", "data.level x -> y" })
		local diff = text(result)
		expect(has(diff, "tok-")).toBe(false)
		expect(has(diff, "api_token: " .. Objdiff.REDACTED_CHANGED)).toBe(true)
		local envCell, envResult = Model.objectDiff(pod("pw-one"), pod("pw-two"), { labels = LABELS, policy = STRICT })
		expect(envCell.paths).toEqual({ "spec.containers[c].env[DB_PASSWORD].value changed" })
		expect(has(text(envResult), "pw-")).toBe(false)
		local plain = Model.objectDiff(cm("tok-aaaa", "x"), cm("tok-bbbb", "x"), { labels = LABELS, policy = HIDE })
		expect(plain.paths).toEqual({ "data.api_token tok-aaaa -> tok-bbbb" })
	end)

	it("never modifies the caller's objects", function()
		local a, b = load("a-secret-tkm-secret.json"), load("b-secret-tkm-secret.json")
		Model.objectDiff(a, b, { labels = LABELS, policy = STRICT })
		expect(a.data.password).toBe("czNjcmV0LUE=")
		expect(b.metadata.resourceVersion ~= nil).toBe(true)
	end)
end)

describe("compare.model listMatrix", function()
	local function lists(): { { any }? }
		return { load("a-deployments-list.json").items, load("b-deployments-list.json").items }
	end

	local function states(m: Model.Matrix): { [string]: { string } }
		local out: { [string]: { string } } = {}
		for _, row in m.rows do
			local s = {}
			for _, cell in row.cells do
				table.insert(s, cell.state)
			end
			out[row.ref.name] = s
		end
		return out
	end

	it("gives same, changed, missing and extra for the two clusters", function()
		local m = Model.listMatrix({ column("dev"), column("dev2") }, lists(), { policy = HIDE, maxPaths = 3 })
		expect(states(m)).toEqual({
			["tkm-api"] = { "base", "same" },
			["tkm-web"] = { "base", "changed" },
			["tkm-only-a"] = { "base", "missing" },
			["tkm-only-b"] = { "absent", "extra" },
		})
		for _, row in m.rows do
			if row.ref.name == "tkm-web" then
				expect(row.key).toBe("apps/Deployment/tern-test-mc/tkm-web")
				expect(row.cells[2].paths).toEqual({
					"metadata.labels.tier frontend -> (absent)",
					"spec.replicas 2 -> 3",
					"spec.template.spec.containers[web].image nginx:1.27-alpine -> nginx:1.28-alpine",
				})
			end
		end
		expect(m.rows[#m.rows].ref.name).toBe("tkm-only-b")
	end)

	it("shows pending and failed columns without guessing their cells", function()
		local columns = { column("dev"), column("dev2", "running"), column("down", "error") }
		columns[3].error = "connection refused"
		local m = Model.listMatrix(columns, { lists()[1], nil, nil }, { policy = HIDE, maxPaths = 3 })
		expect(m.rows[1].cells).toEqual({
			{ state = "base" },
			{ state = "pending" },
			{ state = "error", error = "connection refused" },
		})
		local noBase = Model.listMatrix(
			{ column("dev", "error"), column("dev2") },
			{ nil, lists()[2] },
			{ policy = HIDE, maxPaths = 3 }
		)
		expect(noBase.rows[1].cells[2].state).toBe("error")
	end)

	-- A list compare holds every object of every side in memory: above the
	-- budget the side is refused with a message, the base refuses the whole.
	it("refuses sides above max_objects", function()
		local columns = { column("dev"), column("dev2") }
		local over = Model.listMatrix(columns, lists(), { policy = HIDE, maxPaths = 3, maxObjects = 2 })
		expect(over.rows).toEqual({})
		expect(over.columns[1].status).toBe("error")
		expect(over.notes).toEqual({ "dev: 3 objects, above compare.max_objects (2)" })
		expect(columns[1].status).toBe("ok")
		local sides = lists()
		table.remove(sides[1] :: { any })
		local other = Model.listMatrix(columns, sides, { policy = HIDE, maxPaths = 3, maxObjects = 2 })
		expect(other.columns[2].error).toBe("3 objects, above compare.max_objects (2)")
		expect(other.rows[1].cells[2].state).toBe("error")
	end)
end)

describe("compare.model filter", function()
	local function matrix(): Model.Matrix
		local function row(name: string, states: { any }): Model.Row
			local cells = {}
			for _, s in states do
				table.insert(cells, { state = s })
			end
			return { key = name, ref = { kind = "Deployment", name = name, source = "live" }, cells = cells }
		end
		return {
			columns = { column("a"), column("b") },
			rows = {
				row("same", { "base", "same" }),
				row("changed", { "base", "changed" }),
				row("missing", { "base", "missing" }),
				row("extra", { "absent", "extra" }),
				row("insync", { "insync", "insync" }),
				row("unmanaged", { "unmanaged", "absent" }),
			},
			notes = {},
		}
	end

	local function names(m: Model.Matrix): { string }
		local out = {}
		for _, r in m.rows do
			table.insert(out, r.key)
		end
		return out
	end

	it("keeps differing rows or presence differences", function()
		expect(#Model.filter(matrix(), "all").rows).toBe(6)
		expect(names(Model.filter(matrix(), "differs"))).toEqual({ "changed", "missing", "extra", "unmanaged" })
		expect(names(Model.filter(matrix(), "presence"))).toEqual({ "missing", "extra", "unmanaged" })
	end)
end)

describe("compare.model queue", function()
	it("never runs more than max_parallel sides at once", function()
		expect(Model.queue({ "pending", "pending", "pending", "pending", "pending" }, 2)).toEqual({ 1, 2 })
		expect(Model.queue({ "ok", "running", "pending", "pending" }, 2)).toEqual({ 3 })
		expect(Model.queue({ "running", "running", "pending" }, 2)).toEqual({})
		expect(Model.queue({ "error", "ok", "pending" }, 4)).toEqual({ 3 })
	end)
end)

return nil
