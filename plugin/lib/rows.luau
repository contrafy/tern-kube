--!strict
local columns = require("./columns")

type Row = columns.Row

local M = {}

local function key(s: string): (number?, string)
	local n = tonumber(string.match(s, "^%d+%.?%d*"))
	return n, string.lower(s)
end

function M.sorted(rows: { Row }, col: string?, desc: boolean): { Row }
	local out = table.clone(rows)
	if col == nil then
		return out
	end
	local index: { [Row]: number } = {}
	for i, r in out do
		index[r] = i
	end
	table.sort(out, function(a: Row, b: Row): boolean
		local an, as = key(a.cells[col] or "")
		local bn, bs = key(b.cells[col] or "")
		if an and bn and an ~= bn then
			if desc then
				return an > bn
			end
			return an < bn
		end
		if as ~= bs then
			if desc then
				return as > bs
			end
			return as < bs
		end
		return index[a] < index[b]
	end)
	return out
end

return M
