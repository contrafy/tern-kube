# Live: `logs -f` on the ticking app container. Tern hands plugin lenses
# lines late (plan F3), so by default the block stays raw (live, no lag)
# while the follow runs and turns native with every line after Ctrl-C. With
# general.streaming_view = "native" the native view shows while it runs,
# with a note that it trails the stream.
pod=$(logmix_pod) || {
	fail "no tk-logmix pod in $LNS"
	return
}
trap config_reset EXIT

start_line "kubectl logs -n $LNS $pod -c app -f --tail=3" 5
idle && {
	fail "the follow ended on its own"
	return
}
claimed && { lacks '[data-role="tern-kube.header"]' || fail "native view while following (streaming_view=raw)"; }
stop_line
logs_native || return
eq "stopped by the user" "$(alltext '[data-role="tern-kube.stopped"]')" "stopped (Ctrl-C)"
lacks '[data-role="tern-kube.exit"]' || fail "Ctrl-C shown as a failure"
rows=$(count '.tk-grid .tk-r .tk-c')
[ "$rows" -ge 12 ] || fail "expected the 3 tail lines and the ticks since as rows (cells: $rows)"
excludes "no ^C row" "$(ltext '.tk-grid *')" "^C"

set_config '{"schema_version": 1, "general": {"streaming_view": "native"}}'
start_line "kubectl logs -n $LNS $pod -c app -f --tail=20" 2
following_native() { has "$LOGS" && has '[data-role="tern-kube.note"]'; }
E2E_WAIT=20 wait_for "the native view while following" following_native || {
	stop_line
	return
}
idle && fail "the follow ended on its own"
contains "trailing note" "$(alltext '[data-role="tern-kube.note"]')" "live view trails the stream by about 6 lines; Raw is live"
contains "live badge" "$(ltext '[data-role="tern-kube.bar"] *')" "Live"
stop_line
logs_native
lacks '[data-role="tern-kube.note"]' || fail "trailing note after the follow stopped"
