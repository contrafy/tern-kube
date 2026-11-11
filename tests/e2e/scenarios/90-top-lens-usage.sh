# Live: `kubectl top` in the lens. `--sum` totals are a footer under the rows
# (not rows: they neither count nor sort), `--containers` rows open the real
# pod (POD column, not the container NAME), node percent cells are toned, and
# the Usage chips open Explore's usage view for the same scope.
uns=tern-test-usage

E2E_WAIT=120 wait_for "metrics for $uns" kc top pods -n "$uns" || return

lens 'kubectl top pods -A --sum'
native || return
rows=$(count '.tk-grid .tk-r')
contains "header counts the pods only" "$(ltext '[data-role="tern-kube.header"] .sf-text')" "$rows rows"
excludes "no separator row" "$(ltext '.tk-grid *')" "________"
contains "totals footer" "$(ltext '[data-role="tern-kube.totals"]')" "Total "
click_text 'CPU(cores)' '.tk-grid .tk-h' || return
eq "sorted by CPU" "$(texts '.tk-grid .tk-h' | jq -r '.[2]')" "CPU(cores) ▼"
footer_y=$(ctl tree '[data-role="tern-kube.totals"]' | jq '.nodes[0].rect[1] // 0')
last_y=$(ctl tree '.tk-grid .tk-r' | jq '[.nodes[]?.rect[1]] | max // 0')
eq "footer stays after the sorted rows" "$(jq -n --argjson f "$footer_y" --argjson l "$last_y" '$f > $l')" true

lens "kubectl top pods -n $uns --containers"
native || return
click_text cpu-burner '.tk-grid .tk-c' || return
E2E_WAIT=5 wait_for "the row inspector" has '[data-role="tern-kube.inspector"]' || return
click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act' || return
explore_open || return
xwait 'pod/cpu-burner'
explore_close

lens "kubectl top pods -n $uns --containers"
click_text cpu-burner '.tk-grid .tk-c' || return
click_text 'Usage in Explore' '[data-role="tern-kube.inspector"] .sf-act' || return
explore_open || return
xwait 'cpu-burner'
contains "usage route" "$(xtext '[data-role="tern-kube.explore-header"] *')" "usage"
explore_close

lens "kubectl top pods -n $uns"
native || return
click_text 'Usage vs requests in Explore' '[data-role="tern-kube.chips"] .sf-act' || return
explore_open || return
xwait "usage · pods · ns $uns" '[data-role="tern-kube.explore-header"] *'
explore_close

lens 'kubectl get pods -n tern-test-apps'
native || return
lacks '[data-role="tern-kube.explore-usage"]' || fail "get offers the usage chip"

lens 'kubectl top nodes'
native || return
click_text 'Usage vs requests in Explore' '[data-role="tern-kube.chips"] .sf-act' || return
explore_open || return
xwait "usage · nodes" '[data-role="tern-kube.explore-header"] *'
explore_close

# FAKE: kind's node never nears 80% of allocatable, so the tones come from
# a recorded-shape `top nodes` with 85% CPU and 98% memory.
fake kubectl/usage/hot
lens 'kubectl top nodes'
native || return
eq "warning tone at 85%" "$(texts '.tk-grid .tk-c .sf-t-warning')" '["85%"]'
eq "error tone at 98%" "$(texts '.tk-grid .tk-c .sf-t-error')" '["98%"]'
real
