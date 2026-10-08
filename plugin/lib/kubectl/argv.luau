--!strict
-- Mirrors cobra command lookup and pflag parsing as used by kubectl: flags may
-- appear anywhere, shorthand clusters are bools until the first value flag
-- (which takes the rest of the cluster or the next token), and `--` ends flags.
local Types = require("../model/types")
local flagTables = require("./flags")
local kinds = require("./kinds")

type Invocation = Types.Invocation
type Arity = "bool" | "value" | "optional"
type FlagDef = { name: string, arity: Arity }
type FlagSet = { long: { [string]: FlagDef }, short: { [string]: FlagDef } }

local function addSpec(set: FlagSet, spec: flagTables.FlagSpec)
	local function add(entry: string, arity: Arity)
		local name, short = string.match(entry, "^([^/]+)/(.)$")
		local long = name or entry
		local def: FlagDef = {
			name = long,
			arity = if arity == "value" and flagTables.optionalValue[long] then "optional" else arity,
		}
		set.long[long] = def
		if short then
			set.short[short] = def
		end
	end
	for _, e in spec.bool do
		add(e, "bool")
	end
	for _, e in spec.value do
		add(e, "value")
	end
end

local function newSet(): FlagSet
	local set: FlagSet = { long = {}, short = {} }
	addSpec(set, flagTables.global)
	addSpec(set, { bool = { "help/h" }, value = {} })
	return set
end

local globalSet = newSet()

-- Arity of any kubectl flag regardless of command; used before the command is
-- known, the way cobra strips flags while searching for the subcommand.
local anySet: FlagSet = newSet()
do
	for _, spec in flagTables.commands do
		local local_: FlagSet = { long = {}, short = {} }
		addSpec(local_, spec)
		for name, def in local_.long do
			local prev = anySet.long[name]
			if prev == nil or (prev.arity == "bool" and def.arity ~= "bool") then
				anySet.long[name] = def
			end
		end
		for s, def in local_.short do
			local prev = anySet.short[s]
			if prev == nil or (prev.arity == "bool" and def.arity ~= "bool") then
				anySet.short[s] = def
			end
		end
	end
end

local commandSets: { [string]: FlagSet } = {}
local function setFor(path: string?): FlagSet
	if path == nil then
		return globalSet
	end
	local cached = commandSets[path]
	if cached then
		return cached
	end
	local set = newSet()
	local spec: flagTables.FlagSpec? = flagTables.commands[path]
	if spec == nil then
		local parent = string.match(path, "^(%S+)")
		spec = if parent then flagTables.commands[parent] else nil
	end
	if spec then
		addSpec(set, spec)
	end
	commandSets[path] = set
	return set
end

local KUBECOLOR_BOOL = {
	plain = true,
	["light-background"] = true,
	["force-colors"] = true,
	["kubecolor-version"] = true,
}
local KUBECOLOR_VALUE = { ["kubecolor-theme"] = true }

local function basename(program: string): string
	return string.match(program, "([^/\\]+)$") or program
end

