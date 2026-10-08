# Live: on a list longer than the block (all namespaces, 25+ pods) the
# keyboard selection stays inside the visible rows: G and gg move the
# window, and the rows beyond it are announced as clickable indicators.
lens 'kubectl get pods -n tern-test-apps'
native
click_text db-0 '.kl-grid .kl-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
xkey escape
xwait 'crashloop' '.kl-grid *'
xkey n
xwait 'all namespaces' '[data-role="kube-lens.explore-namespaces"] *'
xkey g g enter
xwait 'pods' '[data-role="kube-lens.explore-list"] *'
total=$(xtext '[data-role="kube-lens.explore-list"] *' | sed -n 's/.*[^0-9]\([0-9][0-9]*\) pods.*/\1/p')
[ "${total:-0}" -ge 25 ] || fail "expected 25+ pods in all namespaces, got ${total:-none}"
height=$(ctl dump 'body' | jq -r '.header.viewport.height')

# visible_sel: the selected row's first cell lies inside the window.
visible_sel() {
	ctl tree "$EX .kl-sel .kl-c" | jq -e --argjson h "$height" \
		'.nodes[0].rect as $r | $r[3] > 0 and $r[1] >= 0 and ($r[1] + $r[3]) <= $h' >/dev/null
}

xkey G
E2E_WAIT=5 wait_for "the last row to be visible after G" visible_sel
contains "rows above are announced" "$(xtext '[data-role="kube-lens.overflow"]')" "above"
xkey g g
E2E_WAIT=5 wait_for "the first row to be visible after gg" visible_sel
contains "rows below are announced" "$(xtext '[data-role="kube-lens.overflow"]')" "below"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
	ctl key j >/dev/null
done
sleep 0.5
E2E_WAIT=5 wait_for "the selection to stay visible while j scrolls" visible_sel
click_text '↓*' "$EX [data-role='kube-lens.overflow']"
E2E_WAIT=5 wait_for "the selection to stay visible after paging" visible_sel
explore_close
