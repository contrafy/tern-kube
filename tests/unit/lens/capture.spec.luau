--!strict
-- Captures built from real kubectl output. Ages, hashes and restart counts
-- change between fixture captures, so assertions stick to structure and
-- stable names.
local Capture = require("../../../plugin/lib/lens/capture")
local json = require("../../lib/json")
local runs = require("../../lib/runs")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function build(id: string): Capture.Capture
	local f = runs.load(id)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function fromLines(command: string, lines: { string }, status: number?): Capture.Capture
	return Capture.build(runs.run(command), lines, status, { decode = json.decode })
end

local function headersOf(c: Capture.Capture, i: number): { string }
	return (c.snapshot :: any).tables[i].headers
end

local function keysOf(c: Capture.Capture): { string }
	local out: { string } = {}
	for _, tbl in (c.snapshot :: any).tables do
		for _, row in tbl.rows do
			table.insert(out, row.key)
		end
	end
	return out
end

describe("lens capture", function()
	it("get pods -n: one Pod table, rows keyed by namespace and name", function()
		local c = build("ns-apps/get_pods")
		expect(c.mode).toBe("table")
		local snap = c.snapshot :: any
		expect(#snap.tables).toBe(1)
		expect(snap.tables[1].kind).toBe("Pod")
		expect(headersOf(c, 1)).toEqual({ "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
		expect(snap.tables[1].types).toEqual({ "text", "ratio", "status", "count", "duration" })
		expect(#snap.tables[1].rows).toBe(7)
		expect(table.find(keysOf(c), "/Pod/tern-test-apps/db-0") ~= nil).toBe(true)
		expect(snap.confidence).toBe("high")
		expect(c.unparsed).toBe(0)
	end)

	it("get pods -A takes each row's namespace from the NAMESPACE column", function()
		local c = build("all-namespaces/get_pods_-A")
		expect(headersOf(c, 1)[1]).toBe("NAMESPACE")
		local keys = keysOf(c)
		expect(table.find(keys, "/Pod/tern-test-apps/db-0") ~= nil).toBe(true)
		local kubeSystem = 0
		for _, k in keys do
			if string.find(k, "^/Pod/kube%-system/") then
				kubeSystem += 1
			end
		end
		expect(kubeSystem > 0).toBe(true)
	end)

	it("-o wide and --show-labels keep every column", function()
		local wide = build("ns-apps/get_pods_-o_wide")
		expect(headersOf(wide, 1)).toEqual({
			"NAME",
			"READY",
			"STATUS",
			"RESTARTS",
			"AGE",
			"IP",
			"NODE",
			"NOMINATED NODE",
			"READINESS GATES",
		})
		local labels = build("ns-apps/get_pods_--show-labels")
		local h = headersOf(labels, 1)
		expect(h[#h]).toBe("LABELS")
		expect(((labels.snapshot :: any).tables[1].rows[2].cells :: { string })[6]).toBe("app=crashloop")
	end)

	it("--no-headers gets kubectl's own column names for pods", function()
		local c = build("ns-apps/get_pods_--no-headers")
		expect(headersOf(c, 1)).toEqual({ "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
		expect(#(c.snapshot :: any).tables[1].rows).toBe(7)
		local all = build("all-namespaces/get_pods_-A_--no-headers")
		expect(headersOf(all, 1)[1]).toBe("NAMESPACE")
		expect(all.unparsed).toBe(0)
	end)

	it("--no-headers of an unknown kind numbers the columns instead of guessing", function()
		local c = fromLines("kubectl get widgets --no-headers", { "gizmo   blue   3", "sprocket   green   120" }, 0)
		expect(headersOf(c, 1)).toEqual({ "COLUMN 1", "COLUMN 2", "COLUMN 3" })
		expect(keysOf(c)).toEqual({ "t1#1", "t1#2" })
	end)

	it("get all: one table per kind, kind taken from the NAME prefix", function()
		local c = build("ns-apps/get_all")
		local kinds: { string } = {}
		for _, tbl in (c.snapshot :: any).tables do
			table.insert(kinds, tbl.kind)
		end
		expect(kinds).toEqual({ "Pod", "Service", "DaemonSet", "Deployment", "ReplicaSet", "StatefulSet" })
		local keys = keysOf(c)
		expect(table.find(keys, "apps/Deployment/tern-test-apps/web") ~= nil).toBe(true)
		expect(table.find(keys, "/Service/tern-test-apps/web") ~= nil).toBe(true)
		local first = (c.snapshot :: any).tables[1].rows[1]
		expect(string.sub(first.cells[1], 1, 4)).toBe("pod/")
		expect(first.ref.name).toBe(string.sub(first.cells[1], 5))
	end)

	it("multi-kind get deploy,rs,pods keys each table by its own kind", function()
		local c = build("ns-apps/get_deploy,rs,pods")
		local snap = c.snapshot :: any
		expect(#snap.tables).toBe(3)
		expect(snap.tables[1].kind).toBe("Deployment")
		expect(snap.tables[1].group).toBe("apps")
		expect(snap.tables[3].kind).toBe("Pod")
	end)

	it("CRD widgets: unknown kind keeps the typed resource and printer columns", function()
		local c = build("ns-crd/get_widgets")
		local snap = c.snapshot :: any
		expect(headersOf(c, 1)).toEqual({ "NAME", "COLOR", "SIZE", "DESCRIPTION", "AGE" })
		expect(snap.tables[1].types[3]).toBe("number")
		expect(table.find(keysOf(c), "/widgets/tern-test-crd/gizmo") ~= nil).toBe(true)
		-- The empty DESCRIPTION of sprocket is a cell, not a lost column.
		expect(snap.tables[1].rows[3].cells[4]).toBe("")
		expect(snap.tables[1].rows[3].cells[5] ~= "").toBe(true)
	end)

	it("-o json pods: summary rows, refs from the objects, objects reachable by key", function()
		local c = build("ns-apps/get_pods_-o_json")
		expect(c.mode).toBe("json")
		local snap = c.snapshot :: any
		expect(#snap.tables[1].rows).toBe(7)
		local key = "/Pod/tern-test-apps/db-0"
		expect(table.find(keysOf(c), key) ~= nil).toBe(true)
		local obj = (c.objects :: any)[key]
		expect(obj.metadata.name).toBe("db-0")
		expect(c.sensitive).toBe(false)
	end)

	it("-o json of a Secret masks values and flags the raw output as sensitive", function()
		local text =
			[[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s","namespace":"n"},"data":{"password":"aHVudGVyMg=="}}]]
		local c = fromLines("kubectl get secret s -n n -o json", { text }, 0)
		expect(c.sensitive).toBe(true)
		local obj = (c.objects :: any)["/Secret/n/s"]
		expect(string.find(obj.data.password, "redacted", 1, true) ~= nil).toBe(true)
	end)

	it("-o yaml of a Secret is redacted and sensitive", function()
		local c = build("ns-apps/get_secret_app-secret_-o_yaml")
		expect(c.mode).toBe("yaml")
		expect(c.sensitive).toBe(true)
		local joined = table.concat(c.yamlLines :: { string }, "\n")
		expect((string.find(joined, "tern-kube-test-not-a-secret", 1, true))).toBeNil()
	end)

	it("-o name: rows from kind/name lines", function()
		local c = build("ns-apps/get_pods_-o_name")
		expect(c.mode).toBe("name")
		local snap = c.snapshot :: any
		expect(snap.tables[1].kind).toBe("Pod")
		expect(#snap.tables[1].rows).toBe(7)
		expect(table.find(keysOf(c), "/Pod/tern-test-apps/crashloop") ~= nil).toBe(true)
	end)

	it("top pods and top nodes: quantity and percent columns, kind from the subcommand", function()
		local pods = build("ns-apps/top_pods")
		expect((pods.snapshot :: any).tables[1].kind).toBe("Pod")
		expect((pods.snapshot :: any).tables[1].types).toEqual({ "text", "quantity", "quantity" })
		local nodes = build("cluster/top_nodes")
		local tbl = (nodes.snapshot :: any).tables[1]
		expect(tbl.kind).toBe("Node")
		expect(tbl.types).toEqual({ "text", "quantity", "percent", "quantity", "percent" })
		-- Nodes are cluster-scoped: no namespace in the key.
		expect(tbl.rows[1].key).toBe("/Node//tern-kube-dev-control-plane")
	end)

	it("error-only output: no tables, one error diagnostic, exit status kept", function()
		local c = build("errors/get_foos")
		expect(c.mode).toBe("table")
		expect(#(c.snapshot :: any).tables).toBe(0)
		expect(#c.diagnostics).toBe(1)
		expect(c.diagnostics[1].severity).toBe("error")
		expect(c.status).toBe(1)
	end)

	it("partial NotFound keeps the found rows and the error", function()
		local c = build("errors/get_pods_does-not-exist_crashloop")
		expect(#keysOf(c)).toBe(1)
		expect(c.diagnostics[1].severity).toBe("error")
	end)

	it("No resources found is an info diagnostic, not an unparsed line", function()
		local c = build("ns-empty/get_pods")
		expect(#(c.snapshot :: any).tables).toBe(0)
		expect(c.diagnostics[1].severity).toBe("info")
		expect(c.unparsed).toBe(0)
	end)

	it("unrecognised lines make the capture partial", function()
		local f = runs.load("ns-apps/get_pods")
		local lines = table.clone(f.lines)
		table.insert(lines, "   stray text  that fits no column")
		local c = Capture.build(f.run, lines, 0, { decode = json.decode })
		expect(c.unparsed > 0).toBe(true)
		expect((c.snapshot :: any).confidence).toBe("partial")
	end)

	it("unsupported commands are raw with kubectl's reason (watch, jsonpath, logs)", function()
		for _, command in
			{ "kubectl get pods -w", "kubectl get pods -o jsonpath={.items}", "kubectl -n x logs pod get" }
		do
			local c = fromLines(command, { "NAME   READY", "a      1/1" }, 0)
			expect(c.mode).toBe("raw")
			expect(type(c.support.reason)).toBe("string")
		end
	end)

	it("drops the ^C a watch leaves when interrupted", function()
		local c = fromLines("kubectl get pods", { "NAME   READY", "a      1/1", "^C" }, 130)
		expect(c.lineCount).toBe(2)
		expect(c.unparsed).toBe(0)
	end)

	it("describe, mutation and yaml commands pick their modes", function()
		expect(build("ns-apps/describe_pod_crashloop").mode).toBe("describe")
		expect(build("mutate-ops/scale_deployment+api_--replicas=3").mode).toBe("mutation")
		expect(build("mutate-ops/rollout_restart_deployment+api").mode).toBe("mutation")
		expect(build("ns-apps/get_pods_-o_yaml").mode).toBe("yaml")
		expect(Capture.modeOf(runs.run("kubectl --context x describe pod a"))).toBe("describe")
	end)

	it("row keys are unique even when kubectl prints the same name twice", function()
		local c = fromLines("kubectl get pods", { "NAME   READY", "a      1/1", "a      0/1" }, 0)
		expect(keysOf(c)).toEqual({ "/Pod//a", "/Pod//a#2" })
	end)

	it("refs carry the command's --context", function()
		local c = fromLines("kubectl --context prod -n web get pods", { "NAME   READY", "a      1/1" }, 0)
		local row = (c.snapshot :: any).tables[1].rows[1]
		expect(row.ref.clusterContext).toBe("prod")
		expect(row.ref.namespace).toBe("web")
	end)
end)

describe("lens capture of an alias program", function()
	-- bash/fish report `k get pods` as typed when `k` is a claimed alias.
	it("builds the same capture as kubectl", function()
		local f = runs.load("ns-apps/get_pods")
		local viaAlias = { program = "k", args = f.run.args }
		local c = Capture.build(viaAlias, f.lines, f.status, { decode = json.decode })
		local ref = build("ns-apps/get_pods")
		expect(Capture.modeOf(viaAlias)).toBe(Capture.modeOf(f.run))
		expect(c.mode).toBe(ref.mode)
		expect(keysOf(c)).toEqual(keysOf(ref))
		expect(c.invocation.program).toBe("k")
	end)
end)

describe("lens capture redaction policy", function()
	local SHOW = { showSecrets = true, strict = false }
	local STRICT = { showSecrets = false, strict = true }
	local SECRET_JSON =
		[[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"s","namespace":"n"},"data":{"password":"aHVudGVyMg=="}}]]

	local function withPolicy(command: string, lines: { string }, policy: any): Capture.Capture
		return Capture.build(runs.run(command), lines, 0, { decode = json.decode, policy = policy })
	end

	local function fixture(id: string, policy: any): Capture.Capture
		local f = runs.load(id)
		return Capture.build(f.run, f.lines, f.status, { decode = json.decode, policy = policy })
	end

	it("defaults to masking and records the policy it used", function()
		local c = fromLines("kubectl get secret s -n n -o json", { SECRET_JSON }, 0)
		expect(c.policy).toEqual({ showSecrets = false, strict = false })
		expect(c.masked).toBe(true)
		expect(c.sensitive).toBe(true)
	end)

	it("a plain table capture hides nothing", function()
		expect(build("ns-apps/get_pods").masked).toBe(false)
	end)

	-- sensitive keeps describing the raw output; masked describes the view.
	it("shows Secret values in -o json when the policy allows it", function()
		local c = withPolicy("kubectl get secret s -n n -o json", { SECRET_JSON }, SHOW)
		expect(c.sensitive).toBe(true)
		expect(c.masked).toBe(false)
		expect((c.objects :: any)["/Secret/n/s"].data.password).toBe("aHVudGVyMg==")
	end)

	it("shows Secret values in -o yaml when the policy allows it", function()
		local c = fixture("ns-apps/get_secret_app-secret_-o_yaml", SHOW)
		expect(c.sensitive).toBe(true)
		expect(c.masked).toBe(false)
		expect(c.yamlLines).toEqual(c.lines)
		expect(fixture("ns-apps/get_secret_app-secret_-o_yaml", nil).masked).toBe(true)
	end)

	it("strict mode masks sensitive env values in -o json", function()
		local pod = [[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"p","namespace":"n"},
			"spec":{"containers":[{"name":"app","env":[{"name":"DB_PASSWORD","value":"hunter2"},
			{"name":"tokenizer_mode","value":"fast"}]}]}}]]
		local c = withPolicy("kubectl get pod p -n n -o json", { pod }, STRICT)
		local env = (c.objects :: any)["/Pod/n/p"].spec.containers[1].env
		expect(env[1].value).toBe("<redacted: 7 bytes>")
		expect(env[2].value).toBe("fast")
		expect(c.masked).toBe(true)
		expect(c.sensitive).toBe(false)
	end)

	it("strict mode masks sensitive values in -o yaml", function()
		local lines = {
			"apiVersion: v1",
			"data:",
			"  LOG_LEVEL: info",
			"  api_key: abc123",
			"kind: ConfigMap",
			"metadata:",
			"  name: c",
		}
		local c = withPolicy("kubectl get cm c -o yaml", lines, STRICT)
		expect((c.yamlLines :: { string })[3]).toBe("  LOG_LEVEL: info")
		expect((c.yamlLines :: { string })[4]).toBe("  api_key: '<redacted: 6 bytes>'")
		expect(c.masked).toBe(true)
		expect(withPolicy("kubectl get cm c -o yaml", lines, nil).masked).toBe(false)
	end)

	local DESCRIBE_POD = {
		"Name:             web-1",
		"Namespace:        apps",
		"Containers:",
		"  app:",
		"    Image:          busybox",
		"    Environment:",
		"      DB_PASSWORD:      hunter2",
		"      API_TOKEN:        <set to the key 'token' in secret 'creds'>  Optional: false",
		"      LOG_LEVEL:        info",
		"      tokenizer_mode:   fast",
		"    Mounts:         <none>",
		"Volumes:",
		"  creds:",
		"    Type:        Secret (a volume populated by a Secret)",
		"    SecretName:  creds",
		"Events:  <none>",
	}

	local function envOf(c: Capture.Capture): { [string]: string }
		local out: { [string]: string } = {}
		local obj = (c.describe :: any).objects[1]
		local function walk(fields: { any })
			for _, f in fields do
				out[f.key] = f.value
				walk(f.children)
			end
		end
		walk(obj.fields)
		return out
	end

	it("strict mode masks describe env values but not references or unrelated names", function()
		local c = withPolicy("kubectl describe pod web-1 -n apps", DESCRIBE_POD, STRICT)
		local f = envOf(c)
		expect(f.DB_PASSWORD).toBe("<redacted: 7 bytes>")
		expect(f.API_TOKEN).toBe("<set to the key 'token' in secret 'creds'>  Optional: false")
		expect(f.LOG_LEVEL).toBe("info")
		expect(f.tokenizer_mode).toBe("fast")
		expect(f.SecretName).toBe("creds")
		expect(c.masked).toBe(true)
		local plain = withPolicy("kubectl describe pod web-1 -n apps", DESCRIBE_POD, nil)
		expect(envOf(plain).DB_PASSWORD).toBe("hunter2")
		expect(plain.masked).toBe(false)
	end)

	-- describe prints ConfigMap data as `key:` / `----` / value lines.
	it("strict mode masks describe ConfigMap data under sensitive keys", function()
		local lines = {
			"Name:         app-config",
			"Namespace:    apps",
			"Labels:       <none>",
			"Annotations:  <none>",
			"",
			"Data",
			"====",
			"db_password:",
			"----",
			"s3cr3t",
			"more",
			"LOG_LEVEL:",
			"----",
			"info",
			"",
			"BinaryData",
			"====",
			"",
			"Events:  <none>",
		}
		local c = withPolicy("kubectl describe cm app-config -n apps", lines, STRICT)
		local values: { string } = {}
		for _, f in (c.describe :: any).objects[1].fields do
			if f.key == "" and f.table == nil then
				table.insert(values, f.value)
			end
		end
		expect(values).toEqual({ "Data", "====", "<redacted: 11 bytes>", "info", "BinaryData", "====" })
		expect(c.masked).toBe(true)
	end)

	-- describe never prints Secret values, only sizes; masking those hides nothing.
	it("strict mode leaves describe Secret byte counts alone", function()
		local lines =
			{ "Name:         s", "Namespace:    n", "", "Type:  Opaque", "", "Data", "====", "password:  12 bytes" }
		local c = withPolicy("kubectl describe secret s -n n", lines, STRICT)
		expect(c.masked).toBe(false)
	end)
end)

return nil
