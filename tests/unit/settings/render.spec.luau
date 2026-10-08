--!strict
-- What the settings block shows: every setting with its effective value and
-- whether it comes from the file, the edit input where the block can focus
-- it, the keyboard selection kept in view, and a status page that tells the
-- user what kube-lens cannot detect itself (the shell guard).
local Render = require("../../../plugin/lib/settings/render")
local State = require("../../../plugin/lib/settings/state")
local json = require("../../lib/json")
local nodes = require("../../lib/nodes")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State

local ENV: State.Env = {
	decode = json.decode,
	isList = function(v: any): boolean
		return type(v) == "table" and next(v) == nil
	end,
	home = "/home/u",
}

local PATH = "/home/u/.config/kube-lens/config.json"

local function open(text: string?): State
	local s = State.init(ENV, nil)
	return (State.update(s, { t = "file", path = PATH, target = PATH, text = text }))
end

local function main(s: State, rows: number?): nodes.Node
	return Render.view(s, 160, rows or 200).main :: any
end

local function select(s: State, path: string): State
	return (State.update(s, { t = "action", act = "sel", value = path }))
end

describe("settings render: editor", function()
	it("lists every setting with its effective value when the block is tall enough", function()
		local m = main(open('{"general": {"max_rows": 42}}'))
		local rows = nodes.findAll(m, nodes.class("kl-set-r"))
		expect(#rows).toBe(#State.FIELDS)
		local text = nodes.text(m)
		expect(text).toContain("max_rows")
		expect(text).toContain("42")
		expect(text).toContain("busybox:1.36")
	end)

	it("marks values from the file, defaults and rejected values", function()
		local s = open('{"general": {"max_rows": 42, "max_rendered_rows": "lots"}}')
		local m = main(s)
		local set = nodes.find(m, nodes.key("general.max_rows")) :: nodes.Node
		expect(nodes.text(set)).toContain("set")
		expect(nodes.actions(set)).toContain("reset=general.max_rows")
		local bad = nodes.find(m, nodes.key("general.max_rendered_rows")) :: nodes.Node
		expect(nodes.text(bad)).toContain("invalid")
		local dflt = nodes.find(m, nodes.key("general.native_default")) :: nodes.Node
		expect(nodes.text(dflt)).toContain("default")
		expect(nodes.actions(dflt)).toContain("toggle=general.native_default")
		expect(table.find(nodes.actions(dflt), "reset=general.native_default")).toBeNil()
	end)

	it("puts the edit input directly in the main column so it can be focused as main.edit", function()
		local s = select(open(nil), "gitops.gh")
		local m = main(s)
		local input: nodes.Node? = nil
		for _, c in (m.c or {}) :: { nodes.Node } do
			if c.k == "input" then
				input = c
			end
		end
		local p = (input :: nodes.Node).p :: any
		expect(p.key).toBe("edit")
		expect(State.EDIT_INPUT).toBe("main.edit")
		expect(p.prompt).toBe("gitops.gh = ")
		expect(p.text).toBe("gh")
	end)

	it("shows the text being typed and marks the input while editing", function()
		local s = select(open(nil), "gitops.gh")
		s = State.update(s, { t = "key", key = { name = "e", text = "e" } })
		s = State.update(s, { t = "key", key = { name = "x", text = "x" } })
		local input = nodes.find(main(s), nodes.kind("input")) :: nodes.Node
		expect((input.p :: any).text).toBe("ghx")
		expect((input.p :: any).class).toBe("kl-editing")
	end)

	it("highlights the selected row and keeps it inside a short block", function()
		local s = select(open(nil), "gitops.gh")
		local m = main(s, 20)
		local sel = nodes.find(m, nodes.class("kl-set-sel")) :: nodes.Node
		expect((sel.p :: any).key).toBe("gitops.gh")
		expect(#nodes.findAll(m, nodes.class("kl-set-r"))).toBe(State.viewport(20))
		expect(nodes.text(m)).toContain("above")
	end)

	it("windows the list around the selection", function()
		expect({ Render.window(1, 30, 10) }).toEqual({ 1, 10 })
		expect({ Render.window(15, 30, 10) }).toEqual({ 10, 19 })
		expect({ Render.window(30, 30, 10) }).toEqual({ 21, 30 })
		expect({ Render.window(3, 5, 10) }).toEqual({ 1, 5 })
	end)

	it("shows the loader's diagnostic for the selected key", function()
		local s = select(open('{"quick_actions": {"placement": "left"}}'), "quick_actions.placement")
		expect(nodes.text(main(s))).toContain('expected one of "right", "down", "tab"')
	end)

	it("shows why a broken file cannot be edited", function()
		expect(nodes.text(main(open("{nope")))).toContain("not valid JSON")
	end)
end)

describe("settings render: status page", function()
	local function status(s: State): string
		local st = State.update(s, { t = "key", key = { name = "tab" } })
		st = State.update(st, {
			t = "info",
			info = {
				loadStatus = "loaded",
				pluginVersion = "0.0.1",
				pluginDir = "/p/plugin",
				ternVersion = "0.6.2 (4b3ed42)",
				ternPending = false,
				kubectl = {
					program = "kubectl",
					source = "the daemon's PATH",
					resolved = "/usr/bin/kubectl",
					version = "v1.31.0",
					pending = false,
				},
				aliasClaims = { "k get *" },
				spool = "/data/spool",
				paneRecords = {
					{ pane = 4, kubeconfig = "/k/a", live = true },
					{ pane = 9, problem = "x", live = false } :: any,
				},
			},
		})
		return nodes.text(main(st))
	end

	it("names the config file, versions and the resolved kubectl", function()
		local text = status(open(nil))
		expect(text).toContain(PATH)
		expect(text).toContain("kube-lens 0.0.1")
		expect(text).toContain("0.6.2 (4b3ed42)")
		expect(text).toContain("/usr/bin/kubectl")
		expect(text).toContain("v1.31.0")
	end)

	it("lists alias claims and configured aliases that are not claimed", function()
		local text = status(open('{"aliases": {"additional": ["k", "kk"]}}'))
		expect(text).toContain("k  (1 globs)")
		expect(text).toContain("configured but not claimed: kk")
	end)

	it("reports the spool injection and pane records, and how to check the guard", function()
		local text = status(open(nil))
		expect(text).toContain("KUBE_LENS_SPOOL=/data/spool")
		expect(text).toContain("2 recorded, 1 live")
		expect(text).toContain("pane 4: /k/a")
		expect(text).toContain("kube-lens-guard-status")
	end)

	it("summarizes the confirmation tiers and supported operations", function()
		local text = status(open(nil))
		expect(text).toContain("Enter")
		expect(text).toContain("Typed")
		expect(text).toContain("Blocked")
		expect(text).toContain("every delete")
		expect(text).toContain("Supported operations")
	end)

	it("says when mutations are disabled", function()
		expect(status(open('{"mutations": {"enabled": false}}'))).toContain("every mutation is refused")
	end)

	it("lists diagnostics", function()
		expect(status(open('{"genral": {}}'))).toContain("genral: unknown key")
	end)
end)

describe("settings render: chrome", function()
	it("lists every key in the help layer", function()
		local s = State.update(open(nil), { t = "key", key = { name = "?", text = "?" } })
		local layer = Render.view(s, 160, 50).layer :: any
		local text = nodes.text(layer)
		for _, k in Render.KEYS do
			expect(text).toContain(k[1])
		end
	end)

	it("offers Open config file, Reload and the two pages as chips", function()
		local acts = nodes.actions(main(open(nil)))
		expect(acts).toContain("open")
		expect(acts).toContain("reload")
		expect(acts).toContain("page=settings")
		expect(acts).toContain("page=status")
	end)

	it("hints the edit keys in the dock while editing", function()
		local s = select(open(nil), "gitops.gh")
		s = State.update(s, { t = "key", key = { name = "e", text = "e" } })
		local dock = Render.view(s, 160, 50).dock :: any
		expect(nodes.text(dock)).toContain("enter saves")
	end)
end)

return nil
