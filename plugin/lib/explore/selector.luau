--!strict
-- Kubernetes label selector semantics (apimachinery pkg/labels):
--   * LabelSelector objects (matchLabels + matchExpressions); a nil selector
--     selects nothing, an empty one selects everything;
--   * Service spec.selector equality maps, where an empty map selects nothing
--     (the endpoints controller skips selector-less Services);
--   * `kubectl -l` strings: `a=b,a==b,c!=d,e in (x,y),f notin (z),g,!h`.

export type Op = "=" | "!=" | "in" | "notin" | "exists" | "!"
export type Requirement = { key: string, op: Op, values: { string } }
export type Selector = { requirements: { Requirement } }

local NAME_MAX = 63
local PREFIX_MAX = 253

local function validName(s: string): boolean
	if #s == 0 or #s > NAME_MAX then
		return false
	end
	return string.match(s, "^[%w]$") ~= nil or string.match(s, "^[%w][%w%-_%.]*[%w]$") ~= nil
end

local function validDnsLabel(s: string): boolean
	return #s <= NAME_MAX and (string.match(s, "^[%l%d]$") ~= nil or string.match(s, "^[%l%d][%l%d%-]*[%l%d]$") ~= nil)
end

local function validPrefix(prefix: string): boolean
	if #prefix == 0 or #prefix > PREFIX_MAX then
		return false
	end
	for label in string.gmatch(prefix .. ".", "([^.]*)%.") do
		if not validDnsLabel(label) then
			return false
		end
	end
	return true
end

local function validKey(key: string): boolean
	local prefix, name = string.match(key, "^([^/]*)/([^/]*)$")
	if prefix == nil or name == nil then
		return validName(key)
	end
	return validPrefix(prefix) and validName(name)
end

local function validValue(v: string): boolean
	return v == "" or validName(v)
end

local function sortedRequirements(reqs: { Requirement }): Selector
	table.sort(reqs, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.op < b.op
	end)
	return { requirements = reqs }
end

local function requirement(key: string, op: Op, values: { string }): (Requirement?, string?)
	if not validKey(key) then
		return nil, string.format("invalid label key %q", key)
	end
	for _, v in values do
		if not validValue(v) then
			return nil, string.format("invalid label value %q for key %q", v, key)
		end
	end
	if (op == "in" or op == "notin") and #values == 0 then
		return nil, string.format("%s requires at least one value for key %q", op, key)
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return { key = key, op = op, values = sorted }, nil
end

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Splits on commas outside parentheses.
local function splitTerms(text: string): ({ string }?, string?)
	local terms: { string } = {}
	local depth, start = 0, 1
	for i = 1, #text do
		local c = string.sub(text, i, i)
		if c == "(" then
			depth += 1
			if depth > 1 then
				return nil, "nested parentheses"
			end
		elseif c == ")" then
			depth -= 1
			if depth < 0 then
				return nil, "unbalanced parentheses"
			end
		elseif c == "," and depth == 0 then
			table.insert(terms, string.sub(text, start, i - 1))
			start = i + 1
		end
	end
	if depth ~= 0 then
		return nil, "unbalanced parentheses"
	end
	table.insert(terms, string.sub(text, start))
	return terms, nil
end

local function parseTerm(raw: string): (Requirement?, string?)
	local term = trim(raw)
	if term == "" then
		return nil, "empty requirement"
	end
	local notKey = string.match(term, "^!%s*([^%s=!(),]+)$")
	if notKey then
		return requirement(notKey, "!", {})
	end
	local setKey, setOp, list = string.match(term, "^([^%s=!(),]+)%s+(%l+)%s*%((.*)%)$")
	if setKey and (setOp == "in" or setOp == "notin") then
		local values: { string } = {}
		if trim(list :: string) ~= "" then
			for v in string.gmatch((list :: string) .. ",", "([^,]*),") do
				table.insert(values, trim(v))
			end
		end
		return requirement(setKey, setOp :: Op, values)
	end
	local key, op, value = string.match(term, "^([^%s=!(),]+)%s*([!=]=?)%s*([^%s=!(),]*)$")
	if key then
		if op == "=" or op == "==" then
			return requirement(key, "=", { value :: string })
		elseif op == "!=" then
			return requirement(key, "!=", { value :: string })
		end
		return nil, string.format("invalid operator in %q", term)
	end
	if string.match(term, "^[^%s=!(),]+$") then
		return requirement(term, "exists", {})
	end
	return nil, string.format("cannot parse requirement %q", term)
end

local M = {}

