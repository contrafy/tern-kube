--!strict
-- Helm values three ways: user-supplied, chart defaults and computed
-- (coalesced). Rows say what the user changed and flag settings the chart
-- never reads. Stored defaults are not always the chart's: `upgrade
-- --reuse-values` stores the previous coalesced values as the chart's
-- defaults, so `pristine` picks the revision whose record can be trusted.

local Emit = require("../gitops/emit")
local HelmTypes = require("./types")
local Redact = require("../model/redact")

export type Leaf = { path: string, value: any }
-- `user`: a user-supplied leaf while the chart defaults are unavailable.
export type RowState = "override" | "same-as-default" | "unknown-key" | "subchart" | "default" | "removed" | "user"
-- Values are masked for display when `masked`; `state` was decided on the raw values.
export type Row = { path: string, default: any?, user: any?, computed: any?, state: RowState, masked: boolean }
export type DefaultsSource =
	"record"
	| "record-earliest"
	| "chart-dir"
	| "chart-source"
	| "record-suspect"
	| "unavailable"
export type Compare = { rows: { Row }, source: DefaultsSource, sourceNote: string?, counts: { [RowState]: number } }
-- What `pristine` reads: extras (stored chart) of `extras`, user values of `users`.
export type Needs = { extras: { number }, users: { number } }

type IsList = (t: any) -> boolean
type Entry = { value: any, first: string, ancestors: { string } }
type Tree = { leaves: { [string]: Entry }, order: { string }, dirs: { [string]: boolean } }

local M = {}

local function isSequence(t: { [any]: any }): boolean
	local n = 0
	for k in t do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #t
end

local function join(parent: string, key: any): string
	if type(key) == "string" and string.match(key, "^[%a_][%w_%-]*$") then
		return if parent == "" then key else parent .. "." .. key
	end
	local text = if type(key) == "string" then key else tostring(key)
	return parent .. '["' .. (string.gsub(text, '[\\"]', "\\%0")) .. '"]'
end

-- Lists are leaves: helm replaces lists, it never merges them.
local function collect(tree: Tree, v: any, path: string, first: string, ancestors: { string })
	if type(v) == "table" and next(v) ~= nil and not isSequence(v) then
		local below = ancestors
		if path ~= "" then
			tree.dirs[path] = true
			below = table.clone(ancestors)
			table.insert(below, path)
		end
		for k, child in v do
			collect(tree, child, join(path, k), if path == "" then tostring(k) else first, below)
		end
	elseif path ~= "" then
		tree.leaves[path] = { value = v, first = first, ancestors = ancestors }
		table.insert(tree.order, path)
	end
end

local function tree(v: any): Tree
	local t: Tree = { leaves = {}, order = {}, dirs = {} }
	collect(t, v, "", "", {})
	table.sort(t.order)
	return t
end

function M.flatten(t: { [string]: any }): { Leaf }
	local tr = tree(t)
	local out: { Leaf } = table.create(#tr.order)
	for _, path in tr.order do
		table.insert(out, { path = path, value = tr.leaves[path].value })
	end
	return out
end

-- `[]` and `{}` differ for helm (a list vs a map default); only `isList` can tell.
local function equal(a: any, b: any, isList: IsList?): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	if next(a) == nil and next(b) == nil then
		return isList == nil or isList(a) == isList(b)
	end
	for k, v in a do
		if not equal(v, b[k], isList) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function underLeaf(t: Tree, e: Entry): boolean
	for _, a in e.ancestors do
		if t.leaves[a] then
			return true
		end
	end
	return false
end

function M.compare(
	defaults: { [string]: any }?,
	user: { [string]: any },
	computed: { [string]: any }?,
	deps: { HelmTypes.Dependency },
	isList: IsList,
	policy: Redact.Policy
): { Row }
	local function masked(v: any): any
		return if v == nil then nil else Redact.maskTree(v, policy, isList).value
	end
	local d, u, c = tree(defaults), tree(user), tree(computed)
	local md, mu, mc = tree(masked(defaults)), tree(masked(user)), tree(masked(computed))

	local subcharts: { [string]: boolean } = {}
	for _, dep in deps do
		subcharts[dep.name] = true
		if dep.alias ~= "" then
			subcharts[dep.alias] = true
		end
	end
	-- Every subchart reads `global`.
	if #deps > 0 then
		subcharts.global = true
	end

	local rows: { Row } = {}
	local seen: { [string]: boolean } = {}
	local function add(path: string, state: RowState)
		seen[path] = true
		local hidden = false
		local function side(raw: Tree, shown: Tree): any
			local r, s = raw.leaves[path], shown.leaves[path]
			if r == nil then
				return nil
			end
			local value = if s then s.value else r.value
			hidden = hidden or value ~= r.value
			return value
		end
		local row: Row = {
			path = path,
			default = side(d, md),
			user = side(u, mu),
			computed = side(c, mc),
			state = state,
			masked = false,
		}
		row.masked = hidden
		table.insert(rows, row)
	end

	for _, path in u.order do
		local e = u.leaves[path]
		local de = d.leaves[path]
		local state: RowState
		if defaults ~= nil and de then
			state = if equal(de.value, e.value, isList) then "same-as-default" else "override"
		elseif subcharts[e.first] then
			state = "subchart"
		elseif defaults == nil then
			state = "user"
		elseif d.dirs[path] or underLeaf(d, e) then
			state = "override"
		else
			state = "unknown-key"
		end
		add(path, state)
	end

	local base = if computed ~= nil then c else d
	for _, path in base.order do
		if not seen[path] and not u.dirs[path] then
			add(path, "default")
		end
	end

	-- Decoded JSON drops null members: a default unset with null is only
	-- visible as missing from the computed values.
	if computed ~= nil and defaults ~= nil then
		for _, path in d.order do
			if not seen[path] and not c.leaves[path] and not c.dirs[path] and not underLeaf(c, d.leaves[path]) then
				add(path, "removed")
			end
		end
	end

	table.sort(rows, function(a: Row, b: Row): boolean
		return a.path < b.path
	end)
	return rows
end

function M.counts(rows: { Row }): { [RowState]: number }
	local out: { [RowState]: number } = {
		override = 0,
		["same-as-default"] = 0,
		["unknown-key"] = 0,
		subchart = 0,
		default = 0,
		removed = 0,
		user = 0,
	}
	for _, r in rows do
		local s: RowState = r.state
		out[s] = (out[s] or 0) + 1
	end
	return out
end

local function find(history: { HelmTypes.Revision }, revision: number): HelmTypes.Revision?
	for _, r in history do
		if r.revision == revision then
			return r
		end
	end
	return nil
end

-- Earliest revision of the same chart name+version: helm stores the chart's
-- own defaults when it first sees a chart version, unless reuse-values.
local function firstOfChart(history: { HelmTypes.Revision }, row: HelmTypes.Revision): number
	local f = row.revision
	for _, r in history do
		if r.revision < f and r.chartName == row.chartName and r.chartVersion == row.chartVersion then
			f = r.revision
		end
	end
	return f
end

local function installed(history: { HelmTypes.Revision }, f: number): boolean
	if f == 1 then
		return true
	end
	local row = find(history, f)
	return row ~= nil and string.sub(row.description, 1, #"Install complete") == "Install complete"
end

-- Every previous user leaf is in the stored defaults with the same value.
-- No previous user values: nothing could have been reused.
local function reused(defaults: { [string]: any }, previous: { [string]: any }): boolean
	local prev = tree(previous)
	if #prev.order == 0 then
		return false
	end
	local d = tree(defaults)
	for _, path in prev.order do
		local de = d.leaves[path]
		if de == nil or not equal(de.value, prev.leaves[path].value) then
			return false
		end
	end
	return true
end

function M.needs(history: { HelmTypes.Revision }, revision: number): Needs
	local row = find(history, revision)
	if row == nil then
		return { extras = { revision }, users = {} }
	end
	local f = firstOfChart(history, row)
	local extras = { f }
	if f ~= revision then
		table.insert(extras, revision)
	end
	return { extras = extras, users = if installed(history, f) then {} else { f - 1 } }
end

-- The revision whose stored `defaults` to show for `revision`, and why. For
-- "record-suspect" the caller tries chart-dir / chart-source first. Missing
-- inputs (see `needs`) count as suspect, never as trusted.
function M.pristine(
	history: { HelmTypes.Revision },
	extras: { [number]: HelmTypes.Extras },
	users: { [number]: { [string]: any } },
	revision: number
): (number?, DefaultsSource)
	local function fallback(): (number?, DefaultsSource)
		if extras[revision] then
			return revision, "record-suspect"
		end
		return nil, "unavailable"
	end
	local row = find(history, revision)
	if row == nil then
		return fallback()
	end
	local f = firstOfChart(history, row)
	local first = extras[f]
	if first == nil then
		return fallback()
	end
	if not installed(history, f) then
		local previous = users[f - 1]
		if previous == nil or reused(first.defaults, previous) then
			return fallback()
		end
	end
	return f, if f == revision then "record" else "record-earliest"
end

local REUSE = "upgrades with --reuse-values store the previous values as the chart's defaults"

-- Banner for the defaults column; nil when the release's own record is used.
function M.note(source: DefaultsSource, revision: number, defaultsRevision: number?): string?
	if source == "record-earliest" then
		return string.format(
			"Chart defaults from revision %d, the first with this chart version (%s)",
			defaultsRevision or revision,
			REUSE
		)
	elseif source == "record-suspect" then
		return string.format(
			"Stored defaults of revision %d may include values reused from an earlier revision (%s); "
				.. "settings equal to them may be reused, not redundant",
			revision,
			REUSE
		)
	elseif source == "chart-dir" then
		return "Chart defaults from the matching chart directory in the repository (values.yaml)"
	elseif source == "chart-source" then
		return "Chart defaults from the configured chart source (helm show values)"
	elseif source == "unavailable" then
		return "Chart defaults unavailable (helm get all --template failed): user-supplied and computed values only"
	end
	return nil
end

function M.yaml(t: { [string]: any }, isList: IsList, null: any?): string
	return Emit.yaml(t, { isList = isList, null = null })
end

return M
