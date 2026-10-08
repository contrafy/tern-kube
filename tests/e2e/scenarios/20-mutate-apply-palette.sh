# Palette "Kube Lens: Apply file or directory": the block asks for a path
# relative to the focused pane's cwd, previews (server dry run + diff), and
# applies only after confirmation; cancel never applies. A Secret's values
# (masked by kubectl, repeated in last-applied) never show in the preview.
# Objects: tern-test-mutate kl-e2e-applied / kl-e2e-secret, deleted at the end.
work=$E2E_SB/apply
e2e_apply_cleanup() {
	kc -n "$MNS" delete configmap/kl-e2e-applied secret/kl-e2e-secret --ignore-not-found --wait=true >/dev/null 2>&1
	rm -rf "$work"
}
trap e2e_apply_cleanup EXIT
e2e_apply_cleanup
mkdir -p "$work/manifests"
cat >"$work/manifests/applied.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kl-e2e-applied
  namespace: $MNS
data:
  LEVEL: debug
EOF
sh_line "cd '$work' && clear"

apply_palette() {
	ctl plugins run plugin.kube-lens.apply >/dev/null
	approve_open && a_input
}

apply_palette || return
contains "prompt names the pane cwd" "$(atext)" "relative to $work"
ctl type manifests >/dev/null
xkey enter
a_ready || return
contains "directory resolved against the cwd" "$(atext)" "apply -f $work/manifests"
contains "create preview" "$(atext)" "CREATE ConfigMap $MNS/kl-e2e-applied"
xkey escape
approve_closed || return
absent $MNS configmap/kl-e2e-applied || fail "cancelled apply created kl-e2e-applied"

apply_palette || return
ctl type manifests/applied.yaml >/dev/null
xkey enter
a_ready || return
xkey t
xkey enter
a_done || return
eq "applied" "$(jp $MNS configmap/kl-e2e-applied '{.data.LEVEL}')" debug
xkey escape
approve_closed || return

# Secret: live value kl-e2e-old-1 (applied with last-applied), file changes a label.
secret() { # VALUE PART_OF
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: kl-e2e-secret\n  namespace: %s\n  labels:\n    app.kubernetes.io/part-of: %s\ntype: Opaque\nstringData:\n  password: %s\n' \
		"$MNS" "$2" "$1"
}
secret kl-e2e-old-1 kl-e2e-old | kc apply -f - >/dev/null
secret kl-e2e-new-2 kl-e2e-new >"$work/secret.yaml"
apply_palette || return
ctl type secret.yaml >/dev/null
xkey enter
a_ready || return
contains "secret diff shown" "$(atext)" "MODIFY Secret $MNS/kl-e2e-secret"
contains "last-applied redacted" "$(atext)" "last-applied-configuration redacted by kube-lens"
excludes "old value hidden" "$(atext)" "kl-e2e-old-1"
excludes "new value hidden" "$(atext)" "kl-e2e-new-2"
xkey escape
approve_closed
sh_line "cd '$E2E_REPO' && clear"
