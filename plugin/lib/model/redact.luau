--!strict
-- What the native views hide. Secret data is masked unless the user opted to
-- see it; strict mode adds a key-name heuristic for values that merely look
-- sensitive. Advisory only: it can never recognise every secret, and Raw
-- (kubectl's own output) is never masked.

local Config = require("../config")

export type Policy = { showSecrets: boolean, strict: boolean }

local M = {}

M.DEFAULT = table.freeze({ showSecrets = false, strict = false }) :: Policy

M.REVEALED = "Output contains Secret values (security.show_secret_values is on)"
M.STRICT = "Values under sensitive-looking names are masked (security.sensitive_output_strict_mode); "
	.. "best effort, Raw shows everything"

function M.fromConfig(cfg: Config.Config?): Policy
	if cfg == nil then
		return M.DEFAULT
	end
	return table.freeze({
		showSecrets = cfg.security.show_secret_values == true,
		strict = cfg.security.sensitive_output_strict_mode == true,
	})
end

local WORDS: { [string]: boolean } = {
	password = true,
	passwords = true,
	passwd = true,
	secret = true,
	secrets = true,
	token = true,
	tokens = true,
	apikey = true,
	apikeys = true,
	privatekey = true,
	credential = true,
	credentials = true,
}

local PAIRS: { [string]: boolean } = { api = true, private = true }

local REFERENCE: { [string]: boolean } = { name = true, names = true, ref = true, refs = true }

local function segments(name: string): { string }
	local split = string.gsub(name, "(%l)(%u)", "%1_%2")
	split = string.gsub(split, "(%d)(%u)", "%1_%2")
	split = string.gsub(split, "(%u)(%u%l)", "%1_%2")
	local out: { string } = {}
	for part in string.gmatch(string.lower(split), "[%l%d]+") do
		table.insert(out, part)
	end
	return out
end

-- Whole name segments only (`DB_PASSWORD`, `apiKey`), so `tokenizer_mode`
-- stays visible; names ending in name/ref point at a Secret, they are not one.
function M.sensitiveKey(name: string): boolean
	local parts = segments(name)
	local n = #parts
	if n == 0 or (n > 1 and REFERENCE[parts[n]]) then
		return false
	end
	for i, part in parts do
		if WORDS[part] then
			return true
		end
		local nextPart = parts[i + 1]
		if PAIRS[part] and (nextPart == "key" or nextPart == "keys") then
			return true
		end
	end
	return false
end

function M.isMask(value: any): boolean
	return type(value) == "string"
		and (value == "<redacted>" or string.match(value, "^<redacted: %d+ bytes[^>]*>$") ~= nil)
end

function M.maskValue(value: any, suffix: string?): string
	if M.isMask(value) then
		return value
	end
	if type(value) == "string" then
		return string.format("<redacted: %d bytes%s>", #value, suffix or "")
	end
	return "<redacted>"
end

-- Banner texts for a capture: `maskedText` is the view's own wording for
-- masked Secret output.
function M.notices(policy: Policy, sensitive: boolean, masked: boolean, maskedText: string): { string }
	local out: { string } = {}
	if sensitive and not policy.showSecrets then
		table.insert(out, maskedText)
		return out
	end
	if sensitive then
		table.insert(out, M.REVEALED)
	end
	if masked then
		table.insert(out, M.STRICT)
	end
	return out
end

return M
