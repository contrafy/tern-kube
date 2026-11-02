# Explore X patches the focused object: a merge patch of a Deployment's
# replicas shows the before/after diff of the server dry run and runs on
# enter (simple tier); a JSON patch is typed, and an inexact token or a
# cancel never patches. tk-e2e-* objects are deleted at the end.
trap e2e_objects_delete EXIT
e2e_objects

# patch_input TYPE JSON: replace the prefilled prompt (no spaces in JSON).
patch_input() {
	xkey cmd+a
	ctl type "--type=$1" >/dev/null
	ctl type '" "' >/dev/null
	ctl type "$2" >/dev/null
}

lens "kubectl --context kind-tern-kube-dev get deploy tk-e2e-web -n $MNS"
native
click_text tk-e2e-web '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/tk-e2e-web'
contains "patch key listed" "$(xtext)" "Patch (X)"

xkey X
approve_open || return
a_input || return
contains "patch prompt" "$(atext)" "Patch for deployment.apps/tk-e2e-web"
eq "prefilled patch type" "$(ctl tree "$AP .sf-input" | jq -r '.nodes[0].text')" ">--type=strategic"
patch_input merge '{"spec":{"replicas":2}}'
xkey enter
a_ready || return
contains "object diff" "$(atext)" "MODIFY Deployment tern-test-mutate/tk-e2e-web"
contains "replicas after" "$(atext)" "replicas: 2"
contains "count badge" "$(atext)" "1 to patch"
xkey enter
a_done || return
contains "exit status" "$(atext)" "exit 0"
eq "merge patch ran" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2
xkey escape
approve_closed || return

xkey X
approve_open || return
a_input || return
patch_input json '[{"op":"replace","path":"/spec/replicas","value":3}]'
xkey enter
a_ready || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "json patch reason" "$(atext)" "JSON patch operations can remove or replace any path"
ctl type tk-e2e-we >/dev/null
xkey enter
sleep 1
eq "inexact token never patches" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2
xkey escape
approve_closed || return
eq "cancelled json patch" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 2
explore_close
