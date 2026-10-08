--!strict
-- Reads the kubectl argv a lens was claimed for. Manifest globs cannot
-- express "global flags, then get" exactly ("kubectl -* get *" also claims
-- "kubectl -n x logs pod get"), so the view re-checks the verb here.

local M = {}

local VALUE_FLAGS: { [string]: boolean } = {
	["-n"] = true,
	["--namespace"] = true,
	["--context"] = true,
	["--kubeconfig"] = true,
	["--cluster"] = true,
	["--user"] = true,
	["-s"] = true,
	["--server"] = true,
	["--token"] = true,
	["--as"] = true,
	["--as-group"] = true,
	["--request-timeout"] = true,
	["-v"] = true,
	["-l"] = true,
	["--selector"] = true,
	["-o"] = true,
	["--output"] = true,
}

function M.verb(args: { string }): string?
	local i = 1
	while i <= #args do
		local a = args[i]
		if VALUE_FLAGS[a] then
			i += 2
		elseif string.sub(a, 1, 1) == "-" then
			i += 1
		else
			return a
		end
	end
	return nil
end

function M.output(args: { string }): string?
	for i, a in args do
		if a == "-o" or a == "--output" then
			return args[i + 1]
		end
		local v = string.match(a, "^%-%-output=(.+)$") or string.match(a, "^%-o=?(.+)$")
		if v then
			return v
		end
	end
	return nil
end

function M.watching(args: { string }): boolean
	for _, a in args do
		if a == "-w" or a == "--watch" or a == "--watch-only" or string.match(a, "^%-%-watch=") then
			return true
		end
	end
	return false
end

return M
