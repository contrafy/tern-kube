# The opt-in shell guard on the new verbs in a real pane (new tab, zsh
# snippet): `kubectl label`, `patch --patch-file`, `rollout undo` (typed),
# `cordon` and `uncordon` wait for the approve block and run once approved;
# `drain --dry-run=server` passes through without approval; `kubectl edit`
# (sandbox KUBE_EDITOR script) asks after the save: approve applies the
# edit, deny leaves the object unchanged. The EXIT trap closes the tab,
# uncordons the node and deletes the tk-e2e-* objects.
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
node=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
home_tab=$(focused_id)
gdir=$E2E_SB/guard-verbs
verbs_cleanup() {
	guard_tab_close
	kc uncordon "$node" >/dev/null 2>&1
	rm -rf "$gdir" "$E2E_SB/edit-script"
	e2e_objects_delete
}
trap verbs_cleanup EXIT
e2e_objects
kc -n "$MNS" set image deploy/tk-e2e-web web=registry.k8s.io/pause:3.9 >/dev/null
kc -n "$MNS" rollout status deploy/tk-e2e-web --timeout=60s >/dev/null || fail "second revision not ready"
mkdir -p "$gdir/tmp"
printf '{"spec":{"replicas":2}}\n' >"$gdir/replicas.json"
cat >"$E2E_SB/edit-script" <<'EOF'
sed 's/^  LEVEL: .*/  LEVEL: edited/' "$1" >"$1.new" && cat "$1.new" >"$1" && rm -f "$1.new"
EOF

ctl tab new >/dev/null
E2E_WAIT=10 wait_for "a new tab" not_focused "$home_tab"
E2E_WAIT=10 wait_for "the new tab's prompt" at_prompt
# TMPDIR in the sandbox: denied edit copies land there and go with it.
sh_line "source '$E2E_REPO/shell/tern-kube.zsh' && cd '$gdir' && export TMPDIR='$gdir/tmp' && clear"
sh_line tern-kube-guard-status
expect_grid "drain" || return
sh_line clear

K="kubectl --context kind-tern-kube-dev"
# guarded LINE: run LINE, wait for its preview.
guarded() {
	type_line "$1; echo GUARD-RC=\$?"
	approve_open && a_ready
}
approved() { # approved RC
	approve_closed || return 1
	expect_grid "GUARD-RC=$1" || return 1
	sh_line clear
}

guarded "$K label configmap tk-e2e-cm -n $MNS tier=gold" || return
contains "guard mode" "$(atext)" "Shell guard approval"
contains "label diff" "$(atext)" "tier: gold"
xkey enter
approved 0 || return
eq "label ran" "$(jp $MNS cm/tk-e2e-cm '{.metadata.labels.tier}')" gold

guarded "$K patch deploy tk-e2e-web -n $MNS --type=merge --patch-file replicas.json" || return
contains "patch diff" "$(atext)" "replicas: 2"
xkey enter
approved 0 || return
eq "patch ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2

guarded "$K rollout undo deploy/tk-e2e-web -n $MNS" || return
contains "undo typed" "$(atext)" "Typed confirm"
contains "undo template" "$(atext)" "image: registry.k8s.io/pause:3.10"
ctl type tk-e2e-web >/dev/null
xkey enter
approved 0 || return
eq "undo ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.template.spec.containers[0].image}')" registry.k8s.io/pause:3.10

guarded "$K cordon $node" || return
contains "cordon diff" "$(atext)" "unschedulable: true"
xkey enter
approved 0 || return
eq "cordon ran" "$(kc get node "$node" -o jsonpath='{.spec.unschedulable}')" true

guarded "$K uncordon $node" || return
xkey enter
approved 0 || return
eq "uncordon ran" "$(kc get node "$node" -o jsonpath='{.spec.unschedulable}')" ""

# A server dry run of drain passes through: no approve block.
type_line "$K drain $node --dry-run=server --ignore-daemonsets --pod-selector=app=tk-e2e-web; echo GUARD-RC=\$?"
E2E_WAIT=30 expect_grid "GUARD-RC=0" || return
expect_grid "drained (server dry run)" || return
lacks "$AP" || fail "drain --dry-run=server asked for approval"
eq "dry-run drain left the node schedulable" "$(kc get node "$node" -o jsonpath='{.spec.unschedulable}')" ""
sh_line clear

# kubectl edit: approve, then deny.
guarded "$K edit configmap/tk-e2e-cm -n $MNS" || return
contains "edit diff" "$(atext)" "LEVEL: edited"
xkey enter
approved 0 || return
eq "approved edit" "$(jp $MNS cm/tk-e2e-cm '{.data.LEVEL}')" edited

kc -n "$MNS" patch cm tk-e2e-cm --type=merge -p '{"data":{"LEVEL":"info"}}' >/dev/null
guarded "$K edit configmap/tk-e2e-cm -n $MNS" || return
xkey escape
approve_closed || return
expect_grid "your edit is saved at" || return
expect_grid "Edit cancelled, no changes made." || return
# kubectl itself exits 0 ("Edit cancelled"); the guard reports the denial.
expect_grid "GUARD-RC=1" || return
saved=$(find "$gdir/tmp" -name 'kubectl-edit-denied-*' | head -1)
[ -n "$saved" ] || fail "no kubectl-edit-denied-* copy in $gdir/tmp"
[ -n "$saved" ] && contains "denied copy holds the edit" "$(cat "$saved")" "LEVEL: edited"
eq "denied edit" "$(jp $MNS cm/tk-e2e-cm '{.data.LEVEL}')" info
guard_tab_close
eq "back in the first tab" "$(focused_id)" "$home_tab"
