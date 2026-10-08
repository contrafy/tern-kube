--!strict
-- The user's config file ($XDG_CONFIG_HOME/kube-lens/config.json), parsed
-- and validated. A bad value never fails the load: it falls back to its
-- default and yields a diagnostic naming the key path, so a typo can never
-- take the plugin down or silently weaken a safety default.

local M = {}

M.SCHEMA_VERSION = 1
M.RELATIVE_PATH = "kube-lens/config.json"
M.DEFAULT_SHELL_COMMAND = table.freeze({ "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh" })

export type Placement = "right" | "down" | "tab"

export type Config = {
	schema_version: number,
	general: {
		native_default: boolean,
		max_rows: number,
		max_rendered_rows: number,
		max_capture_bytes: number,
	},
	aliases: { additional: { string } },
	explore: {
		allow_live_queries: boolean,
		auto_refresh: boolean,
		query_timeout_ms: number,
		relationship_max_nodes: number,
	},
	mutations: {
		enabled: boolean,
		interactive_guard: boolean,
		require_target_confirmation: boolean,
		allow_failed_preview_override: boolean,
		preview_timeout_ms: number,
		execute_timeout_ms: number,
	},
	security: {
		show_secret_values: boolean,
		sensitive_output_strict_mode: boolean,
	},
	quick_actions: {
		placement: Placement,
		shell_command: { string },
		logs_tail: number,
		debug_image: string,
	},
	kubectl: string,
	kubeconfig: string?,
	gitops: { [string]: any },
}

export type Level = "error" | "warning" | "info"

export type Diagnostic = {
	level: Level,
	-- Dotted key path ("general.max_rows", "aliases.additional[2]"); "" is the whole file.
	path: string,
	message: string,
	-- Invalid JSON only: 1-based byte offset, line and column of the error when known.
	offset: number?,
	line: number?,
	column: number?,
}

export type ParseOptions = { home: string? }

type Ctx = { diags: { Diagnostic }, home: string?, newer: boolean }
type Check = (value: any, path: string, default: any, ctx: Ctx) -> any
type Field = { key: string, check: Check }

local function freezeDeep<T>(t: T): T
	for _, v in t :: any do
		if type(v) == "table" and not table.isfrozen(v) then
			freezeDeep(v)
		end
	end
	return table.freeze(t :: any) :: any
end

function M.defaults(): Config
	local cfg: Config = {
		schema_version = M.SCHEMA_VERSION,
		general = {
			native_default = true,
			max_rows = 20000,
			max_rendered_rows = 500,
			max_capture_bytes = 16777216,
		},
		aliases = { additional = {} },
		explore = {
			allow_live_queries = true,
			auto_refresh = false,
			query_timeout_ms = 10000,
			relationship_max_nodes = 250,
		},
		mutations = {
			enabled = true,
			interactive_guard = false,
			require_target_confirmation = true,
			allow_failed_preview_override = false,
			preview_timeout_ms = 30000,
			execute_timeout_ms = 300000,
		},
		security = {
			show_secret_values = false,
			sensitive_output_strict_mode = false,
		},
		quick_actions = {
			placement = "right",
			shell_command = table.clone(M.DEFAULT_SHELL_COMMAND),
			logs_tail = 200,
			debug_image = "busybox:1.36",
		},
		kubectl = "kubectl",
		kubeconfig = nil,
		gitops = {},
	}
	return freezeDeep(cfg)
end

-- Shapes ----------------------------------------------------------------------

