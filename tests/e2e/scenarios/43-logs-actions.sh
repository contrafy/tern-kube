# Live: the logs lens's split actions on tk-logmix (tern-test-logs, 2 pods x
# app/side/crashy). "Follow in split" runs the raw `logs -f` quick action
# (an sh -c split, never lensed); a "Run in split" variant is typed at the
# prompt of a new interactive split, so the lens claims it there and the pane
# stays at a prompt; a lensed command whose kubeconfig path holds a quote is
# never typed (no quoting is literal in zsh, bash and fish alike): the line
# is copied and a toast says so. Nothing mutates.
lns=tern-test-logs
LOGS='[data-role="tern-kube.logs"]'
ACTS='[data-role="tern-kube.logs-actions"] .sf-act'

pod=$(kc -n "$lns" get pods -l app=tk-logmix -o name | LC_ALL=C sort | head -n 1)
pod=${pod#pod/}
[ -n "$pod" ] || {
	fail "no tk-logmix pod in $lns"
	return
}

panes_are() {
	[ "$(pane_count)" -eq "$1" ]
}

# Without -c the Defaulted line names every container: a variant per other one.
lens "kubectl logs -n $lns $pod"
native
has "$LOGS" || fail "logs view not shown"
before=$(pane_count)

# Follow in split: raw live stream in an sh -c split titled with the target.
click_text 'Follow in split' "$ACTS" || return
E2E_WAIT=15 quick_pane "tern-kube logs pod $lns/$pod" || return
eq "follow opened one split" "$(pane_count)" $((before + 1))
eq "follow split is raw (not lensed)" "$(count "$LOGS")" 1
grep -q 'tern-kube quick action.*logs-follow' "$(window_log)" || fail "no logs-follow quick action logged"
ctl close >/dev/null
E2E_WAIT=5 wait_for "the follow split to close" panes_are "$before"
ctl click 30 600 >/dev/null
top

# Run in split, side container: typed into an interactive split, lensed there.
click_text '▸ side' "$ACTS" || return
E2E_WAIT=15 wait_for "a typed split" panes_are $((before + 1)) || return
E2E_WAIT=20 wait_for "the typed command lensed in the new split" has "$LOGS" 2 || return
E2E_WAIT=20 wait_for "the typed split back at its prompt" idle || return
grep -q "tern-kube typed quick action.*logs.*$lns/$pod:side" "$(window_log)" ||
	fail "no typed logs launch logged for $pod:side"
contains "typed split shows the side container" "$(blocktext)" "side: beat"
eq "typed split stays open at its prompt" "$(pane_count)" $((before + 1))
ctl close >/dev/null
E2E_WAIT=5 wait_for "the typed split to close" panes_are "$before"
ctl click 30 600 >/dev/null

# Refusal: a kubeconfig path with a quote is copied, not typed.
qdir="$E2E_SB/kube'q"
mkdir -p "$qdir"
cp "$E2E_REPO/.sandbox/kubeconfig" "$qdir/config"
typed_before=$(grep -c 'tern-kube typed quick action' "$(window_log)")
lens "kubectl --kubeconfig \"$qdir/config\" logs -n $lns $pod"
native
before=$(pane_count)
click_text '▸ side' "$ACTS" || {
	rm -rf "$qdir"
	return
}
sleep 1
eq "refused variant opened no pane" "$(pane_count)" "$before"
contains "refusal toast" "$(alltext '.toast span')" "not typed into a split"
contains "refused line copied" "$(clip)" "kubectl logs --kubeconfig '$E2E_SB/kube'\\''q/config' -n $lns $pod -c side"
eq "refused line never typed" "$(grep -c 'tern-kube typed quick action' "$(window_log)")" "$typed_before"
rm -rf "$qdir"
