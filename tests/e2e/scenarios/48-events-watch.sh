# Live: event watches (tern-test-logs, where crashy restarts keep events
# coming). Raw while the watch runs (Raw is live; a plugin view trails it),
# native after Ctrl-C with the rows in arrival order and "stopped (Ctrl-C)"
# instead of exit 130; --output-watch-events keeps its EVENT column.
watch_case() {
	start_line "$1" 4
	idle && {
		fail "$1 ended on its own"
		return 1
	}
	claimed && { lacks '[data-role="tern-kube.header"]' || fail "$1: native while running"; }
	stop_line
	native || return 1
	eq "$1 stopped by the user" "$(alltext '[data-role="tern-kube.stopped"]')" "stopped (Ctrl-C)"
	lacks '[data-role="tern-kube.exit"]' || fail "$1: Ctrl-C shown as a failure"
	has '.tk-grid .tk-r .tk-c' || fail "$1: no rows"
	lacks '[data-role="tern-kube.partial"]' || fail "$1: misaligned watch rows left unparsed"
}

watch_case "kubectl get events -n $LNS -w" || return
watch_case "kubectl events -n $LNS -w" || return
watch_case "kubectl get events -n $LNS -w --output-watch-events" || return
eq "EVENT column first" "$(texts '.tk-grid .tk-h' | jq -r '.[0]')" "EVENT"
values=$(column_texts 1 6 | jq -r 'unique | join(",")')
case $values in
ADDED | ADDED,MODIFIED | MODIFIED) ;;
*) fail "EVENT cells: $values" ;;
esac
if [ "$values" = ADDED,MODIFIED ]; then
	contains "EVENT facet" "$(ltext '[data-role="tern-kube.chips"] *')" "MODIFIED"
fi
