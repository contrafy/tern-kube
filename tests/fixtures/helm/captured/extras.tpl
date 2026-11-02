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
{"format":"tern-kube/helm-extras/v1","name":{{ printf "%+q" $r.Name }},"namespace":{{ printf "%+q" $r.Namespace }},"revision":{{ $r.Version }},"chart":{"name":{{ printf "%+q" $m.Name }},"version":{{ printf "%+q" $m.Version }},"app_version":{{ printf "%+q" $m.AppVersion }},"type":{{ printf "%+q" $m.Type }},"description":{{ printf "%+q" $m.Description }},"home":{{ printf "%+q" $m.Home }},"sources":[{{ range $i, $s := $m.Sources }}{{ if $i }},{{ end }}{{ printf "%+q" $s }}{{ end }}],"dependencies":[{{ range $i, $d := $m.Dependencies }}{{ if $i }},{{ end }}{"name":{{ printf "%+q" $d.Name }},"version":{{ printf "%+q" $d.Version }},"repository":{{ printf "%+q" $d.Repository }},"alias":{{ printf "%+q" $d.Alias }}}{{ end }}]},"defaults":{{ template "j" $r.Chart.Values }},"hooks":[{{ range $i, $h := $r.Hooks }}{{ if $i }},{{ end }}{"name":{{ printf "%+q" $h.Name }},"kind":{{ printf "%+q" $h.Kind }},"path":{{ printf "%+q" $h.Path }},"weight":{{ $h.Weight }},"events":[{{ range $j, $e := $h.Events }}{{ if $j }},{{ end }}{{ printf "%+q" (printf "%s" $e) }}{{ end }}],"delete_policies":[{{ range $j, $e := $h.DeletePolicies }}{{ if $j }},{{ end }}{{ printf "%+q" (printf "%s" $e) }}{{ end }}],"last_run":{"phase":{{ printf "%+q" (printf "%s" $h.LastRun.Phase) }},"started_at":{{ template "t" $h.LastRun.StartedAt }},"completed_at":{{ template "t" $h.LastRun.CompletedAt }}},"manifest":{{ printf "%+q" $h.Manifest }}}{{ end }}]}
