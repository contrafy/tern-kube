--!strict
-- The k9s-parity fixtures (scripts/fixtures/capture-k9s.sh) as a lens gets
-- them: argv from tests/fixtures/kubectl/k9s/MANIFEST.tsv (synthetic/ has
-- its own), stdout lines then stderr lines, the exit status. `expanded`
-- reads the tab-expanded stdout a terminal grid shows (--revision forms).

local fixtures = require("./fixtures")
local runs = require("./runs")

export type Fixture = { run: runs.Run, lines: { string }, status: number, argv: string }

local M = {}

local manifests: { [string]: { [string]: string } } = {}

local function manifest(root: string): { [string]: string }
	local cached = manifests[root]
	if cached then
		return cached
	end
	local map: { [string]: string } = {}
	for i, line in fixtures.lines(root .. "/MANIFEST.tsv") do
		local name, argv = string.match(line, "^([^\t]+)\t([^\t]+)")
		if i > 1 and name and argv then
			map[name] = argv
		end
	end
	manifests[root] = map
	return map
end

M.ROOT = "kubectl/k9s"

function M.names(): { string }
	local out: { string } = {}
	for name in manifest(M.ROOT) do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- `id`: a capture name, or "synthetic/<name>".
function M.load(id: string, expanded: boolean?): Fixture
	local root = M.ROOT
	local name = id
	local sub = string.match(id, "^synthetic/(.+)$")
	if sub then
		root, name = M.ROOT .. "/synthetic", sub
	end
	local argv = manifest(root)[name]
	if argv == nil then
		error("fixture not in " .. root .. "/MANIFEST.tsv: " .. name, 2)
	end
	local base = root .. "/" .. name
	local lines: { string } = {}
	local stdout = if expanded then base .. ".expanded.txt" else base .. ".txt"
	if fixtures.has(stdout) then
		for _, l in fixtures.lines(stdout) do
			table.insert(lines, l)
		end
	elseif expanded then
		error("no expanded form of " .. id, 2)
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
	return { run = runs.run(argv), lines = lines, status = status, argv = argv }
end

-- stdout alone (no stderr), for parser specs.
function M.stdout(id: string, expanded: boolean?): { string }
	local sub = string.match(id, "^synthetic/(.+)$")
	local base = if sub then M.ROOT .. "/synthetic/" .. sub else M.ROOT .. "/" .. id
	local path = if expanded then base .. ".expanded.txt" else base .. ".txt"
	return if fixtures.has(path) then fixtures.lines(path) else {}
end

return M
