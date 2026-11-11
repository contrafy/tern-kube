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
		{ "tkg_undo", "rollout undo" },
		{ "tkg_pause", "rollout pause" },
		{ "tkg_resume", "rollout resume" },
		{ "tkg_patch", "patch" },
		{ "tkg_label", "label" },
		{ "tkg_annotate", "annotate" },
		{ "tkg_cordon", "cordon" },
		{ "tkg_uncordon", "uncordon" },
		{ "tkg_drain", "drain" },
		{ "tkg_edit", "edit" },
		{ "tkg_setimage", "set image" },
		{ "tkg_setenv", "set env" },
		{ "tkg_setresources", "set resources" },
		{ "tkg_setselector", "set selector" },
		{ "tkg_setsa", "set serviceaccount" },
		{ "tkg_setsubject", "set subject" },
		{ "tkg_replace", "replace" },
		{ "tkg_taint", "taint" },
		{ "tkg_run", "run" },
		{ "tkg_expose", "expose" },
		{ "tkg_create", "create" },
		{ "tkg_create_clusterrole", "create clusterrole" },
		{ "tkg_create_clusterrolebinding", "create clusterrolebinding" },
		{ "tkg_create_configmap", "create configmap" },
		{ "tkg_create_cronjob", "create cronjob" },
		{ "tkg_create_deployment", "create deployment" },
		{ "tkg_create_ingress", "create ingress" },
		{ "tkg_create_job", "create job" },
		{ "tkg_create_namespace", "create namespace" },
		{ "tkg_create_poddisruptionbudget", "create poddisruptionbudget" },
		{ "tkg_create_priorityclass", "create priorityclass" },
		{ "tkg_create_quota", "create quota" },
		{ "tkg_create_role", "create role" },
		{ "tkg_create_rolebinding", "create rolebinding" },
		{ "tkg_create_serviceaccount", "create serviceaccount" },
		{ "tkg_create_secret_generic", "create secret generic" },
		{ "tkg_create_secret_tls", "create secret tls" },
		{ "tkg_create_secret_docker_registry", "create secret docker-registry" },
		{ "tkg_create_service_clusterip", "create service clusterip" },
		{ "tkg_create_service_externalname", "create service externalname" },
		{ "tkg_create_service_loadbalancer", "create service loadbalancer" },
		{ "tkg_create_service_nodeport", "create service nodeport" },
	}
do
	local spec = flags.commands[verb[2]]
	assert(spec, "flags.luau lacks " .. verb[2])
	emit(verb[1], spec)
end
print("# END generated flags")
