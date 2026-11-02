# Remote Explore: "Explore live" on a remote lens row goes through this
# window's route.link (the window half) and the block opens on the clicked
# pane's host, reading the remote kubeconfig; palette "Tern Kube: Explore"
# with a remote pane focused opens there as well.
remote_switch || return
lens "kubectl --context kind-tern-kube-dev get pods -n tern-test-apps"
native
click_text crashloop '.tk-grid .tk-c' || return
click_text 'Explore live' || return
explore_open || return
xwait 'Object pod/crashloop' || return
contains "Explore reads the remote kubeconfig" "$(xtext)" "/home/tk/.kube/config"
grep -q 'tern-kube route.link.*tern-kube://explore?' "$(window_log)" || fail "the link did not go through the window half"
explore_close

ctl plugins run plugin.tern-kube.explore >/dev/null
explore_open || return
xwait /home/tk/.kube/config || return
eq "palette Explore stays on the remote host" "$(ctl state | jq -r '.hosts.current')" "$TK_REMOTE_NAME"
explore_close