-- `kubectl -l` syntax. The empty string selects everything, like kubectl.
function M.parse(text: string): (Selector?, string?)
	if trim(text) == "" then
		return { requirements = {} }, nil
	end
	local terms, err = splitTerms(text)
	if terms == nil then
		return nil, err
	end
	local reqs: { Requirement } = {}
	for _, term in terms do
		local req, termErr = parseTerm(term)
		if req == nil then
			return nil, termErr
		end
		table.insert(reqs, req)
	end
	return sortedRequirements(reqs), nil
end

local EXPRESSION_OPS: { [string]: Op } = {
	In = "in",
	NotIn = "notin",
	Exists = "exists",
	DoesNotExist = "!",
}

-- metav1.LabelSelector. nil (or a non-object) yields nil, which selects nothing.
function M.fromLabelSelector(ls: any): (Selector?, string?)
	if type(ls) ~= "table" then
		return nil, nil
	end
	local reqs: { Requirement } = {}
	if type(ls.matchLabels) == "table" then
		for key, value in ls.matchLabels do
			if type(key) ~= "string" or type(value) ~= "string" then
				return nil, "matchLabels entries must be strings"
			end
			local req, err = requirement(key, "=", { value })
			if req == nil then
				return nil, err
			end
			table.insert(reqs, req)
		end
	end
	if type(ls.matchExpressions) == "table" then
		for _, expr in ls.matchExpressions do
			if type(expr) ~= "table" or type(expr.key) ~= "string" then
				return nil, "matchExpressions entries need a key"
			end
			local op = EXPRESSION_OPS[expr.operator]
			if op == nil then
				return nil, string.format("unsupported matchExpressions operator %q", tostring(expr.operator))
			end
			local values: { string } = {}
			if type(expr.values) == "table" then
				for _, v in expr.values do
					if type(v) ~= "string" then
						return nil, "matchExpressions values must be strings"
					end
					table.insert(values, v)
				end
			end
			if (op == "exists" or op == "!") and #values > 0 then
				return nil, string.format("%s takes no values for key %q", tostring(expr.operator), expr.key)
			end
			local req, err = requirement(expr.key, op :: Op, values)
			if req == nil then
				return nil, err
			end
			table.insert(reqs, req)
		end
	end
	return sortedRequirements(reqs), nil
end

-- Equality map (Service spec.selector, matchLabels-only callers).
function M.fromMap(map: any): Selector
	local reqs: { Requirement } = {}
	if type(map) == "table" then
		for key, value in map do
			if type(key) == "string" and type(value) == "string" then
				table.insert(reqs, { key = key, op = "=" :: Op, values = { value } })
			end
		end
	end
	return sortedRequirements(reqs)
end

local function contains(list: { string }, value: string): boolean
	for _, v in list do
		if v == value then
			return true
		end
	end
	return false
end

local function requirementMatches(req: Requirement, labels: { [string]: any }): boolean
	local value = labels[req.key]
	local present = type(value) == "string"
	local op = req.op
	if op == "=" then
		return present and value == req.values[1]
	elseif op == "!=" then
		return not present or value ~= req.values[1]
	elseif op == "in" then
		return present and contains(req.values, value)
	elseif op == "notin" then
		return not present or not contains(req.values, value)
	elseif op == "exists" then
		return present
	end
	return not present
end

-- nil selects nothing; an empty selector selects everything.
function M.matches(sel: Selector?, labels: any): boolean
	if sel == nil then
		return false
	end
	local map: { [string]: any } = if type(labels) == "table" then labels else {}
	for _, req in sel.requirements do
		if not requirementMatches(req, map) then
			return false
		end
	end
	return true
end

-- Service semantics: a nil or empty selector map selects nothing.
function M.matchesMap(map: any, labels: any): boolean
	if type(map) ~= "table" or next(map) == nil then
		return false
	end
	local present: { [string]: any } = if type(labels) == "table" then labels else {}
	for key, value in map do
		if present[key] ~= value then
			return false
		end
	end
	return true
end

local function formatRequirement(req: Requirement): string
	local op = req.op
	if op == "=" or op == "!=" then
		return req.key .. op .. req.values[1]
	elseif op == "in" or op == "notin" then
		return string.format("%s %s (%s)", req.key, op, table.concat(req.values, ","))
	elseif op == "exists" then
		return req.key
	end
	return "!" .. req.key
end

-- Canonical `-l` form (requirements sorted by key). Round-trips through parse.
function M.format(sel: Selector): string
	local parts = table.create(#sel.requirements)
	for i, req in sel.requirements do
		parts[i] = formatRequirement(req)
	end
	return table.concat(parts, ",")
end

return M
