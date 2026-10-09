--!strict
-- Pure core of the Tern Kube Settings block: the editable catalog of every
-- config key, the status facts the host collects, key/pointer handling and
-- the config file round trip (decode, change one key, encode with unknown
-- keys kept, validate with Config.parse). The host (settings_host.luau)
-- performs the effects: reads, the atomic write, opening the file.

local Config = require("../config")

type Config = Config.Config
type Diagnostic = Config.Diagnostic

local M = {}

M.EDIT_INPUT = "main.edit"
M.ALIAS_BEGIN = "# BEGIN tern-kube aliases"
M.ALIAS_END = "# END tern-kube aliases"

-- Catalog ----------------------------------------------------------------------

export type Kind = Config.Kind

export type Field = {
	path: string,
	section: string?,
	key: string,
	kind: Kind,
	min: number?,
	max: number?,
	values: { string }?,
	-- Unset is meaningful (kubeconfig, unmanaged_kinds): an empty edit removes the key.
	optional: boolean?,
	doc: string,
}

local function field(spec: Config.Spec, section: string?): Field
	return table.freeze({
		path = if section then section .. "." .. spec.key else spec.key,
		section = section,
		key = spec.key,
		kind = spec.kind,
		min = spec.min,
		max = spec.max,
		values = spec.values,
		optional = spec.optional,
		doc = spec.doc,
	})
end

-- Every key of Config.CATALOG that the user edits, in its order. The
-- managed keys ($schema, schema_version) are kept as they are.
local fields: { Field } = {}
-- Key order of the written file: the documented order, unknown keys after
-- (sorted), so a rewrite never reshuffles a hand-written file needlessly.
local TOP_ORDER: { string } = {}
local ORDER: { [string]: { string } } =
	{ [""] = TOP_ORDER, ["gitops.helm[]"] = { "chart", "release", "namespace", "values" } }
local LIST_PATHS: { [string]: boolean } = { ["gitops.helm[].values"] = true }
for _, spec in Config.CATALOG do
	table.insert(TOP_ORDER, spec.key)
	local children: { Config.Spec } = spec.fields or { spec }
	local section = if spec.fields then spec.key else nil
	if section then
		ORDER[section] = {}
	end
	for _, child in children do
		if child.managed then
			continue
		end
		local f = field(child, section)
		table.insert(fields, f)
		if section then
			table.insert(ORDER[section], f.key)
		end
		if f.kind == "list" or f.kind == "json" then
			LIST_PATHS[f.path] = true
		end
	end
end
M.FIELDS = table.freeze(fields)

local BY_PATH: { [string]: Field } = {}
for _, f in M.FIELDS do
	BY_PATH[f.path] = f
end

function M.field(path: string): Field?
	return BY_PATH[path]
end

-- JSON -------------------------------------------------------------------------

-- `isList` tells an empty decoded array from an empty object (tern.json
-- tags arrays; a plain Lua table cannot say).
export type IsList = (t: any) -> boolean

local function isArray(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k in v do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #v
end

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\b"] = "\\b",
	["\f"] = "\\f",
}

