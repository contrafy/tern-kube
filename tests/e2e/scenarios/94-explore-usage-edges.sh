# Live: usage edges. allow_live_queries=false blocks % with a toast and no
# run; an empty namespace says so; a pod this scenario creates in
# tern-test-usage shows <no metrics> until its first window and r; narrow
# help lists the usage keys. Creates and deletes only pod usage-fresh.
uns=tern-test-usage
fresh=usage-fresh
trap 'kc delete pod -n "$uns" "$fresh" --wait=false >/dev/null 2>&1' EXIT

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

set_config '{"schema_version": 1, "explore": {"allow_live_queries": false}}'
runs=$(runs_now)
xkey %
sleep 1
contains "live queries disabled" "$(alltext '.toast span' | tr '\n' ' ')$(xtext)" "Live queries are disabled"
eq "no run while disabled" "$(runs_now)" "$runs"
config_reset
explore_close_all

lens 'kubectl --context kind-tern-kube-dev get pods -n tern-test-empty'
native || return
click_text 'Explore live' || return
explore_open || return
xkey %
E2E_WAIT=20 xwait "usage · pods · ns tern-test-empty" || return
contains "empty namespace" "$(xtext)" "No pods"
explore_close_all

kc run "$fresh" -n "$uns" --image=busybox:1.37 --restart=Never -- sh -c 'sleep 600' >/dev/null || fail "cannot create $fresh"
E2E_WAIT=60 wait_for "$fresh running" sh -c "[ \"\$(kubectl --context kind-tern-kube-dev get pod -n $uns $fresh -o jsonpath='{.status.phase}')\" = Running ]" || return
lens "kubectl --context kind-tern-kube-dev get pods -n $uns"
native || return
click_text "$fresh" '.tk-grid .tk-c' || return
click_text 'Explore live' || return
explore_open || return
xwait "Object pod/$fresh"
xkey escape
xwait "$fresh" "$XT"
xkey %
E2E_WAIT=20 xwait "usage · pods · ns $uns" || return
xselect "$fresh" || return
contains "fresh pod without metrics" "$(texts "$EX .sf-tbl-row.sel > .sf-tbl-c" | jq -r 'join(" ")')" "<no metrics>"
E2E_WAIT=90 wait_for "a metrics window for $fresh" sh -c "kubectl --context kind-tern-kube-dev top pod -n $uns $fresh >/dev/null 2>&1" || return
xkey r
sleep 3
xselect "$fresh" || return
excludes "metrics after r" "$(texts "$EX .sf-tbl-row.sel > .sf-tbl-c" | jq -r 'join(" ")')" "<no metrics>"

viewport_size 500 800 || fail "the viewport stays $(viewport), not 500x800"
xkey '?'
help=$(alltext "[data-role='tern-kube.explore-layer'] *" | tr '\n' ' ')
contains "help: %" "$help" "%"
contains "help: w" "$help" "w"
contains "help: This view" "$help" "This view"
xkey escape
viewport_size 1280 800 || fail "the viewport stays $(viewport), not 1280x800"
explore_close_all
