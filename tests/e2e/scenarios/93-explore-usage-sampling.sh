# Live: usage trends (read-only). Two r reads a window apart give a
# two-sample trend; w samples only the metrics read every 15 s behind a
# visible badge while the numbers stay put; w again stops it, and so does
# leaving the view: no run happens after either.
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

sleep 16
xkey r
sleep 3
spark=$(ctl tree "$EX .sf-tbl-row.sel [title*='samples']" | jq -r '.nodes[0].title // empty')
contains "two samples after r" "$spark" "2 samples"

cpu=$(hcol 2)
log=$(daemon_log)
lines=$(wc -l <"$log")
runs=$(runs_now)
xkey w
# The badge is a single span carrying the role (no child elements).
xwait 'Sampling' '[data-role="tern-kube.sampling"]' || return
contains "badge says how to stop" "$(xtext '[data-role="tern-kube.sampling"]')" "w stops"
sleep 35
grown=$(($(runs_now) - runs))
[ "$grown" -ge 2 ] && [ "$grown" -le 3 ] || fail "sampling ran $grown reads in 35 s (want 2-3)"
# The log names a run by its tag, not its argv: sample reads are tagged
# `usage-sample|GEN` and read only pods.metrics.k8s.io (tests/unit/explore/
# usage.spec.luau "sampling"); a full re-read (pods + metrics) is `usage|...`.
sampled=$(tail -n +"$((lines + 1))" "$log" | grep 'tern-kube explore.run')
excludes "samples read metrics only" "$(printf '%s\n' "$sampled" | grep -v 'explore.run.usage-sample|')" "explore.run"
eq "CPU cells unchanged while sampling" "$(hcol 2)" "$cpu"

xkey w
E2E_WAIT=5 wait_for "the badge to go" lacks "$EX [data-role='tern-kube.sampling']" || return
runs=$(runs_now)
sleep 20
eq "no runs after w stops" "$(runs_now)" "$runs"

xkey w
xwait 'Sampling' '[data-role="tern-kube.sampling"]' || return
xkey escape
runs=$(runs_now)
sleep 20
eq "no runs after leaving the view" "$(runs_now)" "$runs"
explore_close_all
