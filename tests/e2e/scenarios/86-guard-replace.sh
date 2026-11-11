# v1.2 guard (a): `kubectl replace` in a real pane. A plain replace of the
# tk-e2e-web manifest with replicas 2 (diff, approve); `replace --force`
# with a changed (immutable) selector: typed tier, "field is immutable"
# finding, approve, the deployment gets a new uid. The EXIT trap closes the
# tab and deletes the tk-e2e-* objects.
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
gdir=$E2E_SB/guard-replace
replace_cleanup() {
	guard_tab_close
	rm -rf "$gdir"
	e2e_objects_delete
}
trap replace_cleanup EXIT
e2e_objects
mkdir -p "$gdir"
kc -n "$MNS" get deploy tk-e2e-web -o yaml |
	sed -e '/^  resourceVersion:/d' -e '/^  uid:/d' -e '/^status:/,$d' -e 's/^  replicas: 1$/  replicas: 2/' >"$gdir/web.yaml"
sed 's/app: tk-e2e-web$/app: tk-e2e-web2/' "$gdir/web.yaml" >"$gdir/web-sel.yaml"
guard_tab "$gdir"

guarded "$K replace -f web.yaml" || return
contains "replace reason" "$(atext)" "fields not in the file are removed"
contains "replicas diff" "$(atext)" "replicas: 2"
xkey enter
finished 0 || return
eq "replace ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2

uid=$(jp "$MNS" deploy/tk-e2e-web '{.metadata.uid}')
guarded "$K replace --force -f web-sel.yaml" || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "force reason" "$(atext)" "new uid"
contains "immutable finding" "$(atext)" "field is immutable"
ctl type tk-e2e-web >/dev/null
xkey enter
E2E_WAIT=60 finished 0 || return
new=$(jp "$MNS" deploy/tk-e2e-web '{.metadata.uid}')
[ -n "$new" ] && [ "$new" != "$uid" ] || fail "uid $uid -> $new"
eq "new selector" "$(jp $MNS deploy/tk-e2e-web '{.spec.selector.matchLabels.app}')" tk-e2e-web2
guard_tab_close
eq "back in the first tab" "$(focused_id)" "$home_tab"
