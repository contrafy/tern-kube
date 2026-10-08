--!strict
local Yaml = require("../../../plugin/lib/parse/yaml")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function text(lines: { string }): string
	return table.concat(lines, "\n")
end

local function identities(docs: { Yaml.Doc }): { string }
	local out = {}
	for _, d in docs do
		local id =
			string.format("%d-%d %s %s %s", d.startLine, d.endLine, d.kind or "-", d.name or "-", d.namespace or "-")
		table.insert(out, id)
	end
	return out
end

local LIST = {
	"apiVersion: v1", -- 1
	"items:", -- 2
	"- apiVersion: v1", -- 3
	"  kind: Pod", -- 4
	"  metadata:", -- 5
	"    annotations:", -- 6
	"      note: |", -- 7
	"        kind: Fake", -- 8
	"        name: nope", -- 9
	"    name: api-1", -- 10
	"    namespace: default", -- 11
	"  spec:", -- 12
	"    containers:", -- 13
	"    - name: api", -- 14
	"      env:", -- 15
	"      - name: X", -- 16
	'        value: "kind: Bogus"', -- 17
	"  extra:", -- 18
	"  - apiVersion: apps/v1", -- 19
	"    kind: ReplicaSet", -- 20
	"    name: api", -- 21
	"- apiVersion: apps/v1", -- 22
	"  kind: Deployment", -- 23
	"  metadata:", -- 24
	'    name: "web"', -- 25
	"    namespace: shop", -- 26
	"kind: List", -- 27
	"metadata:", -- 28
	'  resourceVersion: ""', -- 29
}

describe("yaml.split kubectl -o yaml lists", function()
	local result = Yaml.split(text(LIST))

	it("splits each item of a List into its own document", function()
		expect(identities(result.docs)).toEqual({
			"3-21 Pod api-1 default",
			"22-26 Deployment web shop",
		})
		expect(result.diagnostics).toEqual({})
	end)

	-- Nested block scalars, sequences and quoted values contain text that looks
	-- like identity keys; only the object's own top-level keys count.
	it("ignores key-like lines nested inside the item", function()
		expect(result.docs[1].kind).toBe("Pod")
		expect(result.docs[1].name).toBe("api-1")
	end)

	it("builds refs with group and version for actions", function()
		expect(result.docs[2].ref).toEqual({
			group = "apps",
			version = "v1",
			kind = "Deployment",
			name = "web",
			namespace = "shop",
			source = "snapshot",
		})
		expect(result.docs[1].indent).toBe(2)
	end)

	it("treats an empty List as no documents", function()
		local r =
			Yaml.split(text({ "apiVersion: v1", "items: []", "kind: List", "metadata:", '  resourceVersion: ""' }))
		expect(r.docs).toEqual({})
		expect(r.diagnostics).toEqual({})
	end)

	it("handles indented sequences under items", function()
		local r = Yaml.split(text({
			"kind: List",
			"items:",
			"  - kind: Pod",
			"    metadata: {name: a}",
			"  - kind: Pod",
			"    metadata:",
			"      name: b",
		}))
		expect(identities(r.docs)).toEqual({ "3-4 Pod a -", "5-7 Pod b -" })
	end)

	it("splits a single object as one document", function()
		local r = Yaml.split(text({ "apiVersion: v1", "kind: Pod", "metadata:", "  name: p", "  namespace: x" }))
		expect(identities(r.docs)).toEqual({ "1-5 Pod p x" })
	end)
end)

local MANIFEST = {
	"# leading comment", -- 1
	"---", -- 2
	"apiVersion: v1", -- 3
	"kind: ConfigMap", -- 4
	"metadata:", -- 5
	"  name: settings  # trailing comment", -- 6
	"  namespace: 'team-a'", -- 7
	"data:", -- 8
	"  script: |", -- 9
	"    ---", -- 10
	"    kind: Secret", -- 11
	"    metadata:", -- 12
	"      name: fake", -- 13
	"  other: >-", -- 14
	"    apiVersion: x", -- 15
	"", -- 16
	"--- # second", -- 17
	"apiVersion: apps/v1", -- 18
	"kind: Deployment", -- 19
	'metadata: {name: web, namespace: "shop", labels: {app: web}}', -- 20
	"spec:", -- 21
	"  replicas: 1", -- 22
	"...", -- 23
	"---", -- 24
	"# only comments", -- 25
	"---", -- 26
	'"apiVersion": v1', -- 27
	"kind: Service # svc", -- 28
	"metadata:", -- 29
	"  generateName: svc-", -- 30
	"---", -- 31
	"apiVersion: v1", -- 32
	"metadata:", -- 33
	"  name: kindless", -- 34
}

