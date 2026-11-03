--!strict
-- Pairs one object, or one list, fetched from several contexts and says
-- where they differ. Both sides are normalized first (compare/normalize), so
-- only differences a user could have caused remain. Equality is decided on
-- the real values; what the user sees (diff text, difference paths) never
-- carries a hidden value: Secret data unless security.show_secret_values,
-- and in strict mode values under sensitive-looking names, are masked on
-- both sides together so a changed hidden value still reads as changed.

local Normalize = require("./normalize")
local Objdiff = require("../mutation/objdiff")
local Redact = require("../model/redact")
local Resource = require("../model/resource")
local Types = require("../model/types")

type Ref = Types.ResourceRef

export type State =
	"base"
	| "same"
	| "changed"
	| "missing"
	| "extra"
	| "insync"
	| "unmanaged"
	| "absent"
	| "error"
	| "pending"

-- `paths` holds the first differences, `total` how many there are.
export type Cell = {
	state: State,
	added: number?,
	removed: number?,
	paths: { string }?,
	total: number?,
	error: string?,
}
export type Column = {
	context: string,
	label: string,
	server: string?,
	fetchedAt: number?,
	status: "pending" | "running" | "ok" | "error",
	error: string?,
	argv: { string }?,
}
-- `cells` are aligned with the matrix columns.
export type Row = { key: string, ref: Ref, cells: { Cell } }
export type Matrix = { columns: { Column }, rows: { Row }, notes: { string } }
export type Filter = "all" | "differs" | "presence"

export type DiffOptions = {
	-- {base context, other context}: the diff headers.
	labels: { string },
	policy: Redact.Policy,
	null: any?,
	isList: ((t: { [any]: any }) -> boolean)?,
	maxPaths: number?,
}

export type ListOptions = {
	policy: Redact.Policy,
	maxPaths: number,
	-- A side with more objects becomes an error column (the base: no rows).
	maxObjects: number?,
}

local M = {}

local DEFAULT_MAX_PATHS = 20
local MAX_VALUE = 60

local function map(v: any): { [string]: any }?
	return if type(v) == "table" then v else nil
end

local function isSecret(obj: any): boolean
	local o = map(obj)
	return o ~= nil and o.kind == "Secret" and o.apiVersion == "v1"
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
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

local function keyOf(obj: any): (string?, Ref?)
	local o = map(obj)
	local ref = if o then Resource.fromObject(o, "live") else nil
	if ref == nil then
		return nil, nil
	end
	return Resource.key(ref), ref
end

function M.pair(base: { any }, other: { any }): { { key: string, a: any?, b: any? } }
	local out: { { key: string, a: any?, b: any? } } = {}
	local byKey: { [string]: { key: string, a: any?, b: any? } } = {}
	local function add(obj: any, side: "a" | "b", index: number)
		local key = keyOf(obj) or string.format("unidentified.%s.%d", side, index)
		local p = byKey[key]
		if p == nil then
			p = { key = key }
			byKey[key] = p
			table.insert(out, p)
		end
		local entry = p :: { key: string, a: any?, b: any? }
		if entry[side] == nil then
			entry[side] = obj
		end
	end
	for i, obj in base do
		add(obj, "a", i)
	end
	for i, obj in other do
		add(obj, "b", i)
	end
	return out
end

-- Paths ---------------------------------------------------------------------

local function isArray(t: any): boolean
	return type(t) == "table" and t[1] ~= nil
end

-- Lists whose items all carry a unique string `name` (containers, ports,
-- env, volumes) are paired and addressed by name, so reordering is not a
-- difference of every item.
local function namedItems(t: any): { [string]: any }?
	if type(t) ~= "table" then
		return {}
	end
	if next(t) ~= nil and not isArray(t) then
		return nil
	end
	local out: { [string]: any } = {}
	for _, item in t do
		local name = if type(item) == "table" then item.name else nil
		if type(name) ~= "string" or out[name] ~= nil then
			return nil
		end
		out[name] = item
	end
	return out
end

type Step = { segment: string, key: string?, a: any, b: any }

local function child(prefix: string, k: string): string
	if string.find(k, "^[%a_][%w_%-]*$") then
		return if prefix == "" then k else prefix .. "." .. k
	end
	return string.format('%s["%s"]', prefix, k)
end

