--!strict
-- The settings block edits a hand-written file: it must never lose what it
-- does not understand (unknown keys, newer schema versions), never write a
-- value the loader would reject or silently replace, and never clobber a
-- file that changed on disk after it was read. Every key the loader knows
-- must be editable with a control that matches its type.
local Config = require("../../../plugin/lib/config")
local State = require("../../../plugin/lib/settings/state")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect

local PATH = "/home/u/.config/kube-lens/config.json"

-- tern.json tags decoded arrays; the test decoder records them instead.
local arrays: { [any]: boolean } = {}
local function decode(text: string): any
	local value, tagged = json.decodeTracking(text)
	for k in tagged do
		arrays[k] = true
	end
	return value
end
local function isList(v: any): boolean
	return arrays[v] == true
end

local ENV: State.Env = { decode = decode, isList = isList, home = "/home/u" }

local function step(s: State, msg: any): (State, { Effect })
	return State.update(s, msg)
end

-- A block that read `text` (nil: no file) from PATH.
local function open(text: string?, target: string?): State
	local s = State.init(ENV, nil)
	s = step(s, { t = "file", path = PATH, target = target or PATH, text = text })
	return s
end

local function key(s: State, name: string, extra: { [string]: any }?): (State, { Effect })
	local k: { [string]: any } = { name = name, ctrl = false, alt = false, shift = false, meta = false }
	if #name == 1 then
		k.text = name
	end
	if extra then
		for a, b in extra do
			k[a] = b
		end
	end
	return step(s, { t = "key", key = k })
end

local function typeText(s: State, text: string): State
	for i = 1, #text do
		s = key(s, string.sub(text, i, i))
	end
	return s
end

local function select(s: State, path: string): State
	return (step(s, { t = "action", act = "sel", value = path }))
end

local function writeOf(effects: { Effect }): Effect?
	for _, e in effects do
		if e.t == "write" then
			return e
		end
	end
	return nil
end

local function written(effects: { Effect }): any
	local e = writeOf(effects)
	assert(e, "expected a write effect")
	return decode(e.text :: string)
end

local function hasEffect(effects: { Effect }, kind: string): boolean
	for _, e in effects do
		if e.t == kind then
			return true
		end
	end
	return false
end

local function encodeDefaultsKeys(): { string }
	local out: { string } = {}
	for k, v in Config.defaults() :: any do
		if k == "schema_version" then
			continue
		end
		if type(v) == "table" then
			for sub in v do
				table.insert(out, k .. "." .. sub)
			end
		else
			table.insert(out, k)
		end
	end
	return out
end