local function stripKubecolor(args: { string }): { string }
	local out = {}
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == "--" then
			table.move(args, i, #args, #out + 1, out)
			break
		end
		local name = string.match(a, "^%-%-([%w%-]+)")
		if name and KUBECOLOR_BOOL[name] then
			i += 1
		elseif name and KUBECOLOR_VALUE[name] then
			i += if string.find(a, "=", 1, true) then 1 else 2
		else
			table.insert(out, a)
			i += 1
		end
	end
	return out
end

type Token = { kind: "flag", name: string, value: string?, raw: string } | { kind: "pos", value: string, index: number }

local function isFlagLike(s: string?): boolean
	return s ~= nil and #s > 1 and string.sub(s, 1, 1) == "-"
end

type Scan = { tokens: { Token }, afterDash: { string }, unknown: { string }, ambiguities: { string } }

-- Tokenises args against a flag set. Unknown flags never consume the next
-- token; when that token could be their value an ambiguity is recorded.
local function scan(args: { string }, set: FlagSet): Scan
	local result: Scan = { tokens = {}, afterDash = {}, unknown = {}, ambiguities = {} }
	local function unknownFlag(raw: string, hasValue: boolean, nextArg: string?)
		table.insert(result.unknown, raw)
		if not hasValue and nextArg ~= nil and not isFlagLike(nextArg) and nextArg ~= "--" then
			table.insert(
				result.ambiguities,
				string.format("unknown flag %s: %q may be its value or a positional argument", raw, nextArg)
			)
		end
	end
	local i = 1
	while i <= #args do
		local a = args[i]
		local nextArg = args[i + 1]
		if a == "--" then
			table.move(args, i + 1, #args, 1, result.afterDash)
			break
		elseif string.sub(a, 1, 2) == "--" and #a > 2 then
			local body = string.sub(a, 3)
			local eq = string.find(body, "=", 1, true)
			local name = if eq then string.sub(body, 1, eq - 1) else body
			local inline = if eq then string.sub(body, eq + 1) else nil
			local def = set.long[name]
			if def == nil then
				unknownFlag("--" .. name, inline ~= nil, nextArg)
				table.insert(result.tokens, { kind = "flag", name = name, value = inline or "true", raw = a })
			elseif inline ~= nil then
				table.insert(result.tokens, { kind = "flag", name = def.name, value = inline, raw = a })
			elseif def.arity == "bool" then
				table.insert(result.tokens, { kind = "flag", name = def.name, value = "true", raw = a })
			elseif def.arity == "optional" then
				table.insert(result.tokens, {
					kind = "flag",
					name = def.name,
					value = flagTables.optionalValue[def.name],
					raw = a,
				})
			elseif nextArg ~= nil then
				table.insert(result.tokens, { kind = "flag", name = def.name, value = nextArg, raw = a })
				i += 1
			else
				table.insert(result.ambiguities, string.format("flag --%s is missing its value", def.name))
				table.insert(result.tokens, { kind = "flag", name = def.name, value = nil, raw = a })
			end
		elseif string.sub(a, 1, 1) == "-" and #a > 1 then
			local pos = 2
			while pos <= #a do
				local c = string.sub(a, pos, pos)
				local def = set.short[c]
				local rest = string.sub(a, pos + 1)
				local explicit = if string.sub(rest, 1, 1) == "=" then string.sub(rest, 2) else nil
				if def == nil then
					unknownFlag("-" .. c, explicit ~= nil or rest ~= "", if rest == "" then nextArg else nil)
					table.insert(
						result.tokens,
						{ kind = "flag", name = c, value = if explicit ~= nil then explicit else "true", raw = a }
					)
					break
				elseif explicit ~= nil then
					table.insert(result.tokens, { kind = "flag", name = def.name, value = explicit, raw = a })
					break
				elseif def.arity == "bool" then
					table.insert(result.tokens, { kind = "flag", name = def.name, value = "true", raw = a })
					pos += 1
				elseif def.arity == "optional" then
					table.insert(result.tokens, {
						kind = "flag",
						name = def.name,
						value = if rest ~= "" then rest else flagTables.optionalValue[def.name],
						raw = a,
					})
					break
				elseif rest ~= "" then
					table.insert(result.tokens, { kind = "flag", name = def.name, value = rest, raw = a })
					break
				elseif nextArg ~= nil then
					table.insert(result.tokens, { kind = "flag", name = def.name, value = nextArg, raw = a })
					i += 1
					break
				else
					table.insert(result.ambiguities, string.format("flag -%s is missing its value", c))
					table.insert(result.tokens, { kind = "flag", name = def.name, value = nil, raw = a })
					break
				end
			end
		else
			table.insert(result.tokens, { kind = "pos", value = a, index = i })
		end
		i += 1
	end
	return result
end

local function resolveSub(parent: string, token: string?): string?
	if token == nil then
		return nil
	end
	local aliases = flagTables.subcommandAliases[parent]
	local canonical = if aliases and aliases[token] then aliases[token] else token
	local subs = flagTables.subcommands[parent]
	if subs and table.find(subs, canonical) then
		return canonical
	end
	return nil
end

local function splitList(value: string): { string }
	local out = {}
	for part in string.gmatch(value, "[^,]+") do
		table.insert(out, part)
	end
	return out
end

local OUTPUT_PREFIXES: { { prefix: string, format: Types.OutputFormat } } = {
	{ prefix = "custom-columns-file", format = "custom-columns-file" },
	{ prefix = "custom-columns", format = "custom-columns" },
	{ prefix = "jsonpath-as-json", format = "jsonpath" },
	{ prefix = "jsonpath-file", format = "jsonpath" },
	{ prefix = "jsonpath", format = "jsonpath" },
	{ prefix = "go-template-file", format = "go-template" },
	{ prefix = "go-template", format = "go-template" },
	{ prefix = "templatefile", format = "template" },
	{ prefix = "template", format = "template" },
}

local SIMPLE_OUTPUTS: { [string]: Types.OutputFormat } = {
	wide = "wide",
	json = "json",
	yaml = "yaml",
	name = "name",
}

local function outputOf(value: string?, template: string?): (Types.OutputFormat, string?)
	if value == nil or value == "" then
		if template ~= nil then
			return "template", template
		end
		return "table", nil
	end
	local simple: Types.OutputFormat? = SIMPLE_OUTPUTS[value]
	if simple then
		return simple, nil
	end
	for _, entry in OUTPUT_PREFIXES do
		local p = entry.prefix
		if value == p then
			return entry.format, template
		end
		if string.sub(value, 1, #p + 1) == p .. "=" then
			return entry.format, string.sub(value, #p + 2)
		end
	end
	return "other", value
end

-- Verbs whose first positional is TYPE[,TYPE] or TYPE/NAME, followed by names.
local TYPED_VERBS = {
	get = true,
	describe = true,
	delete = true,
	edit = true,
	label = true,
	annotate = true,
	patch = true,
	scale = true,
	rollout = true,
	explain = true,
	wait = true,
	autoscale = true,
	expose = true,
	set = true,
}

-- Verbs addressing a pod (or TYPE/NAME) as first positional.
local POD_VERBS = { logs = true, exec = true, attach = true, ["port-forward"] = true }

local function isLabelEdit(s: string): boolean
	return string.find(s, "=", 1, true) ~= nil or string.sub(s, -1) == "-"
end

local function slashed(token: string): Types.ResourceArg?
	local typ, name = string.match(token, "^([^/]+)/(.+)$")
	if typ == nil or name == nil then
		return nil
	end
	local k = kinds.normalize(typ)
	return { kind = k.kind, group = k.group, name = name }
end

local function resourcesFor(
	verb: string?,
	subverb: string?,
	positionals: { string }
): ({ Types.ResourceArg }, { string })
	local resources: { Types.ResourceArg } = {}
	local names: { string } = {}
	if verb == nil or #positionals == 0 then
		return resources, names
	end
	if verb == "top" then
		local kind = if subverb == "node" then "Node" elseif subverb == "pod" then "Pod" else nil
		if kind then
			for _, n in positionals do
				table.insert(names, n)
				table.insert(resources, { kind = kind, group = nil, name = n })
			end
		end
		return resources, names
	end
	if POD_VERBS[verb] then
		local first = positionals[1]
		local typed = slashed(first)
		local r: Types.ResourceArg = typed or { kind = "Pod", group = nil, name = first }
		table.insert(resources, r)
		table.insert(names, r.name :: string)
		return resources, names
	end
	if not TYPED_VERBS[verb] or (verb == "set" and subverb == nil) then
		return resources, names
	end
	local args = positionals
	local filtersEdits = verb == "label"
		or verb == "annotate"
		or (verb == "set" and (subverb == "env" or subverb == "image" or subverb == "resources"))
	if filtersEdits then
		args = {}
		for _, p in positionals do
			if not isLabelEdit(p) then
				table.insert(args, p)
			end
		end
	end
	if #args == 0 then
		return resources, names
	end
	if string.find(args[1], "/", 1, true) then
		for _, a in args do
			local r = slashed(a)
			if r then
				table.insert(resources, r)
				table.insert(names, r.name :: string)
			end
		end
		return resources, names
	end
	local types: { Types.ResourceArg } = {}
	for _, typ in splitList(args[1]) do
		if typ == "all" then
			table.insert(types, { kind = "all", group = nil, name = nil })
		else
			local k = kinds.normalize(typ)
			table.insert(types, { kind = k.kind, group = k.group, name = nil })
		end
	end
	if #args == 1 then
		return types, names
	end
	for idx = 2, #args do
		local n = args[idx]
		table.insert(names, n)
		for _, t in types do
			table.insert(resources, { kind = t.kind, group = t.group, name = n })
		end
	end
	return resources, names
end

local function last(list: { string }?): string?
	return if list then list[#list] else nil
end

local function truthy(list: { string }?): boolean
	local v = last(list)
	return v ~= nil and v ~= "false"
end

local M = {}

function M.parse(program: string, args: { string }): Invocation
	local input = if basename(program) == "kubecolor" then stripKubecolor(args) else args

	local pre = scan(input, anySet)
	local verb: string? = nil
	local subverb: string? = nil
	local commandTokens: { [number]: boolean } = {}
	for _, tok in pre.tokens do
		if tok.kind == "pos" then
			if verb == nil then
				verb = tok.value
				commandTokens[tok.index] = true
			else
				local sub = resolveSub(verb, tok.value)
				if sub then
					subverb = sub
					commandTokens[tok.index] = true
				end
				break
			end
		end
	end

	local path = if verb and subverb then verb .. " " .. subverb else verb
	local s = scan(input, setFor(path))

	local flags: { [string]: { string } } = {}
	local positionals: { string } = {}
	for _, tok in s.tokens do
		if tok.kind == "flag" then
			local list = flags[tok.name]
			if list == nil then
				list = {}
				flags[tok.name] = list
			end
			if tok.value ~= nil then
				table.insert(list, tok.value)
			end
		elseif not commandTokens[tok.index] then
			table.insert(positionals, tok.value)
		end
	end

	local filenames: { string } = {}
	for _, v in flags.filename or {} :: { string } do
		for _, f in splitList(v) do
			table.insert(filenames, f)
		end
	end
	local labelColumns: { string } = {}
	for _, v in flags["label-columns"] or {} :: { string } do
		for _, c in splitList(v) do
			table.insert(labelColumns, c)
		end
	end

	local output: Types.OutputFormat, outputSpec: string? = outputOf(last(flags.output), last(flags.template))
	local resources, names = resourcesFor(verb, subverb, positionals)

	return {
		program = program,
		verb = verb,
		subverb = subverb,
		resources = resources,
		names = names,
		namespace = last(flags.namespace),
		allNamespaces = truthy(flags["all-namespaces"]),
		context = last(flags.context),
		kubeconfig = last(flags.kubeconfig),
		cluster = last(flags.cluster),
		user = last(flags.user),
		output = output,
		outputSpec = outputSpec,
		watch = truthy(flags.watch) or truthy(flags["watch-only"]),
		noHeaders = truthy(flags["no-headers"]),
		showLabels = truthy(flags["show-labels"]),
		showKind = truthy(flags["show-kind"]),
		selector = last(flags.selector),
		fieldSelector = last(flags["field-selector"]),
		sortBy = last(flags["sort-by"]),
		labelColumns = labelColumns,
		filenames = filenames,
		recursive = truthy(flags.recursive),
		kustomize = last(flags.kustomize),
		dryRun = last(flags["dry-run"]),
		flags = flags,
		positionals = positionals,
		afterDash = s.afterDash,
		unknownFlags = s.unknown,
		ambiguities = s.ambiguities,
	}
end

export type LensSupport = { supported: boolean, reason: string? }

local RAW_VERBS: { [string]: string } = {
	logs = "Logs stream as plain text; showing raw output.",
	exec = "exec runs an interactive command in a container; showing raw output.",
	attach = "attach connects to a running container; showing raw output.",
	["port-forward"] = "port-forward is a long-running tunnel; showing raw output.",
	proxy = "proxy is a long-running server; showing raw output.",
	edit = "edit opens an editor; showing raw output.",
	explain = "explain prints API documentation; showing raw output.",
	debug = "debug starts an interactive session; showing raw output.",
	cp = "cp copies files; showing raw output.",
}

local NATIVE_VERBS = { get = true, describe = true, top = true, apply = true, delete = true, scale = true }

local UNSUPPORTED_OUTPUT: { [Types.OutputFormat]: string } = {
	jsonpath = "jsonpath output is free-form; use -o json or -o yaml for a native view.",
	["go-template"] = "go-template output is free-form; use -o json or -o yaml for a native view.",
	template = "Template output is free-form; use -o json or -o yaml for a native view.",
	["custom-columns-file"] = "Columns from a file cannot be read by the lens; use -o custom-columns=... inline.",
	other = "This output format is not recognized; use -o wide, -o json or -o yaml for a native view.",
}

function M.lensSupport(inv: Invocation): LensSupport
	local verb = inv.verb
	if verb == nil then
		return { supported = false, reason = "No kubectl command was given; showing raw output." }
	end
	local rawReason = RAW_VERBS[verb]
	if rawReason then
		return { supported = false, reason = rawReason }
	end
	if inv.flags.raw ~= nil then
		return { supported = false, reason = "--raw prints the API response verbatim; showing raw output." }
	end
	if inv.watch then
		return {
			supported = false,
			reason = "Watch mode streams changes; run without -w/--watch for a native view.",
		}
	end
	local outputReason = UNSUPPORTED_OUTPUT[inv.output]
	if outputReason then
		return { supported = false, reason = outputReason }
	end
	if verb == "rollout" then
		if inv.subverb == "restart" then
			return { supported = true }
		end
		return {
			supported = false,
			reason = string.format("kubectl rollout %s has no native view yet; showing raw output.", inv.subverb or ""),
		}
	end
	if NATIVE_VERBS[verb] then
		return { supported = true }
	end
	return {
		supported = false,
		reason = string.format("kubectl %s has no native view yet; showing raw output.", verb),
	}
end

return M
