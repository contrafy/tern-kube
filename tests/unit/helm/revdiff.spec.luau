--!strict
-- Revision diffs show what a rollback (or a history comparison) changes in
-- the recorded release: one segment per object in the same shape the approve
-- block and drift already render. Secrets in values must never reach the
-- diff text, yet a change hidden by masking must still be reported.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local HelmTypes = require("../../../plugin/lib/helm/types")
local Redact = require("../../../plugin/lib/model/redact")
local RevDiff = require("../../../plugin/lib/helm/revdiff")
local Types = require("../../../plugin/lib/model/types")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NS = "tern-test-helm"
local SECRETS = { "hunter2-REDACTME", "hunter3-REDACTME", "tok-REDACTME" }

local function manifest(name: string): string
	return fixtures.read("helm/captured/manifest-" .. name .. ".yaml")
end

local function opts(policy: Redact.Policy?): RevDiff.Options
	return { namespace = NS, policy = policy or Redact.DEFAULT, secrets = SECRETS }
end

local function replace(text: string, from: string, to: string): string
	local out, n = string.gsub(text, string.gsub(from, "%p", "%%%0"), (string.gsub(to, "%%", "%%%%")))
	assert(n > 0, "fixture no longer contains " .. from)
	return out
end

local function byKey(result: RevDiff.Result): { [string]: Diffseg.Segment }
	local out: { [string]: Diffseg.Segment } = {}
	for _, seg in result.summary.segments do
		out[seg.key] = seg
	end
	return out
end

local function allText(result: RevDiff.Result): string
	local parts = {}
	for _, seg in result.summary.segments do
		table.insert(parts, Diffseg.text(seg))
	end
	return table.concat(parts, "\n")
end

local function hasHunk(seg: Diffseg.Segment): boolean
	for _, line in seg.lines do
		if string.sub(line, 1, 3) == "@@ " then
			return true
		end
	end
	return false
end

local function ref(doc: RevDiff.Doc): Types.ResourceRef
	return assert(doc.ref, "document without an identity: " .. doc.key)
end

local function hook(name: string, manifestText: string): HelmTypes.Hook
	return {
		name = name,
		kind = "ConfigMap",
		path = "web/templates/hooks.yaml",
		weight = 0,
		events = { "pre-rollback" },
		deletePolicies = {},
		phase = "",
		manifest = manifestText,
	}
end

local CM = "v1.ConfigMap.tern-test-helm.shop-a-shop-config"
local DEPLOY = "apps.v1.Deployment.tern-test-helm.shop-a-shop"

