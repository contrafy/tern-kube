--!strict
-- What the Helm views say about a release: a status nobody can misread
-- (stuck pending upgrades look different from healthy ones), breadcrumbs and
-- hints for every route, values leaves printed the way helm prints them, and
-- an owner line that tells hooks and release records apart from managed
-- objects (they carry no release annotation and cannot be "owned").
local HelmView = require("../../../plugin/lib/helm/view")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function isList(v: any): boolean
	return type(v) == "table" and (#v > 0 or next(v) == nil)
end

describe("helm view: status", function()
	it("tones statuses: deployed ok, failed error, pending warn, superseded muted", function()
		local want: { [string]: string } = {
			deployed = "success",
			failed = "error",
			["pending-install"] = "warning",
			["pending-upgrade"] = "warning",
			["pending-rollback"] = "warning",
			uninstalling = "warning",
			superseded = "neutral",
			uninstalled = "neutral",
			unknown = "neutral",
		}
		for status, tone in want do
			local b = HelmView.statusBadge(status :: any, false)
			expect((b.p :: any).tone).toBe(tone)
			expect((b.p :: any).text).toBe(status)
			expect((b.p :: any).role).toBe("tern-kube.helm-status")
		end
	end)

	-- A SIGKILLed upgrade stays pending-upgrade forever (F11); only the age
	-- tells it from one that is still running.
	it("labels a stuck pending release and explains the recovery", function()
		local b = HelmView.statusBadge("pending-upgrade", true)
		expect((b.p :: any).text).toBe("pending-upgrade (stuck?)")
		expect((b.p :: any).tone).toBe("warning")
		expect((b.p :: any).title).toContain("Rollback is the recovery")
		expect(HelmView.statusText("pending-upgrade", true)).toBe("pending-upgrade (stuck?)")
		expect(HelmView.statusText("deployed", false)).toBe("deployed")
	end)
end)

describe("helm view: crumbs and hints", function()
	local KINDS = {
		"helm-releases",
		"helm-release",
		"helm-history",
		"helm-values",
		"helm-manifest",
		"helm-notes",
		"helm-hooks",
		"helm-resources",
		"helm-diff",
	}

	it("every Helm route has a dock hint and a breadcrumb naming the release", function()
		for _, kind in KINDS do
			local route: any = { kind = kind, release = "shop-a", namespace = "tern-test-helm" }
			expect(HelmView.hint(route) ~= nil).toBe(true)
			if kind ~= "helm-releases" then
				expect(HelmView.crumb(route)).toContain("shop-a")
			end
		end
		expect(HelmView.crumb({ kind = "helm-releases" } :: any)).toBe("Helm releases")
	end)

	it("crumbs carry the revision, the values mode and the diff pair", function()
		local base: any = { release = "shop-a", namespace = "tern-test-helm" }
		local function crumb(extra: { [string]: any }): string
			local r = table.clone(base)
			for k, v in extra do
				r[k] = v
			end
			return HelmView.crumb(r)
		end
		expect(crumb({ kind = "helm-release" })).toBe("release tern-test-helm/shop-a")
		expect(crumb({ kind = "helm-release", revision = 2 })).toBe("release tern-test-helm/shop-a rev 2")
		expect(crumb({ kind = "helm-values" })).toBe("Values shop-a (changed)")
		expect(crumb({ kind = "helm-values", mode = "diff", revision = 1 })).toBe("Values shop-a rev 1 (diff)")
		expect(crumb({ kind = "helm-diff", revision = 1, against = 3 })).toBe("Diff shop-a rev 1..3")
	end)

	-- The history mark key is space (x stays global for track 5).
	it("the history hint names space as the mark key, not x", function()
		local hint = HelmView.hint({ kind = "helm-history" } :: any) :: string
		expect(hint).toContain("space mark")
		expect((string.find(hint, "x mark", 1, true))).toBeNil()
	end)
end)

describe("helm view: values text", function()
	it("prints leaves like helm: plain strings, integers without .0, lists and maps inline", function()
		expect(HelmView.valueText("nginx", isList)).toBe("nginx")
		expect(HelmView.valueText(2, isList)).toBe("2")
		expect(HelmView.valueText(2.5, isList)).toBe("2.5")
		expect(HelmView.valueText(true, isList)).toBe("true")
		expect(HelmView.valueText(nil, isList)).toBe("")
		local mixed: { any } = { 1, "a", { b = false } }
		expect(HelmView.valueText(mixed, isList)).toBe('[1, "a", {b: false}]')
		expect(HelmView.valueText({ z = 1, a = 'q"x' }, isList)).toBe('{a: "q\\"x", z: 1}')
		expect(HelmView.valueText({}, isList)).toBe("[]")
	end)
end)

describe("helm view: owner line", function()
	local function ctx(): HelmView.Ctx
		return {
			chip = function(text: string, action: string, props: { [string]: any }?): any
				local p: { [string]: any } = { text = text, actions = { click = action } }
				if props then
					for k, v in props do
						p[k] = v
					end
				end
				return { k = "badge", p = p }
			end,
		} :: any
	end

	-- Hook objects carry only helm.sh/hook annotations (F12): calling them
	-- "managed by" a release would be wrong, and no chip could open it.
	it("names hook objects as hooks, with their events", function()
		local hook = {
			kind = "ConfigMap",
			metadata = {
				name = "web-b-web-pre-upgrade",
				namespace = "tern-test-helm",
				annotations = { ["helm.sh/hook"] = "pre-upgrade,pre-rollback" },
			},
		}
		local line = HelmView.ownerLine(ctx(), hook) :: nodes.Node
		expect(nodes.text(line)).toContain("Helm hook (pre-upgrade, pre-rollback)")
		expect(#nodes.actions(line)).toBe(0)
	end)

	it("names release records and links the recorded revision", function()
		local record = {
			kind = "Secret",
			type = "helm.sh/release.v1",
			metadata = {
				name = "sh.helm.release.v1.shop-a.v2",
				namespace = "tern-test-helm",
				labels = { owner = "helm", name = "shop-a", version = "2", status = "superseded" },
			},
		}
		local line = HelmView.ownerLine(ctx(), record) :: nodes.Node
		expect(nodes.text(line)).toContain("Helm release record shop-a rev 2")
		expect(nodes.actions(line)).toEqual({ "helm-open=tern-test-helm/shop-a#2" })
	end)

	it("says nothing without an object", function()
		expect(HelmView.ownerLine(ctx(), nil)).toBeNil()
	end)
end)

describe("helm view: helm missing", function()
	-- Without a helm program nothing is queried; the view says how to fix it
	-- instead of showing an empty list that reads as "no releases".
	it("every Helm route shows one actionable error", function()
		for _, kind in { "helm-releases", "helm-release", "helm-history" } do
			local v: any = {
				hctx = { helm = nil },
				route = { kind = kind, release = "shop-a", namespace = "tern-test-helm" },
				chip = function(text: string, action: string, _props: { [string]: any }?): any
					return { k = "badge", p = { text = text, actions = { click = action } } }
				end,
			}
			local root: nodes.Node = { k = "col", c = HelmView.body(v) :: any }
			expect(nodes.text(root)).toContain("helm not found")
			expect(nodes.actions(root)).toEqual({ "settings" })
		end
	end)
end)

return nil
