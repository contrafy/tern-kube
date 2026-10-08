# Live: -A namespace chips filter; Problems excludes Completed pods.
lens 'kubectl get pods -A'
native
eq "first header" "$(texts '.tk-grid .tk-h' | jq -r '.[0]')" NAMESPACE
chips=$(texts '[data-role="tern-kube.chips"] .sf-act')
contains "namespace chips" "$chips" '"tern-test-apps 7"'
contains "namespace chips" "$chips" '"kube-system'
click_text "tern-test-apps 7"
contains "filtered counts" "$(alltext '[data-role="tern-kube.counts"]')" "7 of "
eq "filtered cells" "$(count '.tk-grid .tk-c')" 42
click_text "Clear filters"
click_text "Problems*"
cells=$(alltext '.tk-grid .tk-c')
contains "problems" "$cells" crashloop
contains "problems" "$cells" fail-job
excludes "problems" "$cells" done-job
