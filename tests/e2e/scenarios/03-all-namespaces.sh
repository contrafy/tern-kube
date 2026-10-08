# Live: -A namespace chips filter; Problems excludes Completed pods.
lens 'kubectl get pods -A'
native
eq "first header" "$(texts '.kl-grid .kl-h' | jq -r '.[0]')" NAMESPACE
chips=$(texts '[data-role="kube-lens.chips"] .sf-act')
contains "namespace chips" "$chips" '"tern-test-apps 7"'
contains "namespace chips" "$chips" '"kube-system'
click_text "tern-test-apps 7"
contains "filtered counts" "$(alltext '[data-role="kube-lens.counts"]')" "7 of "
eq "filtered cells" "$(count '.kl-grid .kl-c')" 42
click_text "Clear filters"
click_text "Problems*"
cells=$(alltext '.kl-grid .kl-c')
contains "problems" "$cells" crashloop
contains "problems" "$cells" fail-job
excludes "problems" "$cells" done-job
