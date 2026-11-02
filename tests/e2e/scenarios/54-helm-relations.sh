# Live: objects and their Helm release (tests/e2e/helm.sh, read-only). The
# Explore detail and relations of Deployment shop-a-shop name the release
# with revision and status; its chip opens the release; R lists the
# release's objects present live and enter opens one. The lens chip "Helm
# release ns/X" on describe and get -o yaml opens the same release in
# Explore (the lens itself never queries helm).
. "$E2E_REPO/tests/e2e/helm.sh"
helm_world || return
OWNER="$EX [data-role='tern-kube.helm-owner']"

lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
native
click_text shop-a-shop '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/shop-a-shop'
E2E_WAIT=20 wait_for "the owner line" has "$OWNER" || return
owner=$(xtext "[data-role='tern-kube.helm-owner'] *")
contains "owner line" "$owner" "Managed by Helm release $HNS/shop-a rev 3"
contains "owner status" "$owner" "deployed"
contains "owner chart" "$owner" "shop-0.1.0"

# Relations show the same line.
xkey R
xwait 'Relations'
E2E_WAIT=20 wait_for "the owner line in relations" has "$OWNER" || return
xkey escape
xwait 'Object deployment/shop-a-shop'

# The chip opens the release; R there lists its objects.
click_text 'Helm release (H)' "$OWNER .sf-act" || return
xwait 'rev 3 of 3'
contains "chip opened the release" "$(xtext '[data-role="tern-kube.explore-header"] *')" "release $HNS/shop-a"
xkey R
xwait "Resources shop-a"
E2E_WAIT=20 xwait 'present' '.tk-grid *' || return
eq "resource kinds" "$(hcol 1 5)" '["ConfigMap","Service","Deployment"]'
eq "resource names" "$(hcol 2 5)" '["shop-a-shop-config","shop-a-shop","shop-a-shop"]'
eq "all present" "$(hcol 4 5)" '["present","present","present"]'
xkey G enter
xwait 'Object deployment/shop-a-shop'
explore_close_all

# Lens chips: describe and YAML of the managed Deployment.
for line in "describe deploy shop-a-shop -n $HNS" "get deploy shop-a-shop -n $HNS -o yaml"; do
	lens "kubectl --context kind-tern-kube-dev $line"
	native
	eq "lens chip ($line)" "$(ctl tree '.sf-block .sf-act' | jq -c '[.nodes[].text | select(test("^Helm release"))]')" \
		"[\"Helm release $HNS/shop-a\"]"
done
click_text "Helm release $HNS/shop-a" || return
explore_open || return
xwait 'rev 3 of 3'
contains "lens chip opened the release" "$(xtext '[data-role="tern-kube.explore-header"] *')" "release $HNS/shop-a"
explore_close_all
