--!strict
-- argv builders for every helm call tern-kube makes. Cluster calls pin
-- --kube-context first (and --kubeconfig when it names one file) so the
-- user's current-context never decides the target; `env` carries
-- HELM_DRIVER, because the Tern daemon has no shell environment.
local HelmTypes = require("./types")

export type Target = { kubeconfig: string?, context: string? }
export type Key = HelmTypes.ReleaseKey
export type RollbackOptions = HelmTypes.RollbackOptions
export type Scope = { namespace: string?, all: boolean }

local M = {}

-- Go layout for `helm list --time-format`: RFC 3339 seconds.
M.TIME_FORMAT = "2006-01-02T15:04:05Z07:00"
M.RELEASE_MAX_LEN = 53
M.MAX_REVISION = 999999
M.EXTRAS_FORMAT = "tern-kube/helm-extras/v1"
-- Every release status for `helm list`: Helm 4 removed `-a/--all` and Helm 3
-- without a status flag lists only deployed and failed releases; both accept
-- these.
M.LIST_STATUSES =
	table.freeze({ "--deployed", "--failed", "--pending", "--superseded", "--uninstalled", "--uninstalling" })

-- `helm get all --template` input that prints the stored release's chart
-- metadata, chart default values and hooks as JSON. Go templates in helm's
-- `get` have no sprig (no toJson), so "j" walks values by their Go type;
-- strings come out Go-quoted (%+q), which Parse.goJson turns into JSON.
-- Bump EXTRAS_FORMAT (and the tag inside) whenever the output changes.
M.EXTRAS_TEMPLATE = [==[
{{- define "j" -}}
{{- $t := printf "%T" . -}}
{{- if or (eq $t "map[string]interface {}") (eq $t "chartutil.Values") (eq $t "common.Values") -}}{ {{- $first := true -}}{{- range $k, $v := . -}}{{- if not $first -}},{{- end -}}{{- $first = false -}}{{- printf "%+q" $k -}}:{{- template "j" $v -}}{{- end -}} }
{{- else if eq $t "[]interface {}" -}}[ {{- range $i, $v := . -}}{{- if $i -}},{{- end -}}{{- template "j" $v -}}{{- end -}} ]
{{- else if eq $t "string" -}}{{- printf "%+q" . -}}
{{- else if or (eq $t "bool") (eq $t "float64") (eq $t "int64") (eq $t "int") (eq $t "float32") (eq $t "int32") (eq $t "uint64") -}}{{- printf "%v" . -}}
{{- else if eq $t "<nil>" -}}null
{{- else -}}{"$type":{{ printf "%+q" $t }},"$text":{{ printf "%+q" (printf "%v" .) }}}
{{- end -}}
{{- end -}}
{{- define "t" -}}{{ if .IsZero }}null{{ else }}{{ printf "%+q" (.Format "2006-01-02T15:04:05.999999999Z07:00") }}{{ end }}{{- end -}}
{{- $r := .Release -}}{{- $m := $r.Chart.Metadata -}}
{"format":"tern-kube/helm-extras/v1","name":{{ printf "%+q" $r.Name }},"namespace":{{ printf "%+q" $r.Namespace }},"revision":{{ $r.Version }},"chart":{"name":{{ printf "%+q" $m.Name }},"version":{{ printf "%+q" $m.Version }},"app_version":{{ printf "%+q" $m.AppVersion }},"type":{{ printf "%+q" $m.Type }},"description":{{ printf "%+q" $m.Description }},"home":{{ printf "%+q" $m.Home }},"sources":[{{ range $i, $s := $m.Sources }}{{ if $i }},{{ end }}{{ printf "%+q" $s }}{{ end }}],"dependencies":[{{ range $i, $d := $m.Dependencies }}{{ if $i }},{{ end }}{"name":{{ printf "%+q" $d.Name }},"version":{{ printf "%+q" $d.Version }},"repository":{{ printf "%+q" $d.Repository }},"alias":{{ printf "%+q" $d.Alias }}}{{ end }}]},"defaults":{{ template "j" $r.Chart.Values }},"hooks":[{{ range $i, $h := $r.Hooks }}{{ if $i }},{{ end }}{"name":{{ printf "%+q" $h.Name }},"kind":{{ printf "%+q" $h.Kind }},"path":{{ printf "%+q" $h.Path }},"weight":{{ $h.Weight }},"events":[{{ range $j, $e := $h.Events }}{{ if $j }},{{ end }}{{ printf "%+q" (printf "%s" $e) }}{{ end }}],"delete_policies":[{{ range $j, $e := $h.DeletePolicies }}{{ if $j }},{{ end }}{{ printf "%+q" (printf "%s" $e) }}{{ end }}],"last_run":{"phase":{{ printf "%+q" (printf "%s" $h.LastRun.Phase) }},"started_at":{{ template "t" $h.LastRun.StartedAt }},"completed_at":{{ template "t" $h.LastRun.CompletedAt }}},"manifest":{{ printf "%+q" $h.Manifest }}}{{ end }}]}]==]

-- `--kubeconfig` takes one file; a colon-separated list travels in
-- KUBECONFIG. Kept local: mutation/steps has the same rule but requiring it
-- here would close a cycle once the rollback plan requires this module.
local function isPathList(kubeconfig: string?): boolean
	return kubeconfig ~= nil and string.find(kubeconfig, ":", 1, true) ~= nil
end

