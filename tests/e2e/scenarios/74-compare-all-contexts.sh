# Live, two clusters plus an unreachable third context (E2E_MC=1), in a
# private copy of the merged kubeconfig: "All contexts" compares tkm-web in
# every context, the unreachable one is an error row and the others still
# compare; compare.max_contexts 1 disables the row with its reason.
. "$E2E_REPO/tests/e2e/compare.sh"
trap config_reset EXIT

k3=$(mc_kubeconfig3) || {
	fail "cannot write the three-context kubeconfig"
	return
}
mc_object "$MCA" deploy tkm-web deployment "$k3" || return
xkey x
E2E_WAIT=15 xwait "All contexts (3)" "[data-role='tern-kube.compare-picker'] *" || return
xkey G enter
E2E_WAIT=20 wait_for "the fan-out table" has "$EX [data-role='tern-kube.compare-fanout']" || return
E2E_WAIT=20 xwait "error" "[data-role='tern-kube.compare-fanout'] *" || return
rows=$(xtext "[data-role='tern-kube.compare-fanout'] *")
contains "reachable peer compared" "$rows" "changed"
contains "unreachable context listed" "$rows" "$MCDOWN"
contains "error cell for $MCDOWN" "$(mc_cells compare-fanout)" '"error"'
explore_close

set_config '{"schema_version": 1, "compare": {"max_contexts": 1}}'
mc_object "$MCA" deploy tkm-web deployment "$k3" || return
xkey x
E2E_WAIT=15 xwait "All contexts (3)" "[data-role='tern-kube.compare-picker'] *" || return
contains "disabled with its reason" "$(xtext "[data-role='tern-kube.compare-picker'] *")" "above compare.max_contexts (1)"
runs=$(explore_runs)
xkey G enter
contains "refusal toast" "$(toast_text)" "Cannot compare with All contexts (3)"
eq "a disabled row runs nothing" "$(explore_runs)" "$runs"
explore_close
