# Live: help card, Explore live link (real kubectl in the daemon), narrow
# window hides low-priority columns.
lens 'kubectl get pods -n tern-test-apps'
native
click_text '?'
has '[data-role="tern-kube.help"]' || fail "help card did not open"
click_text '? hide help'
lacks '[data-role="tern-kube.help"]' || fail "help card did not close"
click_text db-0 '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
contains "explore target" "$(xtext '[data-role="tern-kube.explore-header"] *')" "ns tern-test-apps"
explore_close
ctl resize 500 800 >/dev/null
sleep 0.8
top
eq "narrow headers" "$(texts '.tk-grid .tk-h')" '["NAME","READY","STATUS"]'
ctl resize 1280 800 >/dev/null
sleep 0.8
