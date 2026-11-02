# Explore rollout keys on a Deployment with two revisions (pause:3.10, then
# pause:3.9): U previews the previous revision's pod template as a diff and
# is typed (the image goes back to 3.10 after the exact name), p pauses and
# P resumes (simple tier, spec.paused verified live each time).
# tk-e2e-* objects are deleted at the end.
trap e2e_objects_delete EXIT
e2e_objects
kc -n "$MNS" set image deploy/tk-e2e-web web=registry.k8s.io/pause:3.9 >/dev/null
kc -n "$MNS" rollout status deploy/tk-e2e-web --timeout=60s >/dev/null || fail "second revision not ready"
image() {
	jp $MNS deploy/tk-e2e-web '{.spec.template.spec.containers[0].image}'
}
eq "second revision" "$(image)" registry.k8s.io/pause:3.9

lens "kubectl --context kind-tern-kube-dev get deploy tk-e2e-web -n $MNS"
native
click_text tk-e2e-web '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/tk-e2e-web'

# U: undo to revision 1; enter without the token and cancel change nothing.
xkey U
approve_open || return
a_ready || return
contains "undo card" "$(atext)" "revision 2 → 1"
contains "template diff" "$(atext)" "image: registry.k8s.io/pause:3.10"
contains "typed tier" "$(atext)" "Typed confirm"
xkey enter
sleep 1
eq "enter without the token keeps the image" "$(image)" registry.k8s.io/pause:3.9
xkey escape
approve_closed || return
eq "cancelled undo keeps the image" "$(image)" registry.k8s.io/pause:3.9

xkey U
approve_open || return
a_ready || return
ctl type tk-e2e-web >/dev/null
xkey enter
a_done || return
contains "exit status" "$(atext)" "exit 0"
eq "undo restored the image" "$(image)" registry.k8s.io/pause:3.10
xkey escape
approve_closed || return

# p: pause; P: resume.
xkey p
approve_open || return
a_ready || return
contains "pause diff" "$(atext)" "paused: true"
xkey enter
a_done || return
eq "paused" "$(jp $MNS deploy/tk-e2e-web '{.spec.paused}')" true
xkey escape
approve_closed || return

xkey P
approve_open || return
a_ready || return
contains "resume op" "$(atext)" "rollout resume"
xkey enter
a_done || return
eq "resumed" "$(jp $MNS deploy/tk-e2e-web '{.spec.paused}')" ""
xkey escape
approve_closed || return
explore_close
