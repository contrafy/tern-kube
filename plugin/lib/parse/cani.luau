--!strict
-- Reads `kubectl auth can-i`. A single question prints `yes` (exit 0), `no`
-- (exit 1: an answer, not a failure) or `no - <reason>`; with -q only the
-- exit status answers. Warnings about unknown types or verbs go to stderr
-- and the question is still answered. `--list` prints `Resources  Non-Resource
-- URLs  Resource Names  Verbs` rows with bracketed, space-separated lists and
-- a blank Resources cell on non-resource rows; the three trailing bracket
-- groups are read from the right, so the header and --no-headers forms parse
-- alike.

local TableParser = require("./table")
local Types = require("../model/types")

type Diagnostic = Types.Diagnostic
type Invocation = Types.Invocation

export type Answer = {
	answer: ("yes" | "no")?,
	reason: string?,
	-- The output line that answered; nil when the exit status did.
	line: number?,
	diagnostics: { Diagnostic },
}

export type Question = {
	verb: string?,
	-- The resource as typed (`pods`, `deployments.apps`, `pods/log`, `*`).
	typed: string?,
	resource: string?,
	group: string?,
	name: string?,
	subresource: string?,
	url: string?,
	namespace: string?,
	allNamespaces: boolean,
	context: string?,
	as: string?,
	asGroups: { string },
	asUid: string?,
	user: string?,
	token: boolean,
	-- Answered for someone other than the context's own user.
	impersonated: boolean,
}

export type Rule = {
	resource: string?,
	group: string?,
	subresource: string?,
	urls: { string },
	names: { string },
	verbs: { string },
	-- Resources, Non-Resource URLs, Resource Names, Verbs as printed.
	cells: { string },
	line: number,
}

export type ListParse = { rules: { Rule }, diagnostics: { Diagnostic } }

local M = {}

M.HEADERS = table.freeze({ "Resources", "Non-Resource URLs", "Resource Names", "Verbs" })

local function rtrim(s: string): string
	return (string.gsub(s, "%s+$", ""))
end

function M.answer(lines: { string }, status: number?, quiet: boolean): Answer
	local diagnostics: { Diagnostic } = {}
	local answer: ("yes" | "no")? = nil
	local reason: string? = nil
	local at: number? = nil
	local failed = false
	for n, raw in lines do
		local line = rtrim(raw)
		if line == "" then
			continue
		end
		local d = TableParser.classify(line, n)
		if d then
			failed = failed or d.severity == "error"
			table.insert(diagnostics, d)
			continue
		end
		if answer == nil and (line == "yes" or line == "no") then
			answer = line :: any
			at = n
			continue
		end
		local why = if answer == nil then string.match(line, "^no %- (.+)$") else nil
		if why then
			answer = "no"
			reason = why
			at = n
			continue
		end
		table.insert(diagnostics, { line = n, severity = "info", text = line })
	end
	if answer == nil and quiet and not failed then
		if status == 0 then
			answer = "yes"
		elseif status == 1 then
			answer = "no"
		end
	end
	return { answer = answer, reason = reason, line = at, diagnostics = diagnostics }
end

local function flagValues(inv: Invocation, name: string): { string }
	return inv.flags[name] or {}
end

local function last(list: { string }): string?
	return list[#list]
end

-- The question as kubectl reads it: `VERB TYPE[.GROUP][/NAME]` or `VERB
-- /non-resource-url`.
function M.question(inv: Invocation): Question
	local verb = inv.positionals[1]
	local typed = inv.positionals[2]
	local q: Question = {
		verb = verb,
		typed = typed,
		resource = nil,
		group = nil,
		name = nil,
		subresource = last(flagValues(inv, "subresource")),
		url = nil,
		namespace = inv.namespace,
		allNamespaces = inv.allNamespaces,
		context = inv.context,
		as = last(flagValues(inv, "as")),
		asGroups = table.clone(flagValues(inv, "as-group")),
		asUid = last(flagValues(inv, "as-uid")),
		user = inv.user,
		token = inv.flags.token ~= nil,
		impersonated = false,
	}
	if typed and string.sub(typed, 1, 1) == "/" then
		q.url = typed
	elseif typed then
		local typ, name = string.match(typed, "^([^/]+)/(.+)$")
		local resource = typ or typed
		q.name = name
		local plural, group = string.match(resource, "^([^.]+)%.(.+)$")
		q.resource = plural or resource
		q.group = group
	end
	q.impersonated = q.as ~= nil or #q.asGroups > 0 or q.asUid ~= nil or q.user ~= nil or q.token
	return q
end

local function items(bracketed: string): { string }
	local out: { string } = {}
	for w in string.gmatch(string.sub(bracketed, 2, -2), "%S+") do
		table.insert(out, w)
	end
	return out
end

local LIST_ROW = "^(.-)%s*(%[[^%]]*%])%s+(%[[^%]]*%])%s+(%[[^%]]*%])$"

function M.list(lines: { string }): ListParse
	local rules: { Rule } = {}
	local diagnostics: { Diagnostic } = {}
	for n, raw in lines do
		local line = rtrim(raw)
		if line == "" then
			continue
		end
		local d = TableParser.classify(line, n)
		if d then
			table.insert(diagnostics, d)
			continue
		end
		if string.find(line, "^Resources%s+Non%-Resource URLs%s+Resource Names%s+Verbs$") then
			continue
		end
		local res, urls, names, verbs = string.match(line, LIST_ROW)
		if res == nil or urls == nil or names == nil or verbs == nil then
			table.insert(diagnostics, { line = n, severity = "info", text = line })
			continue
		end
		local cell = string.match(res, "^%s*(.-)$") or ""
		local rule: Rule = {
			resource = nil,
			group = nil,
			subresource = nil,
			urls = items(urls),
			names = items(names),
			verbs = items(verbs),
			cells = { cell, urls, names, verbs },
			line = n,
		}
		if cell ~= "" then
			local typ, sub = string.match(cell, "^([^/]+)/(.+)$")
			local resource = typ or cell
			rule.subresource = sub
			local plural, group = string.match(resource, "^([^.]+)%.(.+)$")
			rule.resource = plural or resource
			rule.group = group
		end
		table.insert(rules, rule)
	end
	return { rules = rules, diagnostics = diagnostics }
end

return M