local function isObject(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	for k in v do
		if type(k) ~= "string" then
			return false
		end
	end
	return true
end

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

local function isInteger(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v == v and math.abs(v) ~= math.huge
end

local function quoteString(s: string): string
	if #s > 60 then
		s = string.sub(s, 1, 57) .. "..."
	end
	return string.format("%q", s)
end

local function show(v: any): string
	local tv = type(v)
	if tv == "nil" then
		return "null (unset)"
	elseif tv == "string" then
		return quoteString(v)
	elseif tv == "number" then
		return if isInteger(v) then string.format("%d", v) else tostring(v)
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv == "table" then
		if isArray(v) and next(v) ~= nil then
			local parts: { string } = {}
			for i, item in v do
				parts[i] = show(item)
			end
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		return if next(v) == nil then "[]" else "an object"
	end
	return "null"
end

local function describeGot(v: any): string
	if type(v) == "table" then
		return if isArray(v) and next(v) ~= nil then "a list" else "an object"
	end
	if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
		return "null"
	end
	return type(v) .. " " .. show(v)
end

local function add(ctx: Ctx, level: Level, path: string, message: string)
	table.insert(ctx.diags, { level = level, path = path, message = path .. ": " .. message })
end

local function reject(ctx: Ctx, path: string, expected: string, got: any, default: any)
	add(
		ctx,
		"error",
		path,
		string.format("expected %s, got %s; using the default %s.", expected, describeGot(got), show(default))
	)
end

-- Checks ----------------------------------------------------------------------

local function bool(): Check
	return function(v, path, default, ctx)
		if type(v) == "boolean" then
			return v
		end
		reject(ctx, path, "true or false", v, default)
		return default
	end
end

local function int(min: number, max: number): Check
	return function(v, path, default, ctx)
		if isInteger(v) and v >= min and v <= max then
			return v
		end
		reject(ctx, path, string.format("an integer between %d and %d", min, max), v, default)
		return default
	end
end

local function enum(values: { string }): Check
	local quoted: { string } = {}
	for i, s in values do
		quoted[i] = string.format("%q", s)
	end
	local expected = "one of " .. table.concat(quoted, ", ")
	return function(v, path, default, ctx)
		if type(v) == "string" and table.find(values, v) then
			return v
		end
		reject(ctx, path, expected, v, default)
		return default
	end
end

local function argv(): Check
	return function(v, path, default, ctx)
		if isArray(v) and #v > 0 and #v <= 32 then
			local out: { string } = {}
			for i, item in v do
				if type(item) ~= "string" or item == "" then
					reject(ctx, path, "a non-empty list of non-empty strings (program and arguments)", v, default)
					return default
				end
				out[i] = item
			end
			return out
		end
		reject(ctx, path, "a non-empty list of up to 32 strings (program and arguments)", v, default)
		return default
	end
end

local function image(): Check
	return function(v, path, default, ctx)
		if type(v) == "string" and #v <= 255 and string.find(v, "^[%w][%w%._/:@%-]*$") then
			return v
		end
		reject(ctx, path, 'a container image reference without spaces (e.g. "busybox:1.36")', v, default)
		return default
	end
end

local function expandHome(v: string, ctx: Ctx): (string?, string?)
	if v ~= "~" and string.sub(v, 1, 2) ~= "~/" then
		return v, nil
	end
	local home = ctx.home
	if home == nil or home == "" then
		return nil, "starts with ~ but the home directory is unknown; use an absolute path"
	end
	return (string.gsub(home, "/+$", "")) .. string.sub(v, 2), nil
end

-- `program` allows a bare name looked up on the daemon's PATH.
local function filePath(program: boolean): Check
	local expected = if program then "a program name or an absolute path" else "an absolute path or null"
	return function(v, path, default, ctx)
		if type(v) ~= "string" or v == "" then
			reject(ctx, path, expected, v, default)
			return default
		end
		local expanded, problem = expandHome(v, ctx)
		if expanded == nil then
			add(ctx, "error", path, string.format("%s; using the default %s.", problem :: string, show(default)))
			return default
		end
		local absolute = string.sub(expanded, 1, 1) == "/"
		local bare = program and not string.find(expanded, "/", 1, true)
		if not absolute and not bare then
			reject(ctx, path, expected, v, default)
			return default
		end
		return expanded
	end
end

local ALIAS_NAME = "^[%w_][%w_%.%-]*$"

local function aliasNames(): Check
	return function(v, path, default, ctx)
		if not isArray(v) then
			reject(ctx, path, "a list of command names", v, default)
			return default
		end
		local out: { string } = {}
		for i, item in v do
			if type(item) == "string" and #item <= 64 and string.find(item, ALIAS_NAME) then
				table.insert(out, item)
			else
				add(
					ctx,
					"error",
					string.format("%s[%d]", path, i),
					string.format(
						"expected a command name (letters, digits, _ . -), got %s; the entry is ignored.",
						describeGot(item)
					)
				)
			end
		end
		return out
	end
end

local function autoRefresh(): Check
	local check = bool()
	return function(v, path, default, ctx)
		local value = check(v, path, default, ctx)
		if value == true then
			add(
				ctx,
				"warning",
				path,
				"Explore never polls the cluster; refresh with r or the Refresh chip. Using false."
			)
			return false
		end
		return value
	end
end

local function schemaVersion(): Check
	return function(v, path, default, ctx)
		if not isInteger(v) or v < 1 then
			reject(ctx, path, "a positive integer", v, default)
			return default
		end
		if v > M.SCHEMA_VERSION then
			ctx.newer = true
			add(
				ctx,
				"warning",
				path,
				string.format(
					"file is schema_version %d but this kube-lens understands %d; known settings are applied, "
						.. "unknown ones are ignored. Update kube-lens to use them.",
					v,
					M.SCHEMA_VERSION
				)
			)
		end
		return v
	end
end

-- Schema ----------------------------------------------------------------------

local SECTIONS: { { key: string, fields: { Field } } } = {
	{
		key = "general",
		fields = {
			{ key = "native_default", check = bool() },
			{ key = "max_rows", check = int(1, 100000) },
			{ key = "max_rendered_rows", check = int(1, 10000) },
			{ key = "max_capture_bytes", check = int(65536, 268435456) },
		},
	},
	{ key = "aliases", fields = { { key = "additional", check = aliasNames() } } },
	{
		key = "explore",
		fields = {
			{ key = "allow_live_queries", check = bool() },
			{ key = "auto_refresh", check = autoRefresh() },
			{ key = "query_timeout_ms", check = int(500, 600000) },
			{ key = "relationship_max_nodes", check = int(1, 5000) },
		},
	},
	{
		key = "mutations",
		fields = {
			{ key = "enabled", check = bool() },
			{ key = "interactive_guard", check = bool() },
			{ key = "require_target_confirmation", check = bool() },
			{ key = "allow_failed_preview_override", check = bool() },
			{ key = "preview_timeout_ms", check = int(1000, 600000) },
			{ key = "execute_timeout_ms", check = int(1000, 3600000) },
		},
	},
	{
		key = "security",
		fields = {
			{ key = "show_secret_values", check = bool() },
			{ key = "sensitive_output_strict_mode", check = bool() },
		},
	},
	{
		key = "quick_actions",
		fields = {
			{ key = "placement", check = enum({ "right", "down", "tab" }) },
			{ key = "shell_command", check = argv() },
			{ key = "logs_tail", check = int(1, 100000) },
			{ key = "debug_image", check = image() },
		},
	},
}

local TOP_LEVEL: { Field } = {
	{ key = "schema_version", check = schemaVersion() },
	{ key = "kubectl", check = filePath(true) },
	{ key = "kubeconfig", check = filePath(false) },
}

local KNOWN_TOP: { [string]: boolean } = { gitops = true }
for _, s in SECTIONS do
	KNOWN_TOP[s.key] = true
end
for _, f in TOP_LEVEL do
	KNOWN_TOP[f.key] = true
end

local function warnUnknown(obj: { [string]: any }, known: { [string]: boolean }, prefix: string, ctx: Ctx)
	local unknown: { string } = {}
	for k in obj do
		if not known[k] then
			table.insert(unknown, k)
		end
	end
	table.sort(unknown)
	local hint = if ctx.newer
		then "unknown key, possibly from a newer kube-lens; it is ignored."
		else "unknown key; it is ignored. Check the spelling against docs/configuration.md."
	for _, k in unknown do
		add(ctx, "warning", prefix .. k, hint)
	end
end

local function applySection(raw: any, key: string, fields: { Field }, defaults: { [string]: any }, ctx: Ctx): any
	local out = table.clone(defaults)
	if raw == nil then
		return out
	end
	if not isObject(raw) then
		add(
			ctx,
			"error",
			key,
			string.format("expected an object, got %s; using the defaults for this section.", describeGot(raw))
		)
		return out
	end
	local known: { [string]: boolean } = {}
	for _, f in fields do
		known[f.key] = true
		local v = raw[f.key]
		if v ~= nil then
			out[f.key] = f.check(v, key .. "." .. f.key, defaults[f.key], ctx)
		end
	end
	warnUnknown(raw, known, key .. ".", ctx)
	return out
end

-- Invalid JSON ------------------------------------------------------------------

local function lineColumn(text: string, offset: number): (number, number)
	local line, start = 1, 1
	for pos in string.gmatch(string.sub(text, 1, offset - 1), "()\n") do
		line += 1
		start = (pos :: number) + 1
	end
	return line, offset - start + 1
end

local function offsetOf(text: string, line: number, column: number): number
	local start = 1
	for _ = 2, line do
		local nl = string.find(text, "\n", start, true)
		if nl == nil then
			break
		end
		start = nl + 1
	end
	return math.min(start + column - 1, #text + 1)
end

-- Tern errors arrive as "runtime error: tern.json.decode: <reason>" plus a
-- stack traceback; users need only the reason.
function M.errorText(err: any): string
	local first = string.match(tostring(err), "^[^\n]*") :: string
	first = string.gsub(first, "^runtime error: ", "")
	first = string.gsub(first, "^tern%.json%.decode: ", "")
	return (string.gsub(first, "%s+$", ""))
end

local function decodeDiagnostic(text: string, err: any): Diagnostic
	local raw = M.errorText(err)
	local offset, line, column
	local byte = string.match(raw, "byte (%d+)")
	if byte then
		offset = tonumber(byte) :: number
		line, column = lineColumn(text, offset)
	else
		local l, c = string.match(raw, "line (%d+),? column (%d+)")
		if l and c then
			line, column = tonumber(l) :: number, tonumber(c) :: number
			offset = offsetOf(text, line, column)
		end
	end
	local where = if offset
		then string.format(" at byte %d (line %d, column %d)", offset, line :: number, column :: number)
		else ""
	return {
		level = "error",
		path = "",
		message = string.format(
			"config.json is not valid JSON%s: %s. Using the defaults for every setting until the file is fixed.",
			where,
			raw
		),
		offset = offset,
		line = line,
		column = column,
	}
end

-- API -------------------------------------------------------------------------

-- `decode` is tern.json.decode in the plugin (raises on malformed input).
-- nil, empty or blank text means "no config file": all defaults, no diagnostics.
function M.parse(text: string?, decode: (string) -> any, opts: ParseOptions?): (Config, { Diagnostic })
	local diags: { Diagnostic } = {}
	if text == nil or not string.find(text, "%S") then
		return M.defaults(), diags
	end
	local ok, value = pcall(decode, text)
	if not ok then
		table.insert(diags, decodeDiagnostic(text, value))
		return M.defaults(), diags
	end
	-- An empty JSON array decodes to the same empty table as an empty object.
	if not isObject(value) or not string.find(text, "^%s*{") then
		table.insert(diags, {
			level = "error",
			path = "",
			message = string.format(
				"config.json must contain a JSON object ({ ... }), got %s. Using the defaults for every setting.",
				describeGot(value)
			),
		})
		return M.defaults(), diags
	end

	local ctx: Ctx = { diags = diags, home = opts and opts.home, newer = false }
	local defaults = M.defaults()
	local out: { [string]: any } = table.clone(defaults :: any)

	local dflt = defaults :: any
	local top = TOP_LEVEL[1]
	if value[top.key] ~= nil then
		out[top.key] = top.check(value[top.key], top.key, dflt[top.key], ctx)
	end
	for _, s in SECTIONS do
		out[s.key] = applySection(value[s.key], s.key, s.fields, dflt[s.key], ctx)
	end
	for i = 2, #TOP_LEVEL do
		local f = TOP_LEVEL[i]
		if value[f.key] ~= nil then
			out[f.key] = f.check(value[f.key], f.key, dflt[f.key], ctx)
		end
	end

	local gitops = value.gitops
	if gitops ~= nil then
		if not isObject(gitops) then
			reject(ctx, "gitops", "an object", gitops, {})
		elseif next(gitops) ~= nil then
			add(
				ctx,
				"info",
				"gitops",
				"section is reserved for a later kube-lens milestone; its keys are not read yet."
			)
		end
	end

	warnUnknown(value, KNOWN_TOP, "", ctx)
	return freezeDeep(out) :: any, diags
end

-- Where the file lives: $XDG_CONFIG_HOME/kube-lens/config.json when that is
-- an absolute path (the XDG spec says to ignore relative values), else
-- $HOME/.config/kube-lens/config.json.
function M.path(env: { XDG_CONFIG_HOME: string?, HOME: string? }): string?
	local xdg = env.XDG_CONFIG_HOME
	if xdg and string.sub(xdg, 1, 1) == "/" then
		return (string.gsub(xdg, "/+$", "")) .. "/" .. M.RELATIVE_PATH
	end
	local home = env.HOME
	if home and home ~= "" then
		return (string.gsub(home, "/+$", "")) .. "/.config/" .. M.RELATIVE_PATH
	end
	return nil
end

-- The kubectl program to run. The kv override serves tests and the settings
-- flow; an explicit config value beats KUBE_LENS_KUBECTL; the bare default
-- "kubectl" defers to it.
function M.kubectlProgram(cfg: Config, kvValue: any, envValue: string?): string
	if type(kvValue) == "string" and kvValue ~= "" then
		return kvValue
	end
	if cfg.kubectl ~= "kubectl" then
		return cfg.kubectl
	end
	if envValue and envValue ~= "" then
		return envValue
	end
	return "kubectl"
end

return M
