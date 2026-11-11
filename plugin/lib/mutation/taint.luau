--!strict
-- `kubectl taint` specs and what a NoExecute taint does to the pods already
-- on a node. The server dry run returns the node only; evictions are computed
-- here with the Kubernetes toleration rules (k8s.io/api core/v1
-- Toleration.ToleratesTaint) over the pods the preview read.
local T = require("./types")

type Spec = T.TaintSpec

export type Pod = { namespace: string, name: string }
export type Delayed = { namespace: string, name: string, seconds: number }

-- immediate: no toleration matches a new NoExecute taint (evicted at once);
-- delayed: every new taint tolerated, some only for tolerationSeconds;
-- stays: tolerated without a time limit.
export type Evictions = {
	taints: { Spec },
	immediate: { Pod },
	delayed: { Delayed },
	stays: { Pod },
}

local M = {}

M.EFFECTS = { NoSchedule = true, PreferNoSchedule = true, NoExecute = true } :: { [string]: boolean }

-- nil and why when `spec` is not a taint kubectl accepts.
function M.parse(spec: string): (Spec?, string?)
	if string.sub(spec, -1) == "-" then
		local body = string.sub(spec, 1, -2)
		local key, effect = string.match(body, "^([^:=]+):?([^:]*)$")
		if key == nil then
			-- `key=value:Effect-` names the taint by key and effect only.
			key, effect = string.match(body, "^([^:=]+)=[^:]*:?([^:]*)$")
		end
		if key == nil then
			return nil, string.format("%q is not KEY- or KEY:EFFECT-", spec)
		end
		if effect ~= "" and not M.EFFECTS[effect :: string] then
			return nil,
				string.format("%q: effect %s is not NoSchedule, PreferNoSchedule or NoExecute", spec, effect :: string)
		end
		return { key = key :: string, value = nil, effect = if effect ~= "" then effect else nil, remove = true }, nil
	end
	local head, effect = string.match(spec, "^([^:]+):([^:]+)$")
	if head == nil then
		return nil, string.format("%q is not KEY[=VALUE]:EFFECT", spec)
	end
	if not M.EFFECTS[effect :: string] then
		return nil,
			string.format("%q: effect %s is not NoSchedule, PreferNoSchedule or NoExecute", spec, effect :: string)
	end
	local key, value = string.match(head :: string, "^([^=]*)=(.*)$")
	key = key or head
	if key == "" then
		return nil, string.format("%q has an empty key", spec)
	end
	return {
		key = key :: string,
		value = if value ~= nil and value ~= "" then value else nil,
		effect = effect,
		remove = false,
	},
		nil
end

local function str(v: any): string
	return if type(v) == "string" then v else ""
end

-- Kubernetes rules: an empty toleration effect matches every effect, an
-- empty key with Exists every taint; Exists ignores the value; Equal (the
-- default operator) needs the same key and value.
function M.tolerates(toleration: any, taint: any): boolean
	if type(toleration) ~= "table" or type(taint) ~= "table" then
		return false
	end
	local effect = str(toleration.effect)
	if effect ~= "" and effect ~= str(taint.effect) then
		return false
	end
	local key = str(toleration.key)
	if key ~= "" and key ~= str(taint.key) then
		return false
	end
	local op = str(toleration.operator)
	if op == "Exists" then
		return true
	elseif op == "" or op == "Equal" then
		return str(toleration.value) == str(taint.value)
	end
	return false
end

local function taintsOf(node: any): { any }
	local spec = if type(node) == "table" and type(node.spec) == "table" then node.spec else {}
	local out: { any } = {}
	for _, t in (if type(spec.taints) == "table" then spec.taints else {}) :: { any } do
		if type(t) == "table" then
			table.insert(out, t)
		end
	end
	return out
end

-- NoExecute taints `after` has that `before` lacks or carries with another
-- value (same key and effect): only those start evictions.
function M.newNoExecute(before: any, after: any): { Spec }
	local was: { [string]: string } = {}
	for _, t in taintsOf(before) do
		if t.effect == "NoExecute" then
			was[str(t.key)] = str(t.value)
		end
	end
	local out: { Spec } = {}
	for _, t in taintsOf(after) do
		if t.effect == "NoExecute" and was[str(t.key)] ~= str(t.value) then
			local value = str(t.value)
			table.insert(out, {
				key = str(t.key),
				value = if value ~= "" then value else nil,
				effect = "NoExecute",
				remove = false,
			})
		end
	end
	return out
end

local MIRROR = "kubernetes.io/config.mirror"

local function skipped(pod: any): boolean
	local meta = if type(pod.metadata) == "table" then pod.metadata else {}
	local annotations = if type(meta.annotations) == "table" then meta.annotations else {}
	if annotations[MIRROR] ~= nil then
		return true
	end
	local phase = if type(pod.status) == "table" then pod.status.phase else nil
	return phase == "Succeeded" or phase == "Failed"
end

-- Per pod, as the taint manager decides: the first matching toleration of
-- each new taint counts; false when a taint has none (evicted now), else
-- the smallest tolerationSeconds among them (<= 0 means now), nil when none
-- sets one (the pod stays).
local function verdict(pod: any, taints: { Spec }): number | boolean | nil
	local spec = if type(pod.spec) == "table" then pod.spec else {}
	local tolerations: { any } = if type(spec.tolerations) == "table" then spec.tolerations else {}
	local min: number? = nil
	for _, taint in taints do
		local used: any = nil
		for _, tol in tolerations do
			if M.tolerates(tol, taint) then
				used = tol
				break
			end
		end
		if used == nil then
			return false
		end
		local secs = used.tolerationSeconds
		if type(secs) == "number" then
			local b = math.max(secs, 0)
			min = if min == nil then b else math.min(min :: number, b)
		end
	end
	return min
end

-- What the new NoExecute taints of a node (before -> after) do to `pods`
-- (the pods scheduled on it). Mirror pods and finished pods are skipped.
function M.evictions(before: any, after: any, pods: { any }): Evictions
	local taints = M.newNoExecute(before, after)
	local out: Evictions = { taints = taints, immediate = {}, delayed = {}, stays = {} }
	if #taints == 0 then
		return out
	end
	for _, pod in pods do
		if type(pod) ~= "table" or skipped(pod) then
			continue
		end
		local meta = if type(pod.metadata) == "table" then pod.metadata else {}
		local ref: Pod = { namespace = str(meta.namespace), name = str(meta.name) }
		local v = verdict(pod, taints)
		if v == false then
			table.insert(out.immediate, ref)
		elseif type(v) == "number" then
			if v == 0 then
				table.insert(out.immediate, ref)
			else
				table.insert(out.delayed, { namespace = ref.namespace, name = ref.name, seconds = v })
			end
		else
			table.insert(out.stays, ref)
		end
	end
	return out
end

-- Taint specs among a taint command's positionals; the rest name nodes.
function M.specs(positionals: { string }, isSpec: (string) -> boolean): ({ Spec }, { string })
	local specs: { Spec } = {}
	local errors: { string } = {}
	for _, p in positionals do
		if isSpec(p) then
			local s, e = M.parse(p)
			if s then
				table.insert(specs, s)
			else
				table.insert(errors, e :: string)
			end
		end
	end
	return specs, errors
end

return M
