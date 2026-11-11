# Live: Explore pods usage of tern-test-usage (read-only). % from the pods
# list opens the usage view with tiles; cpu-burner sits at its CPU limit
# (error tone), limits-only has a request percentage (requests default to
# limits), enter on pod-level notes its pod-level requests, enter on
# sidecar-init lists the sidecar and the finished init; Y copies both pinned
# reads; nothing re-reads without r.
uns=tern-test-usage

E2E_WAIT=120 wait_for "metrics for $uns" kc top pods -n "$uns" || return

runs_now() {
	sleep 1
	grep -c 'tern-kube explore.run' "$(daemon_log)"
}

lens "kubectl --context kind-tern-kube-dev get pods -n $uns"
native || return
click_text cpu-burner '.tk-grid .tk-c' || return
click_text 'Explore live' || return
explore_open || return
xwait 'Object pod/cpu-burner'
xkey escape
xwait 'cpu-burner' "$XT"

xkey %
E2E_WAIT=20 xwait "usage · pods · ns $uns" || return
xwait 'metrics' '[data-role="tern-kube.metrics-at"] *' || return
t=$(xtext)
contains "Pods tile" "$t" "4 / 4"
contains "Near limits tile" "$t" "Near limits"
contains "No requests tile" "$t" "No requests"
eq "pod columns" "$(texts "$EX .sf-tbl-row.head > .sf-tbl-c" | jq -c '.[0:2]')" '["NAME","CPU"]'
has "$EX $XT .sf-t-error" || fail "cpu-burner %CPU/L is not error-toned"
eq "the opened pod is selected" "$(xsel)" "cpu-burner"

xselect limits-only || return
contains "limits-only has %CPU/R" "$(texts "$EX .sf-tbl-row.sel > .sf-tbl-c" | jq -r '.[6]')" "%"

xselect pod-level || return
xkey enter
xwait "usage · pod/pod-level" || return
contains "pod-level note" "$(xtext '[data-role="tern-kube.usage-note"] *')" "pod-level requests 200m / 64Mi"
xkey escape
xwait "usage · pods · ns $uns" || return

xselect sidecar-init || return
xkey enter
xwait "usage · pod/sidecar-init" || return
kinds=$(hcol 2)
contains "sidecar kind" "$kinds" '"sidecar"'
contains "finished init kind" "$kinds" '"init (done)"'
contains "app container kind" "$kinds" '"container"'
xkey escape
xwait "usage · pods · ns $uns" || return

xkey Y
copied=$(clip)
eq "Y copies the pods and metrics reads" "$(printf '%s\n' "$copied" | grep -c '^kubectl ')" 2
contains "pods read pinned" "$copied" "--context kind-tern-kube-dev get pods -n $uns -o jsonpath="
contains "metrics read pinned" "$copied" "--context kind-tern-kube-dev get pods.metrics.k8s.io -n $uns -o jsonpath="

runs=$(runs_now)
sleep 20
eq "no kubectl run without r" "$(runs_now)" "$runs"
explore_close
