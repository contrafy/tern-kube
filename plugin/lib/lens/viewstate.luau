--!strict
-- A lens loses its state on reload and is rebuilt from the captured output
-- alone, so every clickable carries the whole view choice in its action name:
-- "v=sort:STATUS;desc:1;f:STATUS~Running;open:<key>". The encoded form holds
-- no "=", so the action splits into act/value at the only "=" there is.

export type ViewState = {
	sort: string?,
	desc: boolean,
	-- "COLUMN=value" exact matches, sorted and deduped.
	filters: { string },
	problems: boolean,
	open: string?,
	full: boolean,
	page: number,
	help: boolean,
}

local M = {}

function M.default(): ViewState
	return {
		sort = nil,
		desc = false,
		filters = {},
		problems = false,
		open = nil,
		full = false,
		page = 0,
		help = false,
	}
end

local function copy(vs: ViewState): ViewState
	return {
		sort = vs.sort,
		desc = vs.desc,
		filters = vs.filters,
		problems = vs.problems,
		open = vs.open,
		full = vs.full,
		page = vs.page,
		help = vs.help,
	}
end

local function escape(s: string): string
	return (
		string.gsub(s, "[%%;:=,~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function unescape(s: string): string
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

function M.filter(col: string, value: string): string
	return col .. "=" .. value
end

-- Column and value of a "COLUMN=value" filter (column names hold no "=").
function M.splitFilter(f: string): (string, string)
	local col, value = string.match(f, "^([^=]*)=(.*)$")
	if col == nil or value == nil then
		return f, ""
	end
	return col, value
end

local function normalized(filters: { string }): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, f in filters do
		if not seen[f] then
			seen[f] = true
			table.insert(out, f)
		end
	end
	table.sort(out)
	return out
end

function M.encode(vs: ViewState): string
	local parts: { string } = {}
	if vs.sort then
		table.insert(parts, "sort:" .. escape(vs.sort))
	end
	if vs.desc then
		table.insert(parts, "desc:1")
	end
	if #vs.filters > 0 then
		local fs: { string } = table.create(#vs.filters)
		for i, f in vs.filters do
			local col, value = M.splitFilter(f)
			fs[i] = escape(col) .. "~" .. escape(value)
		end
		table.insert(parts, "f:" .. table.concat(fs, ","))
	end
	if vs.problems then
		table.insert(parts, "p:1")
	end
	if vs.open then
		table.insert(parts, "open:" .. escape(vs.open))
	end
	if vs.full then
		table.insert(parts, "full:1")
	end
	if vs.page > 0 then
		table.insert(parts, "page:" .. tostring(vs.page))
	end
	if vs.help then
		table.insert(parts, "help:1")
	end
	return table.concat(parts, ";")
end

-- Unknown or malformed fields are ignored: actions encoded by a newer or
-- older plugin version must still decode to a usable state.
function M.decode(s: string): ViewState
	local vs = M.default()
	for part in string.gmatch(s, "[^;]+") do
		local k, matched = string.match(part, "^([^:]+):(.*)$")
		if k == nil or matched == nil then
			continue
		end
		local val: string = matched
		local on = val == "1"
		if k == "sort" then
			vs.sort = if val ~= "" then unescape(val) else nil
		elseif k == "desc" then
			vs.desc = on
		elseif k == "f" then
			local fs: { string } = {}
			for item in string.gmatch(val, "[^,]+") do
				local col, value = string.match(item, "^([^~]*)~(.*)$")
				if col and value and col ~= "" then
					table.insert(fs, M.filter(unescape(col), unescape(value)))
				end
			end
			vs.filters = normalized(fs)
		elseif k == "p" then
			vs.problems = on
		elseif k == "open" then
			vs.open = if val ~= "" then unescape(val) else nil
		elseif k == "full" then
			vs.full = on
		elseif k == "page" then
			local n = tonumber(val)
			if n and n >= 0 and n == math.floor(n) then
				vs.page = n
			end
		elseif k == "help" then
			vs.help = on
		end
	end
	if vs.open == nil then
		vs.full = false
	end
	return vs
end

function M.action(vs: ViewState): string
	return "v=" .. M.encode(vs)
end

-- Same column flips direction; a new column starts ascending.
function M.sortedBy(vs: ViewState, col: string): ViewState
	local out = copy(vs)
	out.desc = vs.sort == col and not vs.desc
	out.sort = col
	out.page = 0
	return out
end

function M.hasFilter(vs: ViewState, col: string, value: string): boolean
	local f = M.filter(col, value)
	for _, existing in vs.filters do
		if existing == f then
			return true
		end
	end
	return false
end

function M.toggledFilter(vs: ViewState, col: string, value: string): ViewState
	local f = M.filter(col, value)
	local fs: { string } = {}
	local removed = false
	for _, existing in vs.filters do
		if existing == f then
			removed = true
		else
			table.insert(fs, existing)
		end
	end
	if not removed then
		table.insert(fs, f)
	end
	local out = copy(vs)
	out.filters = normalized(fs)
	out.page = 0
	return out
end

function M.clearedFilters(vs: ViewState): ViewState
	local out = copy(vs)
	out.filters = {}
	out.problems = false
	out.page = 0
	return out
end

function M.toggledProblems(vs: ViewState): ViewState
	local out = copy(vs)
	out.problems = not vs.problems
	out.page = 0
	return out
end

-- Clicking the open row closes it.
function M.opened(vs: ViewState, key: string): ViewState
	local out = copy(vs)
	out.open = if vs.open == key then nil else key
	out.full = false
	return out
end

function M.inspect(vs: ViewState, key: string): ViewState
	local out = copy(vs)
	out.open = key
	out.full = true
	return out
end

-- Leaves the full view with the row still open, so the user lands where
-- they were.
function M.back(vs: ViewState): ViewState
	local out = copy(vs)
	out.full = false
	return out
end

function M.paged(vs: ViewState, n: number): ViewState
	local out = copy(vs)
	out.page = math.max(0, math.floor(n))
	return out
end

function M.toggledHelp(vs: ViewState): ViewState
	local out = copy(vs)
	out.help = not vs.help
	return out
end

return M
