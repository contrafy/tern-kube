# Live: Explore from an unpinned lens row infers the kubeconfig's
# current-context (warned, unconfirmed); relations of a Deployment and a
# Service carry their provenance.
lens 'kubectl get deploy -n tern-test-apps'
native
click_text web '.kl-grid .kl-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/web'
hdr=$(xtext '[data-role="kube-lens.explore-header"] *')
contains "inferred provenance" "$hdr" "(inferred: current-context at "
contains "inferred warning" "$hdr" "inferred target: check before acting"
contains "unconfirmed" "$hdr" "Confirm target"
contains "context pinned after inference" "$hdr" "context kind-kube-lens-dev"

xkey R
xwait 'Relations deployment/web'
xwait 'Pod' '[data-role="kube-lens.explore-relations"] *'
rel=$(xtext '[data-role="kube-lens.explore-relations"] *')
contains "deployment owns its replicaset" "$rel" "ReplicaSet"
contains "replicaset owns pods" "$rel" "Pod"
eq "owner provenance badges" "$(texts "$EX [data-role='kube-lens.explore-relations'] .kl-c" | jq -c 'map(select(. == "owner")) | length')" 3
excludes "no long provenance text" "$rel" "ownerReference"
pods=$(texts "$EX [data-role='kube-lens.explore-relations'] .kl-c" | jq '[.[] | select(test("^↳ web-[a-z0-9]+-[a-z0-9]{5}$"))] | length')
eq "both web pods" "$pods" 2
explore_close

lens 'kubectl get svc -n tern-test-apps'
native
click_text web '.kl-grid .kl-c'
click_text 'Explore live'
explore_open || return
xwait 'Object service/web'
xkey R
xwait 'Relations service/web'
xwait 'Pod' '[data-role="kube-lens.explore-relations"] *'
rel=$(xtext '[data-role="kube-lens.explore-relations"] *')
contains "service endpointslices" "$rel" "EndpointSlice"
contains "endpointslice provenance" "$rel" "slice"
contains "service pods" "$rel" "Pod"
contains "targetRef provenance" "$rel" "endpoint"
explore_close
