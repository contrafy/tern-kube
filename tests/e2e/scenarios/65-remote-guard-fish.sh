# Shell guard on the remote host, in its login shell (fish by default): the
# snippet sourced from the remote package finds Tern through TERN_EXE (no
# TERN_BIN, no tern on the remote PATH), a guarded `kubectl scale` opens the
# approve block on the remote host through this window, Approve runs it
# (exit 0, remote audit line), Deny exits 1 and changes nothing, and
# `command kubectl` bypasses the guard untouched. Objects live in their own
# namespace tern-test-remote, deleted at the end.
RNS=tern-test-remote
shell=${TK_REMOTE_SHELL:-fish}
rc_word='$?'
[ "$shell" = fish ] && rc_word='$status'
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $RNS}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: tk-e2e-rweb, namespace: $RNS, labels: {app: tk-e2e-rweb}}
spec:
  replicas: 1
  selector: {matchLabels: {app: tk-e2e-rweb}}
  template:
    metadata: {labels: {app: tk-e2e-rweb}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - {name: web, image: registry.k8s.io/pause:3.10, imagePullPolicy: IfNotPresent}
EOF
focused_id() {
	ctl state | jq -r '.focused.id'
}
not_focused() {
	[ "$(focused_id)" != "$1" ]
}
replicas() {
	jp "$RNS" deploy/tk-e2e-rweb '{.spec.replicas}'
}

remote_switch || return
home_tab=$(focused_id)
trap '[ "$(focused_id)" != "$home_tab" ] && ctl close >/dev/null 2>&1; kc delete namespace "$RNS" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1' EXIT
# A tab opened after the plugin loaded: its spawn hook set TKUBE_SPOOL.
ctl tab new >/dev/null
E2E_WAIT=10 wait_for "a new remote tab" not_focused "$home_tab" || return
E2E_WAIT=15 wait_for "the new tab's prompt" host_shown "$TK_REMOTE_NAME" || return
sh_line "sh -c 'command -v tern || echo TK65-no-\$(echo tern); echo TK65-bin=\${TERN_BIN-unset}'"
expect_grid "TK65-no-tern" || return
expect_grid "TK65-bin=unset" || return
sh_line "source ~/tern-kube-pkg/shell/tern-kube.$shell; clear"
sh_line tern-kube-guard-status
expect_grid "tern: /home/tk/.local/share/tern/build/tern (TERN_EXE)" || return
expect_grid "guarded verbs ask for approval" || return
sh_line clear

scale() { # REPLICAS
	type_line "kubectl scale deploy/tk-e2e-rweb --replicas=$1 -n $RNS; echo GUARD-RC=$rc_word"
	approve_open && a_ready
}

scale 2 || return
contains "guard mode" "$(atext)" "Shell guard approval"
contains "remote cwd" "$(atext)" "/home/tk"
xkey t
xkey enter
approve_closed || return
expect_grid "GUARD-RC=0" || return
eq "approved scale ran" "$(replicas)" 2
contains "remote audit records the guard run" \
	"$(rsh 'tail -n 3 "$HOME/.local/state/tern/plugin-data/tern-kube/audit.log"')" '"mode":"guard","op":"scale"'
sh_line clear

scale 3 || return
xkey escape
approve_closed || return
expect_grid "GUARD-RC=1" || return
eq "deny left replicas" "$(replicas)" 2
sh_line clear

sh_line "command kubectl scale deploy/tk-e2e-rweb --replicas=3 -n $RNS; echo BYPASS-RC=$rc_word"
expect_grid "BYPASS-RC=0" || return
lacks "$AP" || fail "command kubectl opened the approve block"
eq "bypass ran unguarded" "$(replicas)" 3
