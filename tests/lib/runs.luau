--!strict
-- Rebuilds what a lens receives for a captured fixture: the argv from the
-- fixture MANIFEST, the output lines (stdout then stderr, as kubectl prints
-- its aggregated errors after the table) and the exit status.

local fixtures = require("./fixtures")

export type Run = { program: string, args: { string } }
export type Fixture = { run: Run, lines: { string }, status: number }

local M = {}

-- POSIX-shell word splitting for the manifest's argv column (single quotes only).
function M.words(line: string): { string }
	local out: { string } = {}
	local current: string? = nil
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == "'" then
			local close = string.find(line, "'", i + 1, true) :: number
			current = (current or "") .. string.sub(line, i + 1, close - 1)
			i = close + 1
		elseif c == " " or c == "\t" then
			if current then
				table.insert(out, current)
				current = nil
			end
			i += 1
		else
			current = (current or "") .. c
			i += 1
		end
	end
	if current then
		table.insert(out, current)
	end
	return out
end

local manifests: { [string]: { [string]: string } } = {}

local function manifest(root: string): { [string]: string }
	local cached = manifests[root]
	if cached then
		return cached
	end
	local map: { [string]: string } = {}
	for _, line in fixtures.lines(root .. "/MANIFEST.tsv") do
		local scenario, key, argv = string.match(line, "^([^\t]+)\t([^\t]+)\t([^\t]+)")
		if scenario and key and argv then
			map[scenario .. "/" .. key] = argv
		end
	end
	manifests[root] = map
	return map
end

function M.run(commandLine: string): Run
	local words = M.words(commandLine)
	local program = table.remove(words, 1) :: string
	return { program = program, args = words }
end

-- `id` is "<scenario>/<key>" under tests/fixtures/real (or synthetic when
-- prefixed "synthetic/").
function M.load(id: string): Fixture
	local root, rest = "real", id
	local sub = string.match(id, "^synthetic/(.+)$")
	if sub then
		root, rest = "synthetic", sub
	end
	local argv = manifest(root)[rest]
	if argv == nil then
		error("fixture not in " .. root .. "/MANIFEST.tsv: " .. rest, 2)
	end
	local base = root .. "/" .. rest
	local lines: { string } = {}
	if fixtures.has(base .. ".txt") then
		for _, l in fixtures.lines(base .. ".txt") do
			table.insert(lines, l)
		end
	end
	if fixtures.has(base .. ".stderr") then
		for _, l in fixtures.lines(base .. ".stderr") do
			table.insert(lines, l)
		end
	end
	local status = 0
	if fixtures.has(base .. ".exit") then
		status = tonumber((string.gsub(fixtures.read(base .. ".exit"), "%s", ""))) or 0
	end
	return { run = M.run(argv), lines = lines, status = status }
end

return M
