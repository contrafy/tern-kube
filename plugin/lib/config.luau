--!strict
-- The user's config file ($XDG_CONFIG_HOME/tern-kube/config.json), parsed
-- and validated. A bad value never fails the load: it falls back to its
-- default and yields a diagnostic naming the key path, so a typo can never
-- take the plugin down or silently weaken a safety default.

local M = {}

M.SCHEMA_VERSION = 1
M.RELATIVE_PATH = "tern-kube/config.json"
-- The published JSON Schema (schema/config.schema.json, `make schema`).
M.SCHEMA_URL = "https://raw.githubusercontent.com/contrafy/tern-kube/master/schema/config.schema.json"
M.DEFAULT_SHELL_COMMAND = table.freeze({ "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh" })

export type Placement = "right" | "down" | "tab"

-- `helm template <release> <chart> [-n namespace] [-f values]...`; paths are
-- absolute or relative to the repository root.
export type HelmRelease = { chart: string, release: string, namespace: string?, values: { string } }

export type Config = {
	schema_version: number,
	general: {
		native_default: boolean,
		max_rows: number,
		max_rendered_rows: number,
		max_capture_bytes: number,
		shell_env: boolean,
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
	gitops: {
		helm: { HelmRelease },
		-- Kinds checked for unmanaged objects; nil = the kinds the source declares.
		unmanaged_kinds: { string }?,
		max_files: number,
		max_bytes: number,
		max_file_bytes: number,
		render_kustomize: boolean,
		gh: string,
	},
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

-- How the Settings block edits a key; "section" is an object of keys.
export type Kind = "bool" | "int" | "enum" | "string" | "list" | "json" | "section"

-- One key of the file: the single source for the loader, the Settings
-- catalog and the published JSON Schema (scripts/gen-config-schema.luau).
export type Spec = {
	key: string,
	kind: Kind,
	doc: string,
	check: Check,
	-- JSON Schema keywords for the value besides description and default.
	schema: { [string]: any },
	min: number?,
	max: number?,
	values: { string }?,
	-- Unset is meaningful (kubeconfig, unmanaged_kinds).
	optional: boolean?,
	-- Kept by tern-kube, not edited in Settings ($schema, schema_version).
	managed: boolean?,
	fields: { Spec }?,
}

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
			shell_env = true,
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
		gitops = {
			helm = {},
			unmanaged_kinds = nil,
			max_files = 2000,
			max_bytes = 33554432,
			max_file_bytes = 1048576,
			render_kustomize = true,
			gh = "gh",
		},
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

-- `program` allows a bare name, resolved by lib/env/shellenv.luau.
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
					"file is schema_version %d but this tern-kube understands %d; known settings are applied, "
						.. "unknown ones are ignored. Update tern-kube to use them.",
					v,
					M.SCHEMA_VERSION
				)
			)
		end
		return v
	end
end

local function dnsLabel(s: any): boolean
	return type(s) == "string"
		and #s <= 63
		and string.find(s, "^[a-z0-9][a-z0-9%-]*$") ~= nil
		and string.find(s, "[a-z0-9]$") ~= nil
end

local function relPath(v: any, ctx: Ctx): string?
	if type(v) ~= "string" or v == "" or #v > 4096 or string.find(v, "%c") then
		return nil
	end
	return (expandHome(v, ctx))
end

-- `gitops.helm`: releases rendered by `helm template` for diff and drift.
local function helmReleases(): Check
	return function(v, path, default, ctx)
		if not isArray(v) then
			reject(ctx, path, "a list of {chart, release, namespace?, values?} objects", v, default)
			return default
		end
		local out: { HelmRelease } = {}
		for i, item in v do
			local at = string.format("%s[%d]", path, i)
			local problem: string? = nil
			local chart = if isObject(item) then relPath(item.chart, ctx) else nil
			local values: { string } = {}
			if not isObject(item) then
				problem = "expected an object with chart and release"
			elseif chart == nil then
				problem = "chart must be a path (absolute or relative to the repository root)"
			elseif not dnsLabel(item.release) then
				problem = "release must be a lowercase DNS label"
			elseif item.namespace ~= nil and not dnsLabel(item.namespace) then
				problem = "namespace must be a lowercase DNS label"
			elseif item.values ~= nil and not isArray(item.values) then
				problem = "values must be a list of paths"
			else
				for _, f in (item.values or {}) :: { any } do
					local p = relPath(f, ctx)
					if p == nil then
						problem = "values must be a list of paths"
						break
					end
					table.insert(values, p)
				end
			end
			if problem then
				add(ctx, "error", at, problem .. "; the entry is ignored.")
			else
				table.insert(out, {
					chart = chart :: string,
					release = item.release,
					namespace = item.namespace,
					values = values,
				})
			end
		end
		return out
	end
end

local KIND_TOKEN = "^[%a][%w%-]*[%.%w%-]*$"