describe("helm.revdiff diff", function()
	it("reports shop-a r1 -> r3 as the ConfigMap and Deployment edits only", function()
		local result = RevDiff.diff(manifest("shop-a-r1"), manifest("shop-a-r3"), opts())
		local s = result.summary
		expect({ s.create, s.modify, s.delete, s.unknown }).toEqual({ 0, 2, 0, 0 })
		expect({ s.added, s.removed }).toEqual({ 3, 3 })
		local segs = byKey(result)
		expect(Diffseg.text(segs[CM])).toContain('+  mode: "staging"')
		local deploy = Diffseg.text(segs[DEPLOY])
		expect(deploy).toContain("-  replicas: 1\n+  replicas: 2")
		expect(deploy).toContain('+          image: "nginx:1.27.3-alpine"')
		expect(result.maskedChanges).toBe(0)
		expect(result.masked).toEqual({})
	end)

	-- Renderers and risk read kind/namespace/name from the segment, exactly
	-- as for kubectl diff output.
	it("keys segments in kubectl diff's file-name format", function()
		local segs = byKey(RevDiff.diff(manifest("shop-a-r1"), manifest("shop-a-r3"), opts()))
		local deploy = segs[DEPLOY]
		expect({ deploy.group, deploy.version, deploy.kind, deploy.namespace, deploy.name }).toEqual({
			"apps",
			"v1",
			"Deployment",
			NS,
			"shop-a-shop",
		})
		expect(Diffseg.identity(CM)).toEqual({
			version = "v1",
			kind = "ConfigMap",
			namespace = NS,
			name = "shop-a-shop-config",
		})
	end)

	it("returns no segments for identical revisions", function()
		local result = RevDiff.diff(manifest("web-b-r1"), manifest("web-b-r3"), opts())
		expect(#result.summary.segments).toBe(0)
		expect(result.maskedChanges).toBe(0)
	end)

	-- A same-length password change masks to the same text on both sides;
	-- without the masked note the rollback would look like it changes nothing.
	it("reports a password change hidden by masking without leaking it", function()
		local old = manifest("web-b-r3")
		local new = replace(old, "hunter2-REDACTME", "hunter3-REDACTME")
		local result = RevDiff.diff(old, new, opts())
		local secret = "v1.Secret.tern-test-helm.web-b-web-auth"
		local config = "v1.ConfigMap.tern-test-helm.web-b-web-config"
		local segs = byKey(result)
		expect(segs[secret].action).toBe("modify")
		expect(hasHunk(segs[secret])).toBe(false)
		-- The DSN embeds the password: the echo rule masks it in a ConfigMap too.
		expect(segs[config].action).toBe("modify")
		expect(hasHunk(segs[config])).toBe(false)
		expect(result.masked).toEqual({ [secret] = true, [config] = true })
		expect(result.maskedChanges).toBe(2)
		expect({ result.summary.modify, result.summary.added, result.summary.removed }).toEqual({ 2, 0, 0 })
		expect((string.find(allText(result), "REDACTME", 1, true))).toBeNil()
		expect(RevDiff.MASKED_NOTE).toBe("values changed (masked)")
	end)

	it("flags a masked change even when other lines of the object changed visibly", function()
		local old = manifest("web-b-r3")
		local new = replace(replace(old, "tok-REDACTME", "token2-REDACTME"), 'mode: "default"', 'mode: "canary"')
		local result = RevDiff.diff(old, new, opts({ showSecrets = false, strict = false }))
		local segs = byKey(result)
		local secret = segs["v1.Secret.tern-test-helm.web-b-web-auth"]
		-- A longer token must not show through as a longer mask (EXP-U8).
		expect((string.find(Diffseg.text(secret), "bytes", 1, true))).toBeNil()
		expect(result.masked["v1.Secret.tern-test-helm.web-b-web-auth"]).toBe(true)
		expect(result.masked["v1.ConfigMap.tern-test-helm.web-b-web-config"]).toBeNil()
		expect((string.find(allText(result), "REDACTME", 1, true))).toBeNil()
	end)

	it("shows real values when the user opted in", function()
		local old = manifest("web-b-r3")
		local new = replace(old, "hunter2-REDACTME", "hunter3-REDACTME")
		local result = RevDiff.diff(old, new, opts({ showSecrets = true, strict = false }))
		expect(allText(result)).toContain('+  password: "hunter3-REDACTME"')
		expect(result.maskedChanges).toBe(0)
	end)

	it("classifies objects only one revision has as create and delete", function()
		local old = '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gone\ndata:\n  a: "1"\n'
		local new = '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fresh\ndata:\n  b: "2"\n'
		local result = RevDiff.diff(old, new, opts())
		local segs = byKey(result)
		local created = segs["v1.ConfigMap.tern-test-helm.fresh"]
		local deleted = segs["v1.ConfigMap.tern-test-helm.gone"]
		expect(created.action).toBe("create")
		expect(created.lines[1]).toBe("--- /dev/null")
		expect(deleted.action).toBe("delete")
		expect(Diffseg.text(deleted)).toContain("@@ -1,6 +0,0 @@")
		expect({ result.summary.create, result.summary.delete, result.summary.modify }).toEqual({ 1, 1, 0 })
	end)

	it("lists hooks added, removed and changed between the revisions", function()
		local base = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  revision: %q\n"
		local oldHooks = {
			hook("pre", string.format(base, "pre", "1")),
			hook("post", string.format(base, "post", "1")),
			hook("same", string.format(base, "same", "1")),
		}
		local newHooks = {
			hook("pre", string.format(base, "pre", "2")),
			hook("same", string.format(base, "same", "1")),
			hook("rollback", string.format(base, "rollback", "1")),
		}
		local m = manifest("shop-a-r1")
		local result = RevDiff.diff(m, m, opts(), oldHooks, newHooks)
		expect(result.hooks).toEqual({
			added = { "ConfigMap/rollback" },
			removed = { "ConfigMap/post" },
			changed = { "ConfigMap/pre" },
		})
		expect(RevDiff.diff(m, m, opts()).hooks).toEqual({ added = {}, removed = {}, changed = {} })
	end)
end)

describe("helm.revdiff docs", function()
	-- helm applies namespace-less documents to the release namespace; a
	-- template that later spells the namespace out must not look like a
	-- delete plus a create.
	it("defaults the namespace of namespaced objects to the release namespace", function()
		local docs = RevDiff.docs(manifest("shop-a-r3"), NS)
		expect(ref(docs[DEPLOY]).namespace).toBe(NS)
		expect(ref(docs[DEPLOY]).kind).toBe("Deployment")
		expect(ref(docs["v1.Service.tern-test-helm.shop-a-shop"]).namespace).toBe(NS)
		expect(docs[CM].text).toContain('  mode: "staging"\n')

		local implicit = 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\ndata:\n  a: "1"\n'
		local explicit = 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\n  namespace: apps\ndata:\n  a: "1"\n'
		local result = RevDiff.diff(implicit, explicit, { namespace = "apps", policy = Redact.DEFAULT, secrets = {} })
		expect(#result.summary.segments).toBe(1)
		expect(result.summary.segments[1].key).toBe("v1.ConfigMap.apps.cm")
		expect(result.summary.segments[1].action).toBe("modify")
	end)

	it("keeps cluster-scoped objects without a namespace", function()
		local text =
			"apiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: reader\nrules: []\n"
		local docs = RevDiff.docs(text, NS)
		local doc = docs["rbac.authorization.k8s.io.v1.ClusterRole..reader"]
		expect(ref(doc).namespace).toBeNil()
		expect(Diffseg.identity(doc.key)).toEqual({
			group = "rbac.authorization.k8s.io",
			version = "v1",
			kind = "ClusterRole",
			name = "reader",
		})
	end)
end)

describe("helm.revdiff changedSets", function()
	-- The rollback preview counts deletes for its risk tier and diffs the
	-- target's objects against the live cluster.
	it("splits objects into create, delete and modify with raw text", function()
		local old = manifest("web-b-r3")
		local new = replace(old, "hunter2-REDACTME", "hunter3-REDACTME")
			.. "---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: extra\n"
		local sets = RevDiff.changedSets(old, new, NS)
		local function keys(list: { RevDiff.Doc }): { string }
			local out = {}
			for _, d in list do
				table.insert(out, d.key)
			end
			table.sort(out)
			return out
		end
		expect(keys(sets.create)).toEqual({ "v1.ConfigMap.tern-test-helm.extra" })
		expect(keys(sets.delete)).toEqual({})
		expect(keys(sets.modify)).toEqual({
			"v1.ConfigMap.tern-test-helm.web-b-web-config",
			"v1.Secret.tern-test-helm.web-b-web-auth",
		})
		local secret = sets.modify[1].text .. sets.modify[2].text
		expect(secret).toContain("hunter3-REDACTME")

		local back = RevDiff.changedSets(new, old, NS)
		expect(keys(back.delete)).toEqual({ "v1.ConfigMap.tern-test-helm.extra" })
	end)
end)

return nil
