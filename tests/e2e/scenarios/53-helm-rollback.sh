# Helm rollback through the approve block (tests/e2e/helm.sh world; shop-a
# is rolled back and rebuilt at revision 3 on exit). ctrl+r on r1 in the
# history previews the recorded change (revisions 3 -> 1) and the live
# objects (kubectl diff), with a dry run; the typed token is the release
# name. After confirm helm is at revision 4 "Rollback to 1" and the audit
# log records family helm-rollback. A second preview goes stale when the
# release is upgraded from the shell before confirm: refused, nothing runs.
# stuck-d (pending-upgrade) is typed with the pending reason; cancelled.
. "$E2E_REPO/tests/e2e/helm.sh"
helm_world || return
trap helm_shop_a EXIT
AUDIT=$E2E_SB/cfg/plugin-data/tern-kube/audit.log

latest() { # REVISION/STATUS/DESCRIPTION of shop-a's newest revision
	hm history shop-a --max 1 -o json 2>/dev/null | jq -r '.[0] | "\(.revision)/\(.status)/\(.description)"'
}

# history DEPLOYMENT: Explore of the deployment, H, then h.
history() {
	lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
	native
	click_text "$1" '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return 1
	xwait "Object deployment/$1"
	xkey H
	xwait 'rev '
	xkey h
	xwait 'revisions'
}

history shop-a-shop || return
xkey G
eq "r1 selected" "$(xsel)" 1
xkey ctrl+r
approve_open || return
E2E_WAIT=40 a_ready || return
a=$(atext)
contains "helm card" "$a" "helm rollback"
contains "revision line" "$a" "3 (deployed) → 1 (superseded)"
contains "recorded change section" "$a" "Recorded change (helm revisions 3 → 1)"
contains "live diff section" "$a" "Against live objects (kubectl diff)"
contains "dry run step" "$a" "helm rollback --dry-run (the revision exists)"
contains "rollback reason" "$a" "Rolls shop-a back from revision 3 to 1"
contains "typed tier" "$a" "Typed confirm"
contains "token prompt" "$a" "Type shop-a to confirm"
lines=$(wc -l 2>/dev/null <"$AUDIT" || echo 0)

# enter without the token changes nothing.
xkey enter
sleep 1
eq "enter without the token" "$(latest)" "3/deployed/Upgrade complete"
ctl type shop-a >/dev/null
xkey enter
E2E_WAIT=200 a_done || return
# The result line appears after the post-run history read, not with done.
E2E_WAIT=30 wait_for "the rollback result line" a_has "shop-a is now at revision 4 (deployed): Rollback to 1"
eq "helm history" "$(latest)" "4/deployed/Rollback to 1"
entry=$(tail -n +"$((lines + 1))" "$AUDIT" | grep '"decision":"executed"' | tail -1)
eq "audit family" "$(printf '%s' "$entry" | jq -r .family)" helm-rollback
eq "audit revisions" "$(printf '%s' "$entry" | jq -r '"\(.release) \(.from_revision)->\(.revision) exit \(.exit_code)"')" "shop-a 3->1 exit 0"
xkey escape
approve_closed || return

# Stale: an upgrade between preview and confirm is refused.
xkey r
xwait '4 revisions'
xkey G ctrl+r
approve_open || return
E2E_WAIT=40 a_ready || return
contains "second preview" "$(atext)" "Rolls shop-a back from revision 4 to 1"
hw upgrade shop-a "$HSHOP" --reuse-values --set config.mode=sneaky || return
ctl type shop-a >/dev/null
xkey enter
await "The release changed since the preview" || return
contains "stale reason" "$(atext)" "revision 5 deployed, previewed 4 deployed"
eq "stale rollback did not run" "$(latest)" "5/deployed/Upgrade complete"
eq "audit blocked" "$(tail -1 "$AUDIT" | jq -r '"\(.family) \(.decision)"')" "helm-rollback blocked"
xkey escape
approve_closed || return
explore_close_all

# Pending: stuck-d's rollback is typed and names the race; cancelled.
lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
click_text stuck-d-shop '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/stuck-d-shop'
xkey H
xwait 'rev 2 of 2'
xkey ctrl+r
approve_open || return
E2E_WAIT=40 a_ready || return
a=$(atext)
contains "pending revision" "$a" "2 (pending-upgrade) → 1"
contains "pending reason" "$a" "if another helm process still runs, the rollback races it"
contains "pending is typed" "$a" "Type stuck-d to confirm"
xkey escape
approve_closed || return
eq "cancel keeps stuck-d pending" "$(hm history stuck-d --max 1 -o json | jq -r '.[0].status')" pending-upgrade
explore_close_all
