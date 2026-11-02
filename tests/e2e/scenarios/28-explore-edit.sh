# Explore e: `kubectl edit` in a new split through the plugin's
# shell/tern-kube-guard; the sandbox KUBE_EDITOR (scripts/e2e.sh) runs
# <sandbox>/edit-script, which changes the ConfigMap's LEVEL. After the save
# the approve block shows the edited file and the object diff; approve ->
# kubectl applies it; a second edit denied -> the object is unchanged and
# the edit is kept in $TMPDIR/kubectl-edit-denied-*. tk-e2e-* objects and the
# script are deleted at the end.
edit_cleanup() {
	rm -f "$E2E_SB/edit-script" "$E2E_SB/edit-tmpdir"
	e2e_objects_delete
}
trap edit_cleanup EXIT
e2e_objects
cat >"$E2E_SB/edit-script" <<EOF
printf '%s' "\${TMPDIR:-/tmp}" >'$E2E_SB/edit-tmpdir'
level=\$(cat '$E2E_SB/edit-level')
sed "s/^  LEVEL: .*/  LEVEL: \$level/" "\$1" >"\$1.new" && cat "\$1.new" >"\$1" && rm -f "\$1.new"
EOF
level() {
	jp $MNS cm/tk-e2e-cm '{.data.LEVEL}'
}
level_is() {
	[ "$(level)" = "$1" ]
}
panes_back() {
	[ "$(pane_count)" = "$before" ]
}

lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-cm -n $MNS"
native
click_text tk-e2e-cm '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object configmap/tk-e2e-cm'
contains "edit key listed" "$(xtext)" "Edit (e)"
before=$(pane_count)
explore_pane=$(ctl state | jq -r '.focused.id')

# Approve: the diff shows the edit, kubectl applies it, the split closes.
echo debug >"$E2E_SB/edit-level"
xkey e
approve_open || return
a_ready || return
# Four panes: zoom the approve block so the whole preview is visible.
ctl zoom >/dev/null
sleep 0.5
contains "guard mode" "$(atext)" "Shell guard approval"
contains "edit operation" "$(atext)" "kubectl edit"
contains "edited file card" "$(atext)" "Edited file"
contains "object diff" "$(atext)" "MODIFY ConfigMap tern-test-mutate/tk-e2e-cm"
contains "new value in the diff" "$(atext)" "LEVEL: debug"
xkey enter
approve_closed || return
E2E_WAIT=20 wait_for "the edit split to close" panes_back || return
E2E_WAIT=10 wait_for "the edited value" level_is debug
eq "approved edit applied" "$(level)" debug

# Deny: unchanged object, the edit saved in a kubectl-edit-denied-* file.
echo trace >"$E2E_SB/edit-level"
[ "$(ctl state | jq -r '.focused.id')" = "$explore_pane" ] || ctl focus right >/dev/null
sleep 0.3
eq "explore pane focused" "$(ctl state | jq -r '.focused.id')" "$explore_pane"
xkey e
approve_open || return
a_ready || return
ctl zoom >/dev/null
sleep 0.5
contains "denied edit diff" "$(atext)" "LEVEL: trace"
denied_dir=$(cat "$E2E_SB/edit-tmpdir")
xkey escape
approve_closed || return
E2E_WAIT=20 wait_for "the edit split to close" panes_back || return
eq "denied edit left the value" "$(level)" debug
saved=$(find "$denied_dir" -maxdepth 1 -name 'kubectl-edit-denied-*' -newer "$E2E_SB/edit-level" 2>/dev/null | head -1)
[ -n "$saved" ] || fail "no kubectl-edit-denied-* copy in $denied_dir"
[ -n "$saved" ] && contains "denied copy holds the edit" "$(cat "$saved")" "LEVEL: trace"
[ -n "$saved" ] && rm -f "$saved"
explore_close
