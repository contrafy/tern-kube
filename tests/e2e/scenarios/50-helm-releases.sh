# Live: the Helm releases route (tests/e2e/helm.sh world, read-only). The
# kinds picker's synthetic first row opens it in the Explore namespace scope;
# status badges by tone (failed error, pending-upgrade warning), chart,
# version and app version columns; n switches to every namespace and back
# to one; / filters by status.
. "$E2E_REPO/tests/e2e/helm.sh"
helm_world || return

lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
native
click_text web-b-web '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/web-b-web'
xkey escape
xwait 'web-b-web' "$XT *"

# : kinds picker: "helm releases" is the first row and the only match of "helm".
xkey :
xwait 'Kinds'
eq "first kinds row" "$(hcol 1 2 | jq -r '.[0]')" "helm releases"
xkey /
ctl type helm >/dev/null
xkey enter
eq "kinds filter helm" "$(hcol 1 2)" '["helm releases"]'
xkey enter
xwait '4 releases'
eq "releases in the namespace scope" "$(hcol 1 8)" '["broken-c","shop-a","stuck-d","web-b"]'
eq "chart column" "$(hcol 5 8)" '["shop","shop","shop","web"]'
eq "version column" "$(hcol 6 8)" '["0.1.0","0.1.0","0.1.0","0.2.1"]'
eq "app version column" "$(hcol 7 8)" '["1.27","1.27","1.27","2.1"]'
eq "revision column" "$(hcol 3 8)" '["1","3","2","3"]'
eq "failed badge" "$(texts "$XROW .sf-t-error")" '["failed"]'
eq "pending badge" "$(texts "$XROW .sf-t-warning")" '["pending-upgrade"]'
eq "deployed badges" "$(texts "$XROW .sf-t-success")" '["deployed","deployed"]'
contains "problems chip" "$(xtext)" "2 need attention"

# n: every namespace adds side-g from the second namespace.
xkey n
xwait 'Namespaces'
xselect 'all namespaces' || return
xkey enter
xwait 'side-g' "$XT *"
contains "all namespaces scope" "$(xtext '[data-role="tern-kube.explore-header"] *')" "all namespaces"
eq "releases across namespaces" "$(hcol 1 8 | jq -c '[.[] | select(. == "side-g" or . == "shop-a")]')" '["shop-a","side-g"]'
contains "second namespace listed" "$(hcol 2 8)" "$HNS2"

# /fail: the failed release only; esc clears the filter.
xkey /
ctl type fail >/dev/null
xkey enter
eq "status filter" "$(hcol 1 8)" '["broken-c"]'
xkey escape
xwait 'side-g' "$XT *"

# n again: one namespace narrows the list to its release.
xkey n
xwait 'Namespaces'
xselect "$HNS2" || return
xkey enter
xwait '1 release'
eq "one namespace" "$(hcol 1 8)" '["side-g"]'
explore_close
