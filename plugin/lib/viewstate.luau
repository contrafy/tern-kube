--!strict
-- A lens loses its state on reload and is rebuilt from the captured output
-- alone, so every clickable carries the whole view choice in its action name:
-- "v=sort:STATUS;desc:1;open:db-0".

export type ViewState = { sort: string?, desc: boolean, open: string? }

local M = {}

function M.default(): ViewState
	return { sort = nil, desc = false, open = nil }
end

local function escape(s: string): string
	return (
		string.gsub(s, "[%%;:=]", function(c: string): string
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

function M.encode(v: ViewState): string
	local parts: { string } = {}
	if v.sort then
		table.insert(parts, "sort:" .. escape(v.sort))
	end
	if v.desc then
		table.insert(parts, "desc:1")
	end
	if v.open then
		table.insert(parts, "open:" .. escape(v.open))
	end
	return table.concat(parts, ";")
end

function M.decode(s: string): ViewState
	local v = M.default()
	for part in string.gmatch(s, "[^;]+") do
		local k, val = string.match(part, "^([^:]+):(.*)$")
		if k == "sort" and val then
			v.sort = unescape(val)
		elseif k == "desc" then
			v.desc = val == "1"
		elseif k == "open" and val then
			v.open = unescape(val)
		end
	end
	return v
end

function M.sorted_by(v: ViewState, col: string): ViewState
	local same = v.sort == col
	return { sort = col, desc = same and not v.desc, open = v.open }
end

function M.toggled(v: ViewState, row: string): ViewState
	return { sort = v.sort, desc = v.desc, open = if v.open == row then nil else row }
end

function M.action(v: ViewState): string
	return "v=" .. M.encode(v)
end

return M
