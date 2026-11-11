# Live: release history and revision diffs (tests/e2e/helm.sh, read-only).
# shop-a: three revisions newest first, the latest marked running; = on r1
# diffs it against the latest (Deployment replicas and image, ConfigMap
# mode, the user values that changed); space marks r1 and = on r2 compares
# the pair. web-b r1..r3 changes the password: the Secret and the
# ConfigMap's DSN echo say "values changed (masked)" and never show it.
. "$E2E_REPO/tests/e2e/helm.sh"
helm_world || return

# release DEPLOYMENT: Explore of the deployment, H opens its release.
release() {
	lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
	native
	click_text "$1" '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return 1
	xwait "Object deployment/$1"
	xkey H
	xwait 'rev 3 of 3'
}

release shop-a-shop || return
xkey h
xwait '3 revisions'
eq "newest first" "$(hcol 1 7)" '["3","2","1"]'
eq "statuses" "$(hcol 2 7)" '["deployed","superseded","superseded"]'
eq "latest badge" "$(hcol 7 7 | jq -r '.[0]')" "latest running"
# DESCRIPTION is prose, the first column a 1280 px split hides: the zoomed
# pane has room for it.
ctl zoom >/dev/null
sleep 0.5
contains "descriptions" "$(hcol 6 7)" "Install complete"
ctl zoom >/dev/null
sleep 0.5

# = on r1: against the latest revision.
xkey G
eq "r1 selected" "$(xsel)" 1
xkey =
xwait 'Diff shop-a rev 1..3'
E2E_WAIT=20 xwait '2 modify' || return
diff=$(xtext '[data-role="tern-kube.gitops-diff"] *')
contains "deployment segment" "$diff" "MODIFY Deployment $HNS/shop-a-shop"
contains "replicas change" "$diff" "replicas: 2"
contains "image change" "$diff" "nginx:1.27.3-alpine"
contains "configmap segment" "$diff" "MODIFY ConfigMap $HNS/shop-a-shop-config"
contains "mode change" "$diff" 'mode: "staging"'
eq "changed user values" "$(hcol 1 4)" '["config.mode","image.tag","replicaCount"]'
excludes "plain values are not masked" "$(xtext)" "values changed (masked)"

# space marks r1; = on r2 compares the marked pair.
xkey escape
xwait '3 revisions'
xkey G space
eq "mark column" "$(hcol 7 7 | jq -r '.[2]')" "marked"
xkey k
eq "r2 selected" "$(xsel)" 2
xkey =
xwait 'Diff shop-a rev 1..2'
E2E_WAIT=20 xwait '2 modify' || return
excludes "r2 keeps the image" "$(xtext '[data-role="tern-kube.gitops-diff"] *')" "1.27.3-alpine"
contains "r2 replicas" "$(xtext '[data-role="tern-kube.gitops-diff"] *')" "replicas: 2"
explore_close_all

# web-b r1..r3: a new password, masked in the values table and the objects.
release web-b-web || return
xkey h
xwait '3 revisions'
xkey G =
xwait 'Diff web-b rev 1..3'
E2E_WAIT=20 xwait 'MODIFY Secret' || return
all=$(xtext)
contains "chart change" "$all" "web-0.2.0 (app 2.0) → web-0.2.1 (app 2.1)"
eq "password row masked" "$(hcol 4 4 | jq -r '.[0]')" "values changed (masked)"
eq "password shown masked" "$(hcol 3 4 | jq -r '.[0]')" "<redacted>"
contains "secret segment" "$all" "MODIFY Secret $HNS/web-b-web-auth"
contains "DSN echo masked" "$all" "postgres://app:<redacted>@db:5432/app"
excludes "no secret in the diff" "$all" "REDACTME"
explore_close_all
