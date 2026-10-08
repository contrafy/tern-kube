# Live: get pods table, sort click, row inspector, copy, Inspect, Back.
lens 'kubectl get pods -n tern-test-apps'
native
eq "headers" "$(texts '.tk-grid .tk-h')" '["NAME","READY","STATUS","RESTARTS","AGE"]'
eq "cells (7 rows x 5)" "$(count '.tk-grid .tk-c')" 35
contains "header" "$(alltext '[data-role="tern-kube.header"] .sf-text')" "7 rows"

click_text NAME '.tk-grid .tk-h'
click_text 'NAME ▲' '.tk-grid .tk-h'
eq "sorted desc header" "$(texts '.tk-grid .tk-h' | jq -r '.[0]')" "NAME ▼"
contains "first row after desc sort" "$(texts '.tk-grid .tk-c' | jq -r '.[0]')" "web-"

click_text db-0 '.tk-grid .tk-c'
has '[data-role="tern-kube.inspector"]' || fail "row click opened no inspector"
click_text "Copy describe"
eq "clipboard" "$(clip)" "kubectl describe pod db-0 -n tern-test-apps"
contains "toast" "$(alltext '.toast span')" "Copied"

click_text Inspect
has '[data-role="tern-kube.inspect"]' || fail "Inspect opened no full view"
contains "breadcrumb" "$(alltext '[data-role="tern-kube.breadcrumb"] *')" db-0
lacks '.tk-grid' || fail "Inspect still shows the table"

click_text Back
has '.tk-grid' || fail "Back did not return to the table"
eq "sort kept after Back" "$(texts '.tk-grid .tk-h' | jq -r '.[0]')" "NAME ▼"
has '[data-role="tern-kube.inspector"]' || fail "Back closed the inspector"
click_text Close
lacks '[data-role="tern-kube.inspector"]' || fail "Close left the inspector open"