describe("settings catalog", function()
	it("covers every key the loader knows, including the ones without a default value", function()
		local paths = encodeDefaultsKeys()
		table.insert(paths, "kubeconfig")
		table.insert(paths, "gitops.unmanaged_kinds")
		for _, p in paths do
			expect(State.field(p) ~= nil and p or "missing " .. p).toBe(p)
		end
		expect(#State.FIELDS).toBe(#paths)
	end)

	it("only lists keys the loader accepts (none is reported as unknown)", function()
		for _, f in State.FIELDS do
			local raw = State.setValue({}, f, State.configValue(Config.defaults(), f) or "x")
			local _, diags = Config.parse(State.encode(raw, isList), decode, { home = "/home/u" })
			for _, d in diags do
				expect((string.find(d.message, "unknown key", 1, true))).toBeNil()
			end
		end
	end)

	it("states the same integer ranges as the loader", function()
		for _, f in State.FIELDS do
			if f.kind ~= "int" then
				continue
			end
			local function errs(v: number): number
				local _, diags = Config.parse(State.encode(State.setValue({}, f, v), isList), decode)
				return #State.diagnosticsFor(diags, f.path)
			end
			expect(errs(f.min :: number)).toBe(0)
			expect(errs(f.max :: number)).toBe(0)
			expect(errs((f.min :: number) - 1)).toBe(1)
			expect(errs((f.max :: number) + 1)).toBe(1)
		end
	end)

	it("cycles exactly the placements the loader accepts", function()
		local f = State.field("quick_actions.placement") :: State.Field
		expect(f.kind).toBe("enum")
		for _, v in f.values :: { string } do
			local _, diags = Config.parse(State.encode(State.setValue({}, f, v), isList), decode)
			expect(#diags).toBe(0)
		end
	end)

	it("gives booleans a toggle and structured values JSON editing", function()
		expect((State.field("security.show_secret_values") :: State.Field).kind).toBe("bool")
		expect((State.field("quick_actions.shell_command") :: State.Field).kind).toBe("list")
		expect((State.field("gitops.helm") :: State.Field).kind).toBe("json")
		expect((State.field("kubectl") :: State.Field).kind).toBe("string")
	end)
end)

describe("settings file serialization", function()
	local HAND = [[
{
  "zzz_top": {"keep": [1, 2, {"x": null, "y": "z"}]},
  "general": {"max_rows": 100, "future_knob": "on", "empty_obj": {}, "empty_list": []},
  "schema_version": 1,
  "kubectl": "/usr/local/bin/kubectl",
  "gitops": {"helm": [{"release": "web", "chart": "charts/web", "extra": true}]}
}
]]

	it("keeps unknown keys at every level through a round trip", function()
		local raw = decode(HAND)
		local back = decode(State.encode(raw, isList))
		expect(back.zzz_top.keep[3].y).toBe("z")
		expect(back.general.future_knob).toBe("on")
		expect(back.gitops.helm[1].extra).toBe(true)
		expect(back.kubectl).toBe("/usr/local/bin/kubectl")
	end)

	it("keeps empty lists as [] and empty objects as {}", function()
		local text = State.encode(decode(HAND), isList)
		expect(text).toContain('"empty_list": []')
		expect(text).toContain('"empty_obj": {}')
	end)

	it("writes known keys in the documented order, unknown keys after them", function()
		local text = State.encode(decode(HAND), isList)
		local sv = string.find(text, '"schema_version"', 1, true) :: number
		local general = string.find(text, '"general"', 1, true) :: number
		local kubectl = string.find(text, '"kubectl"', 1, true) :: number
		local gitops = string.find(text, '"gitops"', 1, true) :: number
		local unknown = string.find(text, '"zzz_top"', 1, true) :: number
		expect(sv < general and general < kubectl and kubectl < gitops and gitops < unknown).toBe(true)
		local maxRows = string.find(text, '"max_rows"', 1, true) :: number
		local knob = string.find(text, '"future_knob"', 1, true) :: number
		expect(maxRows < knob).toBe(true)
		expect(text).toContain(
			'{\n        "chart": "charts/web",\n        "release": "web",\n        "extra": true\n      }'
		)
	end)

	it("escapes strings so the file stays valid JSON", function()
		local f = State.field("quick_actions.shell_command") :: State.Field
		local argv = { "sh", "-c", 'echo "a\\b"\n\ttab\1' }
		local text = State.encode(State.setValue({}, f, argv), isList)
		expect(decode(text).quick_actions.shell_command).toEqual(argv)
		expect(text).toContain('["sh", "-c", "echo \\"a\\\\b\\"\\n\\ttab\\u0001"]')
	end)

	it("writes integers without a fraction and a trailing newline", function()
		local f = State.field("general.max_capture_bytes") :: State.Field
		local text = State.encode(State.setValue({ schema_version = 1 }, f, 268435456), isList)
		expect(text).toBe('{\n  "schema_version": 1,\n  "general": {\n    "max_capture_bytes": 268435456\n  }\n}\n')
	end)

	it("changes only the edited path and leaves the decoded file untouched", function()
		local raw = decode(HAND)
		local f = State.field("general.max_rows") :: State.Field
		local out = State.setValue(raw, f, 7)
		expect(raw.general.max_rows).toBe(100)
		expect(out.general.max_rows).toBe(7)
		expect(out.zzz_top).toBe(raw.zzz_top)
		expect(out.general.empty_list).toBe(raw.general.empty_list)
	end)

	it("drops a section that a reset leaves empty", function()
		local raw = decode('{"explore": {"query_timeout_ms": 2000}}')
		local out = State.setValue(raw, State.field("explore.query_timeout_ms") :: State.Field, nil)
		expect(out.explore).toBeNil()
	end)
end)

describe("settings state: loading", function()
	it("reads the file and probes status when it opens", function()
		local _, effects = State.init(ENV, nil)
		expect(hasEffect(effects, "reload")).toBe(true)
		expect(hasEffect(effects, "probe")).toBe(true)
	end)

	it("restores the page and the selected key after a restart", function()
		local s = open(nil)
		s = select(s, "gitops.gh")
		s = key(s, "tab")
		local saved = State.save(s)
		local again = State.init(ENV, saved)
		expect(again.page).toBe("status")
		expect(State.selected(again).path).toBe("gitops.gh")
	end)

	it("shows the effective config of the file, with defaults for missing keys", function()
		local s = open('{"schema_version": 1, "general": {"max_rows": 42}}')
		local f = State.field("general.max_rows") :: State.Field
		expect(State.display(s, f)).toBe("42")
		expect(State.origin(s, f)).toBe("file")
		local g = State.field("general.max_rendered_rows") :: State.Field
		expect(State.display(s, g)).toBe("500")
		expect(State.origin(s, g)).toBe("default")
	end)

	it("marks a value the loader rejected as invalid", function()
		local s = open('{"general": {"max_rows": "lots"}}')
		local f = State.field("general.max_rows") :: State.Field
		expect(State.origin(s, f)).toBe("invalid")
		expect(State.display(s, f)).toBe("20000")
	end)

	it("refuses to edit a file that is not valid JSON, but still opens it", function()
		local s = open('{"general": {,}')
		expect(s.fileError ~= nil).toBe(true)
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).level).toBe("error")
		local _, opened = key(s, "o")
		expect(opened[1]).toEqual({ t = "open", path = PATH })
	end)

	it("refuses to edit a file whose top level is not an object", function()
		local s = open("[1, 2]")
		expect(s.fileError ~= nil).toBe(true)
		local _, effects = key(s, "space")
		expect(writeOf(effects)).toBeNil()
	end)
end)

