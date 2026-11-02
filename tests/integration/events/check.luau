--!strict
-- Driver for check.sh. Standalone luau has no file I/O, so check.sh embeds
-- kubectl's output in a generated module and calls this function with it:
-- one entry per command form, JSON text as kubectl printed it.
local Model = require("../../../plugin/lib/events/model")
local Timeline = require("../../../plugin/lib/events/timeline")
local json = require("../../lib/json")

local function problems(form: string, text: string): ({ string }, number)
	local out: { string } = {}
	local ok, obj = pcall(json.decode, text)
	if not ok or type(obj) ~= "table" or type(obj.items) ~= "table" then
		table.insert(out, form .. ": output is not a JSON list: " .. tostring(obj))
		return out, 0
	end
	local events = Model.fromList(obj)
	if #obj.items == 0 then
		table.insert(out, form .. ": no events (expected at least one in tern-test-apps)")
	end
	if #events ~= #obj.items then
		table.insert(out, string.format("%s: %d items but %d events", form, #obj.items, #events))
	end
	for _, e in events do
		local object = e.object
		if not object or object.kind == "" or object.name == "" then
			table.insert(out, form .. ": event " .. e.key .. " has no involved object ref")
		end
		if not e.last or Timeline.parseTime(e.last) == nil then
			table.insert(out, form .. ": event " .. e.key .. " has no parseable last time: " .. tostring(e.last))
		end
		if e.count < 1 then
			table.insert(out, form .. ": event " .. e.key .. " has count " .. e.count)
		end
	end
	return out, #events
end

return function(outputs: { { form: string, text: string } })
	local failures: { string } = {}
	for _, o in outputs do
		local found, n = problems(o.form, o.text)
		for _, f in found do
			table.insert(failures, f)
		end
		print(string.format("%s: %d events, %d problems", o.form, n, #found))
	end
	if #failures > 0 then
		error("events check failed:\n  " .. table.concat(failures, "\n  "), 0)
	end
end
