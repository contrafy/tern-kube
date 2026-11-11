--!strict
-- Random tokens for capabilities (quick-action grants) and the run id that
-- correlates a quick action's audit records. tern.fs.read refuses device
-- files in the window VM, so 32 bytes of /dev/urandom are read through a
-- short-lived process: the first 16 are the token, the last 16 the run id
-- (logged, so it must not reveal the token). There is no fallback: without
-- a clean 32-byte read there is neither.

export type Result = { status: number, stdout: string, timed_out: boolean }

local M = {}

M.ARGV = { "/bin/sh", "-c", "od -An -tx1 -N32 /dev/urandom" }
M.TIMEOUT_MS = 2000

-- Grant token and run id, 32 lowercase hex characters each, or nil, nil.
function M.tokens(result: Result?): (string?, string?)
	if result == nil or result.timed_out or result.status ~= 0 or type(result.stdout) ~= "string" then
		return nil, nil
	end
	local bytes: { string } = {}
	for word in string.gmatch(string.lower(result.stdout), "%S+") do
		if string.find(word, "^%x%x$") == nil then
			return nil, nil
		end
		table.insert(bytes, word)
	end
	if #bytes ~= 32 then
		return nil, nil
	end
	return table.concat(bytes, "", 1, 16), table.concat(bytes, "", 17, 32)
end

return M
