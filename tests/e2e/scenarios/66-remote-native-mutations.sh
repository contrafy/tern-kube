# Native mutations on the remote host: the lens Delete chip (typed confirm)
# runs kubectl there and the remote audit log records it; the Apply palette
# with a remote pane focused resolves a relative path against that pane's
# remote cwd (never this machine's HOME) and applies the remote file. Objects
# live in their own namespace tern-test-remote, deleted at the end.
RNS=tern-test-remote
INS='[data-role="tern-kube.inspector"] .sf-act'
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $RNS}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: tk-e2e-rcm, namespace: $RNS}
data: {LEVEL: info}
EOF
trap 'rsh "rm -rf \"\$HOME/tk-e2e-apply\""; kc delete namespace "$RNS" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1' EXIT

remote_switch || return
lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-rcm -n $RNS"
native
click_text tk-e2e-rcm '.tk-grid .tk-c' || return
click_text Delete "$INS" || return
approve_open || return
a_ready || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "delete preview" "$(atext)" "1 object(s) to be deleted"
ctl type tk-e2e-rcm >/dev/null
xkey enter
a_done || return
E2E_WAIT=20 wait_for "tk-e2e-rcm to be gone" absent "$RNS" configmap/tk-e2e-rcm
contains "remote audit records the native delete" \
	"$(rsh 'tail -n 3 "$HOME/.local/state/tern/plugin-data/tern-kube/audit.log"')" '"mode":"native","op":"delete"'
xkey escape
approve_closed || return

rsh <<EOF
mkdir -p "\$HOME/tk-e2e-apply/manifests"
cat >"\$HOME/tk-e2e-apply/manifests/applied.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: tk-e2e-rapplied
  namespace: $RNS
data:
  LEVEL: debug
YAML
EOF
sh_line 'cd ~/tk-e2e-apply; clear'
ctl plugins run plugin.tern-kube.apply >/dev/null
approve_open || return
a_input || return
contains "prompt names the remote cwd" "$(atext)" "relative to /home/tk/tk-e2e-apply"
ctl type manifests >/dev/null
xkey enter
a_ready || return
contains "directory resolved on the remote host" "$(atext)" "apply -f /home/tk/tk-e2e-apply/manifests"
contains "create preview" "$(atext)" "CREATE ConfigMap $RNS/tk-e2e-rapplied"
xkey t
xkey enter
a_done || return
eq "applied the remote file" "$(jp "$RNS" configmap/tk-e2e-rapplied '{.data.LEVEL}')" debug
xkey escape
approve_closed
sh_line 'cd ~; clear'
