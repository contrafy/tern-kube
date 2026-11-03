--!strict
-- What the native views hide. Secret data is masked unless the user opted to
-- see it; strict mode adds a key-name heuristic for values that merely look
-- sensitive. Advisory only: it can never recognise every secret, and Raw
-- (kubectl's own output) is never masked. Helm values always get the key-name
-- and shape rules (`maskTree`); the values found are then masked wherever
-- charts echo them (notes, manifests, diffs: `maskEchoes`).

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

-- Strict mode only: names that are often but not always secret (`tlsCert`,
-- `authConfig`, `keyFile`); prefixes of whole segments, references excluded.
local STRICT_PREFIXES = { "auth", "cert", "key" }

function M.strictKey(name: string): boolean
	local parts = segments(name)
	local n = #parts
	if n == 0 or (n > 1 and REFERENCE[parts[n]]) then
		return false
	end
	for _, part in parts do
		for _, prefix in STRICT_PREFIXES do
			if string.sub(part, 1, #prefix) == prefix then
				return true
			end
		end
	end
	return false
end

-- Shorter values (`on`, `1`, `app`) would mask unrelated text everywhere.
M.MIN_ECHO = 4
-- Lines of a multi-line secret are echoed separately (templates re-indent
-- them); a stricter minimum keeps lines like `true` or `}` out.
local MIN_ECHO_LINE = 8
local MIN_BEARER = 8

local URL_PASSWORD = "(%a[%w+.-]*://[^/%s:@]*:)([^/%s@]+)@"

local function privateKey(s: string): boolean
	return string.find(s, "%-%-%-%-%-BEGIN [%u%d ]*PRIVATE KEY%-%-%-%-%-") ~= nil
end

local function jwt(s: string): boolean
	return string.find(s, "eyJ[%w_%-]+%.eyJ[%w_%-]+%.") ~= nil
end

local function bearer(s: string): boolean
	for token in string.gmatch(s, "%f[%w][Bb]earer%s+([%w%-%._~%+/]+)") do
		if #token >= MIN_BEARER then
			return true
		end
	end
	return false
end

-- Values that are credentials by shape whatever key holds them: PEM private
-- keys, URL userinfo with a password, JWTs, bearer tokens.
function M.isCredentialText(s: string): boolean
	return privateKey(s) or jwt(s) or bearer(s) or string.find(s, URL_PASSWORD) ~= nil
end

export type Masked = { value: any, secrets: { string }, masked: number }

type Walk = { policy: Policy, secrets: { string }, seen: { [string]: boolean }, masked: number }

local function remember(w: Walk, s: string, minimum: number)
	if #s < minimum or w.seen[s] or M.isMask(s) then
		return
	end
	w.seen[s] = true
	table.insert(w.secrets, s)
end

local function addSecret(w: Walk, s: string)
	remember(w, s, M.MIN_ECHO)
	if string.find(s, "\n", 1, true) then
		for line in string.gmatch(s, "[^\n]+") do
			remember(w, string.match(line, "^%s*(.-)%s*$") :: string, MIN_ECHO_LINE)
		end
	end
end

local function maskShape(w: Walk, s: string): string
	if privateKey(s) or jwt(s) or bearer(s) then
		addSecret(w, s)
		w.masked += 1
		return M.maskValue(s)
	end
	local parts: { string } = {}
	local pos = 1
	while true do
		local first, last, prefix, password = string.find(s, URL_PASSWORD, pos)
		if first == nil or last == nil or prefix == nil or password == nil then
			break
		end
		addSecret(w, password)
		table.insert(parts, string.sub(s, pos, first - 1) .. prefix .. M.maskValue(password) .. "@")
		pos = last + 1
	end
	if pos == 1 then
		return s
	end
	w.masked += 1
	table.insert(parts, string.sub(s, pos))
	return table.concat(parts)
end

local function walk(w: Walk, v: any, hidden: boolean): any
	local kind = type(v)
	if kind == "string" then
		if M.isMask(v) then
			return v
		end
		if hidden then
			addSecret(w, v)
			w.masked += 1
			return M.maskValue(v)
		end
		return maskShape(w, v)
	elseif kind == "number" then
		if hidden then
			w.masked += 1
			return M.maskValue(v)
		end
		return v
	elseif kind == "table" then
		local copy: { [any]: any }? = nil
		for k, child in v do
			local childHidden = hidden
				or (type(k) == "string" and (M.sensitiveKey(k) or (w.policy.strict and M.strictKey(k))))
			local out = walk(w, child, childHidden)
			if out ~= child then
				local c = copy or table.clone(v)
				c[k] = out
				copy = c
			end
		end
		return copy or v
	end
	return v
end

-- Masks Helm values (or any decoded JSON) for display. The key-name rule is
-- always on: values are not Secrets, but charts copy them into ConfigMaps,
-- notes and env. Booleans stay visible (`auth.enabled` is not a secret).
-- Unchanged subtrees keep their identity, so tagged empty lists survive.
-- `secrets` are the masked strings worth looking for in rendered text.
function M.maskTree(value: any, policy: Policy, _isList: (t: any) -> boolean): Masked
	if policy.showSecrets then
		return { value = value, secrets = {}, masked = 0 }
	end
	local w: Walk = { policy = policy, secrets = {}, seen = {}, masked = 0 }
	local out = walk(w, value, false)
	return { value = out, secrets = w.secrets, masked = w.masked }
end

type Hit = { first: number, last: number, secret: string }

-- Replaces every occurrence of a secret with its mask, longest secrets first
-- (a shorter secret inside a longer one must not leave the rest in clear).
-- Matching runs on the original text only, never inside an inserted mask.
function M.maskEchoes(text: string, secrets: { string }): (string, number)
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, s in secrets do
		if #s >= M.MIN_ECHO and not seen[s] and not M.isMask(s) then
			seen[s] = true
			table.insert(list, s)
		end
	end
	if #list == 0 or text == "" then
		return text, 0
	end
	table.sort(list, function(a: string, b: string): boolean
		if #a ~= #b then
			return #a > #b
		end
		return a < b
	end)
	local taken: { [number]: boolean } = {}
	local hits: { Hit } = {}
	for _, s in list do
		local init = 1
		while true do
			local first, last = string.find(text, s, init, true)
			if first == nil or last == nil then
				break
			end
			local free = true
			for i = first, last do
				if taken[i] then
					free = false
					break
				end
			end
			if free then
				for i = first, last do
					taken[i] = true
				end
				table.insert(hits, { first = first, last = last, secret = s })
				init = last + 1
			else
				init = first + 1
			end
		end
	end
	if #hits == 0 then
		return text, 0
	end
	table.sort(hits, function(a: Hit, b: Hit): boolean
		return a.first < b.first
	end)
	local out: { string } = table.create(#hits * 2 + 1)
	local pos = 1
	for _, h in hits do
		table.insert(out, string.sub(text, pos, h.first - 1))
		table.insert(out, M.maskValue(h.secret))
		pos = h.last + 1
	end
	table.insert(out, string.sub(text, pos))
	return table.concat(out), #hits
end

-- Raw texts differ but read the same once masked (a rotated password): the
-- views must still report a change.
function M.hiddenChange(old: string, new: string, secrets: { string }): boolean
	if old == new then
		return false
	end
	return (M.maskEchoes(old, secrets)) == (M.maskEchoes(new, secrets))
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
