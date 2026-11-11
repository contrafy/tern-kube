--!strict
-- Plays the window half of a confirmed quick action: prints the split's
-- command line for the link the approve block opened, built as
-- plugin/window.luau launch() builds it (local pane, the outcome recorded
-- with RUN by CORE). Usage (args after -a): URL CORE RUN
local Quick = require("../../../plugin/lib/actions/quick")

local url, core, run = ...
assert(url and core and run, "usage: splitline.luau -a URL CORE RUN")
local req, err = Quick.decode(url)
assert(req, err)
local l, cerr = Quick.command(
	req.action,
	{ context = req.target.context, kubeconfig = req.target.kubeconfig, program = "kubectl" },
	req.ref,
	req.opts,
	{ guardCore = core, outcome = { run = run } }
)
assert(l, cerr)
print(l.line)
