--!strict
-- The "Helm release ns/X" chip of the lens views. The chip carries only the
-- release key read from the captured object; the host turns it into the
-- Explore URL with the invocation's context and kubeconfig at click time.
-- Nothing here queries helm, so a rehydrated block shows the same chip.

local Command = require("../kubectl/command")
local HelmQuery = require("../helm/query")
local HelmTypes = require("../helm/types")
local Types = require("../model/types")
local ui = require("../ui")

type Node = ui.Node
type Owner = HelmTypes.Owner

local M = {}

M.ACT = "helm-release"
M.ROLE = "tern-kube.helm-release"

local NAMESPACE_MAX_LEN = 63

local function validNamespace(ns: string): boolean
	return #ns > 0
		and #ns <= NAMESPACE_MAX_LEN
		and string.find(ns, "^[%l%d][%l%d%-]*$") ~= nil
		and string.sub(ns, -1) ~= "-"
end

local function valid(owner: Owner): boolean
	return HelmQuery.validRelease(owner.release) and validNamespace(owner.namespace)
end

-- The click value: `<namespace>/<release>` (neither can hold a slash).
function M.value(owner: Owner): string
	return owner.namespace .. "/" .. owner.release
end

-- nil for anything a chip of ours could not have produced.
function M.decode(value: string): HelmTypes.ReleaseKey?
	local namespace, release = string.match(value, "^([^/]+)/([^/]+)$")
	if
		namespace == nil
		or release == nil
		or not valid({ release = release, namespace = namespace, via = "annotation" })
	then
		return nil
	end
	return { name = release, namespace = namespace }
end

-- The chip, or nil without an owner (or one whose names helm would reject).
function M.node(owner: Owner?, key: string?): Node?
	if owner == nil or not valid(owner) then
		return nil
	end
	local label = M.value(owner)
	local title = if owner.via == "instance-label"
		then "Probably installed by Helm release "
			.. label
			.. " (app.kubernetes.io/instance label); open it in Explore (runs helm)"
		else "Open Helm release " .. label .. " in Explore (runs helm)"
	return ui.badge("Helm release " .. label, "accent", {
		key = key,
		title = title,
		actions = { click = M.ACT .. "=" .. M.value(owner) },
		role = M.ROLE,
	})
end

-- The Explore link for a chip value; nil when the value is not one of ours.
function M.url(inv: Types.Invocation, value: string, cwd: string?): string?
	local key = M.decode(value)
	if key == nil then
		return nil
	end
	return Command.exploreUrl(inv, nil, {
		route = "helm-release",
		release = key.name,
		namespace = key.namespace,
		cwd = cwd,
	})
end

-- `--show-labels` LABELS cell (`k=v,k2=v2`) as a labels map.
function M.labels(cell: string): { [string]: string }
	local out: { [string]: string } = {}
	for part in string.gmatch(cell, "[^,]+") do
		local k, v = string.match(part, "^%s*([^=]+)=(.*)$")
		if k and v then
			out[k] = v
		end
	end
	return out
end

return M
