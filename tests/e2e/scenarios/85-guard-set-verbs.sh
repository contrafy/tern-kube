# v1.2 guard (a): `kubectl set image|env|resources` in a real pane (new tab,
# zsh snippet). `set image` approve (diff shows the image line, simple
# tier); `set image -l` over two deployments where one is already on the
# image (one changed, the other listed unchanged, typed); `set env` with a
# sensitive key (advisory reason, masked command); `set resources`. The
# EXIT trap closes the tab and deletes the tk-e2e-* objects.
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
gdir=$E2E_SB/guard-set
set_cleanup() {
	guard_tab_close
	kc -n "$MNS" delete deploy/tk-e2e-web2 --ignore-not-found --wait=false >/dev/null 2>&1
	rm -rf "$gdir"
	e2e_objects_delete
}
trap set_cleanup EXIT
e2e_objects
kc -n "$MNS" create deployment tk-e2e-web2 --image=registry.k8s.io/pause:3.9 >/dev/null &&
	kc -n "$MNS" label deploy tk-e2e-web2 tk-e2e=set >/dev/null &&
	kc -n "$MNS" label deploy tk-e2e-web tk-e2e=set >/dev/null || fail "cannot label the set targets"
mkdir -p "$gdir"
guard_tab "$gdir"

guarded "$K set image deploy/tk-e2e-web web=registry.k8s.io/pause:3.9 -n $MNS" || return
contains "guard mode" "$(atext)" "Shell guard approval"
contains "image diff" "$(atext)" "image: registry.k8s.io/pause:3.9"
excludes "simple tier" "$(atext)" "Typed confirm"
xkey enter
finished 0 || return
eq "set image ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.template.spec.containers[0].image}')" registry.k8s.io/pause:3.9

# tk-e2e-web2 moves to 3.10 first, so only tk-e2e-web (now 3.9) changes;
# their containers have different names, hence `*`.
kc -n "$MNS" set image deploy/tk-e2e-web2 '*=registry.k8s.io/pause:3.10' >/dev/null
guarded "$K set image deploy -l tk-e2e=set '*=registry.k8s.io/pause:3.10' -n $MNS" || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "the changed one" "$(atext)" "tk-e2e-web"
contains "unchanged note" "$(atext)" "unchanged"
xkey escape
finished 1 || return
eq "denied: image kept" "$(jp $MNS deploy/tk-e2e-web '{.spec.template.spec.containers[0].image}')" registry.k8s.io/pause:3.9

guarded "$K set env deploy/tk-e2e-web DB_PASSWORD=tk-e2e-hunter2 -n $MNS" || return
contains "sensitive env reason" "$(atext)" "use --from=secret"
contains "masked command" "$(alltext "$AP [data-role='tern-kube.approve-header'] *")" "DB_PASSWORD=<redacted>"
# The argv is masked; the object diff shows the pod spec it would store,
# which is what the reason warns about.
excludes "literal not in the header" "$(alltext "$AP [data-role='tern-kube.approve-header'] *")" "tk-e2e-hunter2"
excludes "literal not in the steps" "$(alltext "$AP [data-role='tern-kube.approve-steps'] *")" "tk-e2e-hunter2"
xkey escape
finished 1 || return
eq "denied: no env" "$(jp $MNS deploy/tk-e2e-web '{.spec.template.spec.containers[0].env}')" ""

# The fixture already limits memory to 32Mi (e2e_manifest).
guarded "$K set resources deploy/tk-e2e-web --limits=memory=48Mi -n $MNS" || return
contains "resources diff" "$(atext)" "memory: 48Mi"
xkey enter
finished 0 || return
eq "set resources ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.template.spec.containers[0].resources.limits.memory}')" 48Mi
guard_tab_close
eq "back in the first tab" "$(focused_id)" "$home_tab"
