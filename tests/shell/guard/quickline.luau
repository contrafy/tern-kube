--!strict
-- Prints the split command line the window launches for a confirmed mutating
-- quick action (plugin/lib/actions/quick.luau), so the guard tests run the
-- real script against the real `tern-kube-guard record`. Usage (args after
-- -a): ACTION CONTEXT CORE RUN
--   ACTION  debug-pod (Pod apps/web) or cronjob-run (CronJob batch/nightly)
--   CORE    absolute path of the guard core, or "remote" for a remote pane
local Quick = require("../../../plugin/lib/actions/quick")

local action, context, core, run = ...
assert(action and context and core and run, "usage: quickline.luau -a ACTION CONTEXT CORE RUN")
local ref: any = if action == "cronjob-run"
	then { kind = "CronJob", name = "nightly", namespace = "batch", group = "batch", source = "snapshot" }
	else { kind = "Pod", name = "web", namespace = "apps", source = "snapshot" }
local settings: Quick.Settings = { outcome = { run = run } }
if core == "remote" then
	settings.remote = { name = "tk@remote" }
else
	settings.guardCore = core
end
local opts: Quick.Opts = if action == "cronjob-run" then { suffix = "k3x9" } else {}
local l, err = Quick.command(action, { context = context }, ref, opts, settings)
assert(l, err)
print(l.line)
