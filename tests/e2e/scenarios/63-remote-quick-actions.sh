# Remote quick actions: a chip on a remote lens row opens a split that runs
# on the remote host, in its login shell. The program is a bare `kubectl`
# (the remote PATH resolves it) although this window's environment has
# TKUBE_KUBECTL; the split says the kubeconfig comes from the remote login
# environment; port-forward listens on the remote loopback and says how to
# reach it from here; the remote host's quick_actions.placement (written
# into the chip's link by the remote half) wins over this machine's.
# Toolbox: tern-test-mutate/tk-qa-shell (busybox httpd on 8080 + ticker).
qa_ns=tern-test-mutate
rh() {
	sh "$E2E_REPO/scripts/remote-host.sh" "$@"
}
# The remote half caches its config at plugin load; relinking reloads it.
remote_config() { # JSON, or nothing to go back to the stub
	if [ $# -gt 0 ]; then
		printf 'mkdir -p "$HOME/.config/tern-kube"\ncat >"$HOME/.config/tern-kube/config.json" <<'"'"'EOF'"'"'\n%s\nEOF\n' "$1" | rsh
	else
		rsh 'rm -f "$HOME/.config/tern-kube/config.json"'
	fi
	rh install "$E2E_SB/pkg" >/dev/null
	sleep 1.5
}
trap 'remote_config; rsh "pkill -f \"kubectl port-forward\"" >/dev/null 2>&1' EXIT
remote_procs() { # PATTERN: matching remote command lines
	rsh "pgrep -af '$1' || true"
}
remote_has() {
	[ -n "$(remote_procs "$1")" ]
}
panes_back() {
	[ "$(pane_count)" = "$before" ]
}

remote_switch || return
lens "kubectl --context kind-tern-kube-dev get pods -n $qa_ns -l app=tk-qa-shell"
native
before=$(pane_count)
click_text 'tk-qa-shell-*' '.tk-grid .tk-c' || return
click_text Shell '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube shell $qa_ns/tk-qa-shell-" || return
eq "shell split beside the lens" "$(pane_count)" $((before + 1))
expect_grid "tern-kube: $TK_REMOTE_NAME: kubeconfig from the login environment"
E2E_WAIT=15 wait_for "kubectl exec on the remote host" remote_has 'kubectl exec' || return
# The login shell's command line holds the split's whole script; kubectl's
# own is the line that starts with it.
exec_lines=$(remote_procs 'kubectl exec')
excludes "remote split runs no absolute kubectl" "$exec_lines" "/kubectl exec"
printf '%s\n' "$exec_lines" | grep -q "^[0-9]* kubectl exec -it --context kind-tern-kube-dev -n $qa_ns tk-qa-shell-" ||
	fail "remote split does not run a bare kubectl: $exec_lines"
sleep 1.5
type_line 'echo tk-e2e-$(echo ok)'
E2E_WAIT=15 expect_grid "tk-e2e-ok" || return
type_line exit
E2E_WAIT=10 wait_for "the shell split to close" panes_back || return

click_text Logs '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube logs pod $qa_ns/tk-qa-shell-" || return
E2E_WAIT=20 expect_grid "ticker: tick" || return
E2E_WAIT=15 wait_for "kubectl logs on the remote host" remote_has 'kubectl logs -f --tail=200' || return
ctl close >/dev/null
E2E_WAIT=10 wait_for "the logs split to close" panes_back || return

lens "kubectl --context kind-tern-kube-dev get svc tk-qa-shell -n $qa_ns"
native
click_text tk-qa-shell '.tk-grid .tk-c' || return
click_text Port-forward '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube port-forward " || return
E2E_WAIT=15 wait_for "kubectl port-forward on the remote host" remote_has 'kubectl port-forward' || return
pf=$(remote_procs 'kubectl port-forward')
lport=$(printf '%s\n' "$pf" | sed -n 's/^[0-9]* kubectl port-forward .* \([0-9][0-9]*\):80$/\1/p' | head -1)
[ -n "$lport" ] || fail "no local port in: $pf"
expect_grid "tern-kube: forwarding localhost:$lport -> 80 on $TK_REMOTE_NAME"
# The split is half the window wide: the hint wraps after the port.
expect_grid "tern-kube: from this machine: ssh -N -L $lport:localhost:$lport -p ${TK_REMOTE_NAME##*:}"
E2E_WAIT=15 expect_grid "Forwarding from 127.0.0.1:$lport" || return
contains "forward serves on the remote loopback" \
	"$(rsh "curl -s --max-time 5 http://127.0.0.1:$lport/index.html")" "tk-qa-ok"
ctl close >/dev/null
E2E_WAIT=10 wait_for "the port-forward split to close" panes_back || return

remote_config '{"schema_version": 1, "quick_actions": {"placement": "tab"}}'
lens "kubectl --context kind-tern-kube-dev get pods -n $qa_ns -l app=tk-qa-shell"
native
first=$(ctl state | jq -r '.focused.id')
click_text 'tk-qa-shell-*' '.tk-grid .tk-c' || return
click_text Logs '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube logs pod $qa_ns/tk-qa-shell-" || return
eq "remote placement tab: a new tab, no split" "$(pane_count)" 1
[ "$(ctl state | jq -r '.focused.id')" != "$first" ] || fail "the logs action did not open a new tab"
ctl close >/dev/null
sleep 1