-- `gitops.unmanaged_kinds`: Kind or kind.group tokens.
local function kindList(): Check
	return function(v, path, default, ctx)
		if not isArray(v) or #v == 0 or #v > 64 then
			reject(
				ctx,
				path,
				'a non-empty list of up to 64 kinds (e.g. "Deployment", "widgets.example.com")',
				v,
				default
			)
			return default
		end
		local out: { string } = {}
		for i, item in v do
			if type(item) == "string" and #item <= 253 and string.find(item, KIND_TOKEN) then
				table.insert(out, item)
			else
				add(
					ctx,
					"error",
					string.format("%s[%d]", path, i),
					string.format(
						'expected a kind such as "Deployment", got %s; the entry is ignored.',
						describeGot(item)
					)
				)
			end
		end
		return if #out > 0 then out else default
	end
end

local function schemaRef(): Check
	return function(v, path, _default, ctx)
		if type(v) ~= "string" then
			add(
				ctx,
				"warning",
				path,
				string.format("expected the schema URL (a string), got %s; it is ignored.", describeGot(v))
			)
		end
		return nil
	end
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
		then "unknown key, possibly from a newer tern-kube; it is ignored."
		else "unknown key; it is ignored. Check the spelling against docs/configuration.md."
	for _, k in unknown do
		add(ctx, "warning", prefix .. k, hint)
	end
end

local function section(fields: { Spec }): Check
	return function(raw, key, defaults, ctx)
		local out = table.clone(defaults)
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
end

-- Catalog -----------------------------------------------------------------------

