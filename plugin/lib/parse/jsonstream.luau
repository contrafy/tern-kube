--!strict
-- Splits kubectl's `-o json` output into its top-level JSON texts. With more
-- than one object (label, annotate and patch over several targets, `patch
-- --local` over a List) kubectl prints the objects one after another instead
-- of wrapping them in a List, so a single JSON decode of stdout fails. Only
-- the structure is scanned here (strings, escapes, bracket depth); each piece
-- is decoded by the caller.

local M = {}

local OPEN_OBJECT, OPEN_ARRAY, CLOSE_OBJECT, CLOSE_ARRAY = 123, 91, 125, 93
local QUOTE, BACKSLASH = 34, 92

local function isSpace(b: number): boolean
	return b == 32 or b == 9 or b == 10 or b == 13
end

-- Each returned text is one complete object or array, verbatim. Empty or
-- whitespace-only input yields no texts (kubectl prints nothing when a
-- selector matches nothing).
function M.split(text: string): ({ string }?, string?)
	local out: { string } = {}
	local n = #text
	local i = 1
	while i <= n do
		local b = string.byte(text, i)
		if isSpace(b) then
			i += 1
			continue
		end
		if b ~= OPEN_OBJECT and b ~= OPEN_ARRAY then
			return nil, string.format("expected '{' or '[' at byte %d", i)
		end
		local start = i
		local depth = 0
		local inString = false
		while i <= n do
			local c = string.byte(text, i)
			if inString then
				if c == BACKSLASH then
					i += 1
				elseif c == QUOTE then
					inString = false
				end
			elseif c == QUOTE then
				inString = true
			elseif c == OPEN_OBJECT or c == OPEN_ARRAY then
				depth += 1
			elseif c == CLOSE_OBJECT or c == CLOSE_ARRAY then
				depth -= 1
				if depth == 0 then
					break
				end
			end
			i += 1
		end
		if depth ~= 0 or i > n then
			return nil, string.format("unterminated JSON value starting at byte %d", start)
		end
		table.insert(out, string.sub(text, start, i))
		i += 1
	end
	return out, nil
end

return M