describe("yaml.split multi-document manifests", function()
	local result = Yaml.split(text(MANIFEST))

	it("splits on --- (with trailing comments) and ... and skips comment-only documents", function()
		expect(identities(result.docs)).toEqual({
			"3-15 ConfigMap settings team-a",
			"18-22 Deployment web shop",
			"27-30 Service - -",
			"32-34 - kindless -",
		})
	end)

	it("is not fooled by separators and keys inside block scalars", function()
		expect(result.docs[1].kind).toBe("ConfigMap")
		expect(result.docs[1].endLine).toBe(15)
	end)

	-- generateName objects are applied but cannot be addressed before creation.
	it("gives no ref to documents without a name and flags documents without a kind", function()
		expect(result.docs[3].ref).toBeNil()
		expect(result.docs[4].ref).toBeNil()
		expect(result.diagnostics).toEqual({
			{ line = 32, severity = "warning", text = "document at line 32 has no kind" },
		})
	end)

	it("reports multi-line flow metadata as unsupported instead of guessing", function()
		local r = Yaml.split(text({ "kind: Pod", "metadata: {name: a,", "  namespace: b}" }))
		expect(r.docs[1].kind).toBe("Pod")
		expect(r.docs[1].name).toBeNil()
		expect(r.diagnostics[1].severity).toBe("warning")
		expect(r.diagnostics[1].line).toBe(2)
	end)

	it("unquotes single- and double-quoted scalars and tolerates CRLF", function()
		local r = Yaml.split('kind: "Pod"\r\nmetadata:\r\n  name: \'it\'\'s\'\r\n  namespace: "a\\"b"\r\n')
		expect(identities(r.docs)).toEqual({ "1-4 Pod it's a\"b" })
	end)

	-- stderr lines are interleaved into the capture.
	it("moves stderr lines out of documents into diagnostics", function()
		local r = Yaml.split(text({
			"Warning: v1 ComponentStatus is deprecated in v1.19+",
			"apiVersion: v1",
			"kind: ComponentStatus",
			"metadata:",
			"  name: scheduler",
			'Error from server (NotFound): pods "x" not found',
		}))
		expect(identities(r.docs)).toEqual({ "2-5 ComponentStatus scheduler -" })
		expect(r.diagnostics).toEqual({
			{ line = 1, severity = "warning", text = "Warning: v1 ComponentStatus is deprecated in v1.19+" },
			{ line = 6, severity = "error", text = 'Error from server (NotFound): pods "x" not found' },
		})
	end)
end)

local SECRETS = {
	"apiVersion: v1", -- 1
	"items:", -- 2
	"- apiVersion: v1", -- 3
	"  data:", -- 4
	"    password: aHVudGVyMg==", -- 5
	'    user: "YWRtaW4="', -- 6
	"  kind: Secret", -- 7
	"  metadata:", -- 8
	"    annotations:", -- 9
	"      kubectl.kubernetes.io/last-applied-configuration: |", -- 10
	'        {"data":{"password":"aHVudGVyMg=="}}', -- 11
	"      team: data", -- 12
	"    name: db", -- 13
	"  stringData:", -- 14
	"    cert: |", -- 15
	"      line-one", -- 16
	"      line-two", -- 17
	"    token: abc", -- 18
	"  type: Opaque", -- 19
	"- apiVersion: v1", -- 20
	"  data:", -- 21
	"    password: plain", -- 22
	"  kind: ConfigMap", -- 23
	"  metadata:", -- 24
	"    name: settings", -- 25
	"kind: List", -- 26
}

