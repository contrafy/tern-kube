--!strict
-- What the settings block shows: every setting with its effective value and
-- whether it comes from the file, the edit input where the block can focus
-- it, the keyboard selection kept in view, and a status page that tells the
-- user what tern-kube cannot detect itself (the shell guard).
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

local PATH = "/home/u/.config/tern-kube/config.json"

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
		local rows = nodes.findAll(m, nodes.class("tk-set-r"))
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
		expect((input.p :: any).class).toBe("tk-editing")
	end)

	it("draws the caret where the user put it", function()
		local s = select(open(nil), "gitops.gh")
		s = State.update(s, { t = "key", key = { name = "e", text = "e" } })
		s = State.update(s, { t = "key", key = { name = "left" } })
		local input = nodes.find(main(s), nodes.kind("input")) :: nodes.Node
		expect((input.p :: any).cursor).toBe(1)
	end)

	it("highlights the selected row and keeps it inside a short block", function()
		local s = select(open(nil), "gitops.gh")
		local m = main(s, 20)
		local sel = nodes.find(m, nodes.class("tk-set-sel")) :: nodes.Node
		expect((sel.p :: any).key).toBe("gitops.gh")
		expect(#nodes.findAll(m, nodes.class("tk-set-r"))).toBe(State.viewport(20))
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

	-- auto_refresh can only be false (LENS-L13): a toggle that always refuses
	-- and an `invalid` badge made it look broken, so it reads as fixed.
	it("shows auto_refresh as a fixed value with its reason and no toggle", function()
		local s = select(open('{"explore": {"auto_refresh": true}}'), "explore.auto_refresh")
		local m = main(s)
		local row = nodes.find(m, nodes.key("explore.auto_refresh")) :: nodes.Node
		local text = nodes.text(row)
		expect(text).toContain("fixed")
		expect(text).toContain("false")
		expect((string.find(text, "invalid", 1, true))).toBeNil()
		expect(table.find(nodes.actions(row), "toggle=explore.auto_refresh")).toBeNil()
		expect(nodes.find(m, nodes.kind("input"))).toBeNil()
		expect(nodes.text(m)).toContain("never polls")
	end)

	-- The always-visible input above the list looked editable for booleans
	-- (LENS-L13): only text-edited kinds get the input; a boolean or choice
	-- gets its toggle with the key that flips it.
	it("offers a toggle, not a text input, when a boolean or choice is selected", function()
		for _, path in { "general.native_default", "quick_actions.placement" } do
			local m = main(select(open(nil), path))
			expect(nodes.find(m, nodes.kind("input"))).toBeNil()
			local current = nodes.find(m, nodes.key("current")) :: nodes.Node
			local text = nodes.text(current)
			expect(text).toContain(path)
			local button = nodes.find(current, nodes.kind("button")) :: nodes.Node
			expect(nodes.action(button)).toBe("toggle=" .. path)
			expect((button.p :: any).keys).toEqual({ "enter" })
		end
	end)

	-- Row actions are native buttons; the selected row names its keys as
	-- keycaps, other rows stay quiet so the list does not repeat them.
	it("draws row actions as buttons with keycaps on the selected row", function()
		local s = select(open('{"general": {"max_rows": 42}}'), "general.max_rows")
		local m = main(s)
		local row = nodes.find(m, nodes.key("general.max_rows")) :: nodes.Node
		local buttons = nodes.findAll(row, nodes.kind("button"))
		local keys: { [string]: any } = {}
		for _, b in buttons do
			keys[nodes.action(b) :: string] = (b.p :: any).keys
		end
		expect(keys["edit=general.max_rows"]).toEqual({ "e" })
		expect(keys["reset=general.max_rows"]).toEqual({ "r" })
		local other = nodes.find(m, nodes.key("general.native_default")) :: nodes.Node
		local toggle = nodes.find(other, nodes.kind("button")) :: nodes.Node
		expect((toggle.p :: any).keys).toBeNil()
		expect((toggle.p :: any).on).toBe(true)
	end)

	-- A narrow pane squeezed the value column until "true" broke into "tru e"
	-- (MUT-F17). Tern's CSS has no container queries, so the view drops the
	-- origin badge column itself below NARROW_COLS to leave key and value room.
	it("drops the origin badge column in a narrow pane", function()
		local s = open('{"general": {"max_rows": 42}}')
		local wide = Render.view(s, Render.NARROW_COLS, 200).main :: any
		local narrow = Render.view(s, Render.NARROW_COLS - 1, 200).main :: any
		local grid = nodes.find(narrow, nodes.class("tk-set-grid")) :: nodes.Node
		expect(nodes.class("tk-set-narrow")(grid)).toBe(true)
		local row = nodes.find(narrow, nodes.key("general.max_rows")) :: nodes.Node
		expect(#nodes.findAll(row, nodes.kind("badge"))).toBe(0)
		expect(nodes.text(row)).toContain("42")
		expect(nodes.actions(row)).toContain("reset=general.max_rows")
		local wideRow = nodes.find(wide, nodes.key("general.max_rows")) :: nodes.Node
		expect(#nodes.findAll(wideRow, nodes.kind("badge"))).toBe(1)
	end)
end)

describe("settings render: status page", function()
	local function status(s: State, extra: { [string]: any }?): string
		local st = State.update(s, { t = "key", key = { name = "tab" } })
		local info: { [string]: any } = {
			loadStatus = "loaded",
			pluginVersion = "0.0.1",
			pluginDir = "/p/plugin",
			ternVersion = "0.6.2 (4b3ed42)",
			ternPending = false,
			kubectl = {
				program = "/usr/local/bin/kubectl",
				source = "from your shell's PATH",
				found = true,
				version = "v1.31.0",
				pending = false,
			},
			helm = {
				program = "/opt/homebrew/bin/helm",
				source = "from a common install location",
				found = true,
				pending = false,
			},
			gh = { program = "gh", source = "not found", found = false, pending = false },
			shellEnv = {
				phase = "done",
				shell = "/bin/zsh",
				tookMs = 312,
				entries = 14,
				daemonPath = "/usr/bin:/bin:/usr/sbin:/sbin",
			},
			aliasClaims = { "k get *" },
			spool = "/data/spool",
			paneRecords = {
				{ pane = 4, kubeconfig = "/k/a", live = true },
				{ pane = 9, problem = "x", live = false } :: any,
			},
		}
		local overrides: { [string]: any } = extra or {}
		for k, v in overrides do
			info[k] = v
		end
		st = State.update(st, { t = "info", info = info })
		return nodes.text(main(st))
	end

	it("names the config file, versions and the resolved kubectl", function()
		local text = status(open(nil))
		expect(text).toContain(PATH)
		expect(text).toContain("tern-kube 0.0.1")
		expect(text).toContain("0.6.2 (4b3ed42)")
		expect(text).toContain("/usr/local/bin/kubectl")
		expect(text).toContain("v1.31.0")
	end)

	-- A Tern started from the Dock has a minimal PATH; the user must be able
	-- to see which kubectl/helm/gh is used and why, and whether the shell read worked.
	it("shows each program's absolute path and where it was found", function()
		local text = status(open(nil))
		expect(text).toContain("/usr/local/bin/kubectl  from your shell's PATH")
		expect(text).toContain("/opt/homebrew/bin/helm  from a common install location")
		expect(text).toContain("gh  not found")
	end)

	it("reports the login-shell read, its duration and Tern's own PATH", function()
		local text = status(open(nil))
		expect(text).toContain("read from /bin/zsh  in 312 ms · 14 entries")
		expect(text).toContain("/usr/bin:/bin:/usr/sbin:/sbin")
		local failed = status(open(nil), {
			shellEnv = {
				phase = "failed",
				shell = "/bin/zsh",
				tookMs = 5000,
				error = "timed out after 5000 ms",
				daemonPath = "/usr/bin",
			},
		})
		expect(failed).toContain(
			"/bin/zsh failed after 5000 ms: timed out after 5000 ms; using common install locations"
		)
		local off = status(open(nil), { shellEnv = { phase = "off", daemonPath = "/usr/bin" } })
		expect(off).toContain("off (general.shell_env)")
	end)

	it("lists alias claims and configured aliases that are not claimed", function()
		local text = status(open('{"aliases": {"additional": ["k", "kk"]}}'))
		expect(text).toContain("k  (1 globs)")
		expect(text).toContain("configured but not claimed: kk")
	end)

	it("reports the spool injection and pane records, and how to check the guard", function()
		local text = status(open(nil))
		expect(text).toContain("TKUBE_SPOOL=/data/spool")
		expect(text).toContain("2 recorded, 1 live")
		expect(text).toContain("pane 4: /k/a")
		expect(text).toContain("tern-kube-guard-status")
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

	-- Header actions are native buttons that show their shortcut as keycaps,
	-- so the keys are discoverable without opening help.
	it("offers Open config file, Reload, help and the two pages as buttons with keycaps", function()
		local header = nodes.find(main(open(nil)), nodes.role("tern-kube.settings-header")) :: nodes.Node
		local keys: { [string]: any } = {}
		local on: { [string]: any } = {}
		for _, b in nodes.findAll(header, nodes.kind("button")) do
			local act = nodes.action(b) :: string
			keys[act] = (b.p :: any).keys
			on[act] = (b.p :: any).on
		end
		expect(keys.open).toEqual({ "o" })
		-- Tern draws single letters as capitals, so R is spelled shift + r to
		-- stay distinct from r (reset).
		expect(keys.reload).toEqual({ "shift", "r" })
		expect(keys.help).toEqual({ "?" })
		expect(keys["page=status"]).toEqual({ "tab" })
		expect(on["page=settings"]).toBe(true)
		expect(on["page=status"]).toBe(false)
	end)

	-- While editing, the input gets Save and Cancel buttons naming enter and
	-- esc, so a pointer user can finish an edit.
	it("offers Save and Cancel with their keys while editing", function()
		local s = select(open(nil), "gitops.gh")
		s = State.update(s, { t = "key", key = { name = "e", text = "e" } })
		local current = nodes.find(main(s), nodes.key("current")) :: nodes.Node
		local keys: { [string]: any } = {}
		for _, b in nodes.findAll(current, nodes.kind("button")) do
			keys[nodes.action(b) :: string] = (b.p :: any).keys
		end
		expect(keys["edit-apply"]).toEqual({ "enter" })
		expect(keys["edit-cancel"]).toEqual({ "esc" })
	end)

	it("hints the edit keys in the dock while editing", function()
		local s = select(open(nil), "gitops.gh")
		s = State.update(s, { t = "key", key = { name = "e", text = "e" } })
		local dock = Render.view(s, 160, 50).dock :: any
		expect(nodes.text(dock)).toContain("enter saves")
	end)
end)

return nil
