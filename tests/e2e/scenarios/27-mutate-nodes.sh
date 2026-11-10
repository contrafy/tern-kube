# Node keys in Explore on the kind node: C cordons and u uncordons
# (spec.unschedulable verified live). D drains with --pod-selector limited
# to tk-e2e-web: with a PodDisruptionBudget allowing no disruption the
# preview lists the pod as blocked and cancel changes nothing; without it the
# typed confirm evicts the pod, the node stays cordoned and u uncordons it.
# The EXIT trap uncordons the node whatever happens, then deletes the PDB and
# the tk-e2e-* objects.
node=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
nodes_cleanup() {
	kc uncordon "$node" >/dev/null 2>&1
	kc -n "$MNS" delete pdb tk-e2e-pdb --ignore-not-found >/dev/null 2>&1
	e2e_objects_delete
}
trap nodes_cleanup EXIT
e2e_objects
kc -n "$MNS" create pdb tk-e2e-pdb --selector=app=tk-e2e-web --min-available=1 >/dev/null
unschedulable() {
	kc get node "$node" -o jsonpath='{.spec.unschedulable}'
}
eq "node schedulable before" "$(unschedulable)" ""

lens "kubectl --context kind-tern-kube-dev get nodes"
native
click_text "$node" '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait "Object node/$node"

xkey C
approve_open || return
a_ready || return
contains "cordon diff" "$(atext)" "unschedulable: true"
contains "control-plane reason" "$(atext)" "control-plane"
# kind has one node: cordoning it leaves nothing schedulable (MUT-F13).
contains "typed tier" "$(atext)" "Typed confirm"
contains "last node reason" "$(atext)" "Cordoning $node leaves no schedulable node"
ctl type "$node" >/dev/null
xkey enter
a_done || return
eq "cordoned" "$(unschedulable)" true
xkey escape
approve_closed || return

xkey u
approve_open || return
a_ready || return
contains "uncordon op" "$(atext)" "uncordon"
xkey enter
a_done || return
eq "uncordoned" "$(unschedulable)" ""
xkey escape
approve_closed || return

drain_input() {
	xkey cmd+a
	ctl type '"--ignore-daemonsets --timeout=2m --pod-selector=app=tk-e2e-web"' >/dev/null
	xkey enter
}

# D with the PDB: the eviction probe reports the pod as blocked.
xkey D
approve_open || return
a_input || return
contains "drain prompt" "$(atext)" "Drain node $node with:"
eq "drain prefill" "$(ctl tree "$AP .sf-input" | jq -r '.nodes[0].text')" ">--ignore-daemonsets --timeout=4m"
drain_input
E2E_WAIT=40 a_ready || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "eviction listed" "$(atext)" "tk-e2e-web-"
contains "pdb reason" "$(atext)" "PodDisruptionBudget blocks eviction"
contains "nowhere to reschedule" "$(atext)" "have nowhere to reschedule"
xkey escape
approve_closed || return
eq "cancelled drain leaves the node schedulable" "$(unschedulable)" ""

# D without the PDB, typed confirm: the pod is evicted, the node cordoned.
kc -n "$MNS" delete pdb tk-e2e-pdb >/dev/null
pod=$(kc -n "$MNS" get pod -l app=tk-e2e-web -o jsonpath='{.items[0].metadata.name}')
xkey D
approve_open || return
a_input || return
drain_input
E2E_WAIT=40 a_ready || return
excludes "no pdb reason" "$(atext)" "PodDisruptionBudget blocks eviction"
ctl type "$node" >/dev/null
xkey enter
E2E_WAIT=90 a_done || return
contains "exit status" "$(atext)" "exit 0"
eq "drain cordoned the node" "$(unschedulable)" true
absent "$MNS" "pod/$pod" || fail "pod $pod was not evicted"
xkey escape
approve_closed || return

xkey u
approve_open || return
a_ready || return
xkey enter
a_done || return
eq "uncordoned after drain" "$(unschedulable)" ""
xkey escape
approve_closed || return
explore_close
