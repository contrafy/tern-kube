# Live: error-only output renders natively; leading global flags claimed.
lens 'kubectl get foos'
native
has '[data-role="kube-lens.exit"]' || fail "no exit badge"
contains "diagnostic" "$(alltext '[data-role="kube-lens.diagnostics"] *')" 'resource type "foos"'
lens 'kubectl --context kind-kube-lens-dev -n tern-test-apps get deploy'
native
contains "context" "$(alltext '[data-role="kube-lens.header"] .sf-text')" "kind-kube-lens-dev"