local function quote(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function number(n: number): string
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.17g", n)
end

local function childPath(path: string, key: string): string
	return if path == "" then key else path .. "." .. key
end

local function keysOf(t: { [string]: any }, path: string): { string }
	local known: { string } = ORDER[path] or {}
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, k in known do
		if t[k] ~= nil then
			table.insert(out, k)
			seen[k] = true
		end
	end
	local rest: { string } = {}
	for k in t do
		if type(k) == "string" and not seen[k] then
			table.insert(rest, k)
		end
	end
	table.sort(rest)
	for _, k in rest do
		table.insert(out, k)
	end
	return out
end

local function listLike(v: any, path: string, isList: IsList): boolean
	if next(v) == nil then
		return LIST_PATHS[path] == true or isList(v)
	end
	return isArray(v)
end

local function scalar(v: any): string?
	local tv = type(v)
	if tv == "string" then
		return quote(v)
	elseif tv == "number" then
		return number(v)
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv ~= "table" then
		return "null"
	end
	return nil
end

local function encodeInline(v: any, path: string, isList: IsList): string
	local s = scalar(v)
	if s then
		return s
	end
	if listLike(v, path, isList) then
		local parts: { string } = {}
		for i, item in v do
			parts[i] = encodeInline(item, path .. "[]", isList)
		end
		return "[" .. table.concat(parts, ", ") .. "]"
	end
	local parts: { string } = {}
	for _, k in keysOf(v, path) do
		table.insert(parts, quote(k) .. ": " .. encodeInline(v[k], childPath(path, k), isList))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function encodeBlock(v: any, path: string, indent: string, isList: IsList): string
	local s = scalar(v)
	if s then
		return s
	end
	local inner = indent .. "  "
	if listLike(v, path, isList) then
		if #v == 0 then
			return "[]"
		end
		local flat = true
		for _, item in v do
			if type(item) == "table" then
				flat = false
			end
		end
		if flat then
			return encodeInline(v, path, isList)
		end
		local parts: { string } = {}
		for i, item in v do
			parts[i] = inner .. encodeBlock(item, path .. "[]", inner, isList)
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
	end
	local keys = keysOf(v, path)
	if #keys == 0 then
		return "{}"
	end
	local parts: { string } = {}
	for i, k in keys do
		parts[i] = inner .. quote(k) .. ": " .. encodeBlock(v[k], childPath(path, k), inner, isList)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

-- The config file text for a decoded (and edited) top-level object.
function M.encode(raw: { [string]: any }, isList: IsList): string
	return encodeBlock(raw, "", "", isList) .. "\n"
end

function M.encodeInline(v: any, path: string, isList: IsList): string
	return encodeInline(v, path, isList)
end

-- Raw object edits -------------------------------------------------------------

-- `raw` with the field set to `value` (nil removes it). Only the tables on
-- the path are copied, so untouched values (and their array tags) are kept.
-- A section left empty by a removal is dropped.
function M.setValue(raw: { [string]: any }, f: Field, value: any): { [string]: any }
	local out = table.clone(raw)
	if f.section == nil then
		out[f.key] = value
		return out
	end
	local section = out[f.section]
	local copy: { [string]: any } = if type(section) == "table" and (next(section) == nil or not isArray(section))
		then table.clone(section)
		else {}
	copy[f.key] = value
	if next(copy) == nil then
		out[f.section] = nil
	else
		out[f.section] = copy
	end
	return out
end

-- The value of a field in the decoded file; nil when absent.
function M.rawValue(raw: { [string]: any }?, f: Field): any
	if raw == nil then
		return nil
	end
	if f.section == nil then
		return raw[f.key]
	end
	local section = raw[f.section]
	return if type(section) == "table" then section[f.key] else nil
end

-- The effective value tern-kube uses.
function M.configValue(cfg: Config, f: Field): any
	local c = cfg :: any
	if f.section == nil then
		return c[f.key]
	end
	return c[f.section][f.key]
end

-- Diagnostics about a field (the key itself or its list entries).
function M.diagnosticsFor(diags: { Diagnostic }, path: string): { Diagnostic }
	local out: { Diagnostic } = {}
	for _, d in diags do
		local p = d.path
		if p == path or string.sub(p, 1, #path + 1) == path .. "[" or string.sub(p, 1, #path + 1) == path .. "." then
			table.insert(out, d)
		end
	end
	return out
end

-- State ------------------------------------------------------------------------

export type Env = {
	decode: (string) -> any,
	isList: IsList,
	home: string?,
}

-- An external program as the plugin runs it (env_host.resolve).
export type ToolInfo = {
	-- What goes in argv[1]: absolute when found.
	program: string,
	-- Shellenv.describe: "from your shell's PATH", "not found", ...
	source: string,
	found: boolean,
	version: string?,
	error: string?,
	pending: boolean,
}

-- The login-shell read (env_host.status).
export type ShellEnvInfo = {
	phase: string,
	shell: string?,
	tookMs: number?,
	error: string?,
	entries: number?,
	daemonPath: string,
	kubeconfig: string?,
}

export type PaneRecord = { pane: number, kubeconfig: string?, problem: string?, live: boolean }

export type Info = {
	loadStatus: string,
	pluginVersion: string?,
	pluginDir: string?,
	ternVersion: string?,
	ternPending: boolean,
	kubectl: ToolInfo?,
	helm: ToolInfo?,
	gh: ToolInfo?,
	shellEnv: ShellEnvInfo?,
	aliasClaims: { string }?,
	aliasError: string?,
	spool: string?,
	paneRecords: { PaneRecord },
}

export type Message = { level: "info" | "success" | "error", text: string }

export type Page = "settings" | "status"

export type Edit = { path: string, text: string }

export type State = {
	env: Env,
	path: string?,
	-- The file actually written: the config path, or its target when it is a symlink.
	target: string?,
	loaded: boolean,
	-- File text as last read; nil when the file does not exist.
	text: string?,
	raw: { [string]: any }?,
	fileError: string?,
	config: Config,
	diagnostics: { Diagnostic },
	info: Info,
	page: Page,
	sel: number,
	rows: number,
	editing: Edit?,
	help: boolean,
	writing: boolean,
	message: Message?,
}

export type Effect = {
	t: "write" | "reload" | "open" | "focus" | "exit" | "probe",
	path: string?,
	text: string?,
	base: string?,
	-- write: whether the file existed when `base` was read.
	existed: boolean?,
	-- write: open the file once written.
	open: boolean?,
	id: string?,
}

export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

export type Msg =
	{ t: "file", path: string?, target: string?, text: string?, error: string? }
	| { t: "info", info: { [string]: any } }
	| { t: "written", ok: boolean, error: string?, open: boolean? }
	| { t: "key", key: Key }
	| { t: "action", act: string, value: string }
	| { t: "resize", rows: number }

local function emptyInfo(): Info
	return {
		loadStatus = "resolving",
		pluginVersion = nil,
		pluginDir = nil,
		ternVersion = nil,
		ternPending = true,
		kubectl = nil,
		helm = nil,
		gh = nil,
		shellEnv = nil,
		aliasClaims = nil,
		aliasError = nil,
		spool = nil,
		paneRecords = {},
	}
end

local function indexOf(path: string?): number?
	if path == nil then
		return nil
	end
	for i, f in M.FIELDS do
		if f.path == path then
			return i
		end
	end
	return nil
end

function M.init(env: Env, saved: any): (State, { Effect })
	local s: State = {
		env = env,
		path = nil,
		target = nil,
		loaded = false,
		text = nil,
		raw = nil,
		fileError = nil,
		config = Config.defaults(),
		diagnostics = {},
		info = emptyInfo(),
		page = "settings",
		sel = 1,
		rows = 40,
		editing = nil,
		help = false,
		writing = false,
		message = nil,
	}
	if type(saved) == "table" then
		if saved.page == "status" then
			s.page = "status"
		end
		s.sel = indexOf(if type(saved.sel) == "string" then saved.sel else nil) or 1
	end
	return s, { { t = "reload" }, { t = "probe" } }
end

function M.save(s: State): any
	return { page = s.page, sel = M.FIELDS[s.sel].path }
end

function M.selected(s: State): Field
	return M.FIELDS[s.sel]
end

-- Applies a fresh read of the config file.
local function loadFile(s: State, msg: { path: string?, target: string?, text: string?, error: string? })
	s.path = msg.path
	s.target = msg.target or msg.path
	s.loaded = true
	s.text = msg.text
	s.raw = nil
	s.fileError = msg.error
	if msg.error then
		s.config, s.diagnostics = Config.defaults(), {}
		return
	end
	local text = msg.text
	s.config, s.diagnostics = Config.parse(text, s.env.decode, { home = s.env.home })
	if text == nil or not string.find(text, "%S") then
		s.raw = {}
		return
	end
	local ok, value = pcall(s.env.decode, text)
	if not ok then
		s.fileError = "config.json is not valid JSON; settings cannot be edited until it is fixed (o opens it)."
	elseif type(value) ~= "table" or not string.find(text, "^%s*{") then
		s.fileError = "config.json is not a JSON object; settings cannot be edited until it is fixed (o opens it)."
	else
		s.raw = value
	end
end

-- Display ----------------------------------------------------------------------

export type Origin = "default" | "file" | "invalid"

function M.origin(s: State, f: Field): Origin
	if M.rawValue(s.raw, f) == nil then
		return "default"
	end
	for _, d in M.diagnosticsFor(s.diagnostics, f.path) do
		if d.level == "error" or d.level == "warning" then
			return "invalid"
		end
	end
	return "file"
end

function M.display(s: State, f: Field): string
	local v = M.configValue(s.config, f)
	if v == nil then
		return "unset"
	elseif type(v) == "table" then
		return M.encodeInline(v, f.path, s.env.isList)
	end
	return tostring(v)
end

-- Initial text of an edit: what the file holds, else the effective value.
function M.editText(s: State, f: Field): string
	local v = M.rawValue(s.raw, f)
	if v == nil then
		v = M.configValue(s.config, f)
	end
	if v == nil then
		return ""
	elseif type(v) == "table" then
		return M.encodeInline(v, f.path, s.env.isList)
	end
	return tostring(v)
end

-- Validation and writes ----------------------------------------------------------

local REMOVE = table.freeze({})
M.REMOVE = REMOVE

-- The value an edit's text stands for, or nil and the problem.
function M.parseEdit(s: State, f: Field, text: string): (any, string?)
	local trimmed = string.match(text, "^%s*(.-)%s*$") :: string
	if f.kind == "int" then
		if not string.find(trimmed, "^%-?%d+$") then
			return nil, string.format("%s: enter a whole number between %d and %d", f.path, f.min or 0, f.max or 0)
		end
		return tonumber(trimmed), nil
	elseif f.kind == "string" then
		if trimmed == "" then
			if f.optional then
				return REMOVE, nil
			end
			return nil, f.path .. ": cannot be empty; r resets it to the default"
		end
		return trimmed, nil
	elseif f.kind == "list" or f.kind == "json" then
		if trimmed == "" and f.optional then
			return REMOVE, nil
		end
		if string.sub(trimmed, 1, 1) ~= "[" then
			return nil, f.path .. ': enter a JSON list, e.g. ["a", "b"]'
		end
		local ok, value = pcall(s.env.decode, trimmed)
		if not ok then
			return nil, f.path .. ": not valid JSON: " .. Config.errorText(value)
		end
		if f.optional and type(value) == "table" and next(value) == nil then
			return REMOVE, nil
		end
		return value, nil
	end
	return nil, f.path .. ": not editable as text"
end

-- Validates the file with `f` set to `value` and asks the host to write it.
local function commit(s: State, f: Field, value: any, effects: { Effect }): boolean
	if s.writing then
		s.message = { level = "error", text = "A write is still in progress." }
		return true
	end
	if not s.loaded or s.target == nil then
		s.message = { level = "error", text = "The config path is unknown (no XDG_CONFIG_HOME or HOME)." }
		return true
	end
	if s.fileError or s.raw == nil then
		s.message = { level = "error", text = s.fileError or "The config file could not be read." }
		return true
	end
	local raw = M.setValue(s.raw, f, if value == REMOVE then nil else value)
	if raw.schema_version == nil then
		raw.schema_version = Config.SCHEMA_VERSION
	end
	if s.text == nil then
		raw["$schema"] = Config.SCHEMA_URL
	end
	local text = M.encode(raw, s.env.isList)
	local _, diags = Config.parse(text, s.env.decode, { home = s.env.home })
	for _, d in M.diagnosticsFor(diags, f.path) do
		s.message = { level = "error", text = "Not saved: " .. d.message }
		return true
	end
	s.writing = true
	s.message = {
		level = "info",
		text = (if value == REMOVE then "Resetting " .. f.path else "Saving " .. f.path) .. " …",
	}
	table.insert(effects, { t = "write", path = s.target, text = text, base = s.text, existed = s.text ~= nil })
	return true
end

local function toggle(s: State, f: Field, effects: { Effect }): boolean
	if f.kind == "bool" then
		return commit(s, f, not M.configValue(s.config, f), effects)
	elseif f.kind == "enum" then
		local values = f.values or {}
		local i = table.find(values, M.configValue(s.config, f)) or 0
		return commit(s, f, values[i % #values + 1], effects)
	end
	return false
end

local function startEdit(s: State, effects: { Effect }): boolean
	local f = M.selected(s)
	if f.kind == "bool" or f.kind == "enum" then
		return toggle(s, f, effects)
	end
	if s.fileError then
		s.message = { level = "error", text = s.fileError }
		return true
	end
	s.page = "settings"
	s.editing = { path = f.path, text = M.editText(s, f) }
	table.insert(effects, { t = "focus", id = M.EDIT_INPUT })
	return true
end

local function reset(s: State, f: Field, effects: { Effect }): boolean
	if M.rawValue(s.raw, f) == nil then
		s.message = { level = "info", text = f.path .. " already uses its default." }
		return true
	end
	return commit(s, f, REMOVE, effects)
end

local function openFile(s: State, effects: { Effect }): boolean
	if s.target == nil then
		s.message = { level = "error", text = "The config path is unknown (no XDG_CONFIG_HOME or HOME)." }
		return true
	end
	if s.text == nil and s.fileError == nil then
		-- Tern cannot open a missing file: create a minimal one first.
		if s.writing then
			return false
		end
		s.writing = true
		s.message = { level = "info", text = "Creating " .. s.target .. " …" }
		table.insert(effects, {
			t = "write",
			path = s.target,
			text = Config.STUB_TEXT,
			base = nil,
			existed = false,
			open = true,
		})
		return true
	end
	table.insert(effects, { t = "open", path = s.path })
	return true
end

local function move(s: State, delta: number?, to: number?)
	local n = #M.FIELDS
	local target = to or (s.sel + (delta or 0))
	s.sel = math.clamp(target, 1, n)
end

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function editKey(s: State, key: Key, effects: { Effect }): boolean
	local edit = s.editing :: Edit
	local name = key.name
	if name == "escape" then
		s.editing = nil
		s.message = nil
		return true
	elseif name == "enter" or name == "return" then
		local f = M.field(edit.path) :: Field
		local value, problem = M.parseEdit(s, f, edit.text)
		if problem then
			s.message = { level = "error", text = problem }
			return true
		end
		s.editing = nil
		return commit(s, f, value, effects)
	elseif name == "backspace" then
		s.editing = { path = edit.path, text = string.sub(edit.text, 1, -2) }
		return true
	elseif name == "paste" then
		local text = string.gsub(key.text or "", "[\r\n]+", " ")
		s.editing = { path = edit.path, text = edit.text .. text }
		return true
	elseif key.ctrl and name == "u" then
		s.editing = { path = edit.path, text = "" }
		return true
	end
	local ch = printable(key)
	if ch then
		s.editing = { path = edit.path, text = edit.text .. ch }
		return true
	end
	return false
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	if s.editing then
		return editKey(s, key, effects)
	end
	local name = key.name
	local ch = printable(key)
	if s.help then
		if name == "escape" or ch == "?" then
			s.help = false
			return true
		end
		return false
	end
	if ch == "?" then
		s.help = true
	elseif name == "escape" then
		table.insert(effects, { t = "exit" })
	elseif name == "tab" then
		s.page = if s.page == "settings" then "status" else "settings"
	elseif ch == "o" then
		return openFile(s, effects)
	elseif ch == "R" or (name == "r" and key.shift) then
		s.message = { level = "info", text = "Reloaded the config file and status." }
		table.insert(effects, { t = "reload" })
		table.insert(effects, { t = "probe" })
	elseif s.page ~= "settings" then
		return false
	elseif ch == "j" or name == "down" then
		move(s, 1)
	elseif ch == "k" or name == "up" then
		move(s, -1)
	elseif name == "home" or ch == "g" then
		move(s, nil, 1)
	elseif name == "end" or ch == "G" then
		move(s, nil, #M.FIELDS)
	elseif name == "pagedown" then
		move(s, M.viewport(s.rows))
	elseif name == "pageup" then
		move(s, -M.viewport(s.rows))
	elseif name == "enter" or name == "return" or name == "space" or ch == "e" then
		return startEdit(s, effects)
	elseif ch == "r" then
		return reset(s, M.selected(s), effects)
	else
		return false
	end
	return true
end

local function selectPath(s: State, path: string): boolean
	local i = indexOf(path)
	if i == nil then
		return false
	end
	s.sel = i
	return true
end

local function onAction(s: State, act: string, value: string, effects: { Effect }): boolean
	if act == "sel" then
		if s.editing and s.editing.path ~= value then
			s.editing = nil
		end
		return selectPath(s, value)
	elseif act == "toggle" or act == "edit" then
		if not selectPath(s, value) then
			return false
		end
		s.editing = nil
		return startEdit(s, effects)
	elseif act == "reset" then
		if not selectPath(s, value) then
			return false
		end
		s.editing = nil
		return reset(s, M.selected(s), effects)
	elseif act == "edit-focus" then
		if s.editing then
			return false
		end
		local f = M.selected(s)
		if f.kind == "bool" or f.kind == "enum" then
			return false
		end
		return startEdit(s, effects)
	elseif act == "edit-apply" then
		if s.editing == nil then
			return false
		end
		return editKey(s, { name = "enter" }, effects)
	elseif act == "edit-cancel" then
		if s.editing == nil then
			return false
		end
		return editKey(s, { name = "escape" }, effects)
	elseif act == "page" then
		if value ~= "settings" and value ~= "status" then
			return false
		end
		s.page = value :: Page
	elseif act == "open" then
		return openFile(s, effects)
	elseif act == "reload" then
		return onKey(s, { name = "R", text = "R" }, effects)
	elseif act == "help" then
		s.help = not s.help
	elseif act == "exit" then
		table.insert(effects, { t = "exit" })
	else
		return false
	end
	return true
end

local function mergeInfo(s: State, patch: { [string]: any })
	local info = table.clone(s.info) :: any
	for k, v in patch do
		info[k] = v
	end
	s.info = info
end

-- Rows the settings list gets in a block `rows` cells tall.
function M.viewport(rows: number): number
	return math.max(5, rows - 12)
end

-- Applies `msg`; returns the next state (a new table when anything changed)
-- and the effects for the host.
function M.update(prev: State, msg: Msg): (State, { Effect })
	local s = table.clone(prev)
	local effects: { Effect } = {}
	local changed: boolean
	if msg.t == "file" then
		loadFile(s, msg :: any)
		changed = true
	elseif msg.t == "info" then
		mergeInfo(s, (msg :: any).info)
		changed = true
	elseif msg.t == "written" then
		local m = msg :: any
		s.writing = false
		if m.ok then
			s.message = { level = "success", text = "Saved. New lens blocks and Explore blocks use it." }
			if m.open then
				table.insert(effects, { t = "open", path = s.path })
			end
		else
			s.message = { level = "error", text = "Not saved: " .. tostring(m.error) }
		end
		table.insert(effects, { t = "reload" })
		changed = true
	elseif msg.t == "key" then
		changed = onKey(s, (msg :: any).key, effects)
	elseif msg.t == "action" then
		local m = msg :: any
		changed = onAction(s, m.act, m.value, effects)
	elseif msg.t == "resize" then
		changed = s.rows ~= (msg :: any).rows
		s.rows = (msg :: any).rows
	else
		changed = false
	end
	if not changed and #effects == 0 then
		return prev, effects
	end
	return s, effects
end

-- Status facts (pure parsing of what the host reads) -----------------------------

-- `version = "x"` of the installed plugin.toml.
function M.manifestVersion(toml: string): string?
	return string.match(toml, '\nversion%s*=%s*"([^"\n]+)"') or string.match(toml, '^version%s*=%s*"([^"\n]+)"')
end

-- Lens match globs between the alias markers of plugin.toml; nil and the
-- problem when the markers are missing.
function M.aliasClaims(toml: string): ({ string }?, string?)
	local b = string.find(toml, M.ALIAS_BEGIN, 1, true)
	local e = string.find(toml, M.ALIAS_END, 1, true)
	if b == nil or e == nil or e < b then
		return nil, "the alias markers are missing from plugin.toml"
	end
	local out: { string } = {}
	for glob in string.gmatch(string.sub(toml, b, e), '"([^"\n]+)"') do
		table.insert(out, glob)
	end
	return out, nil
end

-- Command names claimed by alias globs ("k get *" -> "k").
function M.aliasNames(claims: { string }): { string }
	local out: { string } = {}
	for _, glob in claims do
		local name = string.match(glob, "^([^%s]+)")
		if name and not table.find(out, name) then
			table.insert(out, name)
		end
	end
	return out
end

-- clientVersion.gitVersion of `kubectl version --client -o json`.
function M.kubectlVersion(stdout: string, decode: (string) -> any): string?
	local ok, value = pcall(decode, stdout)
	if not ok or type(value) ~= "table" or type(value.clientVersion) ~= "table" then
		return nil
	end
	local v = value.clientVersion.gitVersion
	return if type(v) == "string" then v else nil
end

-- "tern 0.6.2 (4b3ed42)" -> "0.6.2 (4b3ed42)".
function M.ternVersion(stdout: string): string?
	local v = string.match(stdout, "^%s*tern%s+([^\n]-)%s*$") or string.match(stdout, "^%s*tern%s+([^\n]+)")
	return v
end

-- Pane env records in the spool: `pane-<id>.env` names.
function M.recordPanes(names: { string }): { number }
	local out: { number } = {}
	for _, name in names do
		local id = string.match(name, "^pane%-(%d+)%.env$")
		if id then
			table.insert(out, tonumber(id) :: number)
		end
	end
	table.sort(out)
	return out
end

-- Safety and supported operations (static, shown on the status page) --------------

M.TIERS = table.freeze({
	{
		tier = "Enter",
		text = "scale, rollout restart, apply, debug container, CronJob run-now, after a clean preview",
	},
	{
		tier = "Typed",
		text = "every delete; --prune/--force; selectors, --all, -A; cluster-scoped or namespace/CRD deletes; "
			.. "debug node; --server/--cluster overrides; privileged/hostPath manifests",
	},
	{
		tier = "Blocked",
		text = "preview pending or failed (unless allow_failed_preview_override), mutations.enabled false, "
			.. "inputs or target changed since the preview",
	},
})

M.OPERATIONS = table.freeze({
	{ what = "Lens", text = "kubectl/kubecolor get, describe, top, apply, delete, rollout restart, scale" },
	{ what = "Explore", text = "lists, object, describe, logs, relations; context/namespace/kind pickers" },
	{ what = "Quick actions", text = "shell, follow logs, port-forward in a split; debug, CronJob run-now" },
	{ what = "Mutations", text = "apply, delete, scale, rollout restart via preview + diff + confirm" },
	{ what = "Shell guard", text = "opt-in zsh/bash/fish: apply, delete, scale, rollout restart" },
	{ what = "GitOps", text = "open/diff manifest, drift report, export, branch/commit/PR" },
})

return M
