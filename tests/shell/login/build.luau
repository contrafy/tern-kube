--!strict
-- The plugin's real strings for tests/shell/login/run.sh, so the suite runs
-- what Tern runs rather than a copy:
--   probe SHELL           `set -- ARGV...`: Shellenv.probeArgv(SHELL)
--   parse STDOUT          Shellenv.parseProbe: `path=DIR` lines, `kubeconfig=V`
--   line CONTEXT KC       the shell quick action's split command line
--   argv CONTEXT KC       `set -- ARGS...`: the kubectl arguments that line runs
local Command = require("../../../plugin/lib/kubectl/command")
local Quick = require("../../../plugin/lib/actions/quick")
local Shellenv = require("../../../plugin/lib/env/shellenv")

local function setArgs(words: { string }): string
	return "set -- " .. Command.format(words)
end

local function launch(context: string, kubeconfig: string): Quick.Launch
	local ref: any = { kind = "Pod", name = "web-0", namespace = "team-a", source = "snapshot" }
	local l, err = Quick.command("shell", { context = context, kubeconfig = kubeconfig }, ref, {})
	if l == nil then
		error("Quick.command: " .. tostring(err))
	end
	return l
end

local args = { ... }
local mode = args[1]
if mode == "probe" then
	local argv = Shellenv.probeArgv(args[2])
	if argv == nil then
		error("no probe argv for " .. tostring(args[2]))
	end
	print(setArgs(argv))
elseif mode == "parse" then
	local p = Shellenv.parseProbe(args[2] or "")
	if p == nil then
		error("no probe line in the output")
	end
	for _, dir in p.path do
		print("path=" .. dir)
	end
	print("kubeconfig=" .. (p.kubeconfig or ""))
elseif mode == "line" then
	print(launch(args[2], args[3]).line)
elseif mode == "argv" then
	local argv = table.clone(launch(args[2], args[3]).argv)
	table.remove(argv, 1)
	print(setArgs(argv))
else
	error("usage: build.luau -a probe SHELL | parse STDOUT | line CONTEXT KC | argv CONTEXT KC")
end
