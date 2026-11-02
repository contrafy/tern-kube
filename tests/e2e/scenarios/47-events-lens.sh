# Live: event listings in the lens (tern-test-apps): `kubectl events` in its
# forms and `get events` render as native tables whose rows stand for the
# involved object: LAST SEEN keeps the age and shows `×N over D`, TYPE and
# REASON are facets, Warning rows are marked, the inspector's Explore live
# opens the object and "Events for" opens its Explore timeline.
ans=tern-test-apps

lens "kubectl events -n $ans"
native || return
chips=$(ltext '[data-role="tern-kube.chips"] *')
contains "TYPE facet" "$chips" "TYPE"
contains "REASON facet" "$chips" "REASON"
contains "a Warning facet chip" "$chips" "Warning "
contains "LAST SEEN ×N suffix" "$(ltext '.tk-grid *')" "×"
has '.tk-grid .tk-lvl-warn .tk-c' || fail "no Warning row marked"
click_text 'Warning *' '[data-role="tern-kube.chips"] .sf-act' || return
eq "TYPE filter keeps Warning rows" "$(column_texts 2 5 | jq -r 'unique | join(",")')" "Warning"

lens "kubectl events -A"
native || return
contains "NAMESPACE column" "$(texts '.tk-grid .tk-h')" '"NAMESPACE"'
contains "NAMESPACE facet" "$(ltext '[data-role="tern-kube.chips"] *')" "NAMESPACE"

lens "kubectl events -n $ans --types=Warning"
native || return
eq "--types=Warning" "$(column_texts 2 5 | jq -r 'unique | join(",")')" "Warning"

lens "kubectl get events -n $ans"
native || return
contains "get events OBJECT" "$(ltext '.tk-grid *')" "pod/"

lens "kubectl events -n $ans --for pod/crashloop"
native || return
eq "--for pod/crashloop" "$(column_texts 4 5 | jq -r 'unique | join(",")')" "Pod/crashloop"
click_text 'Pod/crashloop' '.tk-grid .tk-c' || return
E2E_WAIT=5 wait_for "the row inspector" has '[data-role="tern-kube.inspector"]' || return
click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act' || return
explore_open || return
xwait 'pod/crashloop'
explore_close

lens "kubectl events -n $ans --for pod/crashloop"
click_text 'Pod/crashloop' '.tk-grid .tk-c' || return
click_text 'Events for pod/crashloop' '[data-role="tern-kube.inspector"] .sf-act' || return
explore_open || return
E2E_WAIT=15 wait_for "the scoped events timeline" has "$EX [data-role='tern-kube.events-summary']" || return
contains "timeline of the object" "$(xtext)" "crashloop"
explore_close
