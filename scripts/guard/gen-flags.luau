--!strict
-- Prints the flag-arity block embedded in shell/tern-kube-guard. Run through
-- scripts/guard/gen-flags (which also writes or checks the embedded copy).
local flags = require("../../plugin/lib/kubectl/flags")

type FlagSpec = { bool: { string }, value: { string } }

local function split(entries: { string }): ({ string }, { string })
	local long, short = {}, {}
	for _, e in entries do
		local name, s = string.match(e, "^([^/]+)/(.)$")
		table.insert(long, name or e)
		if s then
			table.insert(short, s)
		end
	end
	table.sort(long)
	table.sort(short)
	return long, short
end

local function set(names: { string }): string
	if #names == 0 then
		return "'|'"
	end
	return "'|" .. table.concat(names, "|") .. "|'"
end

local function emit(prefix: string, spec: FlagSpec)
	local lb, sb = split(spec.bool)
	local lv, sv = split(spec.value)
	print(string.format("%s_lb=%s", prefix, set(lb)))
	print(string.format("%s_lv=%s", prefix, set(lv)))
	print(string.format("%s_sb=%s", prefix, set(sb)))
	print(string.format("%s_sv=%s", prefix, set(sv)))
end

local global: FlagSpec = { bool = table.clone(flags.global.bool), value = flags.global.value }
table.insert(global.bool, "help/h")

local optional = {}
for name in flags.optionalValue do
	table.insert(optional, name)
end
table.sort(optional)

print(
	string.format(
		"# BEGIN generated flags (scripts/guard/gen-flags from plugin/lib/kubectl/flags.luau, kubectl %s; do not edit)",
		flags.kubectlVersion
	)
)
emit("tkg_g", global)
print(string.format("tkg_opt=%s", set(optional)))
for _, verb in
	{
		{ "tkg_apply", "apply" },
		{ "tkg_delete", "delete" },
		{ "tkg_scale", "scale" },
		{ "tkg_restart", "rollout restart" },
	}
do
	local spec = flags.commands[verb[2]]
	assert(spec, "flags.luau lacks " .. verb[2])
	emit(verb[1], spec)
end
print("# END generated flags")
