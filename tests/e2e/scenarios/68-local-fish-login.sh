# fish as the login shell on this machine (`dev-tern.sh start --shell
# fish`; sandbox config.fish, never the user's): panes are fish login
# shells, Settings reads PATH from fish, the guard's fish snippet asks for
# approval and records the pane's KUBECONFIG, and a quick action from that
# pane's lens runs through `fish -l -c` with the exact kubectl argv, the
# recorded kubeconfig pinned. The zsh session comes back at the end. Skipped
# when fish is not installed.
fish_bin=$(command -v fish) || {
	note "skipped: fish is not installed"
	return 0
}
ST="[data-surface='plugin.tern-kube.settings']"
focused_id() {
	ctl state | jq -r '.focused.id'
}
not_focused() {
	[ "$(focused_id)" != "$1" ]
}
stext() {
	alltext "$ST *" | tr '\n' ' ' | tr -s ' '
}
s_has() {
	case $(stext) in *"$1"*) true ;; *) false ;; esac
}
trap 'e2e_objects_delete; restart_session >/dev/null' EXIT
e2e_objects
restart_session --shell fish || return

sh_line 'echo TK68 $SHELL (status is-login; and echo login-shell)'
expect_grid "TK68 $fish_bin login-shell" || return

ctl plugins run plugin.tern-kube.settings >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
ctl key tab >/dev/null
E2E_WAIT=20 wait_for "PATH read from fish" s_has "read from $fish_bin" || return
ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST" || return

# A tab opened after the plugin loaded: its spawn hook set TKUBE_SPOOL.
home_tab=$(focused_id)
ctl tab new >/dev/null
E2E_WAIT=10 wait_for "a new tab" not_focused "$home_tab" || return
at_prompt() {
	ctl state | jq -e '.focused.prompt' >/dev/null
}
E2E_WAIT=10 wait_for "the new tab's prompt" at_prompt || return
sh_line "source '$E2E_SB/pkg/shell/tern-kube.fish'; clear"
sh_line tern-kube-guard-status
expect_grid "kubectl function: tern-kube guard (fish)" || return
expect_grid "guarded verbs ask for approval" || return
sh_line clear

type_line "kubectl scale deploy/tk-e2e-web --replicas=2 -n $MNS; echo GUARD-RC=\$status"
approve_open && a_ready || return
contains "guard mode" "$(atext)" "Shell guard approval"
xkey t
xkey enter
approve_closed || return
expect_grid "GUARD-RC=0" || return
eq "approved scale ran" "$(jp "$MNS" deploy/tk-e2e-web '{.spec.replicas}')" 2
sh_line clear

# Same file as the window's KUBECONFIG, spelled differently: the pin shows
# the fish prompt hook recorded this pane's value. Headless, the session's
# host is the in-process `sandbox` host, which the window treats as remote:
# quick actions then use the login environment's kubeconfig (documented for
# remote panes), so the hook's record is checked in the spool instead.
pinned="$E2E_REPO/.sandbox/./kubeconfig"
sh_line "set -gx KUBECONFIG '$pinned'"
sh_line "echo \$TERN_PANE >'$E2E_SB/fish-pane'"
fish_pane=$(cat "$E2E_SB/fish-pane")
sh_line clear
lens "kubectl --context kind-tern-kube-dev get pods -n $MNS -l app=tk-e2e-web"
native
click_text 'tk-e2e-web-*' '.tk-grid .tk-c' || return
click_text Logs '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube logs pod $MNS/tk-e2e-web-" || return
if host_current sandbox; then
	eq "fish pane env record" "$(cat "$E2E_SB/cfg/plugin-data/tern-kube/spool/pane-$fish_pane.env")" "kubeconfig=$pinned"
	expect_grid "tern-kube: sandbox: kubeconfig from the login environment" || return
	E2E_WAIT=10 wait_for "the logs process" \
		pgrep -f -- "kubectl logs -f --tail=200 --context kind-tern-kube-dev -n $MNS tk-e2e-web-"
else
	E2E_WAIT=10 wait_for "the logs process with the exact argv" \
		pgrep -f -- "kubectl logs -f --tail=200 --kubeconfig $pinned --context kind-tern-kube-dev -n $MNS tk-e2e-web-"
fi
E2E_WAIT=10 wait_for "the split's fish login shell" pgrep -f -- "^$fish_bin -l -c sh -c "
