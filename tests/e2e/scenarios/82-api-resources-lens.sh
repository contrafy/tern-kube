# Live: the api-resources lens. `-o wide -n tern-test-crd` offers NAMESPACED,
# GROUP and VERB facets (GROUP apps narrows to the apps resources), and
# "Explore widgets" opens Explore listing widgets.lens.example.com in
# tern-test-crd. The plain table has no VERB facet.
INS='[data-role="tern-kube.inspector"] .sf-act'
lens "kubectl --context kind-tern-kube-dev api-resources -o wide -n tern-test-crd"
native
has '[data-key="facet-NAMESPACED"]' || fail "no NAMESPACED facet"
has '[data-key="facet-GROUP"]' || fail "no GROUP facet"
has '[data-key="facet-VERB"]' || fail "no VERB facet on -o wide"
click_text "false" '[data-key="facet-NAMESPACED"] *'
excludes "cluster-scoped only" "$(column_texts 1 7)" '"pods"'
click_text "Clear filters" '[data-role="tern-kube.chips"] *'
click_text "apps" '[data-key="facet-GROUP"] *'
contains "apps resources" "$(column_texts 1 7)" '"deployments"'
excludes "no core resources" "$(column_texts 1 7)" '"configmaps"'
click_text "Clear filters" '[data-role="tern-kube.chips"] *'

click_text widgets '.tk-grid .tk-c'
eq "api-resources chips" "$(texts "$INS")" '["Inspect","Explore widgets","Copy name","Copy get command","Close"]'
click_text "Explore widgets" "$INS"
explore_open || return
contains "widgets listed" "$(xtext)" "widgets.lens.example.com"
contains "namespace from -n" "$(xtext)" "tern-test-crd"
explore_close

lens "kubectl --context kind-tern-kube-dev api-resources"
native
lacks '[data-key="facet-VERB"]' || fail "plain table offers a VERB facet"
