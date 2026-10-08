--!strict
-- Builds lens captures from real fixtures the way the host does: argv as
-- typed, stdout and stderr lines in one stream, exit status from `.exit`.

local Capture = require("../../plugin/lib/lens/capture")
local fixtures = require("./fixtures")
local json = require("./json")

local M = {}

local function words(command: string): { string }
	local out: { string } = {}
	for w in string.gmatch(command, "%S+") do
		table.insert(out, w)
	end
	return out
end

-- `path` is "real/<scenario>/<key>" without extension; `command` the argv as
-- typed ("kubectl describe pod x -n ns"; split on spaces, so no quoting).
function M.build(path: string, command: string): Capture.Capture
	local lines: { string } = {}
	for _, ext in { ".txt", ".stderr" } do
		if fixtures.has(path .. ext) then
			for _, line in fixtures.lines(path .. ext) do
				table.insert(lines, line)
			end
		end
	end
	local status = if fixtures.has(path .. ".exit")
		then tonumber((string.gsub(fixtures.read(path .. ".exit"), "%s", "")))
		else 0
	local argv = words(command)
	local program = table.remove(argv, 1) :: string
	return Capture.build({ program = program, args = argv }, lines, status, { decode = json.decode })
end

function M.fromLines(command: string, lines: { string }, status: number?): Capture.Capture
	local argv = words(command)
	local program = table.remove(argv, 1) :: string
	return Capture.build({ program = program, args = argv }, lines, status, { decode = json.decode })
end

return M
