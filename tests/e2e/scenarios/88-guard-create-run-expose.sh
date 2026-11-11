# v1.2 guard (a): `create`, `run`, `expose` in a real pane.
# `create secret generic --from-literal` shows masked data and a masked
# command (deny); `create job --from=cronjob/tk-e2e-cron` (approve, the Job
# exists); `run tk-e2e-run --image=pause` (approve, the Pod exists);
# `expose --type=NodePort` shows the public-service reason (deny). The EXIT
# trap closes the tab and deletes everything tk-e2e-*.
focused_id() {
	ctl state | jq -r '.focused.id'
}
not_focused() {
	[ "$(focused_id)" != "$1" ]
}
at_prompt() {
	ctl state | jq -e '.focused.prompt' >/dev/null
}
guard_tab_close() {
	i=0
	while [ "$(focused_id)" != "$home_tab" ] && [ $i -lt 4 ]; do
		ctl close >/dev/null
		sleep 0.5
		i=$((i + 1))
	done
}
home_tab=$(focused_id)
K="kubectl --context kind-tern-kube-dev"
guarded() { # guarded LINE: run LINE, wait for its preview
	type_line "$1; echo GUARD-RC=\$?"
	approve_open && a_ready
}
finished() { # finished RC
	approve_closed || return 1
	expect_grid "GUARD-RC=$1" || return 1
	sh_line clear
}
guard_tab() { # DIR
	ctl tab new >/dev/null
	E2E_WAIT=10 wait_for "a new tab" not_focused "$home_tab"
	E2E_WAIT=10 wait_for "the new tab's prompt" at_prompt
	sh_line "source '$E2E_REPO/shell/tern-kube.zsh' && cd '$1' && clear"
}
create_cleanup() {
	guard_tab_close
	kc -n "$MNS" delete secret/tk-e2e-sec cronjob/tk-e2e-cron job/tk-e2e-job pod/tk-e2e-run service/tk-e2e-svc \
		--ignore-not-found --wait=false >/dev/null 2>&1
	e2e_objects_delete
}
trap create_cleanup EXIT
e2e_objects
kc -n "$MNS" create cronjob tk-e2e-cron --schedule='0 3 * * *' --image=registry.k8s.io/pause:3.10 >/dev/null &&
	kc -n "$MNS" patch cronjob tk-e2e-cron -p '{"spec":{"suspend":true}}' >/dev/null || fail "cannot create tk-e2e-cron"
guard_tab "$E2E_SB"

guarded "$K create secret generic tk-e2e-sec --from-literal=password=tk-e2e-S3cr3t -n $MNS" || return
contains "masked command" "$(atext)" "password=<redacted>"
contains "masked data" "$(atext)" "redacted"
excludes "no literal" "$(atext)" "tk-e2e-S3cr3t"
xkey escape
finished 1 || return
absent "$MNS" secret/tk-e2e-sec || fail "denied secret exists"

guarded "$K create job tk-e2e-job --from=cronjob/tk-e2e-cron -n $MNS" || return
contains "creates the job" "$(atext)" "tk-e2e-job"
if a_has "Typed confirm"; then ctl type tk-e2e-job >/dev/null; fi
xkey enter
finished 0 || return
eq "job from the cronjob" "$(jp $MNS job/tk-e2e-job '{.metadata.annotations.cronjob\.kubernetes\.io/instantiate}')" manual

guarded "$K run tk-e2e-run --image=registry.k8s.io/pause:3.10 --restart=Never -n $MNS" || return
contains "creates the pod" "$(atext)" "tk-e2e-run"
xkey enter
finished 0 || return
eq "pod created" "$(jp $MNS pod/tk-e2e-run '{.spec.containers[0].image}')" registry.k8s.io/pause:3.10

guarded "$K expose deploy/tk-e2e-web --name=tk-e2e-svc --type=NodePort --port=80 -n $MNS" || return
contains "public service" "$(atext)" "NodePort"
xkey escape
finished 1 || return
absent "$MNS" service/tk-e2e-svc || fail "denied service exists"
guard_tab_close
eq "back in the first tab" "$(focused_id)" "$home_tab"
