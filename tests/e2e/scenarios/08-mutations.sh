# FAKE (recorded fixtures): M1 runs only read-only kubectl against the
# cluster, so apply / rollout restart / scale results come from the fake.
fake real/mutate-create
lens 'kubectl apply -f mutate/app.yaml -n tern-test-mutate'
native
contains "summary" "$(texts '[data-role="tern-kube.mutation-summary"] .sf-badge')" '"3 created"'
eq "actions" "$(texts '.tk-grid .tk-c' | jq -c '[.[3], .[7], .[11]]')" '["created","created","created"]'
fake real/mutate-ops
lens 'kubecolor rollout restart deployment/api -n tern-test-mutate'
native
contains "restart" "$(texts '.tk-grid .tk-c')" '"restarted"'
fake real/errors
lens 'kubectl --context kind-tern-kube-dev scale deployment/api --replicas=1 -n tern-test-mutate'
native
eq "error cards" "$(count '[data-role="tern-kube.error"]')" 1
lacks '[data-role="tern-kube.diagnostics"]' || fail "error repeated in the header"
contains "context from flags" "$(alltext '[data-role="tern-kube.header"] .sf-text')" "kind-tern-kube-dev"
