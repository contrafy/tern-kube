# v1.2 guard (b) and (c). A guarded `kubectl delete cm -l tk-e2e=sel` with a
# matching configmap created while the approve block waits: confirm refuses
# with the selection message and nothing is deleted. Then CronJob "Run now"
# and pod "Debug" from the lens: the audit log has an approved record and an
# outcome record (executed/failed) with the same run id for each.
manual_jobs() {
	kc -n tern-test-batch get jobs -o name | grep '^job.batch/nightly-report-manual-' || true
}
jobs_before=$(manual_jobs)
sel_cleanup() {
	kc -n "$MNS" delete configmap -l tk-e2e=sel --ignore-not-found >/dev/null 2>&1
	for j in $(manual_jobs); do
		case " $jobs_before " in *" $j "*) ;; *) kc -n tern-test-batch delete "$j" --wait=false >/dev/null 2>&1 ;; esac
	done
	[ "$(ctl state | jq -r '.focused.id')" = "$home_tab" ] || ctl close >/dev/null 2>&1
	e2e_objects_delete
}
trap sel_cleanup EXIT
e2e_objects
INS='[data-role="tern-kube.inspector"] .sf-act'
audit_log() {
	find "$E2E_SB" -name audit.log -path '*tern-kube*' 2>/dev/null | head -n 1
}
for n in a b; do
	kc -n "$MNS" create configmap "tk-e2e-sel-$n" >/dev/null &&
		kc -n "$MNS" label configmap "tk-e2e-sel-$n" tk-e2e=sel >/dev/null || fail "cannot create tk-e2e-sel-$n"
done

home_tab=$(ctl state | jq -r '.focused.id')
ctl tab new >/dev/null
sh_line "cd '$E2E_REPO' && source shell/tern-kube.zsh && clear"
type_line "kubectl --context kind-tern-kube-dev delete cm -l tk-e2e=sel -n $MNS; echo SEL-RC=\$?"
approve_open || return
a_ready || return
contains "previews both" "$(atext)" "tk-e2e-sel-b"
kc -n "$MNS" create configmap tk-e2e-sel-c >/dev/null && kc -n "$MNS" label configmap tk-e2e-sel-c tk-e2e=sel >/dev/null
contains "typed tier" "$(atext)" "Typed confirm"
ctl type '"delete 2 resources"' >/dev/null
xkey enter
E2E_WAIT=15 wait_for "the selection refusal" a_has "The selection now matches 3 object(s) (previewed 2)" || return
contains "names the new match" "$(atext)" "+ConfigMap $MNS/tk-e2e-sel-c"
eq "nothing deleted" "$(kc -n "$MNS" get configmap -l tk-e2e=sel -o name | wc -l | tr -d ' ')" 3
xkey escape
approve_closed || return
expect_grid "SEL-RC=1" || return
ctl close >/dev/null

log=$(audit_log)
[ -n "$log" ] || fail "no tern-kube audit.log under $E2E_SB"
lines_before=$(wc -l <"$log" | tr -d ' ')

lens "kubectl --context kind-tern-kube-dev get cronjob nightly-report -n tern-test-batch"
native
click_text nightly-report '.tk-grid .tk-c'
click_text 'Run now' "$INS"
approve_open || return
a_ready || return
xkey enter
E2E_WAIT=15 quick_pane "tern-kube run cronjob tern-test-batch/nightly-report @ kind-tern-kube-dev" || return
expect_grid "created" || return
ctl key enter >/dev/null
click_text 'Close*' "$AP button" || return
approve_closed || return

lens "kubectl --context kind-tern-kube-dev get pods -n $MNS -l app=tk-e2e-web"
native
click_text 'tk-e2e-web-*' '.tk-grid .tk-c'
click_text Debug "$INS"
approve_open || return
a_ready || return
xkey enter
E2E_WAIT=15 quick_pane "tern-kube debug $MNS/tk-e2e-web-" || return
sleep 3
type_line exit
sleep 2

new=$(tail -n "+$((lines_before + 1))" "$log")
for fam in cronjob-run debug-pod; do
	approved=$(printf '%s\n' "$new" | grep "\"family\":\"$fam\"" | grep '"decision":"approved","mode":"quick"' |
		sed -n 's/.*"run":"\([0-9a-f]\{32\}\)".*/\1/p' | head -1)
	[ -n "$approved" ] || {
		fail "$fam: no approved quick record with a run id"
		continue
	}
	outcome=$(printf '%s\n' "$new" | grep "\"run\":\"$approved\"" | grep -E '"decision":"(executed|failed)"' | head -1)
	[ -n "$outcome" ] || fail "$fam: no outcome record for run $approved"
	contains "$fam outcome is quick mode" "$outcome" "\"mode\":\"quick\""
done
