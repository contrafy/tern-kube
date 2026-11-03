# Live: Explore logs of a tk-logmix pod (tern-test-logs, read-only): records
# with level badges and sources, ] to the first error, x level floor, /
# search, a container cycle, o previous instance (crashy restarts), w wrap,
# enter inspector, l follow in a split; the logs lens chips "Open in Explore"
# and "Search…" land on this route (the latter with the filter focused).
ns=tern-test-logs
pod=$(kc -n "$ns" get pods -l app=tk-logmix -o jsonpath='{.items[0].metadata.name}')
[ -n "$pod" ] || {
	fail "no tk-logmix pod in $ns (kubectl apply -f tests/integration/manifests/logs/logmix.yaml)"
	return
}

# Cells of the selected record (TIME, SOURCE, LEVEL, MESSAGE).
selected() {
	texts "$EX .tk-sel .tk-c"
}

column() {
	cols=$(count "$EX .tk-grid .tk-h")
	texts "$EX .tk-grid .tk-c" | jq -c --argjson n "$cols" --argjson c "$1" '[to_entries[] | select(.key % $n == $c) | .value]'
}

lens "kubectl --context kind-tern-kube-dev get pods -n $ns -l app=tk-logmix"
native
click_text "$pod" '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait "Object pod/$pod"
xkey L
xwait "Logs pod/$pod"
xwait '--tail=500' '[data-role="tern-kube.logs-summary"] *'
has "$EX [data-role='tern-kube.level']" || fail "no level badges"
eq "every container is a source" "$(count "$EX .tk-grid .tk-h")" 4

# ]: from the newest line (selected) the first error is searched from the top.
xkey ]
contains "] selects an error" "$(selected)" "ERROR"

# x: warnings+, errors+, then every level.
xkey x
excludes "warnings+ hides info" "$(column 2)" '"INFO"'
xkey x
excludes "errors+ hides warnings" "$(column 2)" '"WARN"'
xkey x
contains "every level again" "$(column 2)" '"INFO"'

# /: search messages; backspace takes the search away again.
xkey /
ctl type 'tick' >/dev/null
xkey enter
msgs=$(column 3)
printf '%s' "$msgs" | jq -e 'length > 0 and all(.[]; contains("tick"))' >/dev/null ||
	fail "search keeps only tick lines: $msgs"
xkey / backspace backspace backspace backspace enter

# a: one container at a time (no SOURCE column), then all again.
xkey a
xwait '--tail=500' '[data-role="tern-kube.logs-summary"] *'
eq "one container: no source column" "$(count "$EX .tk-grid .tk-h")" 3
xkey a a
xwait '--tail=500' '[data-role="tern-kube.logs-summary"] *'

# o: the crashy container restarts; its previous instance has the panic.
# For about 80 s after each crashy exit kubectl's --previous answers "unable
# to retrieve container logs" (the kubelet already removed the older
# instance), so o waits until kubectl returns the panic itself.
crashy_previous() {
	kc -n "$ns" logs "$pod" -c crashy --previous --tail=5 2>/dev/null | grep -q panic
}
E2E_WAIT=120 wait_for "crashy's previous instance" crashy_previous || return
xkey o
xwait 'previous instance' '[data-role="tern-kube.logs-summary"] *'
contains "previous crashy logs" "$(xtext '.tk-grid *')" "panic"
xkey o a
xwait '--tail=500' '[data-role="tern-kube.logs-summary"] *'
eq "back to every container" "$(count "$EX .tk-grid .tk-h")" 4

# w wraps; enter opens the inspector, esc closes it before leaving.
xkey w
has "$EX .tk-logwrap" || fail "w did not wrap"
xkey enter
has "$EX [data-role='tern-kube.log-inspector']" || fail "enter did not open the inspector"
xkey escape
lacks "$EX [data-role='tern-kube.log-inspector']" || fail "esc did not close the inspector"
contains "esc kept the logs route" "$(xtext '[data-role="tern-kube.breadcrumb"] *')" "Logs pod/$pod"

# l: follow in a split (raw, live), then close it.
before=$(pane_count)
xkey l
E2E_WAIT=15 quick_pane "tern-kube logs pod $ns/$pod" || return
ctl close >/dev/null
sleep 1
eq "follow split closed" "$(pane_count)" "$before"
explore_close

# Lens chips: Open in Explore re-queries the same source; Search… also
# focuses the filter.
lens "kubectl --context kind-tern-kube-dev logs $pod -n $ns -c app --tail=50"
native
click_text 'Open in Explore'
explore_open || return
xwait "Logs pod/$pod"
contains "same container" "$(xtext '[data-role="tern-kube.chips"] *')" "app"
explore_close
click_text 'Search…'
explore_open || return
xwait "Logs pod/$pod"
contains "filter focused" "$(xtext '[data-role="tern-kube.status"] *')" "filter:"
ctl type 'failed' >/dev/null
xkey enter
msgs=$(column 2)
printf '%s' "$msgs" | jq -e 'length > 0 and all(.[]; contains("failed"))' >/dev/null ||
	fail "Search… filters what is typed: $msgs"
explore_close