describe("settings state: keyboard", function()
	it("moves with j/k and arrows, clamped to the list", function()
		local s = open(nil)
		s = key(s, "k")
		expect(s.sel).toBe(1)
		s = key(s, "j")
		s = key(s, "down")
		expect(s.sel).toBe(3)
		s = key(s, "up")
		expect(s.sel).toBe(2)
		s = key(s, "G", { shift = true })
		expect(s.sel).toBe(#State.FIELDS)
		s = key(s, "j")
		expect(s.sel).toBe(#State.FIELDS)
	end)

	it("toggles a boolean with enter and with space", function()
		local s = open('{"schema_version": 1}')
		s = select(s, "security.show_secret_values")
		local _, e1 = key(s, "enter")
		expect(written(e1).security.show_secret_values).toBe(true)
		local _, e2 = key(s, "space")
		expect(written(e2).security.show_secret_values).toBe(true)
	end)

	it("cycles an enum through its values", function()
		local s = open('{"quick_actions": {"placement": "tab"}}')
		s = select(s, "quick_actions.placement")
		local _, effects = key(s, "enter")
		expect(written(effects).quick_actions.placement).toBe("right")
	end)

	it("toggles the help layer with ? and closes it with esc", function()
		local s = open(nil)
		s = key(s, "?")
		expect(s.help).toBe(true)
		local s2, effects = key(s, "escape")
		expect(s2.help).toBe(false)
		expect(#effects).toBe(0)
	end)

	it("closes the block with esc", function()
		local _, effects = key(open(nil), "escape")
		expect(effects[1]).toEqual({ t = "exit" })
	end)

	it("switches pages with tab and keeps list keys to the settings page", function()
		local s = key(open(nil), "tab")
		expect(s.page).toBe("status")
		local s2 = key(s, "j")
		expect(s2.sel).toBe(1)
		expect(key(s, "tab").page).toBe("settings")
	end)

	it("reports keys it does not use as unhandled", function()
		local s = open(nil)
		local s2 = key(s, "x")
		expect(s2).toBe(s)
	end)
end)

describe("settings state: editing and validation", function()
	it("edits a number: e focuses the input, typing replaces, enter writes", function()
		local s = open('{"schema_version": 1, "general": {"max_rows": 100}}')
		s = select(s, "general.max_rows")
		local effects
		s, effects = key(s, "e")
		expect(effects[1]).toEqual({ t = "focus", id = State.EDIT_INPUT })
		expect((s.editing :: any).text).toBe("100")
		s = key(s, "backspace")
		s = key(s, "backspace")
		s = key(s, "backspace")
		s = typeText(s, "2500")
		s, effects = key(s, "enter")
		expect(s.editing).toBeNil()
		expect(s.writing).toBe(true)
		expect(written(effects).general.max_rows).toBe(2500)
	end)

	it("starts an edit from the effective value when the key is not in the file", function()
		local s = select(open(nil), "quick_actions.logs_tail")
		s = key(s, "e")
		expect((s.editing :: any).text).toBe("200")
	end)

	it("rejects a number outside the loader's range with the loader's message", function()
		local s = select(open('{"schema_version": 1}'), "general.max_rendered_rows")
		s = key(s, "e")
		s = key(s, "u", { ctrl = true })
		s = typeText(s, "999999")
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("expected an integer between 1 and 10000")
		expect(s2.writing).toBe(false)
	end)

	it("rejects text that is not a whole number before validating", function()
		local s = select(open(nil), "explore.query_timeout_ms")
		s = key(s, "e")
		s = key(s, "u", { ctrl = true })
		s = typeText(s, "12.5")
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("whole number")
		expect(s2.editing ~= nil).toBe(true)
	end)

	it("refuses auto_refresh true: the loader would keep it false", function()
		local s = select(open('{"schema_version": 1}'), "explore.auto_refresh")
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("never polls")
	end)

	it("refuses a relative kubeconfig path", function()
		local s = select(open(nil), "kubeconfig")
		s = key(s, "e")
		s = typeText(s, "kube/config")
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("kubeconfig: expected an absolute path")
	end)

	it("unsets an optional key when its text is emptied", function()
		local s = select(open('{"kubeconfig": "/k/config"}'), "kubeconfig")
		s = key(s, "e")
		s = key(s, "u", { ctrl = true })
		local _, effects = key(s, "enter")
		local out = written(effects)
		expect(out.kubeconfig).toBeNil()
		expect(out.schema_version).toBe(1)
	end)

	it("edits lists as JSON and validates their entries", function()
		local s = select(open(nil), "aliases.additional")
		s = key(s, "e")
		expect((s.editing :: any).text).toBe("[]")
		s = key(s, "u", { ctrl = true })
		s = step(s, { t = "key", key = { name = "paste", text = '["k", "kc"]' } })
		local _, effects = key(s, "enter")
		expect(written(effects).aliases.additional).toEqual({ "k", "kc" })

		local bad = select(open(nil), "aliases.additional")
		bad = key(bad, "e")
		bad = key(bad, "u", { ctrl = true })
		bad = typeText(bad, '["no spaces"]')
		local bad2, none = key(bad, "enter")
		expect(writeOf(none)).toBeNil()
		expect((bad2.message :: any).text).toContain("aliases.additional[1]")
	end)

	it("reports malformed JSON in a list edit", function()
		local s = select(open(nil), "quick_actions.shell_command")
		s = key(s, "e")
		s = typeText(s, ",")
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("not valid JSON")
	end)

	it("cancels an edit with esc without writing", function()
		local s = select(open(nil), "gitops.gh")
		s = key(s, "e")
		s = typeText(s, "x")
		local s2, effects = key(s, "escape")
		expect(s2.editing).toBeNil()
		expect(#effects).toBe(0)
	end)

	it("treats j and k as text while editing", function()
		local s = select(open(nil), "gitops.gh")
		s = key(s, "e")
		s = key(s, "u", { ctrl = true })
		s = typeText(s, "jk")
		expect((s.editing :: any).text).toBe("jk")
		expect(State.selected(s).path).toBe("gitops.gh")
	end)
end)

describe("settings state: writes", function()
	local FILE = '{\n  "schema_version": 1,\n  "mystery": {"a": [1]},\n  "general": {"max_rows": 5, "later": true}\n}\n'

	it("keeps unknown keys and schema_version in what it writes", function()
		local s = select(open(FILE), "general.native_default")
		local _, effects = key(s, "enter")
		local out = written(effects)
		expect(out.schema_version).toBe(1)
		expect(out.mystery).toEqual({ a = { 1 } })
		expect(out.general.later).toBe(true)
		expect(out.general.max_rows).toBe(5)
		expect(out.general.native_default).toBe(false)
	end)

	it("keeps a newer schema_version instead of downgrading it", function()
		local s = select(open('{"schema_version": 3, "new_thing": 1}'), "general.native_default")
		local _, effects = key(s, "enter")
		local out = written(effects)
		expect(out.schema_version).toBe(3)
		expect(out.new_thing).toBe(1)
	end)

	it("adds schema_version to a file that lacks it", function()
		local s = select(open('{"general": {"max_rows": 5}}'), "general.native_default")
		local _, effects = key(s, "enter")
		expect(written(effects).schema_version).toBe(Config.SCHEMA_VERSION)
	end)

	it("asks for a write of the read text's replacement, to the resolved target", function()
		local s = select(open(FILE, "/dotfiles/kube-lens.json"), "general.native_default")
		local _, effects = key(s, "enter")
		local e = writeOf(effects) :: Effect
		expect(e.path).toBe("/dotfiles/kube-lens.json")
		expect(e.base).toBe(FILE)
		expect(e.existed).toBe(true)
	end)

	it("creates the file when there is none, marking that nothing existed", function()
		local s = select(open(nil), "general.max_rows")
		s = key(s, "e")
		s = key(s, "u", { ctrl = true })
		s = typeText(s, "10")
		local _, effects = key(s, "enter")
		local e = writeOf(effects) :: Effect
		expect(e.existed).toBe(false)
		expect(e.base).toBeNil()
		expect(decode(e.text :: string)).toEqual({ schema_version = 1, general = { max_rows = 10 } })
	end)

	it("allows one write at a time", function()
		local s = select(open(FILE), "general.native_default")
		s = key(s, "enter")
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("in progress")
	end)

	it("re-reads the file after a write and reports the outcome", function()
		local s = select(open(FILE), "general.native_default")
		s = key(s, "enter")
		local ok, effects = step(s, { t = "written", ok = true })
		expect(ok.writing).toBe(false)
		expect((ok.message :: any).level).toBe("success")
		expect(effects[1]).toEqual({ t = "reload" })
		local failed = step(s, { t = "written", ok = false, error = "the file changed on disk" })
		expect((failed.message :: any).text).toContain("Not saved: the file changed on disk")
	end)

	it("resets a key by removing it from the file", function()
		local s = select(open(FILE), "general.max_rows")
		local _, effects = key(s, "r")
		local out = written(effects)
		expect(out.general.max_rows).toBeNil()
		expect(out.general.later).toBe(true)
	end)

	it("does not write when the key already uses its default", function()
		local s = select(open(FILE), "gitops.gh")
		local s2, effects = key(s, "r")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("already uses its default")
	end)

	it("creates a minimal file before opening a missing one", function()
		local s, effects = key(open(nil), "o")
		local e = writeOf(effects) :: Effect
		expect(e.open).toBe(true)
		expect(e.text).toBe('{\n  "schema_version": 1\n}\n')
		local _, after = step(s, { t = "written", ok = true, open = true })
		expect(after[1]).toEqual({ t = "open", path = PATH })
	end)

	it("cannot write without a config path", function()
		local s = State.init(ENV, nil)
		s = step(s, { t = "file", path = nil, target = nil, text = nil })
		local s2, effects = key(s, "enter")
		expect(writeOf(effects)).toBeNil()
		expect((s2.message :: any).text).toContain("config path is unknown")
	end)
end)

describe("settings state: pointer", function()
	it("selects, toggles and resets by key path", function()
		local s = open('{"mutations": {"enabled": false}}')
		local s1, e1 = step(s, { t = "action", act = "toggle", value = "mutations.enabled" })
		expect(State.selected(s1).path).toBe("mutations.enabled")
		expect(written(e1).mutations.enabled).toBe(true)
		local _, e2 = step(s, { t = "action", act = "reset", value = "mutations.enabled" })
		expect(written(e2).mutations).toBeNil()
	end)

	it("starts editing the selected key when its input is clicked", function()
		local s = select(open(nil), "gitops.gh")
		local s2, effects = step(s, { t = "action", act = "edit-focus", value = "" })
		expect((s2.editing :: any).path).toBe("gitops.gh")
		expect(effects[1]).toEqual({ t = "focus", id = State.EDIT_INPUT })
	end)

	it("ignores unknown key paths", function()
		local s = open(nil)
		local s2, effects = step(s, { t = "action", act = "toggle", value = "nope" })
		expect(s2).toBe(s)
		expect(#effects).toBe(0)
	end)

	it("re-reads everything on Reload", function()
		local _, effects = step(open(nil), { t = "action", act = "reload", value = "" })
		expect(hasEffect(effects, "reload")).toBe(true)
		expect(hasEffect(effects, "probe")).toBe(true)
	end)
end)

describe("settings status facts", function()
	local TOML = table.concat({
		'schema = 1\nid = "kube-lens"\nversion = "0.0.1"\n[[lenses]]\nmatch = [\n\t"kubectl get",',
		"\t" .. State.ALIAS_BEGIN,
		'\t"k get *",\n\t"k -* get *",\n\t"kc describe *",',
		"\t" .. State.ALIAS_END,
		"]\n",
	}, "\n")

	it("reads the plugin version from the manifest", function()
		expect(State.manifestVersion(TOML)).toBe("0.0.1")
	end)

	it("lists only the globs between the alias markers, and their command names", function()
		local claims = State.aliasClaims(TOML) :: { string }
		expect(claims).toEqual({ "k get *", "k -* get *", "kc describe *" })
		expect(State.aliasNames(claims)).toEqual({ "k", "kc" })
		local none, why = State.aliasClaims('match = ["kubectl get"]')
		expect(none).toBeNil()
		expect(why).toContain("markers are missing")
	end)

	it("names where kubectl comes from in the loader's order", function()
		local d = Config.defaults()
		local custom = Config.parse('{"kubectl": "/opt/kubectl"}', decode)
		expect(State.kubectlSource(d, "/kv/kubectl", "/env/kubectl")).toBe("Tern kv key kubectl")
		expect(State.kubectlSource(custom, nil, "/env/kubectl")).toBe("config kubectl")
		expect(State.kubectlSource(d, nil, "/env/kubectl")).toBe("KUBE_LENS_KUBECTL")
		expect(State.kubectlSource(d, nil, nil)).toBe("the daemon's PATH")
	end)

	it("parses kubectl and tern versions", function()
		expect(State.kubectlVersion('{"clientVersion": {"gitVersion": "v1.31.0"}}', decode)).toBe("v1.31.0")
		expect(State.kubectlVersion("not json", decode)).toBeNil()
		expect(State.ternVersion("tern 0.6.2 (4b3ed42)\n")).toBe("0.6.2 (4b3ed42)")
	end)

	it("finds pane env records in the spool listing", function()
		expect(State.recordPanes({ "req-1.json", "pane-12.env", "pane-3.env", "pane-x.env" })).toEqual({ 3, 12 })
	end)
end)

return nil
