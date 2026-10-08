--!strict
-- Drives a whole Explore block (state.luau) through the GitOps world of
-- gitops_world.luau: cluster queries outside the GitOps routes are answered
-- by the json-world fake kubectl (explore.luau), everything else by the
-- world. The repository adds /repo/apps/web.yaml, the manifest of the
-- json-world's tern-test-apps Deployment web.
local State = require("../../plugin/lib/explore/state")
local G = require("./gitops_world")
local W = require("./explore")

type State = State.State
type Effect = State.Effect

local M = {}

M.APPS = "tern-test-apps"

M.WEB = table.concat({
	"apiVersion: apps/v1",
	"kind: Deployment",
	"metadata:",
	"  name: web",
	"  namespace: " .. M.APPS,
	"spec:",
	"  replicas: 1",
	"",
}, "\n")

function M.world(): G.World
	local files = G.driftFiles()
	files["/repo/apps/web.yaml"] = M.WEB
	local w = G.new(files)
	w.answer = function(argv: { string }, e: Effect): G.Result?
		if string.sub(e.tag or "", 1, 7) ~= "gitops|" then
			local r, spawnError = W.responder(argv)
			assert(spawnError == nil, spawnError)
			return r
		end
		return nil
	end
	return w
end

function M.env(): State.Env
	local e = W.env()
	e.cwd = G.ROOT
	e.dataDir = G.DATA
	return e
end

function M.drive(w: G.World, s: State, effects: { Effect }): State
	local cur = s
	G.drive(w, effects, function(msg): { Effect }
		local out
		cur, out = State.update(cur, msg)
		return out
	end)
	return cur
end

function M.open(w: G.World, params: { [string]: string }?, cfgText: string?): State
	local s, effects = State.init(
		{ W.link(params or { context = W.CTX, namespace = M.APPS, kind = "Deployment" }) },
		nil,
		W.config(cfgText),
		M.env()
	)
	return M.drive(w, s, effects)
end

function M.press(w: G.World, s: State, name: string, extra: { [string]: any }?): State
	local s2, effects = State.update(s, W.key(name, extra))
	return M.drive(w, s2, effects)
end

function M.action(w: G.World, s: State, act: string, value: string?): State
	local s2, effects = State.update(s, { t = "action", act = act, value = value })
	return M.drive(w, s2, effects)
end

function M.top(s: State): State.Route
	return s.stack[#s.stack]
end

function M.selectName(w: G.World, s: State, name: string): State
	for _ = 1, 20 do
		local item = State.selectedItem(s)
		if item and item.ref and item.ref.name == name then
			return s
		end
		s = M.press(w, s, "j")
	end
	error("no row " .. name)
end

function M.scans(w: G.World): number
	local n = 0
	for _, e in w.effects do
		if e.t == "scan" then
			n += 1
		end
	end
	return n
end

return M
