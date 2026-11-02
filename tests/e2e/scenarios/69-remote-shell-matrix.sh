# Remote login-shell matrix. 61, 63 and 65 read the remote login shell from
# the host (TK_REMOTE_SHELL), so the matrix is a rerun per shell:
#   scripts/remote-host.sh up --shell bash   (then zsh, then fish again)
#   scripts/e2e.sh --remote --only '6[1359]-*'
# This scenario pins what that rerun relies on: the remote pane runs the
# login shell the host was built with, as a login shell, and the plugin's
# PATH probe (`$SHELL -l -i -c`) and quick-action wrapper (`$SHELL -l -c
# 'sh -c ...'`) both work in it.
ST="[data-surface='plugin.tern-kube.settings']"
login=$(rsh 'getent passwd "$(id -un)" | cut -d: -f7')
case $TK_REMOTE_SHELL in
fish | bash | zsh) ;;
*)
	fail "TK_REMOTE_SHELL is '$TK_REMOTE_SHELL' (remote-host.sh env)"
	return
	;;
esac
eq "the host's login shell is the one it was built with" "${login##*/}" "$TK_REMOTE_SHELL"

remote_switch || return
case $TK_REMOTE_SHELL in
fish) sh_line 'echo TK69 $SHELL (status is-login; and echo login-shell)' ;;
bash) sh_line 'echo TK69 $SHELL $(shopt -q login_shell && echo login-shell)' ;;
zsh) sh_line 'echo TK69 $SHELL ${${options[login]:#off}:+login-shell}' ;;
esac
expect_grid "TK69 $login login-shell" || return

ctl plugins run plugin.tern-kube.settings >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
ctl key tab >/dev/null
stext() {
	alltext "$ST *" | tr '\n' ' ' | tr -s ' '
}
s_has() {
	case $(stext) in *"$1"*) true ;; *) false ;; esac
}
E2E_WAIT=20 wait_for "PATH read from $login" s_has "read from $login" || return
ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST" || return

lens "kubectl --context kind-tern-kube-dev get pods -n tern-test-apps"
native
before=$(pane_count)
click_text 'db-0' '.tk-grid .tk-c' || return
click_text Logs '[data-role="tern-kube.inspector"] .sf-act' || return
E2E_WAIT=15 quick_pane "tern-kube logs pod tern-test-apps/db-0" || return
remote_wrapper() {
	rsh "pgrep -f -- '^$login -l -c sh -c ' >/dev/null"
}
E2E_WAIT=15 wait_for "the split's $TK_REMOTE_SHELL login wrapper on the remote host" remote_wrapper
ctl close >/dev/null
panes_back() {
	[ "$(pane_count)" = "$before" ]
}
E2E_WAIT=10 wait_for "the logs split to close" panes_back
