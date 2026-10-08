--!strict
-- One table cell as a text node, styled by what kubectl's value means:
-- status tones, short ratios, restarts, muted placeholders, mono numbers.

local Types = require("../model/types")
local Values = require("../model/values")
local ui = require("../ui")

type ColumnType = Types.ColumnType
type Node = ui.Node

local M = {}

local NUMERIC: { [string]: boolean } = {
	duration = true,
	count = true,
	quantity = true,
	percent = true,
	number = true,
	ratio = true,
}

M.NUMERIC = NUMERIC

local TONE_STYLE: { [string]: string } = {
	success = "success",
	warning = "warning",
	error = "error",
	muted = "muted",
}

function M.style(col: string, columnType: ColumnType, value: string): string?
	if Values.isPlaceholder(value) then
		return "muted"
	end
	if columnType == "status" or columnType == "ratio" then
		local tone = TONE_STYLE[Values.statusTone(col, value)]
		if columnType == "ratio" then
			return if tone then tone .. " num" else "num"
		end
		return if tone then tone .. " strong" else nil
	end
	if columnType == "count" then
		local n = Values.count(value)
		if col == "RESTARTS" and n and n > 0 then
			return "warning num"
		end
		return "num"
	end
	if NUMERIC[columnType] then
		return "num"
	end
	if col == "NAME" then
		return "strong"
	end
	return nil
end

function M.cell(col: string, columnType: ColumnType, value: string): Node
	local s = M.style(col, columnType, value)
	local span: ui.Span = if s then { t = value, s = s } else { t = value }
	return { k = "text", p = { spans = { span } } }
end

return M
