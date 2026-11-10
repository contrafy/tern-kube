--!strict
-- Helm argv builders. Every cluster call pins --kube-context (and
-- --kubeconfig when it is one file) so a `kubectl config use-context` in the
-- user's shell can never point Explore or a rollback at another cluster, and
-- release names that reach argv can never be read as flags.
local Query = require("../../../plugin/lib/helm/query")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local TARGET: Query.Target = { kubeconfig = "/k/config", context = "kind-dev" }
local KEY: Query.Key = { name = "shop-a", namespace = "apps" }
local PINS = { "helm", "--kube-context", "kind-dev", "--kubeconfig", "/k/config" }

local function pinned(...: string): { string }
	local out = table.clone(PINS)
	for _, a in { ... } do
		table.insert(out, a)
	end
	return out
end

local OPTS: Query.RollbackOptions = {
	wait = false,
	waitForJobs = false,
	cleanupOnFail = false,
	force = false,
	noHooks = false,
	timeoutS = 240,
}

local function opts(over: { [string]: any }): Query.RollbackOptions
	local o = table.clone(OPTS)
	for k, v in over do
		(o :: any)[k] = v
	end
	return o
end

describe("helm query pins", function()
	it("puts --kube-context right after the program, then a single-file --kubeconfig", function()
		expect(Query.base("helm", TARGET)).toEqual(PINS)
		expect(Query.base("helm", { context = "kind-dev" })).toEqual({ "helm", "--kube-context", "kind-dev" })
	end)

	-- helm's --kubeconfig takes one file; a KUBECONFIG list goes through env.
	it("keeps a kubeconfig path list out of argv and in the environment", function()
		local list = "/a/config:/b/config"
		expect(Query.base("helm", { kubeconfig = list, context = "c" })).toEqual({ "helm", "--kube-context", "c" })
		expect(Query.env("secret", list)).toEqual({ HELM_DRIVER = "secret", KUBECONFIG = list })
		expect(Query.env("configmap", "/k/config")).toEqual({ HELM_DRIVER = "configmap" })
		expect(Query.env("secret", nil)).toEqual({ HELM_DRIVER = "secret" })
	end)

	-- Without a context helm would use current-context: refuse instead.
	it("refuses to build a cluster call without a context", function()
		expect(function()
			Query.base("helm", { kubeconfig = "/k/config" })
		end).toThrow("context")
		expect(function()
			Query.base("helm", { context = "" })
		end).toThrow("context")
	end)

	it("pins every cluster builder", function()
		local all = {
			Query.list("helm", TARGET, { all = true }, 10),
			Query.owner("helm", TARGET, KEY),
			Query.history("helm", TARGET, KEY, nil),
			Query.status("helm", TARGET, KEY, nil),
			Query.extras("helm", TARGET, KEY, 1),
			Query.valuesAll("helm", TARGET, KEY, 1),
			Query.rollback("helm", TARGET, KEY, 1, OPTS, false),
		}
		for _, argv in all do
			expect({ table.unpack(argv, 1, #PINS) }).toEqual(PINS)
		end
	end)
end)

describe("helm query verbs", function()
	-- Helm 4 removed `-a/--all` (and lists every status by default); Helm 3
	-- without it lists only deployed and failed releases. The explicit
	-- status flags mean "every status" in both majors.
	it("lists every status in one namespace or all of them, with RFC 3339 times", function()
		local statuses = Query.LIST_STATUSES
		expect(statuses).toEqual({
			"--deployed",
			"--failed",
			"--pending",
			"--superseded",
			"--uninstalled",
			"--uninstalling",
		})
		local function listArgv(...: string): { string }
			local argv = { "list" }
			table.move(statuses, 1, #statuses, 2, argv)
			for _, a in { ... } do
				table.insert(argv, a)
			end
			return pinned(table.unpack(argv))
		end
		expect(Query.list("helm", TARGET, { namespace = "apps", all = false }, 1000)).toEqual(
			listArgv("-o", "json", "--time-format", Query.TIME_FORMAT, "--max", "1000", "-n", "apps")
		)
		expect(Query.list("helm", TARGET, { namespace = "apps", all = true }, 5)).toEqual(
			listArgv("-o", "json", "--time-format", Query.TIME_FORMAT, "--max", "5", "-A")
		)
		for _, argv in { Query.list("helm", TARGET, { all = true }, 5), Query.owner("helm", TARGET, KEY) } do
			expect(table.find(argv, "-a")).toBeNil()
			expect(table.find(argv, "--all")).toBeNil()
		end
		expect(Query.TIME_FORMAT).toBe("2006-01-02T15:04:05Z07:00")
	end)

	-- --filter is a regexp: `web.b` would also match `web-b`.
	it("looks up one release by an anchored, escaped filter", function()
		local want = { "list", "-n", "apps" }
		table.move(Query.LIST_STATUSES, 1, #Query.LIST_STATUSES, #want + 1, want)
		for _, a in { "-o", "json", "--time-format", Query.TIME_FORMAT, "--filter", "^web\\.b$" } do
			table.insert(want, a)
		end
		expect(Query.owner("helm", TARGET, { name = "web.b", namespace = "apps" })).toEqual(pinned(table.unpack(want)))
		expect(Query.regexpQuote("a.b-c")).toBe("a\\.b-c")
		expect(Query.regexpQuote("x+(y)")).toBe("x\\+\\(y\\)")
	end)

	it("reads history, status, values and the stored release by revision", function()
		expect(Query.history("helm", TARGET, KEY, nil)).toEqual(pinned("history", "shop-a", "-n", "apps", "-o", "json"))
		expect(Query.history("helm", TARGET, KEY, 256)).toEqual(
			pinned("history", "shop-a", "-n", "apps", "-o", "json", "--max", "256")
		)
		expect(Query.status("helm", TARGET, KEY, nil)).toEqual(pinned("status", "shop-a", "-n", "apps", "-o", "json"))
		expect(Query.status("helm", TARGET, KEY, 3)).toEqual(
			pinned("status", "shop-a", "-n", "apps", "--revision", "3", "-o", "json")
		)
		expect(Query.valuesAll("helm", TARGET, KEY, 2)).toEqual(
			pinned("get", "values", "shop-a", "-n", "apps", "--revision", "2", "--all", "-o", "json")
		)
		expect(Query.extras("helm", TARGET, KEY, 2)).toEqual(
			pinned("get", "all", "shop-a", "-n", "apps", "--revision", "2", "--template", Query.EXTRAS_TEMPLATE)
		)
	end)

	-- Only what the user supplied: the drift render of a repo chart with the
	-- deployed values must still take its defaults from the repo's values.yaml.
	it("reads the user-supplied values without chart defaults", function()
		expect(Query.values("helm", TARGET, KEY, nil)).toEqual(
			pinned("get", "values", "shop-a", "-n", "apps", "-o", "json")
		)
		expect(Query.values("helm", TARGET, KEY, 3)).toEqual(
			pinned("get", "values", "shop-a", "-n", "apps", "--revision", "3", "-o", "json")
		)
	end)

	-- The parser checks this tag; a template change must bump it.
	it("tags the extras template output with its format version", function()
		expect(Query.EXTRAS_TEMPLATE).toContain('{"format":"tern-kube/helm-extras/v1"')
		expect(Query.EXTRAS_FORMAT).toBe("tern-kube/helm-extras/v1")
		expect(Query.EXTRAS_TEMPLATE).toContain('"defaults":{{ template "j" $r.Chart.Values }}')
	end)

	-- The parser specs run on captures of this template; a template change
	-- without a recapture (scripts/fixtures/capture-helm.sh) must fail here.
	it("is the template the captured extras fixtures were recorded with", function()
		expect(fixtures.read("helm/captured/extras.tpl")).toBe(Query.EXTRAS_TEMPLATE .. "\n")
		local files = fixtures.list("helm/captured/extras-")
		expect(#files).toBe(11)
		for _, f in files do
			local head = '{"format":"' .. Query.EXTRAS_FORMAT .. '",'
			expect(string.sub(fixtures.read(f), 1, #head)).toBe(head)
		end
	end)

	-- Hooks are not release objects: a pre-upgrade hook never exists after
	-- an install, so a render with hooks reports it as missing forever and
	-- an apply bundle would create it as a plain object.
	it("renders a chart offline, without cluster flags or hooks", function()
		expect(Query.template("helm", "shop", "/repo/chart", "apps", { "/repo/a.yaml", "/repo/b.yaml" })).toEqual({
			"helm",
			"template",
			"shop",
			"/repo/chart",
			"--no-hooks",
			"-n",
			"apps",
			"-f",
			"/repo/a.yaml",
			"-f",
			"/repo/b.yaml",
		})
		expect(Query.template("helm", "shop", "/repo/chart", nil, {})).toEqual({
			"helm",
			"template",
			"shop",
			"/repo/chart",
			"--no-hooks",
		})
	end)
end)

describe("helm rollback argv", function()
	-- --timeout also bounds hooks when --wait is off, so it is always pinned.
	it("always pins the timeout and adds options in a fixed order", function()
		expect(Query.rollback("helm", TARGET, KEY, 1, OPTS, false)).toEqual(
			pinned("rollback", "shop-a", "1", "-n", "apps", "--timeout", "240s")
		)
		local all = opts({ wait = true, waitForJobs = true, cleanupOnFail = true, force = true, noHooks = true })
		expect(Query.rollback("helm", TARGET, KEY, 7, all, true)).toEqual(
			pinned(
				"rollback",
				"shop-a",
				"7",
				"-n",
				"apps",
				"--timeout",
				"240s",
				"--wait",
				"--wait-for-jobs",
				"--cleanup-on-fail",
				"--force",
				"--no-hooks",
				"--dry-run"
			)
		)
	end)

	-- helm ignores --wait-for-jobs without --wait.
	it("drops --wait-for-jobs when --wait is off", function()
		expect(Query.rollback("helm", TARGET, KEY, 1, opts({ waitForJobs = true }), false)).toEqual(
			pinned("rollback", "shop-a", "1", "-n", "apps", "--timeout", "240s")
		)
	end)
end)

describe("helm name validation", function()
	it("accepts helm's release names up to 53 characters", function()
		for _, name in { "a", "shop-a", "web.b", "x1.y-2.z", string.rep("a", 53) } do
			expect(Query.validRelease(name) and name or "rejected " .. name).toBe(name)
		end
	end)

	-- A name starting with `-` would be parsed as a flag.
	it("rejects flags, uppercase, empty segments and long names", function()
		for _, name in
			{
				"",
				"-flag",
				"--dry-run",
				"Shop",
				"shop_a",
				"shop-",
				"a..b",
				".a",
				"a.",
				"a.-b",
				"a b",
				string.rep("a", 54),
			}
		do
			expect(Query.validRelease(name) and "accepted " .. name or name).toBe(name)
		end
	end)

	it("accepts integer revisions 1..999999 only", function()
		expect(Query.validRevision(1)).toBe(true)
		expect(Query.validRevision(999999)).toBe(true)
		expect(Query.validRevision(0)).toBe(false)
		expect(Query.validRevision(-1)).toBe(false)
		expect(Query.validRevision(1.5)).toBe(false)
		expect(Query.validRevision(1000000)).toBe(false)
		expect(Query.validRevision(0 / 0)).toBe(false)
		expect(Query.validRevision(math.huge)).toBe(false)
	end)
end)

return nil
