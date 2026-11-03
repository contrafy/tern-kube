--!strict
-- Chart auto-detect: reads Chart.yaml and pairs the chart directories of a
-- checkout with deployed releases. Only an equal chart name makes a
-- candidate; version, app version and namespace hints rank them. Pure.
local Config = require("../config")
local HelmTypes = require("./types")

type ChartDir = HelmTypes.ChartDir
type ReleaseRow = HelmTypes.ReleaseRow

export type ChartMeta = { name: string, version: string, appVersion: string? }

export type Candidate = {
	chart: ChartDir,
	release: ReleaseRow,
	-- The proposed values file; nil with useDeployedValues.
	values: { string }?,
	useDeployedValues: boolean,
	score: number,
	reasons: { string },
}

local M = {}

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s) :: string
end

local function scalar(raw: string): string?
	local s = trim(raw)
	local q = string.sub(s, 1, 1)
	if q == '"' or q == "'" then
		local close = string.find(s, q, 2, true)
		return if close then string.sub(s, 2, close - 1) else nil
	end
	s = trim((string.gsub(s, "%s#.*$", "")))
	if s == "" or s == "~" or s == "null" or string.sub(s, 1, 1) == "#" then
		return nil
	end
	return s
end

-- Top-level `key: value` lines only: nested keys (dependencies,
-- maintainers) carry names and versions that are not the chart's.
function M.chartYaml(text: string): ChartMeta?
	local found: { [string]: string } = {}
	for _, line in string.split(text, "\n") do
		local key, rest = string.match((string.gsub(line, "\r$", "")), "^([%w_]+):(.*)$")
		if key == "name" or key == "version" or key == "appVersion" then
			local v = scalar(rest :: string)
			if v and v ~= "" then
				found[key :: string] = v
			end
		end
	end
	if found.name == nil or found.version == nil then
		return nil
	end
	return { name = found.name, version = found.version, appVersion = found.appVersion }
end

local function basename(path: string): string
	return string.match(path, "([^/]*)$") :: string
end

local function normalize(root: string, path: string): string
	local full = if string.sub(path, 1, 1) == "/" then path else root .. "/" .. path
	local parts: { string } = {}
	for _, part in string.split(full, "/") do
		if part == ".." and #parts > 0 then
			table.remove(parts)
		elseif part ~= "" and part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function inPath(root: string, path: string, segment: string): boolean
	local base = if string.sub(root, -1) == "/" then root else root .. "/"
	local rel = if string.sub(path, 1, #base) == base then string.sub(path, #base + 1) else path
	return table.find(string.split(rel, "/"), segment) ~= nil
end

local GONE: { [string]: boolean } = { uninstalled = true, uninstalling = true }

-- Values files worth proposing for `release`: values* files and files
-- naming the release; the rest of a parent directory belongs to others.
local function proposed(chart: ChartDir, release: ReleaseRow): { string }
	local out: { string } = {}
	for _, f in chart.valuesFiles do
		local name = basename(f)
		if string.sub(name, 1, 6) == "values" or string.find(name, release.name, 1, true) then
			table.insert(out, f)
		end
	end
	return out
end

local function configuredFor(
	configured: { Config.HelmRelease },
	root: string,
	chart: ChartDir,
	release: ReleaseRow
): boolean
	for _, c in configured do
		if
			c.release == release.name
			and (c.namespace == nil or c.namespace == release.namespace)
			and normalize(root, c.chart) == normalize(root, chart.path)
		then
			return true
		end
	end
	return false
end

local function order(a: Candidate, b: Candidate): boolean
	if a.score ~= b.score then
		return a.score > b.score
	end
	local ra = a.release.namespace .. "/" .. a.release.name
	local rb = b.release.namespace .. "/" .. b.release.name
	if ra ~= rb then
		return ra < rb
	end
	if a.chart.path ~= b.chart.path then
		return a.chart.path < b.chart.path
	end
	if a.useDeployedValues ~= b.useDeployedValues then
		return a.useDeployedValues
	end
	local va = (a.values or {})[1] or ""
	local vb = (b.values or {})[1] or ""
	return va < vb
end

-- Per matching (chart, release): one candidate rendering with the deployed
-- values and one per proposed values file, best first. `configured` chart
-- paths are absolute or relative to `root`.
function M.candidates(
	charts: { ChartDir },
	releases: { ReleaseRow },
	configured: { Config.HelmRelease },
	root: string
): { Candidate }
	local out: { Candidate } = {}
	for _, release in releases do
		if GONE[release.status] then
			continue
		end
		for _, chart in charts do
			if chart.name ~= release.chartName or configuredFor(configured, root, chart, release) then
				continue
			end
			local score = 0
			local reasons = { "name" }
			if chart.version == release.chartVersion then
				score += 2
				table.insert(reasons, "version")
			end
			if chart.appVersion ~= nil and chart.appVersion == release.appVersion then
				score += 1
				table.insert(reasons, "app version")
			end
			local nsInChart = inPath(root, chart.path, release.namespace)
			local deployedReasons = table.clone(reasons)
			if nsInChart then
				table.insert(deployedReasons, "namespace in path")
			end
			table.insert(out, {
				chart = chart,
				release = release,
				values = nil,
				useDeployedValues = true,
				score = score + (if nsInChart then 1 else 0),
				reasons = deployedReasons,
			})
			for _, file in proposed(chart, release) do
				local r = table.clone(reasons)
				local s = score
				if nsInChart or inPath(root, file, release.namespace) then
					s += 1
					table.insert(r, "namespace in path")
				end
				local name = basename(file)
				if string.find(name, release.name, 1, true) or string.find(name, release.namespace, 1, true) then
					s += 1
					table.insert(r, "values file name")
				end
				table.insert(out, {
					chart = chart,
					release = release,
					values = { file },
					useDeployedValues = false,
					score = s,
					reasons = r,
				})
			end
		end
	end
	table.sort(out, order)
	return out
end

-- "auto: name+version match".
function M.note(c: Candidate): string
	local parts: { string } = {}
	for _, r in c.reasons do
		if r == "name" or r == "version" or r == "app version" then
			table.insert(parts, r)
		end
	end
	return "auto: " .. table.concat(parts, "+") .. " match"
end

-- The chart dir whose Chart.yaml has exactly this name and version.
function M.matchChart(charts: { ChartDir }, name: string, version: string): ChartDir?
	for _, c in charts do
		if c.name == name and c.version == version then
			return c
		end
	end
	return nil
end

return M
