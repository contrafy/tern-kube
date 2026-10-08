# Live: error-only output renders natively; leading global flags claimed.
lens 'kubectl get foos'
native
has '[data-role="tern-kube.exit"]' || fail "no exit badge"
contains "diagnostic" "$(alltext '[data-role="tern-kube.diagnostics"] *')" 'resource type "foos"'
lens 'kubectl --context kind-tern-kube-dev -n tern-test-apps get deploy'
native
contains "context" "$(alltext '[data-role="tern-kube.header"] .sf-text')" "kind-tern-kube-dev"
