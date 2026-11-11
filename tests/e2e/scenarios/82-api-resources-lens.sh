# Live: the api-resources lens. `-o wide -n tern-test-crd` offers NAMESPACED,
# GROUP and VERB facets (GROUP apps narrows to the apps resources), and
# "Explore widgets" opens Explore listing widgets.lens.example.com in
# tern-test-crd. The plain table has no VERB facet.
INS='[data-role="tern-kube.inspector"] .sf-act'
# Facet groups carry a role, not their key, in the DOM: name them by label.
FACET='[data-role="tern-kube.facet"] .sf-act'
facet_labels() {
	texts '[data-role="tern-kube.facet-label"]'
}
lens "kubectl --context kind-tern-kube-dev api-resources -o wide -n tern-test-crd"
native
contains "NAMESPACED facet" "$(facet_labels)" '"NAMESPACED"'
contains "GROUP facet" "$(facet_labels)" '"GROUP"'
contains "VERB facet on -o wide" "$(facet_labels)" '"VERB"'
click_text "false *" "$FACET"
excludes "cluster-scoped only" "$(column_texts 1 7)" '"pods"'
click_text "Clear filters" '[data-role="tern-kube.chips"] *'
click_text "apps *" "$FACET"
contains "apps resources" "$(column_texts 1 7)" '"deployments"'
excludes "no core resources" "$(column_texts 1 7)" '"configmaps"'
click_text "Clear filters" '[data-role="tern-kube.chips"] *'

# widgets sits below the 800 px viewport: its CATEGORY (lens) brings it up.
click_text "lens *" "$FACET"
eq "lens category rows" "$(column_texts 1 7)" '["widgets"]'
click_text widgets '.tk-grid .tk-c'
eq "api-resources chips" "$(texts "$INS")" '["Inspect","Explore widgets","Copy name","Copy get command","Close"]'
click_text "Explore widgets" "$INS"
explore_open || return
contains "widgets listed" "$(xtext)" "widgets.lens.example.com"
contains "namespace from -n" "$(xtext)" "tern-test-crd"
explore_close

lens "kubectl --context kind-tern-kube-dev api-resources"
native
excludes "plain table offers no VERB facet" "$(facet_labels)" '"VERB"'