local function sortedKeys(a: any, b: any): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, t in { a, b } do
		if type(t) == "table" then
			for k in t do
				local s = tostring(k)
				if not seen[s] then
					seen[s] = true
					table.insert(out, s)
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- Children of two tables at the same path, paired.
local function steps(prefix: string, a: any, b: any): { Step }
	local out: { Step } = {}
	if isArray(a) or isArray(b) then
		local na, nb = namedItems(a), namedItems(b)
		if na and nb then
			local order: { string } = {}
			local seen: { [string]: boolean } = {}
			for _, t in { a, b } do
				if type(t) == "table" then
					for _, item in t do
						if not seen[item.name] then
							seen[item.name] = true
							table.insert(order, item.name)
						end
					end
				end
			end
			for _, name in order do
				table.insert(out, { segment = string.format("%s[%s]", prefix, name), a = na[name], b = nb[name] })
			end
		else
			local n = math.max(if type(a) == "table" then #a else 0, if type(b) == "table" then #b else 0)
			for i = 1, n do
				table.insert(out, {
					segment = string.format("%s[%d]", prefix, i - 1),
					a = if type(a) == "table" then a[i] else nil,
					b = if type(b) == "table" then b[i] else nil,
				})
			end
		end
		return out
	end
	for _, k in sortedKeys(a, b) do
		table.insert(out, {
			segment = child(prefix, k),
			key = k,
			a = if type(a) == "table" then a[k] else nil,
			b = if type(b) == "table" then b[k] else nil,
		})
	end
	return out
end

local function format(v: any): string
	local t = type(v)
	if v == nil then
		return "(absent)"
	elseif t == "string" then
		local lines = select(2, string.gsub(v, "\n", "\n"))
		if lines > 0 then
			return string.format("(%d lines)", lines + (if string.sub(v, -1) == "\n" then 0 else 1))
		elseif #v > MAX_VALUE then
			return string.sub(v, 1, MAX_VALUE - 3) .. "..."
		elseif v == "" then
			return '""'
		end
		return v
	elseif t == "number" then
		return if v == math.floor(v) and math.abs(v) < 2 ^ 53 then string.format("%d", v) else tostring(v)
	elseif t == "table" then
		if next(v) == nil then
			return "{}"
		elseif isArray(v) then
			return string.format("[%d items]", #v)
		end
		local n = 0
		for _ in v do
			n += 1
		end
		return string.format("{%d keys}", n)
	end
	return tostring(v)
end

type PathWalk = { out: { string }, total: number, max: number }

local function emit(w: PathWalk, line: string)
	w.total += 1
	if #w.out < w.max then
		table.insert(w.out, line)
	end
end

-- Strict mode hides values under sensitive-looking names, like the object
-- view, whether or not Secret values are shown.
local function sensitive(strict: boolean, key: string?): boolean
	return strict and key ~= nil and Redact.sensitiveKey(key)
end

local function walkPaths(w: PathWalk, path: string, a: any, b: any, hidden: boolean, strict: boolean)
	if deepEqual(a, b) then
		return
	end
	local ta, tb = type(a) == "table", type(b) == "table"
	if hidden and not (ta and tb) then
		emit(w, path .. (if a == nil then " added" elseif b == nil then " removed" else " changed"))
		return
	end
	if not (ta and tb) or (isArray(a) ~= isArray(b) and next(a) ~= nil and next(b) ~= nil) then
		emit(w, string.format("%s %s -> %s", path, format(a), format(b)))
		return
	end
	-- {name, value} entries (container env): the value hides behind the name.
	local entryName = if type(a.name) == "string" then a.name elseif type(b.name) == "string" then b.name else nil
	local hideValue = sensitive(strict, entryName)
	for _, s in steps(path, a, b) do
		local childHidden = hidden or sensitive(strict, s.key) or (hideValue and s.key == "value")
		walkPaths(w, s.segment, s.a, s.b, childHidden, strict)
	end
end

-- Dotted paths where two normalized objects differ, with scalar old -> new
-- values (`spec.replicas 2 -> 3`); hidden values read `<path> changed`.
-- Returns the first `max` paths and how many differences there are.
function M.paths(a: any, b: any, max: number, policy: Redact.Policy): ({ string }, number)
	local w: PathWalk = { out = {}, total = 0, max = max }
	local secret = isSecret(a) or isSecret(b)
	for _, s in steps("", a, b) do
		local values = secret and (s.key == "data" or s.key == "stringData")
		if values then
			walkPaths(w, s.segment, s.a, s.b, not policy.showSecrets, false)
		else
			walkPaths(w, s.segment, s.a, s.b, sensitive(policy.strict, s.key), policy.strict)
		end
	end
	return w.out, w.total
end

-- Strict masking ------------------------------------------------------------

local function scalar(v: any): boolean
	return type(v) == "string" or type(v) == "number"
end

local function maskPair(a: { [any]: any }?, b: { [any]: any }?, k: any)
	local old = if a then a[k] else nil
	local new = if b then b[k] else nil
	if a and old ~= nil then
		a[k] = Objdiff.REDACTED
	end
	if b and new ~= nil then
		b[k] = if old ~= nil and old == new then Objdiff.REDACTED else Objdiff.REDACTED_CHANGED
	end
end

-- The object view's strict rule (scalars under sensitive names, the value of
-- sensitively named {name, value} entries), applied to both sides at once.
local function strictMask(a: any, b: any, skip: { [string]: boolean }?)
	local ta = if type(a) == "table" then a else nil
	local tb = if type(b) == "table" then b else nil
	if ta == nil and tb == nil then
		return
	end
	local function name(t: any): string?
		return if t and type(t.name) == "string" then t.name else nil
	end
	local entry = name(ta) or name(tb)
	if entry and Redact.sensitiveKey(entry) then
		local va = if ta then ta.value else nil
		local vb = if tb then tb.value else nil
		if scalar(va) or scalar(vb) then
			maskPair(ta, tb, "value")
		end
	end
	if isArray(ta) or isArray(tb) then
		local na, nb = namedItems(ta), namedItems(tb)
		if na and nb then
			for n, item in na do
				strictMask(item, nb[n], nil)
			end
			for n, item in nb do
				if na[n] == nil then
					strictMask(nil, item, nil)
				end
			end
		else
			local n = math.max(if ta then #ta else 0, if tb then #tb else 0)
			for i = 1, n do
				strictMask(if ta then ta[i] else nil, if tb then tb[i] else nil, nil)
			end
		end
		return
	end
	for _, k in sortedKeys(ta, tb) do
		if skip and skip[k] then
			continue
		end
		local va = if ta then ta[k] else nil
		local vb = if tb then tb[k] else nil
		if Redact.sensitiveKey(k) and (scalar(va) or scalar(vb)) then
			maskPair(ta, tb, k)
		elseif type(va) == "table" or type(vb) == "table" then
			strictMask(va, vb, nil)
		end
	end
end

local SECRET_VALUES: { [string]: boolean } = table.freeze({ data = true, stringData = true })

-- Object diff ---------------------------------------------------------------

-- `a` is the base context's object, `b` the other one's (raw `get -o json`
-- items, either may be nil). The diff reads `-` base, `+` other.
function M.objectDiff(a: any?, b: any?, opts: DiffOptions): (Cell, Objdiff.Result?)
	local na = if a ~= nil then Normalize.normalize(a) else nil
	local nb = if b ~= nil then Normalize.normalize(b) else nil
	if na == nil and nb == nil then
		return { state = "absent" }, nil
	end
	local policy = opts.policy
	local cell: Cell
	if na ~= nil and nb ~= nil then
		cell = { state = if deepEqual(na, nb) then "same" else "changed" }
	else
		cell = { state = if na ~= nil then "missing" else "extra" }
	end
	if cell.state == "changed" then
		local paths, total = M.paths(na, nb, opts.maxPaths or DEFAULT_MAX_PATHS, policy)
		cell.paths = paths
		cell.total = total
	end
	-- na/nb are fresh copies from Normalize and the paths are taken: masking
	-- them in place is safe.
	if policy.strict then
		strictMask(na, nb, if isSecret(na) or isSecret(nb) then SECRET_VALUES else nil)
	end
	local key = Objdiff.identity(na or nb) or "object"
	local result = Objdiff.compute({ { key = key, before = na, after = nb } }, {
		showSecretValues = policy.showSecrets,
		null = opts.null,
		isList = opts.isList,
		paths = opts.labels,
	})
	if cell.state ~= "same" then
		cell.added = result.summary.added
		cell.removed = result.summary.removed
	end
	return cell, result
end

-- List matrix ---------------------------------------------------------------

type Side = { byKey: { [string]: any }, order: { string }, refs: { [string]: Ref } }

-- Objects without kind/name cannot be paired across contexts; kubectl
-- list items always have both.
local function index(items: { any }): Side
	local side: Side = { byKey = {}, order = {}, refs = {} }
	for _, obj in items do
		local key, ref = keyOf(obj)
		if key and ref and side.byKey[key] == nil then
			side.byKey[key] = Normalize.normalize(obj)
			side.refs[key] = ref
			table.insert(side.order, key)
		end
	end
	return side
end

-- `sides[i]` are the raw items of `columns[i]` (nil while pending or after
-- an error); column 1 is the base.
function M.listMatrix(columns: { Column }, sides: { { any }? }, opts: ListOptions): Matrix
	local cols: { Column } = {}
	for i, c in columns do
		cols[i] = table.clone(c)
	end
	local notes: { string } = {}
	local indexed: { Side? } = {}
	for i = 1, #cols do
		local items = sides[i]
		if items and opts.maxObjects and #items > opts.maxObjects then
			local message =
				string.format("%d objects, above compare.max_objects (%d)", #items, opts.maxObjects :: number)
			cols[i].status = "error"
			cols[i].error = message
			table.insert(notes, cols[i].context .. ": " .. message)
			if i == 1 then
				return { columns = cols, rows = {}, notes = notes }
			end
		elseif items then
			indexed[i] = index(items)
		end
	end

	local order: { string } = {}
	local refs: { [string]: Ref } = {}
	for i = 1, #cols do
		local side = indexed[i]
		if side then
			for _, k in side.order do
				if refs[k] == nil then
					refs[k] = side.refs[k]
					table.insert(order, k)
				end
			end
		end
	end

	local base = indexed[1]
	local rows: { Row } = {}
	for _, k in order do
		local cells: { Cell } = {}
		for i, col in cols do
			local side = indexed[i]
			local cell: Cell
			if side == nil then
				cell = if col.status == "error" then { state = "error", error = col.error } else { state = "pending" }
			elseif i == 1 then
				cell = { state = if side.byKey[k] ~= nil then "base" else "absent" }
			elseif base == nil then
				cell = if cols[1].status == "error"
					then { state = "error", error = "the base context failed" }
					else { state = "pending" }
			else
				local a, b = base.byKey[k], side.byKey[k]
				if a ~= nil and b ~= nil then
					if deepEqual(a, b) then
						cell = { state = "same" }
					else
						local paths, total = M.paths(a, b, opts.maxPaths, opts.policy)
						cell = { state = "changed", paths = paths, total = total }
					end
				elseif a ~= nil then
					cell = { state = "missing" }
				elseif b ~= nil then
					cell = { state = "extra" }
				else
					cell = { state = "absent" }
				end
			end
			table.insert(cells, cell)
		end
		table.insert(rows, { key = k, ref = refs[k], cells = cells })
	end
	return { columns = cols, rows = rows, notes = notes }
end

local DIFFERS: { [string]: boolean } =
	table.freeze({ changed = true, missing = true, extra = true, unmanaged = true, error = true })
local PRESENCE: { [string]: boolean } = table.freeze({ missing = true, extra = true, unmanaged = true, absent = true })

-- "differs": any cell that is not the same / in sync; "presence": an object
-- that exists in some contexts only.
function M.filter(m: Matrix, f: Filter): Matrix
	if f == "all" then
		return m
	end
	local wanted = if f == "differs" then DIFFERS else PRESENCE
	local rows: { Row } = {}
	for _, row in m.rows do
		for _, cell in row.cells do
			if wanted[cell.state] then
				table.insert(rows, row)
				break
			end
		end
	end
	return { columns = m.columns, rows = rows, notes = m.notes }
end

-- Indexes of pending columns to start now so that at most `maxParallel`
-- run at once, in column order.
function M.queue(statuses: { string }, maxParallel: number): { number }
	local running = 0
	for _, s in statuses do
		if s == "running" then
			running += 1
		end
	end
	local out: { number } = {}
	for i, s in statuses do
		if running + #out >= maxParallel then
			break
		end
		if s == "pending" then
			table.insert(out, i)
		end
	end
	return out
end

return M
