# Remote lens: in a pane on the remote host (login shell TK_REMOTE_SHELL,
# fish by default) `kubectl get pods` is claimed by the remote daemon's
# tern-kube and rendered natively in this window, styles and inspector chips
# included. The remote's own kubectl and ~/.kube/config reach kind over the
# docker network; nothing on this machine runs the command.
remote_switch || return
sh_line 'echo TK61 $SHELL'
expect_grid "TK61 $(rsh 'getent passwd "$(id -un)" | cut -d: -f7')" || return

lens "kubectl --context kind-tern-kube-dev get pods -n tern-test-apps"
native
eq "grid rendered" "$(count '.tk-grid')" 1
contains "remote rows" "$(texts '.tk-grid .tk-c')" '"crashloop"'
click_text crashloop '.tk-grid .tk-c' || return
chips=$(texts '[data-role="tern-kube.inspector"] .sf-act')
for chip in '"Explore live"' '"Shell"' '"Logs"' '"Port-forward"' '"Debug"' '"Delete"'; do
	contains "inspector chip $chip" "$chips" "$chip"
done
eq "still on the remote host" "$(ctl state | jq -r '.hosts.current')" "$TK_REMOTE_NAME"
