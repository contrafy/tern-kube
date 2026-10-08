# Live: get pods table, sort click, row inspector, copy, Inspect, Back.
lens 'kubectl get pods -n tern-test-apps'
native
eq "headers" "$(texts '.kl-grid .kl-h')" '["NAME","READY","STATUS","RESTARTS","AGE"]'
eq "cells (7 rows x 5)" "$(count '.kl-grid .kl-c')" 35
contains "header" "$(alltext '[data-role="kube-lens.header"] .sf-text')" "7 rows"

click_text NAME '.kl-grid .kl-h'
click_text 'NAME ▲' '.kl-grid .kl-h'
eq "sorted desc header" "$(texts '.kl-grid .kl-h' | jq -r '.[0]')" "NAME ▼"
contains "first row after desc sort" "$(texts '.kl-grid .kl-c' | jq -r '.[0]')" "web-"

click_text db-0 '.kl-grid .kl-c'
has '[data-role="kube-lens.inspector"]' || fail "row click opened no inspector"
click_text "Copy describe"
eq "clipboard" "$(clip)" "kubectl describe pod db-0 -n tern-test-apps"
contains "toast" "$(alltext '.toast span')" "Copied"

click_text Inspect
has '[data-role="kube-lens.inspect"]' || fail "Inspect opened no full view"
contains "breadcrumb" "$(alltext '[data-role="kube-lens.breadcrumb"] *')" db-0
lacks '.kl-grid' || fail "Inspect still shows the table"

click_text Back
has '.kl-grid' || fail "Back did not return to the table"
eq "sort kept after Back" "$(texts '.kl-grid .kl-h' | jq -r '.[0]')" "NAME ▼"
has '[data-role="kube-lens.inspector"]' || fail "Back closed the inspector"
click_text Close
lacks '[data-role="kube-lens.inspector"]' || fail "Close left the inspector open"
