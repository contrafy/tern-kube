# Opt-in shell guard in a real pane (new tab: panes opened before the plugin
# loaded lack TKUBE_SPOOL): a guarded `kubectl scale` waits for the
# approve block; approve runs it (exit 0 propagates), deny exits 1 and Ctrl-C
# exits 130, both leaving the Deployment unchanged. The snippet's pane env
# record then pins the pane's own KUBECONFIG (set only in this shell) on a
# quick action launched from that pane's lens.
focused_id() {
	ctl state | jq -r '.focused.id'
}
not_focused() {
	[ "$(focused_id)" != "$1" ]
}
at_prompt() {
	ctl state | jq -e '.focused.prompt' >/dev/null
}
# Close the guard tab (and any split in it) until the first tab has focus.
guard_tab_close() {
	i=0
	while [ "$(focused_id)" != "$home_tab" ] && [ $i -lt 4 ]; do
		ctl close >/dev/null
		sleep 0.5
		i=$((i + 1))
	done
}
home_tab=$(focused_id)
trap 'guard_tab_close; e2e_objects_delete' EXIT
e2e_objects
ctl tab new >/dev/null
E2E_WAIT=10 wait_for "a new tab" not_focused "$home_tab"
guard_pane=$(focused_id)
E2E_WAIT=10 wait_for "the new tab's prompt" at_prompt
sh_line "cd '$E2E_REPO' && source shell/tern-kube.zsh && clear"
sh_line tern-kube-guard-status
expect_grid "guarded verbs ask for approval" || return
sh_line clear

scale() { # REPLICAS
	type_line "kubectl scale deploy/tk-e2e-web --replicas=$1 -n $MNS; echo GUARD-RC=\$?"
	approve_open && a_ready
}

scale 2 || return
contains "guard mode" "$(atext)" "Shell guard approval"
# The guard records its physical cwd (`pwd -P`): /tmp is /private/tmp on macOS.
contains "requesting pane" "$(atext)" "shell pane $guard_pane in $(cd "$E2E_REPO" && pwd -P)"
xkey t
xkey enter
approve_closed || return
expect_grid "GUARD-RC=0" || return
eq "approved scale ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2
sh_line clear

scale 3 || return
xkey escape
approve_closed || return
expect_grid "GUARD-RC=1" || return
expect_grid "denied in Tern"
eq "deny left replicas" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2
sh_line clear

scale 3 || return
# Ctrl-C in the waiting shell (left half of the window) withdraws the request.
ctl click 30 300 >/dev/null
sleep 0.3
eq "shell pane focused" "$(ctl state | jq -r '.focused.id')" "$guard_pane"
ctl key ctrl+c >/dev/null
expect_grid "GUARD-RC=130" || return
approve_closed || return
eq "Ctrl-C left replicas" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2
sh_line clear

# The lens claims the plain guarded command; after a denial it must say
# nothing was executed instead of showing an executed result.
type_line "kubectl scale deploy/tk-e2e-web --replicas=4 -n $MNS"
approve_open && a_ready || return
xkey escape
approve_closed || return
wait_for "the denied command to finish" idle
top
claimed
contains "lens banner after a denial" "$(alltext '[data-role="tern-kube.mutation-banner"] *' | tr '\n' ' ')" \
	"Stopped by the tern-kube shell guard; nothing was executed"
sh_line clear

# Pane env record: this shell's KUBECONFIG differs from the window's only in
# spelling (same file), so the pinned flag shows where it came from.
pinned="$E2E_REPO/.sandbox/./kubeconfig"
sh_line "export KUBECONFIG='$pinned'"
sh_line clear
lens "kubectl --context kind-tern-kube-dev get pods -n $MNS -l app=tk-e2e-web"
native
click_text 'tk-e2e-web-*' '.tk-grid .tk-c'
click_text Logs '[data-role="tern-kube.inspector"] .sf-act'
E2E_WAIT=15 quick_pane "tern-kube logs pod $MNS/tk-e2e-web-" || return
E2E_WAIT=10 wait_for "the logs process" pgrep -f -- "logs -f --tail=200 --kubeconfig $pinned --context kind-tern-kube-dev -n $MNS tk-e2e-web-"
guard_tab_close
eq "back in the first tab" "$(ctl state | jq -r '.focused.id')" "$home_tab"
