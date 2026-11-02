# Live: the logs lens on one container of tk-logmix (tern-test-logs): the
# records view with level badges, a JSON message with its fields, a klog
# location, a Java stack folded into one record, the Errors chip, the row
# inspector, Copy line (clipboard) and the Raw toggle round trip.
pod=$(logmix_pod) || {
	fail "no tk-logmix pod in $LNS"
	return
}
lens "kubectl logs -n $LNS $pod -c app"
logs_native || return
contains "header counts" "$(ltext '[data-role="tern-kube.header"] *')" " lines · "
contains "header names the command" "$(ltext '[data-role="tern-kube.header"] *')" "kubectl logs $pod"

# The newest page is shown; the container's first lines are on page 1.
if has '[data-role="tern-kube.pages"]'; then
	click_text 1 '[data-role="tern-kube.pages"] .sf-act' || return
fi
grid=$(ltext '.tk-grid *')
contains "JSON message with its fields" "$grid" "server started port=8080"
contains "klog location" "$grid" "controller.go:42"
contains "logfmt message" "$grid" "slow request"
contains "Java stack folded into its record" "$grid" "+2 lines"
excludes "stack frames are not rows" "$(column_texts 3 3)" "at com.example.Main.run"
badges=$(texts '.tk-grid .sf-badge')
for level in INFO WARN ERROR DEBUG; do
	contains "level badge $level" "$badges" "\"$level\""
done

# Errors keeps error lines only (every visible row has the error class).
click_text 'Errors *' '[data-role="tern-kube.chips"] .sf-act' || return
eq "only error rows" "$(count '.tk-grid .tk-lvl-error .tk-c')" "$(count '.tk-grid .tk-r .tk-c')"
click_text 'Errors *' '[data-role="tern-kube.chips"] .sf-act' || return

# Row inspector and Copy line (the line exactly as kubectl printed it).
if has '[data-role="tern-kube.pages"]'; then
	click_text 1 '[data-role="tern-kube.pages"] .sf-act' || return
fi
click_text 'server started*' '.tk-grid .tk-c' || return
E2E_WAIT=5 wait_for "the row inspector" has '[data-role="tern-kube.inspector"]' || return
contains "inspector shows the fields" "$(ltext '[data-role="tern-kube.inspector"] *')" "8080"
click_text 'Copy line' '[data-role="tern-kube.inspector"] .sf-act' || return
clip_has() { case $(clip) in *'"msg":"server started"'*) true ;; *) false ;; esac; }
E2E_WAIT=5 wait_for "Copy line on the clipboard" clip_has

# Raw and back: the same block, the same native view.
click_text Raw '.sf-block-opt' || return
raw
click_text Native '.sf-block-opt' || return
logs_native