local function segmentOk(s: string): boolean
	return string.find(s, "^[a-z0-9]$") ~= nil or string.find(s, "^[a-z0-9][%-a-z0-9]*[a-z0-9]$") ~= nil
end

-- helm's release name rule: DNS-1123 subdomain segments, at most 53 bytes.
function M.validRelease(name: string): boolean
	if #name == 0 or #name > M.RELEASE_MAX_LEN then
		return false
	end
	for _, seg in string.split(name, ".") do
		if not segmentOk(seg) then
			return false
		end
	end
	return true
end

function M.validRevision(n: number): boolean
	return n == n and n >= 1 and n <= M.MAX_REVISION and math.floor(n) == n
end

-- Escapes RE2 metacharacters for `helm list --filter`.
function M.regexpQuote(name: string): string
	return (string.gsub(name, "[%.%+%*%?%(%)%[%]{}%^%$|\\]", "\\%0"))
end

local function append(argv: { string }, ...: string): { string }
	for _, a in { ... } do
		table.insert(argv, a)
	end
	return argv
end

function M.base(program: string, target: Target): { string }
	local context = target.context
	if context == nil or context == "" then
		error("helm: no context to pin; refusing to use the current context", 2)
	end
	local argv = { program, "--kube-context", context }
	local kubeconfig = target.kubeconfig
	if kubeconfig and kubeconfig ~= "" and not isPathList(kubeconfig) then
		append(argv, "--kubeconfig", kubeconfig)
	end
	return argv
end

function M.env(driver: string, kubeconfig: string?): { [string]: string }
	local env: { [string]: string } = { HELM_DRIVER = driver }
	if isPathList(kubeconfig) then
		env.KUBECONFIG = kubeconfig :: string
	end
	return env
end

local function verb(program: string, target: Target, key: Key, ...: string): { string }
	local argv = append(M.base(program, target), ...)
	return append(argv, key.name, "-n", key.namespace)
end

local function listArgv(program: string, target: Target, ...: string): { string }
	local argv = append(M.base(program, target), "list", ...)
	return append(argv, table.unpack(M.LIST_STATUSES))
end

function M.list(program: string, target: Target, scope: Scope, max: number): { string }
	local argv = append(listArgv(program, target), "-o", "json", "--time-format", M.TIME_FORMAT, "--max", tostring(max))
	if scope.all then
		table.insert(argv, "-A")
	elseif scope.namespace and scope.namespace ~= "" then
		append(argv, "-n", scope.namespace)
	end
	return argv
end

-- The one release named `key.name` in its namespace, any status.
function M.owner(program: string, target: Target, key: Key): { string }
	return append(
		listArgv(program, target, "-n", key.namespace),
		"-o",
		"json",
		"--time-format",
		M.TIME_FORMAT,
		"--filter",
		"^" .. M.regexpQuote(key.name) .. "$"
	)
end

function M.history(program: string, target: Target, key: Key, max: number?): { string }
	local argv = append(verb(program, target, key, "history"), "-o", "json")
	if max then
		append(argv, "--max", tostring(max))
	end
	return argv
end

function M.status(program: string, target: Target, key: Key, revision: number?): { string }
	local argv = verb(program, target, key, "status")
	if revision then
		append(argv, "--revision", tostring(revision))
	end
	return append(argv, "-o", "json")
end

function M.extras(program: string, target: Target, key: Key, revision: number): { string }
	return append(
		verb(program, target, key, "get", "all"),
		"--revision",
		tostring(revision),
		"--template",
		M.EXTRAS_TEMPLATE
	)
end

function M.valuesAll(program: string, target: Target, key: Key, revision: number): { string }
	return append(verb(program, target, key, "get", "values"), "--revision", tostring(revision), "--all", "-o", "json")
end

-- User-supplied values only (no chart defaults); latest revision when nil.
function M.values(program: string, target: Target, key: Key, revision: number?): { string }
	local argv = verb(program, target, key, "get", "values")
	if revision then
		append(argv, "--revision", tostring(revision))
	end
	return append(argv, "-o", "json")
end

-- --timeout is always pinned: without --wait it still bounds the hooks.
function M.rollback(
	program: string,
	target: Target,
	key: Key,
	revision: number,
	opts: RollbackOptions,
	dryRun: boolean
): { string }
	local argv = append(M.base(program, target), "rollback", key.name, tostring(revision), "-n", key.namespace)
	append(argv, "--timeout", string.format("%ds", opts.timeoutS))
	if opts.wait then
		table.insert(argv, "--wait")
		if opts.waitForJobs then
			table.insert(argv, "--wait-for-jobs")
		end
	end
	if opts.cleanupOnFail then
		table.insert(argv, "--cleanup-on-fail")
	end
	if opts.force then
		table.insert(argv, "--force")
	end
	if opts.noHooks then
		table.insert(argv, "--no-hooks")
	end
	if dryRun then
		table.insert(argv, "--dry-run")
	end
	return argv
end

-- Offline render of the objects a release owns: no cluster flags, no hooks
-- (helm runs them; they are not part of the release's manifest).
function M.template(
	program: string,
	release: string,
	chartDir: string,
	namespace: string?,
	valuesFiles: { string }
): { string }
	local argv = { program, "template", release, chartDir, "--no-hooks" }
	if namespace and namespace ~= "" then
		append(argv, "-n", namespace)
	end
	for _, f in valuesFiles do
		append(argv, "-f", f)
	end
	return argv
end

return M
