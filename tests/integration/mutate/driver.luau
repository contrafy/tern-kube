--!strict
-- Headless host for lib/mutation/session.luau (integration tests). Standalone
-- luau can neither spawn processes nor read files, so harness.sh keeps a
-- transcript (init + every result/user event, as a generated Luau module) and
-- calls this driver after each event. The driver replays the transcript
-- through the pure session (deterministic), then prints:
--   * shell lines for effects not executed yet (index > the harness's count):
--     `kl_effect <index> <type> ...` with POSIX-quoted fields;
--   * `kl_state` assignments describing the session (phase, tier, token, ...);
-- and writes the rendered view as text to <work>/view.txt via stdout markers.
--
--   .tools/bin/luau tests/integration/mutate/driver.luau -a <work dir under repo>
local Command = require("../../../plugin/lib/kubectl/command")
local N = require("../../lib/nodes")
local Render = require("../../../plugin/lib/mutation/render")
local Session = require("../../../plugin/lib/mutation/session")
local json = require("../../lib/json")

local args = { ... }
local work = args[1] :: string
assert(work, "driver: work dir argument missing")

local function unhex(h: string?): string
	if h == nil then
		return ""
	end
	return (string.gsub(h, "%x%x", function(x: string): string
		return string.char(tonumber(x, 16) :: number)
	end))
end

local transcript = (require :: any)("../../../" .. work .. "/transcript")

local init = transcript.init
local s, effects = Session.init({
	args = { unhex(init.arg) },
	now = init.now,
	config = {
		mutations = {
			enabled = init.mutationsEnabled ~= false,
			require_target_confirmation = init.requireTarget ~= false,
			allow_failed_preview_override = init.allowOverride == true,
		},
		previewTimeoutMs = init.previewTimeoutMs or 30000,
		execTimeoutMs = init.execTimeoutMs or 300000,
		showSecretValues = init.showSecretValues == true,
		quick = { debugImage = "busybox:1.36" },
	},
	kubectl = unhex(init.kubectl),
	kubeconfig = if init.kubeconfig then unhex(init.kubeconfig) else nil,
	home = unhex(init.home),
	spool = unhex(init.spool),
	request = if init.request then { text = unhex(init.request) } else nil,
	panes = init.panes,
	decode = json.decode,
})

local all: { Session.Effect } = table.clone(effects)

for _, ev in transcript.events do
	local msg: Session.Msg
	if ev.t == "result" then
		msg = {
			t = "result",
			tag = ev.tag,
			gen = ev.gen,
			now = ev.now,
			result = {
				status = ev.status,
				stdout = unhex(ev.stdout),
				stderr = unhex(ev.stderr),
				timed_out = ev.timed_out == true,
			},
		}
	elseif ev.t == "read" then
		local files: { Session.ReadFile } = {}
		for _, f in ev.files do
			table.insert(files, { path = unhex(f.path), text = if f.text then unhex(f.text) else nil, error = f.error })
		end
		msg = { t = "read", tag = ev.tag, gen = ev.gen, now = ev.now, files = files }
	elseif ev.t == "key" then
		msg = {
			t = "key",
			now = ev.now,
			key = { name = ev.name, text = ev.text, ctrl = false, alt = false, shift = ev.shift == true, meta = false },
		}
	elseif ev.t == "action" then
		msg = { t = "action", now = ev.now, act = ev.act, value = ev.value }
	else
		msg = { t = "tick", now = ev.now, paneAlive = ev.paneAlive, cancelled = ev.cancelled }
	end
	local _, more = Session.update(s, msg)
	for _, e in more do
		table.insert(all, e)
	end
end

local q = Command.quote

local function words(list: { string }?): string
	local out: { string } = {}
	for _, w in list or {} :: { string } do
		table.insert(out, q(w))
	end
	return table.concat(out, " ")
end

local function envWords(env: { [string]: string }?): string
	local out: { string } = {}
	for k, v in env or {} :: { [string]: string } do
		table.insert(out, q(k .. "=" .. v))
	end
	table.sort(out)
	return table.concat(out, " ")
end

local function hex(text: string?): string
	return (
		string.gsub(text or "", ".", function(c: string): string
			return string.format("%02x", string.byte(c))
		end)
	)
end

local done = tonumber(args[2] or "0") :: number
for i, e in all do
	if i <= done then
		continue
	end
	local t = e.t
	if t == "run" then
		print(
			string.format(
				"kl_effect %d run %s %d %d %s %s -- env %s %s",
				i,
				q(e.tag :: string),
				e.gen :: number,
				e.timeout_ms or 30000,
				q(e.cwd or "/"),
				q(hex(e.stdin)),
				envWords(e.env),
				words(e.argv)
			)
		)
	elseif t == "write" then
		print(
			string.format(
				"kl_effect %d write %s %d %s %s -- %s",
				i,
				q(e.tag :: string),
				e.gen :: number,
				q(e.path :: string),
				q(hex(e.text)),
				words(e.argv)
			)
		)
	elseif t == "read" then
		print(string.format("kl_effect %d read %s %d -- %s", i, q(e.tag :: string), e.gen :: number, words(e.paths)))
	elseif t == "audit" or t == "copy" then
		print(string.format("kl_effect %d %s %s", i, t, q(e.line or e.text or "")))
	elseif t == "grant" then
		print(string.format("kl_effect %d grant %s %s %d", i, q(e.token :: string), q(e.url :: string), e.expires or 0))
	elseif t == "open" then
		print(string.format("kl_effect %d open %s", i, q(e.url :: string)))
	elseif t == "remove" then
		print(string.format("kl_effect %d remove %s", i, q(e.path :: string)))
	else
		print(string.format("kl_effect %d %s %s", i, t, q(e.id or e.text or "")))
	end
end

local req = s.requirements
local a = s.assessment
local reasons: { string } = {}
if a then
	for _, r in a.reasons do
		table.insert(reasons, r.tier .. ":" .. r.id)
	end
end
local stepsOut: { string } = {}
for _, run in s.steps do
	table.insert(stepsOut, run.step.id .. "=" .. (if run.outcome then run.outcome.status else run.status))
end
local function assign(k: string, v: string?)
	print(string.format("S_%s=%s", k, q(v or "")))
end
assign("count", tostring(#all))
assign("phase", s.phase)
assign("tier", if a then a.tier else nil)
assign("token", if req then req.typed else nil)
assign("target_confirmation", if req and req.targetConfirmation then "1" else "0")
assign("reasons", table.concat(reasons, " "))
assign("steps", table.concat(stepsOut, " "))
assign("errors", table.concat(s.errors, " | "))
assign("confirm_error", s.confirmError)
assign("fingerprint", s.fingerprint)
assign("context", if s.plan then s.plan.targetContext else nil)
assign("server", if s.target then s.target.server else nil)
assign("exec_status", if s.exec and s.exec.status then tostring(s.exec.status) else nil)
assign("command", Session.commandText(s))
local diff = s.diff
assign(
	"diff",
	if diff
		then string.format(
			"create=%d modify=%d delete=%d unknown=%d",
			diff.create,
			diff.modify,
			diff.delete,
			diff.unknown
		)
		else nil
)
local segs: { string } = {}
if diff then
	for _, seg in diff.segments do
		table.insert(segs, seg.action .. ":" .. (seg.kind or "?") .. "/" .. (seg.name or "?"))
	end
end
assign("segments", table.concat(segs, " "))
assign(
	"diff_text",
	if diff
		then table.concat(
			(function(): { string }
				local out: { string } = {}
				for _, seg in diff.segments do
					for _, l in seg.lines do
						table.insert(out, l)
					end
				end
				return out
			end)(),
			"\n"
		)
		else nil
)

-- The rendered view as plain text, for evidence logs.
local ok, view = pcall(Render.view, s)
assign(
	"view",
	if ok then N.text(view.main) .. "\n" .. N.text(view.dock :: any) else "render failed: " .. tostring(view)
)