describe("yaml.redact", function()
	local split = Yaml.split(text(SECRETS))
	local shown = Yaml.redact(SECRETS, split.docs)

	it("keeps line numbering so rows and docs still map onto Raw", function()
		expect(#shown).toBe(#SECRETS)
	end)

	it("masks Secret data values with their base64 size", function()
		expect(shown[5]).toBe("    password: '<redacted: 12 bytes base64>'")
		expect(shown[6]).toBe("    user: '<redacted: 8 bytes base64>'")
	end)

	it("masks stringData including block scalars", function()
		expect(shown[15]).toBe("    cert: '<redacted: 17 bytes>'")
		expect(shown[16]).toBe("")
		expect(shown[17]).toBe("")
		expect(shown[18]).toBe("    token: '<redacted: 3 bytes>'")
	end)

	it("masks the last-applied annotation, which embeds the secret verbatim", function()
		expect(shown[10]).toBe("      kubectl.kubernetes.io/last-applied-configuration: '<redacted: 36 bytes>'")
		expect(shown[11]).toBe("")
		expect(shown[12]).toBe("      team: data")
	end)

	it("leaves keys, structure and non-secret fields visible", function()
		for _, i in { 1, 2, 3, 4, 7, 8, 9, 13, 14, 19, 26 } do
			expect(shown[i]).toBe(SECRETS[i])
		end
	end)

	it("never masks ConfigMap data by default", function()
		expect(shown[22]).toBe("    password: plain")
	end)

	it("does not modify the input lines", function()
		expect(SECRETS[5]).toBe("    password: aHVudGVyMg==")
	end)

	it("masks a single Secret object and data given in flow style", function()
		local lines = { "apiVersion: v1", "data: {a: YQ==}", "kind: Secret", "metadata:", "  name: s" }
		local out = Yaml.redact(lines, Yaml.split(text(lines)).docs)
		expect(out[2]).toBe("data: '<redacted: 9 bytes>'")
		local empty = { "kind: Secret", "data: {}", "metadata:", "  name: s" }
		expect(Yaml.redact(empty, Yaml.split(text(empty)).docs)[2]).toBe("data: {}")
	end)

	it("masks a data entry written on the item's dash line", function()
		local lines =
			{ "items:", "- data:", "    k: dg==", "  kind: Secret", "  metadata:", "    name: s", "kind: List" }
		local out = Yaml.redact(lines, Yaml.split(text(lines)).docs)
		expect(out[2]).toBe("- data:")
		expect(out[3]).toBe("    k: '<redacted: 4 bytes base64>'")
	end)
end)

describe("yaml.redact with show_secret_values", function()
	-- The user opted in: the YAML view shows Secrets exactly as kubectl printed them.
	it("leaves Secret data and the last-applied annotation visible", function()
		local shown = Yaml.redact(SECRETS, Yaml.split(text(SECRETS)).docs, { showSecrets = true, strict = false })
		expect(shown).toEqual(SECRETS)
	end)
end)

local POD = {
	"apiVersion: v1", -- 1
	"kind: Pod", -- 2
	"metadata:", -- 3
	"  annotations:", -- 4
	"    kubectl.kubernetes.io/last-applied-configuration: |", -- 5
	'      {"env":[{"name":"DB_PASSWORD","value":"hunter2"}]}', -- 6
	"  name: web", -- 7
	"spec:", -- 8
	"  containers:", -- 9
	"  - env:", -- 10
	"    - name: DB_PASSWORD", -- 11
	"      value: hunter2", -- 12
	"    - name: tokenizer_mode", -- 13
	"      value: fast", -- 14
	"    - name: API_TOKEN", -- 15
	"      valueFrom:", -- 16
	"        secretKeyRef:", -- 17
	"          key: token", -- 18
	"          name: creds", -- 19
	"    - name: GITHUB_TOKEN", -- 20
	'      value: "ghp_abc"', -- 21
	"    name: app", -- 22
	"  volumes:", -- 23
	"  - name: creds", -- 24
	"    secret:", -- 25
	"      secretName: creds", -- 26
	"---", -- 27
	"apiVersion: v1", -- 28
	"kind: ConfigMap", -- 29
	"data:", -- 30
	"  LOG_LEVEL: info", -- 31
	"  db_password: |", -- 32
	"    s3cr3t", -- 33
	"metadata:", -- 34
	"  name: settings", -- 35
}

describe("yaml.redact strict mode", function()
	local STRICT = { showSecrets = false, strict = true }
	local shown = Yaml.redact(POD, Yaml.split(text(POD)).docs, STRICT)

	it("masks env values whose name looks sensitive", function()
		expect(shown[12]).toBe("      value: '<redacted: 7 bytes>'")
		expect(shown[21]).toBe("      value: '<redacted: 7 bytes>'")
	end)

	it("masks mapping values under sensitive keys, block scalars included", function()
		expect(shown[32]).toBe("  db_password: '<redacted: 6 bytes>'")
		expect(shown[33]).toBe("")
	end)

	-- The annotation repeats the manifest, so it would leak the env value.
	it("masks the last-applied annotation of a document it masked", function()
		expect(shown[5]).toBe("    kubectl.kubernetes.io/last-applied-configuration: '<redacted: 50 bytes>'")
		expect(shown[6]).toBe("")
	end)

	it("leaves unrelated names, Secret references and structure visible", function()
		for _, i in { 1, 2, 3, 4, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 22, 24, 25, 26, 27, 30, 31, 34, 35 } do
			expect(shown[i]).toBe(POD[i])
		end
	end)

	it("changes nothing when strict mode is off", function()
		expect(Yaml.redact(POD, Yaml.split(text(POD)).docs)).toEqual(POD)
	end)

	it("still masks when Secret values are shown", function()
		local both = Yaml.redact(POD, Yaml.split(text(POD)).docs, { showSecrets = true, strict = true })
		expect(both[12]).toBe("      value: '<redacted: 7 bytes>'")
	end)
end)

describe("yaml.split performance", function()
	it("splits a 1000-item List quickly", function()
		local lines = { "apiVersion: v1", "items:" }
		for i = 1, 1000 do
			for _, line in
				{
					"- apiVersion: v1",
					"  kind: Pod",
					"  metadata:",
					"    labels:",
					"      app: demo",
					"    name: pod-" .. i,
					"    namespace: ns",
					"  spec:",
					"    containers:",
					"    - image: example/demo:1",
					"      name: demo",
					"  status:",
					"    phase: Running",
				}
			do
				table.insert(lines, line)
			end
		end
		table.insert(lines, "kind: List")
		local source = text(lines)
		local started = os.clock()
		local r = Yaml.split(source)
		local shown = Yaml.redact(Yaml.lines(source), r.docs)
		local elapsed = os.clock() - started
		expect(#r.docs).toBe(1000)
		expect(r.docs[1000].name).toBe("pod-1000")
		expect(#shown).toBe(#lines)
		expect(elapsed < 0.2).toBe(true)
		started = os.clock()
		Yaml.redact(Yaml.lines(source), r.docs, { showSecrets = false, strict = true })
		expect(os.clock() - started < 0.2).toBe(true)
	end)
end)

return nil
