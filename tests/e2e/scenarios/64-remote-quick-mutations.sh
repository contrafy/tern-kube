# Remote mutating quick actions: the approve block opens on the remote host,
# but the single-use grant is minted and consumed by this window (window kv),
# so confirming runs the split on the remote host: CronJob "Run now" creates
# exactly the previewed Job, a replayed confirm link is refused (no second
# Job, no split), pod "Debug" adds an ephemeral busybox container with a
# shell round trip. The same Run now from a local pane still works. Objects
# live in their own namespace tern-test-remote, deleted at the end.
RNS=tern-test-remote
remote_objects() {
	kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $RNS}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: tk-e2e-rweb, namespace: $RNS, labels: {app: tk-e2e-rweb}}
spec:
  replicas: 1
  selector: {matchLabels: {app: tk-e2e-rweb}}
  template:
    metadata: {labels: {app: tk-e2e-rweb}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - {name: web, image: registry.k8s.io/pause:3.10, imagePullPolicy: IfNotPresent}
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: tk-e2e-rcron, namespace: $RNS}
spec:
  schedule: "0 3 * * *"
  suspend: true
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - {name: run, image: busybox:1.36, imagePullPolicy: IfNotPresent, command: ["true"]}
EOF
	kc -n "$RNS" rollout status deploy/tk-e2e-rweb --timeout=60s >/dev/null || fail "tk-e2e-rweb not ready"
}
# Waited for: the next scenario creates the namespace again.
trap 'kc delete namespace "$RNS" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1' EXIT
remote_objects
INS='[data-role="tern-kube.inspector"] .sf-act'
manual_jobs() {
	kc -n "$RNS" get jobs -o name | grep -c '^job.batch/tk-e2e-rcron-manual-' || true
}
panes_back() {
	[ "$(pane_count)" = "$before" ]
}
# run_now: Run now on the CronJob lens row, confirmed; prints nothing,
# leaves the created Job's name in $job.
run_now() {
	lens "kubectl --context kind-tern-kube-dev get cronjob tk-e2e-rcron -n $RNS"
	native
	click_text tk-e2e-rcron '.tk-grid .tk-c' || return 1
	before=$(pane_count)
	click_text 'Run now' "$INS" || return 1
	approve_open || return 1
	a_ready || return 1
	contains "quick mode" "$(atext)" "Quick action"
	job=$(atext | grep -o 'tk-e2e-rcron-manual-[0-9a-f]*' | head -1)
	[ -n "$job" ] || {
		fail "no previewed job name"
		return 1
	}
	xkey enter
	E2E_WAIT=15 quick_pane "tern-kube run cronjob $RNS/tk-e2e-rcron @ kind-tern-kube-dev" || return 1
	expect_grid "job.batch/$job created" || return 1
	[ -n "$(jp "$RNS" "job/$job" '{.metadata.name}')" ] || fail "previewed job $job not created"
	ctl key enter >/dev/null
	E2E_WAIT=10 wait_for "the run split to close" panes_back
	# Run-now's approve block stays with the created Job until closed.
	click_text 'Close*' "$AP button" || return 1
	approve_closed || return 1
}

remote_switch || return
run_now || return
eq "one job from the remote run" "$(manual_jobs)" 1

# The confirmed link, as the approve block opened it, sent again (the
# window log is written in batches).
confirmed_url() {
	grep -o "tern-kube://act/cronjob-run?[^[:space:]]*namespace=$RNS[^[:space:]]*confirm=[0-9a-f]\{32\}[^[:space:]]*" "$(window_log)" | tail -1
}
has_url() {
	[ -n "$(confirmed_url)" ]
}
E2E_WAIT=15 wait_for "the confirmed link in the window log" has_url || return
url=$(confirmed_url)
token=$(printf '%s' "$url" | sed 's/.*confirm=\([0-9a-f]*\).*/\1/')
ctl open-url "$url" >/dev/null
replayed() {
	[ "$(grep -c "route.link.*confirm=$token" "$(window_log)")" -ge 2 ]
}
E2E_WAIT=15 wait_for "the replayed link to reach the window" replayed || return
sleep 1
eq "replayed confirm creates no job" "$(manual_jobs)" 1
eq "replayed confirm opens no split" "$(pane_count)" "$before"

lens "kubectl --context kind-tern-kube-dev get pods -n $RNS -l app=tk-e2e-rweb"
native
click_text 'tk-e2e-rweb-*' '.tk-grid .tk-c' || return
before=$(pane_count)
click_text Debug "$INS" || return
approve_open || return
a_ready || return
contains "debug command" "$(atext)" "--image=busybox:1.36"
xkey enter
E2E_WAIT=15 quick_pane "tern-kube debug $RNS/tk-e2e-rweb-" || return
sleep 3
type_line 'echo DBG-$((6*7))'
E2E_WAIT=30 expect_grid "DBG-42" || return
type_line exit
E2E_WAIT=10 wait_for "the debug split to close" panes_back
contains "ephemeral container added" \
	"$(kc -n "$RNS" get pod -l app=tk-e2e-rweb -o jsonpath='{.items[0].spec.ephemeralContainers[*].image}')" "busybox:1.36"

local_switch || return
reset_pane
run_now || return
eq "a second job from the local run" "$(manual_jobs)" 2
