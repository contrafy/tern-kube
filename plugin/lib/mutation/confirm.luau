--!strict
-- The single gate between a preview and execution. Every check fails closed:
-- a missing fingerprint, an unfinished preview or an inexact typed token all
-- refuse. Order matters only for the message shown: the first unmet
-- requirement is reported.
local Fingerprint = require("./fingerprint")
local T = require("./types")

type Plan = T.Plan
type Assessment = T.Assessment

export type Preview = {
	assessment: Assessment,
	-- Fingerprint computed when the preview ran.
	fingerprint: string?,
}

export type Input = {
	-- Text in the typed-confirmation field.
	typed: string?,
	-- The user confirmed an inferred target context.
	targetConfirmed: boolean?,
	-- The user chose to proceed despite a failed preview.
	override: boolean?,
	-- Fingerprint recomputed right before confirming.
	fingerprint: string?,
}

export type MutationsConfig = {
	enabled: boolean,
	require_target_confirmation: boolean,
	allow_failed_preview_override: boolean,
}

export type ConfigLike = { mutations: MutationsConfig }

export type Requirements = {
	-- Exact text to type, when typing is required.
	typed: string?,
	targetConfirmation: boolean,
	-- A failed preview the user may override (config allows it).
	overrideAvailable: boolean,
	-- Reasons nothing can override.
	blockedBy: { T.Reason },
}

local M = {}

local function overridable(a: Assessment): (boolean, { T.Reason })
	local hard: { T.Reason } = {}
	local soft = false
	for _, r in a.reasons do
		if r.tier == "blocked" then
			if r.overridable then
				soft = true
			else
				table.insert(hard, r)
			end
		end
	end
	return soft, hard
end

function M.requirements(plan: Plan, preview: Preview, config: ConfigLike): Requirements
	local a = preview.assessment
	local soft, hard = overridable(a)
	local overrideAvailable = soft and config.mutations.allow_failed_preview_override
	local blockedBy = table.clone(hard)
	if soft and not overrideAvailable then
		for _, r in a.reasons do
			if r.tier == "blocked" and r.overridable then
				table.insert(blockedBy, r)
			end
		end
	end
	return {
		-- An overridden failure gets the typed tier: the user confirms blind.
		typed = if a.tier == "typed" or soft then a.token else nil,
		targetConfirmation = config.mutations.require_target_confirmation and plan.contextSource == "inferred",
		overrideAvailable = overrideAvailable,
		blockedBy = blockedBy,
	}
end

function M.canConfirm(plan: Plan, preview: Preview, input: Input, config: ConfigLike): (boolean, string?)
	if not config.mutations.enabled then
		return false, "Mutations are disabled (mutations.enabled is false)"
	end
	if not Fingerprint.equal(preview.fingerprint, input.fingerprint) then
		return false, "The inputs changed since the preview (fingerprint mismatch); run the preview again"
	end
	local req = M.requirements(plan, preview, config)
	if req.targetConfirmation and input.targetConfirmed ~= true then
		return false,
			string.format(
				"Confirm the target first: context %s was inferred from the kubeconfig's current-context",
				plan.targetContext
			)
	end
	if #req.blockedBy > 0 then
		local r = req.blockedBy[1]
		if r.overridable then
			return false, r.text .. " (mutations.allow_failed_preview_override is off)"
		end
		return false, r.text
	end
	if req.overrideAvailable and input.override ~= true then
		return false, "The preview failed; choose Override to confirm without a successful preview"
	end
	if req.typed and input.typed ~= req.typed then
		return false, string.format("Type %q exactly to confirm", req.typed)
	end
	return true, nil
end

return M
