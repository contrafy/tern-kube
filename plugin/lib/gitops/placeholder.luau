--!strict
-- Export placeholders in Secrets. Export never writes Secret values: it
-- writes REPLACE_ME into stringData (gitops/clean.luau). Applied as is,
-- such a manifest overwrites the live values, and kubectl diff masks both
-- sides as `*** (before)` / `*** (after)`, so a placeholder looks like any
-- other change. These helpers find them in parsed objects and in manifest
-- text, and relabel the masked diff lines.
local Clean = require("./clean")
local Diffseg = require("../mutation/diffseg")

local M = {}

M.TOKEN = Clean.PLACEHOLDER
-- base64 of TOKEN: a placeholder moved into `data` by hand.
M.BASE64 = "UkVQTEFDRV9NRQ=="
M.DIFF_TEXT = M.TOKEN .. " (placeholder)"

local function sorted(set: { [string]: boolean }): { string }
	local out: { string } = {}
	for k in set do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

local function placeholderValue(field: string, value: string): boolean
	return (field == "stringData" and value == M.TOKEN) or (field == "data" and value == M.BASE64)
end

-- Keys of a core v1 Secret whose value is a placeholder (sorted).
function M.secretKeys(obj: any): { string }
	if type(obj) ~= "table" or obj.kind ~= "Secret" or obj.apiVersion ~= "v1" then
		return {}
	end
	local found: { [string]: boolean } = {}
	for _, field in { "data", "stringData" } do
		local values = obj[field]
		if type(values) == "table" then
			for k, v in values do
				if type(k) == "string" and type(v) == "string" and placeholderValue(field, v) then
					found[k] = true
				end
			end
		end
	end
	return sorted(found)
end

local function unquote(raw: string): string
	local s = string.match(raw, "^%s*(.-)%s*$") :: string
	local single = string.match(s, "^'(.*)'$")
	if single then
		return (string.gsub(single, "''", "'"))
	end
	local double = string.match(s, '^"(.*)"$')
	if double then
		return double
	end
	-- A plain scalar ends at a comment.
	return (string.gsub(s, "%s+#.*$", ""))
end

local function topLevel(line: string): (string?, string?)
	local key, rest = string.match(line, "^([%w_]+):(.*)$")
	return key, rest
end

local function addFlow(found: { [string]: boolean }, field: string, body: string)
	for _, pair in string.split(body, ",") do
		local k, v = string.match(pair, "^%s*([^:]-)%s*:%s*(.-)%s*$")
		if k and v and k ~= "" and placeholderValue(field, unquote(v)) then
			found[unquote(k)] = true
		end
	end
end

-- Placeholder keys of one manifest document (YAML text of a single object
-- at column 0, as the index slices it); {} unless it is a core v1 Secret.
function M.textKeys(text: string): { string }
	local lines = string.split(text, "\n")
	local kind, apiVersion
	for _, line in lines do
		local key, rest = topLevel(line)
		if key == "kind" then
			kind = unquote(rest :: string)
		elseif key == "apiVersion" then
			apiVersion = unquote(rest :: string)
		end
	end
	if kind ~= "Secret" or apiVersion ~= "v1" then
		return {}
	end
	local found: { [string]: boolean } = {}
	local field: string? = nil
	local childIndent: number? = nil
	for _, raw in lines do
		local line = string.gsub(raw, "\r$", "")
		local key, rest = topLevel(line)
		if key then
			field = if key == "data" or key == "stringData" then key else nil
			childIndent = nil
			local flow = if field then string.match(rest :: string, "^%s*{(.*)}%s*$") else nil
			if flow then
				addFlow(found, field :: string, flow)
				field = nil
			end
		elseif field and not string.match(line, "^%s*$") and not string.match(line, "^%s*#") then
			local indent = #(string.match(line, "^( *)") :: string)
			childIndent = childIndent or indent
			if indent == childIndent then
				local k, v = string.match(line, "^%s*([^:]-)%s*:%s*(.-)%s*$")
				if k and v and placeholderValue(field :: string, unquote(v)) then
					found[unquote(k)] = true
				end
			end
		end
	end
	return sorted(found)
end

-- kubectl diff masks every Secret value; relabel the added lines of
-- `keys` so a reader can tell a placeholder from a real change.
function M.markSegment(seg: Diffseg.Segment, keys: { string }): Diffseg.Segment
	if #keys == 0 then
		return seg
	end
	local want: { [string]: boolean } = {}
	for _, k in keys do
		want[k] = true
	end
	local copy = table.clone(seg)
	copy.lines = {}
	for _, line in seg.lines do
		local ws, k, v = string.match(line, "^%+(%s+)([^:%s][^:]*):%s*(.-)%s*$")
		if ws and k and v and want[unquote(k)] and string.match(unquote(v), "^%*%*%*") then
			line = "+" .. ws .. k .. ": " .. M.DIFF_TEXT
		end
		table.insert(copy.lines, line)
	end
	return copy
end

return M
