# Live: the rollout history lens. tk-e2e-web (tern-test-mutate) gets a second
# revision with a change-cause; the table marks the highest revision current,
# "Show revision 1" types `rollout history --revision=1` into a new split,
# which the lens renders as the revision view (this run also records whether
# the lens sees raw tabs or the expanded form: both parse the same).
# "Roll back to 1" opens the approve block (revision 2 -> 1); esc cancels and
# the image stays. `--revision=2` typed directly and `deploy/nope` (error
# header) close it.
trap e2e_objects_delete EXIT
e2e_objects
INS='[data-role="tern-kube.inspector"] .sf-act'
kc -n "$MNS" annotate --overwrite deploy/tk-e2e-web 'kubernetes.io/change-cause=e2e: pause 3.10' >/dev/null
kc -n "$MNS" set image deploy/tk-e2e-web '*=registry.k8s.io/pause:3.10' >/dev/null
kc -n "$MNS" rollout status deploy/tk-e2e-web --timeout=60s >/dev/null || fail "second revision not rolled out"
image=$(jp "$MNS" deploy/tk-e2e-web '{.spec.template.spec.containers[0].image}')

lens "kubectl --context kind-tern-kube-dev -n $MNS rollout history deploy/tk-e2e-web"
native
eq "history columns" "$(column_texts 1 2)" '["1","2"]'
contains "current revision noted" "$(alltext)" "current"
contains "change-cause shown" "$(alltext)" "e2e: pause 3.10"

click_text 1 '.tk-grid .tk-c'
eq "history chips on an old revision" "$(texts "$INS")" \
	'["Inspect","Show revision 1","Roll back to 1","Explore","Copy command","Close"]'
before=$(pane_count)
click_text "Show revision 1" "$INS"
E2E_WAIT=10 wait_for "the revision split" eval '[ "$(pane_count)" -gt "$before" ]'
E2E_WAIT=15 wait_for "revision view in the split" has '[data-role="tern-kube.revision"]'
contains "revision view names the revision" "$(alltext)" "revision 1"
contains "pod template rendered" "$(alltext)" "registry.k8s.io/pause:3.9"
reset_pane

lens "kubectl --context kind-tern-kube-dev -n $MNS rollout history deploy/tk-e2e-web"
native
click_text 1 '.tk-grid .tk-c'
click_text "Roll back to 1" "$INS"
approve_open || return
a_ready || return
contains "undo preview targets revision 1" "$(atext)" "1"
xkey escape
approve_closed || return
eq "cancelled roll back left the image" "$(jp "$MNS" deploy/tk-e2e-web '{.spec.template.spec.containers[0].image}')" "$image"

lens "kubectl --context kind-tern-kube-dev -n $MNS rollout history deploy/tk-e2e-web --revision=2"
native
has '[data-role="tern-kube.revision"]' || fail "typed --revision=2 not rendered as a revision view"
contains "revision 2 image" "$(alltext)" "registry.k8s.io/pause:3.10"

lens "kubectl --context kind-tern-kube-dev -n $MNS rollout history deploy/nope"
native
has '[data-role="tern-kube.exit"]' || fail "missing deployment shows no exit badge"
contains "not found error" "$(alltext)" "not found"
