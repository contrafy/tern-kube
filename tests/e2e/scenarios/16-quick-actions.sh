# Live: quick actions open new splits running real kubectl against the kind
# toolbox (tern-test-mutate/tk-qa-shell: busybox httpd on 8080 + ticker):
# s (interactive shell), l (follow logs), shift+f (port-forward) from
# Explore, and Shell from the lens inspector in two clicks. Nothing mutates.
qa_ns=tern-test-mutate

# Clicking the breadcrumb row gives the Explore block keyboard focus.
focus_explore() {
	xy=$(ctl tree "$EX [data-role='tern-kube.breadcrumb']" | jq -r '.nodes[0].rect // empty | "\(.[0] + .[2] - 20) \(.[1] + .[3] / 2)"')
	[ -n "$xy" ] || return 1
	# shellcheck disable=SC2086
	ctl click $xy >/dev/null
	sleep 0.3
}

# shell_roundtrip: in the focused split, run a command whose output differs
# from the typed text, see the output, then exit the shell (pane closes).
shell_roundtrip() {
	panes=$1
	sleep 1.5
	type_line 'echo tk-e2e-$(echo ok)'
	E2E_WAIT=15 expect_grid "tk-e2e-ok" || return 1
	type_line 'exit'
	pane_gone() { [ "$(pane_count)" -lt "$panes" ]; }
	E2E_WAIT=10 wait_for "the shell split to close after exit" pane_gone
}

lens "kubectl get pods -n $qa_ns -l app=tk-qa-shell"
native
click_text 'tk-qa-shell-*' '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/tk-qa-shell-'
before=$(pane_count)

# s: interactive exec shell in a new split titled with the target.
xkey s
E2E_WAIT=15 quick_pane "tern-kube shell $qa_ns/tk-qa-shell-" || return
contains "shell split pins the context" "$(focused_title)" "@ kind-tern-kube-dev"
eq "one more pane" "$(pane_count)" $((before + 1))
shell_roundtrip $((before + 1)) || return

# l: follow logs of both containers in a new split.
focus_explore || fail "cannot focus Explore"
xkey l
E2E_WAIT=15 quick_pane "tern-kube logs pod $qa_ns/tk-qa-shell-" || return
E2E_WAIT=20 expect_grid "ticker: tick" || return
ctl close >/dev/null
sleep 1
eq "logs split closed" "$(pane_count)" "$before"
explore_close

focused_id() {
	ctl state | jq -r '.focused.id'
}

# focus_pane ID X: click at window x X (inside that pane) and check that
# pane ID has focus. `ctl focus` answers only after a 20 s timeout while a
# split runs port-forward, so clicks are used instead.
focus_pane() {
	ctl click "$2" 600 >/dev/null
	sleep 0.3
	[ "$(focused_id)" = "$1" ] || fail "cannot focus pane $1 (focused: $(focused_id))"
}

# shift+f on the Service: port 80 -> local 8080, reached from another pane.
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
	fail "local port 8080 is taken; the port-forward check needs it free"
	return
fi
lens "kubectl get svc -n $qa_ns"
native
home=$(focused_id)
click_text tk-qa-shell '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object service/tk-qa-shell'
before=$(pane_count)
xkey shift+f
E2E_WAIT=15 quick_pane "tern-kube port-forward " || return
contains "port-forward target" "$(focused_title)" "$qa_ns/tk-qa-shell 80 @ kind-tern-kube-dev"
forward=$(focused_id)
expect_grid "Forwarding from 127.0.0.1:8080" || return
focus_pane "$home" 30 || return
sh_line clear
sh_line 'curl -s --max-time 5 http://127.0.0.1:8080/index.html | sed s/^/KLQA:/'
expect_grid "KLQA:tk-qa-ok"
focus_pane "$forward" 1250 || return
ctl close >/dev/null
sleep 1
eq "port-forward split closed" "$(pane_count)" "$before"
focus_pane "$home" 30 || return
sh_line clear
sh_line 'curl -s --max-time 3 http://127.0.0.1:8080/index.html >/dev/null; echo KLQA-rc=$?'
expect_grid "KLQA-rc=7"
focus_explore && explore_close

# Lens inspector: Shell in two clicks (open the row, click Shell).
lens "kubectl get pods -n $qa_ns -l app=tk-qa-shell"
native
before=$(pane_count)
click_text 'tk-qa-shell-*' '.tk-grid .tk-c'
click_text Shell '[data-role="tern-kube.inspector"] .sf-act'
E2E_WAIT=15 quick_pane "tern-kube shell $qa_ns/tk-qa-shell-" || return
contains "unpinned lens command names the current context" "$(focused_title)" "@ current context"
shell_roundtrip $((before + 1)) || return
grep -q 'tern-kube quick action.*shell' "$(window_log)" || fail "no quick action logged"
