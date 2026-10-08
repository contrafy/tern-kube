# Live: help card, Explore live link (spike block, real kubectl in the
# daemon), narrow window hides low-priority columns.
lens 'kubectl get pods -n tern-test-apps'
native
click_text '?'
has '[data-role="kube-lens.help"]' || fail "help card did not open"
click_text '? hide help'
lacks '[data-role="kube-lens.help"]' || fail "help card did not close"
click_text db-0 '.kl-grid .kl-c'
click_text 'Explore live'
E2E_WAIT=10 wait_for "Explore block" has "[data-surface='plugin.kube-lens.explore']"
sleep 1
explore=$(alltext "[data-surface='plugin.kube-lens.explore'] *")
contains "explore params" "$explore" "tern-test-apps"
contains "explore params" "$explore" "db-0"
ctl focus right >/dev/null
ctl key escape >/dev/null
E2E_WAIT=5 wait_for "Explore block to close" lacks "[data-surface='plugin.kube-lens.explore']"
ctl resize 500 800 >/dev/null
sleep 0.8
top
eq "narrow headers" "$(texts '.kl-grid .kl-h')" '["NAME","READY","STATUS"]'
ctl resize 1280 800 >/dev/null
sleep 0.8