-- JSON Schema patterns below restate the Lua patterns of the checks above.
local PROGRAM_SCHEMA = { type = "string", pattern = "^(/|~/|[^/]+$)" }
local NO_CONTROL = "^[^\\x00-\\x1F\\x7F]+$"
local DNS_LABEL_SCHEMA = { type = "string", maxLength = 63, pattern = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" }
local REL_PATH_SCHEMA = { type = "string", maxLength = 4096, pattern = NO_CONTROL }

local function spec(
	key: string,
	kind: Kind,
	doc: string,
	check: Check,
	schema: { [string]: any },
	extra: { [string]: any }?
): Spec
	local s: { [string]: any } = { key = key, kind = kind, doc = doc, check = check, schema = schema }
	if extra then
		for k, v in extra do
			s[k] = v
		end
	end
	return s :: any
end

local function boolSpec(key: string, doc: string): Spec
	return spec(key, "bool", doc, bool(), { type = "boolean" })
end

local function intSpec(key: string, min: number, max: number, doc: string): Spec
	return spec(
		key,
		"int",
		doc,
		int(min, max),
		{ type = "integer", minimum = min, maximum = max },
		{ min = min, max = max }
	)
end

local function sectionSpec(key: string, doc: string, fields: { Spec }): Spec
	return spec(key, "section", doc, section(fields), { type = "object" }, { fields = fields })
end

local PLACEMENTS = { "right", "down", "tab" }

-- Every key of the file in its documented order (the order Settings lists
-- and writes them).
M.CATALOG = freezeDeep({
	spec(
		"$schema",
		"string",
		"JSON Schema of this file, for editor completion and validation; tern-kube ignores it",
		schemaRef(),
		{ type = "string" },
		{ managed = true }
	),
	spec(
		"schema_version",
		"int",
		"Version of this file's format; kept by tern-kube",
		schemaVersion(),
		{ type = "integer", minimum = 1, maximum = M.SCHEMA_VERSION },
		{ managed = true }
	),
	sectionSpec("general", "Native views, capture limits and the login-shell environment", {
		boolSpec("native_default", "Native views for lensed kubectl output; off shows Tern's raw output"),
		intSpec("max_rows", 1, 100000, "Output lines recorded for a native view; more falls back to raw"),
		intSpec("max_rendered_rows", 1, 10000, "Rows drawn at once (lens pages, Explore windows)"),
		intSpec("max_capture_bytes", 65536, 268435456, "Output bytes captured per command; more falls back to raw"),
		boolSpec(
			"shell_env",
			"Read PATH and KUBECONFIG from your login shell (once per Tern daemon) so kubectl, helm, gh and "
				.. "credential plugins are found when Tern starts from the Dock or Finder"
		),
	}),
	sectionSpec("aliases", "Command aliases for kubectl", {
		spec(
			"additional",
			"list",
			"Alias names you intend to claim (informational; scripts/tern-kube-aliases writes the claims)",
			aliasNames(),
			{
				type = "array",
				items = { type = "string", maxLength = 64, pattern = "^[A-Za-z0-9_][A-Za-z0-9_.-]*$" },
			}
		),
	}),
	sectionSpec("explore", "The Tern Kube Explore block", {
		boolSpec("allow_live_queries", "Off: Explore opens but runs no kubectl command"),
		spec(
			"auto_refresh",
			"bool",
			"Only false is supported: Explore never polls",
			autoRefresh(),
			{ type = "boolean", const = false }
		),
		intSpec("query_timeout_ms", 500, 600000, "Each Explore kubectl call is killed after this many ms"),
		intSpec("relationship_max_nodes", 1, 5000, "Objects in a relations graph before it is truncated"),
	}),
	sectionSpec("mutations", "Previews and confirmations for apply, delete, rollout restart and scale", {
		boolSpec("enabled", "Off hides every mutating action; the approve block refuses"),
		boolSpec("interactive_guard", "Marks the opt-in shell guard as wanted (installed separately)"),
		boolSpec("require_target_confirmation", "Mutations need a named or confirmed context, never an inferred one"),
		boolSpec("allow_failed_preview_override", "Allow confirming when the dry run or diff failed"),
		intSpec("preview_timeout_ms", 1000, 600000, "Each preview step is killed after this many ms"),
		intSpec("execute_timeout_ms", 1000, 3600000, "A confirmed mutation is killed after this many ms"),
	}),
	sectionSpec("security", "Secret and sensitive value masking", {
		boolSpec("show_secret_values", "Show Secret values in native views (trusted screens only)"),
		boolSpec("sensitive_output_strict_mode", "Also mask values whose names look sensitive (heuristic)"),
	}),
	sectionSpec("quick_actions", "Shell, logs, port-forward and debug terminals", {
		spec(
			"placement",
			"enum",
			"Where quick-action terminals open",
			enum(PLACEMENTS),
			{ type = "string", enum = PLACEMENTS },
			{ values = PLACEMENTS }
		),
		spec(
			"shell_command",
			"list",
			"Program and arguments the Shell action runs in the container",
			argv(),
			{ type = "array", minItems = 1, maxItems = 32, items = { type = "string", minLength = 1 } }
		),
		intSpec("logs_tail", 1, 100000, "History lines the Logs action shows before following"),
		spec(
			"debug_image",
			"string",
			"Image for debug containers and node debug pods",
			image(),
			{ type = "string", maxLength = 255, pattern = "^[A-Za-z0-9][A-Za-z0-9._/:@-]*$" }
		),
	}),
	spec(
		"kubectl",
		"string",
		"kubectl program: an absolute path, or a name looked up on your shell's PATH, common install dirs, then Tern's PATH",
		filePath(true),
		PROGRAM_SCHEMA
	),
	spec(
		"kubeconfig",
		"string",
		"Kubeconfig for Explore links that name none (absolute path; empty = unset)",
		filePath(false),
		{ type = { "string", "null" }, pattern = "^(/|~/|~$)" },
		{ optional = true }
	),
	sectionSpec("gitops", "Manifest index, diff, drift and export", {
		spec(
			"helm",
			"json",
			"Helm releases for diff and drift: [{chart, release, namespace?, values?}]",
			helmReleases(),
			{
				type = "array",
				items = {
					type = "object",
					required = { "chart", "release" },
					properties = {
						chart = REL_PATH_SCHEMA,
						release = DNS_LABEL_SCHEMA,
						namespace = DNS_LABEL_SCHEMA,
						values = { type = "array", items = REL_PATH_SCHEMA },
					},
				},
			}
		),
		spec(
			"unmanaged_kinds",
			"list",
			"Kinds the drift report checks for unmanaged objects (empty = the source's kinds)",
			kindList(),
			{
				type = { "array", "null" },
				minItems = 1,
				maxItems = 64,
				items = { type = "string", maxLength = 253, pattern = "^[A-Za-z][A-Za-z0-9-]*[.A-Za-z0-9-]*$" },
			},
			{ optional = true }
		),
		intSpec("max_files", 1, 20000, "Manifest files indexed per scan"),
		intSpec("max_bytes", 1048576, 268435456, "Total bytes read per manifest scan"),
		intSpec("max_file_bytes", 4096, 16777216, "Larger manifest files are skipped"),
		boolSpec("render_kustomize", "Render kustomizations while indexing so overlays map to live names"),
		spec(
			"gh",
			"string",
			"GitHub CLI for the optional pull request step: an absolute path, or a name looked up like kubectl's",
			filePath(true),
			PROGRAM_SCHEMA
		),
	}),
}) :: { Spec }

local KNOWN_TOP: { [string]: boolean } = {}
for _, s in M.CATALOG do
	KNOWN_TOP[s.key] = true
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
	for _, s in M.CATALOG do
		local v = value[s.key]
		if v ~= nil then
			out[s.key] = s.check(v, s.key, dflt[s.key], ctx)
		end
	end
	warnUnknown(value, KNOWN_TOP, "", ctx)
	return freezeDeep(out) :: any, diags
end

-- Where the file lives: $XDG_CONFIG_HOME/tern-kube/config.json when that is
-- an absolute path (the XDG spec says to ignore relative values), else
-- $HOME/.config/tern-kube/config.json.
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

-- What the first plugin load writes when there is no config file: just
-- enough for editors to find the schema; every setting stays at its default.
M.STUB_TEXT = string.format('{\n  "$schema": "%s",\n  "schema_version": %d\n}\n', M.SCHEMA_URL, M.SCHEMA_VERSION)

return M
