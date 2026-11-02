# FAKE: no kind container logs 25 000 lines on demand, so the fake kubectl
# serves a generated log (JSON lines, one error every 997). The view keeps
# the newest general.max_rows (20 000) lines, says the rest are only in Raw,
# shows the newest page with page chips, jumps to the first error in a small
# context view, steps to the next error, and stays fast.
dir=$E2E_SB/fake-logs
mkdir -p "$dir"
awk 'BEGIN {
	for (i = 1; i <= 25000; i++) {
		if (i % 997 == 0) printf "{\"level\":\"error\",\"msg\":\"request %d failed\",\"code\":500}\n", i
		else if (i % 13 == 0) printf "level=warn msg=\"slow request %d\" dur=2.1s\n", i
		else printf "{\"level\":\"info\",\"msg\":\"request %d\",\"path\":\"/api\"}\n", i
	}
}' >"$dir/logs_big-0.txt"
sh_line "tk_fake '$dir'"
mark=$(log_lines)
E2E_WAIT=60 lens 'kubectl logs big-0'
logs_native || return
contains "over-cap notice" "$(ltext '[data-role="tern-kube.notices"] *')" "5000 earlier lines only in Raw"
contains "newest page shown" "$(ltext '[data-role="tern-kube.pages"] *')" "Lines 19501-20000 of 20000"
contains "page chips" "$(texts '[data-role="tern-kube.pages"] .sf-act')" '"40"'
contains "the newest line is on screen" "$(ltext '.tk-grid *')" "request 24"

# The first kept error: 5982 = 6 x 997, the first past the 5000 dropped lines.
click_text 'First error' '[data-role="tern-kube.chips"] .sf-act' || return
E2E_WAIT=5 wait_for "the context view" has '[data-role="tern-kube.context"]' || return
contains "context of the first error" "$(ltext '[data-role="tern-kube.context"] *')" "Around line 5982"
contains "the error is shown and open" "$(ltext '[data-role="tern-kube.inspector"] *')" "request 5982 failed"
lacks '[data-role="tern-kube.pages"]' || fail "context view shows page chips"
click_text 'Next error ▸' '[data-role="tern-kube.context"] .sf-act' || return
contains "next error" "$(ltext '[data-role="tern-kube.context"] *')" "Around line 6979"
click_text 'All lines' '[data-role="tern-kube.context"] .sf-act' || return
has '[data-role="tern-kube.pages"]' || fail "All lines does not return to the pages"

worst=$(tail -n +"$((mark + 1))" "$(daemon_log)" | grep 'tern-kube lens.view' | grep 'kind=logs' |
	grep 'finished=true' | sed -n 's/.*view_ms=\([0-9.]*\).*/\1/p' | sort -n | tail -1)
[ -n "$worst" ] || fail "no finished logs view logged"
note "slowest finished logs view: ${worst:-?} ms"
awk -v ms="${worst:-9999}" 'BEGIN { exit !(ms < 250) }' || fail "logs view took ${worst} ms (bound 250 ms)"
real
