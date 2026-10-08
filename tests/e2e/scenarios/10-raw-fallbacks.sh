# Live: claimed but unsupported commands stay raw (watch + Ctrl-C, over-claim).
mark=$(log_lines)
sh_line clear
type_line 'kubectl get pods -n tern-test-apps -w'
sleep 2
ctl key ctrl+c >/dev/null
wait_for "watch to stop" idle
sleep 0.4
raw
# Raw block text is not in the element tree; the lens log shows it received
# the watch rows and finished on the interrupt.
watch_finished() {
	tail -n +"$((mark + 1))" "$(daemon_log)" | grep 'tern-kube lens.view' | grep -q 'finished=true'
}
wait_for "the lens to see the watch finish" watch_finished
# `kubectl -* get *` over-claims a logs command: ours (not the built-in logs
# lens) and raw.
lens 'kubectl -n tern-test-apps logs db-0 get'
raw
