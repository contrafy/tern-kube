# Mutating quick actions go through the approve block, then run in a split
# via a single-use grant: CronJob "Run now" (cancel creates no Job; confirm
# creates exactly the previewed Job) and pod "Debug" (ephemeral busybox
# container, shell round trip). Created Jobs and kl-e2e-web are deleted at
# the end.
manual_jobs() {
	kc -n tern-test-batch get jobs -o name | grep '^job.batch/nightly-report-manual-' || true
}
jobs_before=$(manual_jobs)
quick_cleanup() {
	for j in $(manual_jobs); do
		case " $jobs_before " in *" $j "*) ;; *) kc -n tern-test-batch delete "$j" --wait=false >/dev/null 2>&1 ;; esac
	done
	e2e_objects_delete
}
trap quick_cleanup EXIT
e2e_objects
INS='[data-role="kube-lens.inspector"] .sf-act'
panes_back() {
	[ "$(pane_count)" = "$before" ]
}

lens "kubectl --context kind-kube-lens-dev get cronjob nightly-report -n tern-test-batch"
native
click_text nightly-report '.kl-grid .kl-c'
before=$(pane_count)
click_text 'Run now' "$INS"
approve_open || return
a_ready || return
contains "quick mode" "$(atext)" "Quick action"
contains "previewed job" "$(atext)" "nightly-report-manual-"
xkey escape
approve_closed || return
eq "cancel created no job" "$(manual_jobs)" "$jobs_before"

click_text 'Run now' "$INS"
approve_open || return
a_ready || return
job=$(atext | grep -o 'nightly-report-manual-[0-9a-f]*' | head -1)
xkey enter
E2E_WAIT=15 quick_pane "kube-lens run cronjob tern-test-batch/nightly-report @ kind-kube-lens-dev" || return
expect_grid "job.batch/$job created" || return
[ -n "$(jp tern-test-batch "job/$job" '{.metadata.name}')" ] || fail "previewed job $job not created"
ctl key enter >/dev/null
E2E_WAIT=10 wait_for "the run split to close" panes_back

lens "kubectl --context kind-kube-lens-dev get pods -n $MNS -l app=kl-e2e-web"
native
click_text 'kl-e2e-web-*' '.kl-grid .kl-c'
click_text Debug "$INS"
approve_open || return
a_ready || return
contains "debug command" "$(atext)" "--image=busybox:1.36"
xkey enter
E2E_WAIT=15 quick_pane "kube-lens debug $MNS/kl-e2e-web-" || return
sleep 3
type_line 'echo DBG-$((6*7))'
E2E_WAIT=30 expect_grid "DBG-42" || return
type_line exit
E2E_WAIT=10 wait_for "the debug split to close" panes_back
contains "ephemeral container added" "$(kc -n $MNS get pod -l app=kl-e2e-web -o jsonpath='{.items[0].spec.ephemeralContainers[*].image}')" "busybox:1.36"
