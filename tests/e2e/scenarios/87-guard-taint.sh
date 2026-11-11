# v1.2 guard (a): `kubectl taint` on the kind node in a real pane. A
# NoExecute taint: typed tier, the evictions card lists coredns, deny, the
# node keeps its taints. PreferNoSchedule add then remove, approved. The
# EXIT trap removes every taint with this run's key and uncordons the node.
focused_id() {
	ctl state | jq -r '.focused.id'
}
not_focused() {
	[ "$(focused_id)" != "$1" ]
}
at_prompt() {
	ctl state | jq -e '.focused.prompt' >/dev/null
}
guard_tab_close() {
	i=0
	while [ "$(focused_id)" != "$home_tab" ] && [ $i -lt 4 ]; do
		ctl close >/dev/null
		sleep 0.5
		i=$((i + 1))
	done
}
home_tab=$(focused_id)
K="kubectl --context kind-tern-kube-dev"
guarded() { # guarded LINE: run LINE, wait for its preview
	type_line "$1; echo GUARD-RC=\$?"
	approve_open && a_ready
}
finished() { # finished RC
	approve_closed || return 1
	expect_grid "GUARD-RC=$1" || return 1
	sh_line clear
}
guard_tab() { # DIR
	ctl tab new >/dev/null
	E2E_WAIT=10 wait_for "a new tab" not_focused "$home_tab"
	E2E_WAIT=10 wait_for "the new tab's prompt" at_prompt
	sh_line "source '$E2E_REPO/shell/tern-kube.zsh' && cd '$1' && clear"
}
node=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
tkey=tk-e2e-taint-$$
taint_cleanup() {
	guard_tab_close
	kc taint node "$node" "$tkey-" >/dev/null 2>&1
	kc uncordon "$node" >/dev/null 2>&1
}
trap taint_cleanup EXIT
guard_tab "$E2E_SB"

guarded "$K taint node $node $tkey=x:NoExecute" || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "evictions card" "$(atext)" "evicted"
contains "coredns evicted" "$(atext)" "coredns"
xkey escape
finished 1 || return
excludes "denied: node untainted" "$(kc get node "$node" -o jsonpath='{.spec.taints}')" "$tkey"

guarded "$K taint node $node $tkey=1:PreferNoSchedule" || return
contains "taint diff" "$(atext)" "$tkey"
excludes "simple tier" "$(atext)" "Typed confirm"
xkey enter
finished 0 || return
contains "tainted" "$(kc get node "$node" -o jsonpath='{.spec.taints}')" "$tkey"

guarded "$K taint node $node $tkey:PreferNoSchedule-" || return
xkey enter
finished 0 || return
excludes "untainted" "$(kc get node "$node" -o jsonpath='{.spec.taints}')" "$tkey"
guard_tab_close
eq "back in the first tab" "$(focused_id)" "$home_tab"
