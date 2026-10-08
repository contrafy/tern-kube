--!strict
-- Per-resource segmentation of `kubectl diff`. The approval block shows one
-- expandable diff per object and an aggregate create/modify/delete count, so
-- a mis-split (a line attributed to the wrong object, a create counted as a
-- modify) would misstate what the user is approving.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function brief(summary: Diffseg.Summary): { string }
	local out = {}
	for _, s in summary.segments do
		table.insert(
			out,
			string.format(
				"%s|%s|%s|%s|%s|%s|+%d-%d",
				s.action,
				s.group or "",
				s.version or "",
				s.kind or "",
				s.namespace or "",
				s.name or "",
				s.added,
				s.removed
			)
		)
	end
	return out
end

local function counts(summary: Diffseg.Summary): { number }
	return { summary.create, summary.modify, summary.delete, summary.unknown }
end

local function real(path: string): Diffseg.Summary
	return Diffseg.parse(fixtures.read("real/" .. path))
end

describe("diffseg over real kubectl diff output", function()
	it("splits a configured apply into per-object modifies", function()
		local s = real("mutate-configured/diff_-f_mutate+app-v2.yaml.txt")
		expect(brief(s)).toEqual({
			"modify|apps|v1|Deployment|tern-test-mutate|api|+3-2",
			"modify||v1|ConfigMap|tern-test-mutate|api-config|+2-1",
		})
		expect(counts(s)).toEqual({ 0, 2, 0, 0 })
		expect(s.notes).toEqual({})
	end)

	it("classifies objects missing from the cluster as creates", function()
		local s = real("mutate-create/diff_-f_mutate+app.yaml.txt")
		expect(brief(s)).toEqual({
			"create|apps|v1|Deployment|tern-test-mutate|api|+40-0",
			"create||v1|ConfigMap|tern-test-mutate|api-config|+9-0",
			"create||v1|Service|tern-test-mutate|api|+28-0",
		})
		expect(counts(s)).toEqual({ 3, 0, 0, 0 })
		expect(s.added).toBe(77)
	end)

	it("returns nothing for an unchanged apply (diff exit 0, empty output)", function()
		local s = real("mutate-unchanged/diff_-f_mutate+app.yaml.txt")
		expect(s.segments).toEqual({})
		expect(counts(s)).toEqual({ 0, 0, 0, 0 })
	end)

	it("handles a create + modify mix with multiple hunks per object", function()
		local s = real("mutate-preview/diff_-f_preview+apps-mix.yaml.txt")
		expect(brief(s)).toEqual({
			"modify|apps|v1|Deployment|tern-test-apps|web|+2-2",
			"modify||v1|ConfigMap|tern-test-apps|app-config|+1-1",
			"create||v1|ConfigMap|tern-test-apps|preview-extra|+11-0",
		})
		expect(s.notes).toEqual({})
	end)

	it("reads CRD objects whose group and name both contain dots", function()
		local s = real("mutate-preview/diff_-f_preview+widgets.yaml.txt")
		expect(brief(s)).toEqual({
			"create|lens.example.com|v1alpha1|Widget|tern-test-crd|gadget.v2|+13-0",
			"modify|lens.example.com|v1alpha1|Widget|tern-test-crd|gizmo|+2-2",
		})
	end)

	it("classifies prune removals as deletes", function()
		local s = real(
			"mutate-preview/diff_-f_preview+widgets.yaml_--prune_-l_app=widgets_--prune-allowlist=lens.example.com+v1alpha1+Widget.txt"
		)
		expect(counts(s)).toEqual({ 1, 1, 1, 0 })
		expect(brief(s)[3]).toBe("delete|lens.example.com|v1alpha1|Widget|tern-test-crd|long-description|+0-43")
	end)

	it("reads cluster-scoped objects (empty namespace in kubectl's file name)", function()
		local s = real("mutate-preview/diff_-f_preview+cluster-scoped.yaml.txt")
		expect(brief(s)).toEqual({
			"create|rbac.authorization.k8s.io|v1|ClusterRole||tern-test-preview-wildcard|+13-0",
			"create||v1|Namespace||tern-test-preview|+13-0",
		})
	end)

	it("keeps each segment's lines verbatim for the diff viewer", function()
		local s = real("mutate-configured/diff_-f_mutate+app-v2.yaml.txt")
		local cm = s.segments[2]
		expect(cm.lines[1]).toBe(
			"diff -u -N /tmp/LIVE-1145413731/v1.ConfigMap.tern-test-mutate.api-config /tmp/MERGED-1989329874/v1.ConfigMap.tern-test-mutate.api-config"
		)
		expect(Diffseg.text(cm)).toContain("+  CACHE_TTL: 30s\n+  LOG_LEVEL: debug")
		expect(#cm.lines).toBe(12)
	end)
end)

describe("diffseg robustness", function()
	it("never treats header-looking content lines as a new object", function()
		local text = table.concat({
			"diff -u -N /tmp/LIVE-1/v1.ConfigMap.ns.a /tmp/MERGED-2/v1.ConfigMap.ns.a",
			"--- /tmp/LIVE-1/v1.ConfigMap.ns.a\t2026-01-01 00:00:00",
			"+++ /tmp/MERGED-2/v1.ConfigMap.ns.a\t2026-01-01 00:00:00",
			"@@ -1,2 +1,4 @@",
			" data:",
			"-  x: 1",
			"+++ looks like a header",
			"+diff -u -N /a /b",
			"+--- also content",
			"",
		}, "\n")
		local s = Diffseg.parse(text)
		expect(brief(s)).toEqual({ "modify||v1|ConfigMap|ns|a|+3-1" })
		expect(s.notes).toEqual({})
	end)

	it("segments output without `diff` command lines from the ---/+++ headers", function()
		local text = table.concat({
			"--- /tmp/LIVE-1/v1.Pod.ns.a\t2026-01-01",
			"+++ /tmp/MERGED-2/v1.Pod.ns.a\t2026-01-01",
			"@@ -1 +1 @@",
			"-a",
			"+b",
			"--- /tmp/LIVE-1/v1.Pod.ns.b\t2026-01-01",
			"+++ /tmp/MERGED-2/v1.Pod.ns.b\t2026-01-01",
			"@@ -0,0 +1 @@",
			"+c",
		}, "\n")
		expect(brief(Diffseg.parse(text))).toEqual({ "modify||v1|Pod|ns|a|+1-1", "create||v1|Pod|ns|b|+1-0" })
	end)

	it("marks binary or unreadable objects unknown instead of guessing", function()
		local text = table.concat({
			"diff -u -N /tmp/LIVE-1/v1.Secret.ns.s /tmp/MERGED-2/v1.Secret.ns.s",
			"Binary files /tmp/LIVE-1/v1.Secret.ns.s and /tmp/MERGED-2/v1.Secret.ns.s differ",
			"diff -u -N /tmp/LIVE-1/odd /tmp/MERGED-2/odd",
			"--- /tmp/LIVE-1/odd\t2026",
			"+++ /tmp/MERGED-2/odd\t2026",
			"@@ -1 +1 @@",
			"-a",
			"+b",
		}, "\n")
		local s = Diffseg.parse(text)
		expect(brief(s)).toEqual({ "unknown||v1|Secret|ns|s|+0-0", "modify||||||+1-1" })
		expect(s.segments[2].key).toBe("odd")
		expect(counts(s)).toEqual({ 0, 1, 0, 1 })
	end)

	it("reports stray lines and truncated hunks as notes", function()
		local text = table.concat({
			"Warning: something odd",
			"diff -u -N /tmp/LIVE-1/v1.Pod.ns.a /tmp/MERGED-2/v1.Pod.ns.a",
			"--- /tmp/LIVE-1/v1.Pod.ns.a\t2026",
			"+++ /tmp/MERGED-2/v1.Pod.ns.a\t2026",
			"@@ -1,5 +1,5 @@",
			"-a",
			"+b",
		}, "\n")
		local s = Diffseg.parse(text)
		expect(s.notes).toEqual({ "Warning: something odd", "v1.Pod.ns.a: hunk ended early" })
		expect(s.segments[1].action).toBe("modify")
	end)

	it("accepts CRLF output and the `\\ No newline` marker", function()
		local text =
			"diff -u -N /tmp/L/v1.Pod.ns.a /tmp/M/v1.Pod.ns.a\r\n--- /tmp/L/v1.Pod.ns.a\r\n+++ /tmp/M/v1.Pod.ns.a\r\n@@ -1 +1 @@\r\n-a\r\n\\ No newline at end of file\r\n+b\r\n"
		expect(brief(Diffseg.parse(text))).toEqual({ "modify||v1|Pod|ns|a|+1-1" })
	end)

	it("parses kubectl file names", function()
		expect(Diffseg.identity("apps.v1.Deployment.ns.web")).toEqual({
			group = "apps",
			version = "v1",
			kind = "Deployment",
			namespace = "ns",
			name = "web",
		})
		expect(Diffseg.identity("v1.Node..kind-control-plane")).toEqual({
			version = "v1",
			kind = "Node",
			name = "kind-control-plane",
		})
		expect(Diffseg.identity("policy.v1beta1.PodDisruptionBudget.ns.p.q")).toEqual({
			group = "policy",
			version = "v1beta1",
			kind = "PodDisruptionBudget",
			namespace = "ns",
			name = "p.q",
		})
		expect(Diffseg.identity("garbage")).toBeNil()
	end)
end)

-- kubectl diff masks Secret data but not the last-applied-configuration
-- annotation, which embeds the applied values; bin/tern-kube-drift applies
-- the same rule to the same golden capture, so the two never disagree.
describe("diffseg secret redaction", function()
	local golden = fixtures.read("tests/shell/drift/cases/secret-last-applied.diff")

	it("replaces the last-applied line of a Secret and keeps counts and the masked data", function()
		local plain = Diffseg.parse(golden)
		local red = Diffseg.redactSecrets(plain)
		local text = Diffseg.text(red.segments[1])
		expect((string.find(text, "tern-kube-test-not-a-secret", 1, true))).toBeNil()
		expect((string.find(text, "tern-kube-test-user", 1, true))).toBeNil()
		expect(text).toContain("\n       " .. Diffseg.REDACTED .. "\n")
		expect(text).toContain("+  password: '*** (after)'")
		expect(brief(red)).toEqual(brief(plain))
		expect(#red.segments[1].lines).toBe(#plain.segments[1].lines)
	end)

	it("leaves the parsed summary untouched", function()
		local plain = Diffseg.parse(golden)
		Diffseg.redactSecrets(plain)
		expect(Diffseg.text(plain.segments[1])).toContain("tern-kube-test-not-a-secret")
	end)

	it("redacts added, removed and escaped JSON forms but never other kinds or headers", function()
		local diff = table.concat({
			"diff -u -N /tmp/LIVE-1/v1.Secret.ns.s /tmp/MERGED-1/v1.Secret.ns.s",
			"--- /tmp/LIVE-1/v1.Secret.ns.s\t2026-10-08 12:00:00",
			"+++ /tmp/MERGED-1/v1.Secret.ns.s\t2026-10-08 12:00:00",
			"@@ -1,3 +1,3 @@",
			'-    {"kind":"Secret","data":{"a":"b2xk"}}',
			'+    {"kind":"Secret","data":{"a":"bmV3"}}',
			'   x: "{\\"kind\\":\\"Secret\\",\\"stringData\\":{\\"t\\":\\"v\\"}}"',
			" kind: Secret",
			"diff -u -N /tmp/LIVE-1/v1.ConfigMap.ns.c /tmp/MERGED-1/v1.ConfigMap.ns.c",
			"--- /tmp/LIVE-1/v1.ConfigMap.ns.c\t2026-10-08 12:00:00",
			"+++ /tmp/MERGED-1/v1.ConfigMap.ns.c\t2026-10-08 12:00:00",
			"@@ -1 +1 @@",
			'-  doc: {"kind":"Secret","data":{"a":"x"}}',
			'+  doc: {"kind":"Secret","data":{"a":"y"}}',
			"",
		}, "\n")
		local red = Diffseg.redactSecrets(Diffseg.parse(diff))
		expect(red.segments[1].lines[5]).toBe("-    " .. Diffseg.REDACTED)
		expect(red.segments[1].lines[6]).toBe("+    " .. Diffseg.REDACTED)
		expect(red.segments[1].lines[7]).toBe("   " .. Diffseg.REDACTED)
		expect(red.segments[1].lines[8]).toBe(" kind: Secret")
		expect(red.segments[2].lines[5]).toBe('-  doc: {"kind":"Secret","data":{"a":"x"}}')
	end)
end)

return nil
