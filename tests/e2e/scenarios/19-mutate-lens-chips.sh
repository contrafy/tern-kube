# Live mutations from lens inspector chips (two clicks): Scale on a
# Deployment row from a command without --context (inferred context: the
# block requires target confirmation; cancel never scales), Restart, and
# typed Delete on a ConfigMap row. Objects are tk-e2e-* in tern-test-mutate,
# deleted at the end.
trap e2e_objects_delete EXIT
e2e_objects
INS='[data-role="tern-kube.inspector"] .sf-act'

lens "kubectl get deploy tk-e2e-web -n $MNS"
native
click_text tk-e2e-web '.tk-grid .tk-c'
eq "mutation chips" "$(texts '[data-role="tern-kube.mutate"]')" '["Delete","Restart","Scale"]'

click_text Scale "$INS"
approve_open || return
a_input || return
ctl type 3 >/dev/null
xkey enter
a_ready || return
contains "inferred context warned" "$(atext)" "inferred from current-context"
contains "replica preview" "$(atext)" "replicas 1 → 3"
xkey enter
sleep 1
eq "enter without target confirmation does not scale" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 1
xkey escape
approve_closed || return
eq "cancelled scale left replicas" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 1

click_text Restart "$INS"
approve_open || return
a_ready || return
xkey t
xkey enter
a_done || return
contains "restart executed" "$(jp $MNS deploy/tk-e2e-web '{.spec.template.metadata.annotations}')" "kubectl.kubernetes.io/restartedAt"
xkey escape
approve_closed || return

lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-cm -n $MNS"
native
click_text tk-e2e-cm '.tk-grid .tk-c'
eq "configmaps offer only Delete" "$(texts '[data-role="tern-kube.mutate"]')" '["Delete"]'
click_text Delete "$INS"
approve_open || return
a_ready || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "delete preview" "$(atext)" "1 object(s) to be deleted"
ctl type tk-e2e-cm >/dev/null
xkey enter
a_done || return
E2E_WAIT=20 wait_for "tk-e2e-cm to be gone" absent $MNS configmap/tk-e2e-cm
xkey escape
approve_closed
