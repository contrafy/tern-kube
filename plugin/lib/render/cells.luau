--!strict
-- One table cell as a text node, styled by what kubectl's value means:
-- status tones, short ratios, restarts, muted placeholders, mono numbers.

local Model = require("../usage/model")
local Query = require("../lens/query")
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

-- `kubectl top nodes` percent columns: usage of allocatable, toned with the
-- thresholds of Explore's usage view.
local NODE_PERCENT: { [string]: boolean } = { ["CPU(%)"] = true, ["MEMORY(%)"] = true, ["SWAP(%)"] = true }

-- `finished`: the row's status says it ran to completion (Values.finished);
-- its short READY is expected, so it is muted instead of warning-toned.
function M.style(col: string, columnType: ColumnType, value: string, finished: boolean?): string?
	if Values.isPlaceholder(value) then
		return "muted"
	end
	if columnType == "status" or columnType == "ratio" then
		local tone = TONE_STYLE[Values.statusTone(col, value)]
		if columnType == "ratio" then
			if finished and tone == "warning" then
				return "muted mono"
			end
			return if tone then tone .. " mono" else "mono"
		end
		return if tone then tone .. " strong" else nil
	end
	if columnType == "count" then
		if col == "RESTARTS" and Query.recentRestart(value) then
			return "warning mono"
		end
		return "mono"
	end
	if columnType == "percent" and NODE_PERCENT[col] then
		local tone = Model.tone("node", Values.percent(value))
		return if tone then tone .. " mono" else "mono"
	end
	if NUMERIC[columnType] then
		return "mono"
	end
	if col == "NAME" then
		return "strong"
	end
	return nil
end

function M.cell(col: string, columnType: ColumnType, value: string, finished: boolean?): Node
	local s = M.style(col, columnType, value, finished)
	local span: ui.Span = if s then { t = value, s = s } else { t = value }
	return { k = "text", p = { spans = { span } } }
end

-- Whether a row's status-typed cell says it finished; the flag M.cell takes.
function M.rowFinished(types: { ColumnType }, values: { string }): boolean
	for i, t in types do
		if t == "status" and Values.finished(values[i] or "") then
			return true
		end
	end
	return false
end

return M
