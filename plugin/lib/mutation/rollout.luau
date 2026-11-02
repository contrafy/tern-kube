--!strict
-- After states for verbs without a usable server dry run, and the revision
-- arithmetic of `rollout undo`. `rollout undo --dry-run=server -o json`
-- prints the live object, not the rolled-back one, so the preview builds it
-- from the target revision (`rollout history T/N --revision=R -o json`:
-- a ReplicaSet for Deployments, a DaemonSet/StatefulSet-shaped object for
-- the ControllerRevision kinds; its `spec.template` is the old template).
-- pause/resume and cordon/uncordon have no dry run that prints the object;
-- their change is one field.

export type History = { kind: string, group: string?, name: string, revisions: { number } }
export type UndoTarget = { key: string, name: string, from: number, to: number }

local M = {}

local POD_TEMPLATE_HASH = "pod-template-hash"

local function map(v: any): { [string]: any }?
	return if type(v) == "table" then v else nil
end

-- Empty tables are shared, not copied: `tern.json` keeps the `[]` vs `{}`
-- tag on the table identity.
local function deepCopy(v: any): any
	if type(v) ~= "table" or next(v) == nil then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

-- `rollout history` text, one block per object:
--   deployment.apps/web
--   REVISION  CHANGE-CAUSE
--   1         <none>
-- Revisions come back ascending whatever order kubectl printed.
function M.parseHistory(text: string): { History }
	local out: { History } = {}
	local current: History? = nil
	for _, raw in string.split(text, "\n") do
		local line = string.match(raw, "^%s*(.-)%s*$") or raw
		local resource, name = string.match(line, "^([%w%.%-]+)/(%S+)$")
		if resource and name then
			local dot = string.find(resource, ".", 1, true)
			local entry: History = {
				kind = if dot then string.sub(resource, 1, dot - 1) else resource,
				group = if dot then string.sub(resource, dot + 1) else nil,
				name = name,
				revisions = {},
			}
			table.insert(out, entry)
			current = entry
		elseif current then
			local rev = string.match(line, "^(%d+)%s") or string.match(line, "^(%d+)$")
			if rev then
				table.insert(current.revisions, tonumber(rev) :: number)
			end
		end
	end
	for _, h in out do
		table.sort(h.revisions)
	end
	return out
end

-- Revision `rollout undo` would restore: `--to-revision` when given (0 means
-- previous, as in kubectl), else the second-highest listed revision.
function M.target(revisions: { number }, toRevision: number?): (number?, string?)
	if toRevision ~= nil and toRevision ~= 0 then
		if table.find(revisions, toRevision) == nil then
			return nil, string.format("revision %d is not in the rollout history", toRevision)
		end
		return toRevision, nil
	end
	if #revisions < 2 then
		return nil, "no previous revision to roll back to"
	end
	local sorted = table.clone(revisions)
	table.sort(sorted)
	return sorted[#sorted - 1], nil
end

-- kubectl copies the revision's template without the pod-template-hash
-- label the ReplicaSet controller added (Deployments only).
function M.undoAfter(live: any, revision: any): any
	local out = deepCopy(live)
	local spec = map(out) and map(out.spec)
	local revSpec = map(revision) and map(revision.spec)
	local template = revSpec and map(revSpec.template)
	if spec == nil or template == nil then
		return out
	end
	local copy = deepCopy(template)
	if out.kind == "Deployment" then
		local metadata = map(copy.metadata)
		local labels = metadata and map(metadata.labels)
		if metadata and labels and labels[POD_TEMPLATE_HASH] ~= nil then
			labels[POD_TEMPLATE_HASH] = nil
			if next(labels) == nil then
				metadata.labels = nil
			end
		end
	end
	spec.template = copy
	return out
end

local function withSpecFlag(obj: any, field: string, on: boolean): any
	local out = deepCopy(obj)
	if map(out) == nil then
		return out
	end
	local spec = map(out.spec)
	if spec == nil or next(spec) == nil then
		if not on then
			return out
		end
		spec = {}
		out.spec = spec
	end
	(spec :: { [string]: any })[field] = if on then true else nil
	return out
end

function M.pausedAfter(live: any, paused: boolean): any
	return withSpecFlag(live, "paused", paused)
end

function M.cordonAfter(node: any, unschedulable: boolean): any
	return withSpecFlag(node, "unschedulable", unschedulable)
end

return M
