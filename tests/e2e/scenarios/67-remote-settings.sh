# Settings on the remote host: the block opens there (a link opens on the
# focused pane's host) on the remote config file, its status page reads PATH
# from the remote login shell, and a placement edited there applies to the
# next quick action from a remote lens (the remote half writes it into the
# chip's link; this machine's config is not consulted).
ST="[data-surface='plugin.tern-kube.settings']"
RCFG=/home/tk/.config/tern-kube/config.json
qa_ns=tern-test-mutate
stext() {
	alltext "$ST *" | tr '\n' ' '
}
s_has() {
	case $(stext) in *"$1"*) true ;; *) false ;; esac
}
remote_placement() {
	rsh "cat '$RCFG'" | jq -r '.quick_actions.placement // "unset"'
}
placement_is() {
	[ "$(remote_placement)" = "$1" ]
}
trap 'rsh "rm -f $RCFG"; sh "$E2E_REPO/scripts/remote-host.sh" install "$E2E_SB/pkg" >/dev/null 2>&1' EXIT

remote_switch || return
login=$(rsh 'getent passwd "$(id -un)" | cut -d: -f7')
ctl open-url "tern-kube://settings?key=quick_actions.placement" >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
E2E_WAIT=10 wait_for "the remote config path" s_has "$RCFG" || return
xkey tab
E2E_WAIT=20 wait_for "PATH read from the remote login shell" s_has "read from $login" || return
contains "remote kubectl" "$(stext)" "/usr/local/bin/kubectl"
xkey tab

xkey enter
E2E_WAIT=10 wait_for "placement down" placement_is down || return
xkey enter
E2E_WAIT=10 wait_for "placement tab" placement_is tab || return
ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST" || return

lens "kubectl --context kind-tern-kube-dev get pods -n $qa_ns -l app=tk-qa-shell"
native
first=$(ctl state | jq -r '.focused.id')
click_text 'tk-qa-shell-*' '.tk-grid .tk-c' || return
click_text Logs '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube logs pod $qa_ns/tk-qa-shell-" || return
eq "placement edited on the remote host: a new tab" "$(pane_count)" 1
[ "$(ctl state | jq -r '.focused.id')" != "$first" ] || fail "the logs action did not open a new tab"
ctl close >/dev/null
sleep 1
