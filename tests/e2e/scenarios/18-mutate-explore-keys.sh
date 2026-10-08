# Live mutations from Explore keys against a disposable Deployment
# (tern-test-mutate/kl-e2e-web): shift+s scale (cancel, then confirm),
# ctrl+r rollout restart, ctrl+d delete (inexact token and cancel never
# delete). Tern must deliver all three chords to the block. Every cancel is
# checked against the live object; the Deployment is deleted at the end.
trap e2e_objects_delete EXIT
e2e_objects
lens "kubectl --context kind-kube-lens-dev get deploy kl-e2e-web -n $MNS"
native
click_text kl-e2e-web '.kl-grid .kl-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/kl-e2e-web'
contains "help lists the mutation keys" "$(xtext)" "ctrl+d delete"

# shift+s: replicas prompt, preview, cancel -> unchanged.
xkey shift+s
approve_open || return
a_input || return
contains "scale prompt" "$(atext)" "Scale deployment.apps/kl-e2e-web to how many replicas?"
ctl type 2 >/dev/null
xkey enter
a_ready || return
contains "replica preview" "$(atext)" "replicas 1 → 2"
contains "context pinned from the command" "$(atext)" "from --context"
xkey escape
approve_closed || return
eq "cancelled scale left replicas" "$(jp $MNS deploy/kl-e2e-web '{.spec.replicas}')" 1

# shift+s again, confirm with enter (simple tier) -> replicas 2.
xkey shift+s
approve_open || return
a_input || return
ctl type 2 >/dev/null
xkey enter
a_ready || return
xkey enter
a_done || return
contains "exit status" "$(atext)" "exit 0"
eq "confirmed scale" "$(jp $MNS deploy/kl-e2e-web '{.spec.replicas}')" 2
xkey escape
approve_closed || return

# ctrl+r: rollout restart sets the restartedAt annotation.
eq "no restart yet" "$(jp $MNS deploy/kl-e2e-web '{.spec.template.metadata.annotations}')" ""
xkey ctrl+r
approve_open || return
a_ready || return
contains "restart op" "$(atext)" "rollout restart deployment.apps/kl-e2e-web"
xkey enter
a_done || return
contains "restart executed" "$(jp $MNS deploy/kl-e2e-web '{.spec.template.metadata.annotations}')" "kubectl.kubernetes.io/restartedAt"
xkey escape
approve_closed || return

# ctrl+d: typed tier; enter with an inexact token and escape never delete.
xkey ctrl+d
approve_open || return
a_ready || return
contains "typed tier" "$(atext)" "Typed confirm"
ctl type kl-e2e-we >/dev/null
xkey enter
sleep 1
eq "inexact token keeps the deployment" "$(jp $MNS deploy/kl-e2e-web '{.metadata.name}')" kl-e2e-web
xkey escape
approve_closed || return
eq "cancelled delete keeps the deployment" "$(jp $MNS deploy/kl-e2e-web '{.metadata.name}')" kl-e2e-web

# ctrl+d, exact name -> deleted.
xkey ctrl+d
approve_open || return
a_ready || return
ctl type kl-e2e-web >/dev/null
xkey enter
a_done || return
E2E_WAIT=20 wait_for "kl-e2e-web to be gone" absent $MNS deploy/kl-e2e-web
xkey escape
approve_closed
explore_close
