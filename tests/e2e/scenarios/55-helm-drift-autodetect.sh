# Chart auto-detect against a throwaway git repository (never the user's)
# holding the shop chart and values-staging.yaml. ctrl+g lists shop-a's
# auto sources in both variants (deployed values, the values file); with the
# deployed values the report is clean: the other releases' objects and hooks
# in the namespace are ignored, not unmanaged, and the namespace-less
# objects are compared in the release namespace. A template edit in the
# repository then shows the Deployment as changed.
. "$E2E_REPO/tests/e2e/helm.sh"
helm_world || return
HREPO=$E2E_SB/helm-repo
helm_repo_cleanup() {
	# A failure leaves Explore focused; the cd must reach the shell.
	explore_close_all
	sh_line "cd '$E2E_REPO'"
	rm -rf "$HREPO"
}
trap helm_repo_cleanup EXIT

rm -rf "$HREPO"
mkdir -p "$HREPO/charts"
cp -R "$HSHOP" "$HREPO/charts/shop"
cp "$HSTAGING" "$HREPO/charts/shop/values-staging.yaml"
git -C "$HREPO" init -q -b main
git -C "$HREPO" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$HREPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init

# counts: the report's bucket chips as one JSON array.
counts() {
	texts "$EX .sf-act" | jq -c '[.[] | select(test("^(All|Changed|Missing in cluster|Unmanaged) "))]'
}

sh_line "cd '$HREPO'"
lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
native
click_text shop-a-shop '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/shop-a-shop'
xkey ctrl+g
E2E_WAIT=30 xwait 'Drift sources' || return
# Every release running the chart is a candidate (two rows each, broken-c
# first) and the chooser pages, so shop-a's rows may start below the fold:
# walk the selection to them instead of reading the visible page.
# NOTE is prose, the first column a 1280 px split hides: the zoomed pane
# has room for it.
ctl zoom >/dev/null
E2E_WAIT=30 xwait 'auto: name+version+app version match' "$XT *" || return
ctl zoom >/dev/null
sleep 0.5
xselect "charts/shop as $HNS/shop-a with charts/shop/values-staging.yaml" || return
xselect "charts/shop as $HNS/shop-a with deployed values" || return
xkey enter
E2E_WAIT=30 xwait 'Drift of' || return
E2E_WAIT=30 xwait 'in sync' || return
eq "clean report" "$(counts)" '["All 0","Changed 0","Missing in cluster 0","Unmanaged 0"]'
contains "no drift" "$(xtext)" "No drift: the cluster matches the manifests"
contains "diffed in the release namespace" "$(xtext)" "-n $HNS"
contains "deployed values file" "$(xtext)" "written 0600 for the render, then removed"

# A template edit in the repository: r renders and compares again.
sed 's/containerPort: 80$/containerPort: 8080/' "$HREPO/charts/shop/templates/deployment.yaml" >"$HREPO/deployment.yaml"
mv "$HREPO/deployment.yaml" "$HREPO/charts/shop/templates/deployment.yaml"
xkey r
# xwait, not wait_for x_has: x_has reads its selector argument, unbound
# under the runner's set -u, so a bare x_has never succeeds.
E2E_WAIT=30 xwait 'Changed 1' || return
eq "changed report" "$(counts)" '["All 1","Changed 1","Missing in cluster 0","Unmanaged 0"]'
eq "changed object" "$(hcol 2 6)" '["Deployment"]'
eq "changed name" "$(hcol 4 6)" '["shop-a-shop"]'
explore_close_all
