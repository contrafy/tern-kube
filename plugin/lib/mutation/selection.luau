--!strict
-- Target sets (a selector, --all, --field-selector, -A or a bare type) are
-- resolved by kubectl when it runs. At confirm the block reads the set again
-- and refuses when it is not the one previewed; identity includes the uid,
-- so an object deleted and re-created under the same name is a new target.
local T = require("./types")

type Plan = T.Plan
type Step = T.Step

export type Entry = { group: string, kind: string, namespace: string, name: string, uid: string }

local M = {}

-- `-o name` would drop the namespace with -A; a single named object prints
-- nothing with `range .items`, which is why named targets are excluded.
M.JSONPATH = '{range .items[*]}{.apiVersion}{"\\t"}{.kind}{"\\t"}{.metadata.namespace}{"\\t"}'
	.. '{.metadata.name}{"\\t"}{.metadata.uid}{"\\n"}{end}'

-- Families whose `targets` step reads what the command will act on.
M.FAMILIES = {
	delete = true,
	scale = true,
	restart = true,
	undo = true,
	pause = true,
	resume = true,
	label = true,
	annotate = true,
	cordon = true,
	uncordon = true,
	drain = true,
	["set-image"] = true,
	["set-env"] = true,
	["set-resources"] = true,
	["set-selector"] = true,
	["set-serviceaccount"] = true,
	["set-subject"] = true,
	taint = true,
} :: { [string]: boolean }

-- Shown when more than this many objects differ on one side.
M.MAX_NAMES = 3

local function targetsStep(plan: Plan): Step?
	for _, s in plan.steps do
		if s.kind == "targets" then
			return s
		end
	end
	return nil
end

function M.applies(plan: Plan): boolean
	if not M.FAMILIES[plan.family] or targetsStep(plan) == nil then
		return false
	end
	if #plan.resources > 0 or #plan.filenames > 0 or plan.kustomize ~= nil then
		return false
	end
	return true
end

-- The targets read again (same flags and pins) printing one line per object.
function M.step(plan: Plan): Step?
	if not M.applies(plan) then
		return nil
	end
	local targets = targetsStep(plan) :: Step
	local n = #targets.argv
	if n < 2 or targets.argv[n - 1] ~= "-o" or targets.argv[n] ~= "json" then
		return nil
	end
	local argv = table.move(targets.argv, 1, n - 1, 1, {})
	table.insert(argv, "jsonpath=" .. M.JSONPATH)
	return {
		id = "v-selection",
		kind = "selection",
		label = "Re-read the selection",
		argv = argv,
		env = table.clone(targets.env),
		timeoutMs = targets.timeoutMs,
	}
end

local function groupOf(apiVersion: string): string
	return string.match(apiVersion, "^(.+)/[^/]+$") or ""
end

function M.parse(stdout: string): ({ Entry }?, string?)
	local out: { Entry } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local apiVersion, kind, namespace, name, uid =
			string.match(line, "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
		if apiVersion == nil or kind == "" or name == "" then
			return nil, "unexpected output from kubectl get: " .. string.sub(line, 1, 80)
		end
		table.insert(out, {
			group = groupOf(apiVersion :: string),
			kind = kind :: string,
			namespace = namespace :: string,
			name = name :: string,
			uid = uid :: string,
		})
	end
	return out, nil
end

local function str(v: any): string
	return if type(v) == "string" then v else ""
end

-- The previewed set, from the targets step's decoded objects.
function M.fromLive(live: { any }): { Entry }
	local out: { Entry } = {}
	for _, obj in live do
		if type(obj) == "table" then
			local meta = if type(obj.metadata) == "table" then obj.metadata else {}
			table.insert(out, {
				group = groupOf(str(obj.apiVersion)),
				kind = str(obj.kind),
				namespace = str(meta.namespace),
				name = str(meta.name),
				uid = str(meta.uid),
			})
		end
	end
	return out
end

local function label(e: Entry): string
	return e.kind .. " " .. (if e.namespace ~= "" then e.namespace .. "/" else "") .. e.name
end

local function nameKey(e: Entry): string
	return table.concat({ e.group, e.kind, e.namespace, e.name }, "\0")
end

local function listed(prefix: string, entries: { Entry }): string
	local parts: { string } = {}
	for i = 1, math.min(#entries, M.MAX_NAMES) do
		table.insert(parts, prefix .. label(entries[i]))
	end
	local text = table.concat(parts, ", ")
	if #entries > M.MAX_NAMES then
		text ..= string.format(" and %d more", #entries - M.MAX_NAMES)
	end
	return text
end

-- nil when both name the same objects; else why the confirm is refused.
function M.compare(before: { Entry }, now: { Entry }): string?
	local was: { [string]: string } = {}
	for _, e in before do
		was[nameKey(e)] = e.uid
	end
	local is: { [string]: string } = {}
	for _, e in now do
		is[nameKey(e)] = e.uid
	end
	local added: { Entry } = {}
	local removed: { Entry } = {}
	local recreated: { Entry } = {}
	for _, e in now do
		local uid = was[nameKey(e)]
		if uid == nil then
			table.insert(added, e)
		elseif uid ~= e.uid then
			table.insert(recreated, e)
		end
	end
	for _, e in before do
		if is[nameKey(e)] == nil then
			table.insert(removed, e)
		end
	end
	if #added == 0 and #removed == 0 and #recreated == 0 then
		return nil
	end
	local parts: { string } = {}
	if #added > 0 then
		table.insert(parts, listed("+", added))
	end
	if #removed > 0 then
		table.insert(parts, listed("-", removed))
	end
	if #recreated > 0 then
		table.insert(parts, listed("", recreated) .. " re-created since the preview")
	end
	return string.format(
		"The selection now matches %d object(s) (previewed %d): %s. Press r to preview again.",
		#now,
		#before,
		table.concat(parts, "; ")
	)
end

return M
