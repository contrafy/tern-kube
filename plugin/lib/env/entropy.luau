--!strict
-- Random tokens for capabilities (quick-action grants). tern.fs.read
-- refuses device files in the window VM, so 16 bytes of /dev/urandom are
-- read through a short-lived process. There is no fallback: without a
-- clean 16-byte read there is no token.

export type Result = { status: number, stdout: string, timed_out: boolean }

local M = {}

M.ARGV = { "/bin/sh", "-c", "od -An -tx1 -N16 /dev/urandom" }
M.TIMEOUT_MS = 2000

-- 32 lowercase hex characters from od's dump, or nil.
function M.token(result: Result?): string?
	if result == nil or result.timed_out or result.status ~= 0 or type(result.stdout) ~= "string" then
		return nil
	end
	local bytes: { string } = {}
	for word in string.gmatch(string.lower(result.stdout), "%S+") do
		if string.find(word, "^%x%x$") == nil then
			return nil
		end
		table.insert(bytes, word)
	end
	if #bytes ~= 16 then
		return nil
	end
	return table.concat(bytes)
end

return M
