# Live: the Explore events timeline of tern-test-apps (read-only). v opens the
# namespace timeline (time groups, Warning badges), x keeps Warnings, / filters,
# enter opens the involved object, V on a Deployment includes its pods'
# events, r is the only re-read; the palette command Tern Kube: Events opens
# the same route in the namespace the last Explore used.
ns=tern-test-apps

# Cells of one grid column (0-based) in the Explore block.
column() {
	cols=$(count "$EX .tk-grid .tk-h")
	texts "$EX .tk-grid .tk-c" | jq -c --argjson n "$cols" --argjson c "$1" '[to_entries[] | select(.key % $n == $c) | .value]'
}

lens "kubectl --context kind-tern-kube-dev get pods -n $ns"
native
click_text crashloop '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/crashloop'
xkey escape
xwait 'crashloop' "$XT"

# v: the namespace timeline, newest first, grouped by recency.
xkey v
xwait "events · ns $ns"
has "$EX [data-role='tern-kube.explore-events']" || fail "events route not shown"
has "$EX .tk-grid .tk-sep" || fail "no time-group separators"
has "$EX [data-role='tern-kube.event-type']" || fail "no Warning badge"
contains "crashloop events listed" "$(xtext '.tk-grid *')" "Pod/crashloop"
contains "BackOff reason listed" "$(xtext '.tk-grid *')" "BackOff"

# x: Warning events only, then every type again.
xkey x
xwait 'shown' '[data-role="tern-kube.events-summary"] *'
excludes "x hides Normal events" "$(column 1)" '"Normal"'
xkey x
xwait "events · ns $ns"

# /: filter by object; enter opens the involved object.
xkey /
ctl type crashloop >/dev/null
xkey enter
objects=$(column 3)
contains "filter keeps crashloop" "$objects" "Pod/crashloop"
excludes "filter drops other objects" "$objects" "Pod/pending"
xkey g g enter
xwait 'Object pod/crashloop'
xkey escape
xwait "events · ns $ns"

# r: the only way the timeline is re-read.
runs=$(grep -c 'tern-kube explore.run' "$(daemon_log)")
more_runs() { [ "$(grep -c 'tern-kube explore.run' "$(daemon_log)")" -gt "$runs" ]; }
xkey r
E2E_WAIT=10 wait_for "r to re-read the events" more_runs
xwait 'fetched just now'
explore_close

# V on a Deployment: its own events plus those of its ReplicaSets and Pods.
lens "kubectl --context kind-tern-kube-dev get deploy -n $ns"
native
click_text broken-image '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/broken-image'
xkey V
xwait 'Events deployment/broken-image'
contains "related scope named" "$(xtext '[data-role="tern-kube.events-summary"] *')" "and what it owns"
contains "the deployment's pods' events" "$(column 3)" "Pod/broken-image-"
explore_close

# Palette: Tern Kube: Events opens the timeline of the last Explore's
# namespace (v1.1 first-run scope), here the deployments above.
ctl plugins run plugin.tern-kube.events >/dev/null
explore_open || return
xwait "events · ns $ns"
has "$EX [data-role='tern-kube.explore-events']" || fail "palette did not open the events route"
explore_close
