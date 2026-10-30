--!strict
-- Reads the per-object lines kubectl prints for the mutating verbs:
-- `kind[.group]/name action` and `kind[.group] "name" action [from ns
-- namespace]`, each optionally suffixed with a dry-run marker. Actions are
-- kubectl's words (`configured`, `labeled`, `not labeled`, `unlabeled`,
-- `already cordoned`, `rolled back`, `paused`, `edited`, ...); patch's no-op
-- `patched (no change)` (printed without a dry-run marker even in a dry
-- run) reads as `unchanged`, like apply's.

local Types = require("../model/types")

type Diagnostic = Types.Diagnostic
type MutationResult = Types.MutationResult
type MutationParse = Types.MutationParse

local M = {}

-- `-o name` prints only `kind/name`; the verb implies the action.
local NAME_ONLY_ACTIONS: { [string]: string } = {
	apply = "applied",
	delete = "deleted",
	scale = "scaled",
	rollout = "restarted",
	restart = "restarted",
	["rollout restart"] = "restarted",
	["rollout undo"] = "rolled back",
	["rollout pause"] = "paused",
	["rollout resume"] = "resumed",
	patch = "patched",
	label = "labeled",
	annotate = "annotated",
	edit = "edited",
}

local function splitResource(token: string): (string, string?)
	local dot = string.find(token, ".", 1, true)
	if dot == nil then
		return token, nil
	end
	return string.sub(token, 1, dot - 1), string.sub(token, dot + 1)
end

local function splitDryRun(rest: string): (string, ("server" | "client")?)
	local base = string.match(rest, "^(.-)%s*%(server dry run%)$")
	if base then
		return base, "server"
	end
	base = string.match(rest, "^(.-)%s*%(dry run%)$") or string.match(rest, "^(.-)%s*%(client dry run%)$")
	if base then
		return base, "client"
	end
	return rest, nil
end

local function isAction(text: string): boolean
	return string.match(text, "^%l[%l%- ]*$") ~= nil and string.sub(text, -1) ~= " "
end

local function result(resource: string, name: string, rest: string, lineNo: number, quoted: boolean): MutationResult?
	local action, dryRun: ("server" | "client")? = splitDryRun(rest)
	local noChange = string.match(action, "^(.-)%s*%(no change%)$")
	if noChange and isAction(noChange) then
		action = "unchanged"
	end
	local namespace: string? = nil
	if quoted then
		local base, ns = string.match(action, "^(.-) from (%S+) namespace$")
		if base and ns then
			action, namespace = base, ns
		end
	end
	if not isAction(action) then
		return nil
	end
	local kind, group = splitResource(resource)
	return {
		kind = kind,
		group = group,
		name = name,
		namespace = namespace,
		action = action,
		dryRun = dryRun,
		line = lineNo,
	}
end

local function parseResult(verb: string, line: string, lineNo: number): MutationResult?
	local resource, name, rest = string.match(line, '^([%w%.%-]+) "([^"]+)" (.+)$')
	if resource and name and rest then
		return result(resource, name, rest, lineNo, true)
	end
	resource, name, rest = string.match(line, "^([%w%.%-]+)/(%S+) (.+)$")
	if resource and name and rest then
		return result(resource, name, rest, lineNo, false)
	end
	resource, name = string.match(line, "^([%w%.%-]+)/(%S+)$")
	local implied = NAME_ONLY_ACTIONS[verb]
	if resource and name and implied then
		local kind, group = splitResource(resource)
		return { kind = kind, group = group, name = name, action = implied, line = lineNo }
	end
	return nil
end

local function isError(line: string): boolean
	return string.match(line, "^[Ee]rror[%s:]") ~= nil
		or string.match(line, '^The %S+ "[^"]*" is invalid') ~= nil
		or string.match(line, "^[Uu]nable to ") ~= nil
end

local function isWarning(line: string): boolean
	return string.match(line, "^Warning:") ~= nil or string.match(line, "^W%d%d%d%d %d") ~= nil
end

function M.parse(verb: string, lines: { string }): MutationParse
	local results: { MutationResult } = {}
	local diagnostics: { Diagnostic } = {}
	local openError: Diagnostic? = nil
	local confirming = false
	for lineNo, raw in lines do
		local line = string.match(raw, "^(.-)%s*$") or raw
		if line == "" then
			openError = nil
			continue
		end
		if isError(line) then
			local diagnostic: Diagnostic = { line = lineNo, severity = "error", text = line }
			table.insert(diagnostics, diagnostic)
			openError = diagnostic
			continue
		end
		if isWarning(line) then
			table.insert(diagnostics, { line = lineNo, severity = "warning", text = line })
			openError = nil
			continue
		end
		if string.match(line, "^You are about to delete the following") then
			confirming = true
		elseif string.match(line, "^Do you want to continue%?") then
			confirming = false
			table.insert(diagnostics, { line = lineNo, severity = "info", text = line })
			continue
		end
		local parsed = if confirming then nil else parseResult(verb, line, lineNo)
		if parsed then
			table.insert(results, parsed)
			openError = nil
		elseif openError then
			openError.text ..= "\n" .. line
		else
			table.insert(diagnostics, { line = lineNo, severity = "info", text = line })
		end
	end
	return { results = results, diagnostics = diagnostics }
end

return M
