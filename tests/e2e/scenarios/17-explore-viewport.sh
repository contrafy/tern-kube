# Live: on a list longer than the block (all namespaces) the keyboard
# selection stays inside the visible rows of the list's own scroller (below
# its sticky head): G, gg, j and PageDown scroll it. Rows beyond
# general.max_rendered_rows are not drawn but announced as clickable
# indicators that page. The scenario brings its own pods (tk-e2e-many: pause
# replicas in tern-test-mutate, enough to overflow the window on their own,
# rows being at least 16 px high) and deletes them on exit, so ambient pod
# counts never matter.
height=$(ctl dump 'body' | jq -r '.header.viewport.height')
many=$(((${height%.*} + 15) / 16))
many_cleanup() {
	kc -n "$MNS" delete deploy/tk-e2e-many --ignore-not-found --wait=true >/dev/null 2>&1
	kc -n "$MNS" wait --for=delete pod -l app=tk-e2e-many --timeout=60s >/dev/null 2>&1
	config_reset
}
trap many_cleanup EXIT
kc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tk-e2e-many
  namespace: $MNS
spec:
  replicas: $many
  selector: {matchLabels: {app: tk-e2e-many}}
  template:
    metadata: {labels: {app: tk-e2e-many}}
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
          resources:
            requests: {cpu: 1m, memory: 4Mi}
            limits: {cpu: 5m, memory: 8Mi}
EOF
many_listed() {
	[ "$(kc -n "$MNS" get pods -l app=tk-e2e-many -o name | wc -l | tr -d ' ')" -ge "$many" ]
}
E2E_WAIT=60 wait_for "$many tk-e2e-many pods" many_listed || return

# all_pods: Explore from a lens row, then the pods of all namespaces.
all_pods() {
	lens 'kubectl get pods -n tern-test-apps'
	native
	click_text db-0 '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return 1
	xwait 'Object pod/db-0'
	xkey escape
	xwait 'crashloop' "$XT *"
	xkey n
	xwait 'all namespaces' '[data-role="tern-kube.explore-namespaces"] *'
	xkey g g enter
	xwait 'pods' '[data-role="tern-kube.explore-list"] *'
	total=$(xtext '[data-role="tern-kube.explore-list"] *' | sed -n 's/.*[^0-9]\([0-9][0-9]*\) pods.*/\1/p')
	[ "${total:-0}" -gt "$many" ] || fail "expected more than $many pods in all namespaces, got ${total:-none}"
}

# visible_sel: the selected row lies inside the list's scroller, below its
# sticky head (24 px), and inside the window.
visible_sel() {
	box=$(ctl tree "$EX [data-role='tern-kube.scroller']" | jq -c '.nodes[0].rect // empty')
	[ -n "$box" ] || return 1
	ctl tree "$EX .sf-tbl-row.sel" | jq -e --argjson h "$height" --argjson b "$box" '
		.nodes[0].rect as $r | $r[3] > 0 and $r[1] >= $b[1] + 23 and
			($r[1] + $r[3]) <= ($b[1] + $b[3] + 1) and ($r[1] + $r[3]) <= $h' >/dev/null
}

# The whole list is drawn (it is under general.max_rendered_rows) and the
# scroller follows the keyboard.
all_pods || return
lacks "$EX [data-role='tern-kube.overflow']" || fail "no row is beyond max_rendered_rows, yet overflow notes show"
xkey G
E2E_WAIT=5 wait_for "the last row to be visible after G" visible_sel
xkey g g
E2E_WAIT=5 wait_for "the first row to be visible after gg" visible_sel
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
	ctl key j >/dev/null
done
sleep 0.5
E2E_WAIT=5 wait_for "the selection to stay visible while j scrolls" visible_sel
xkey pagedown
E2E_WAIT=5 wait_for "the selection to stay visible after PageDown" visible_sel
explore_close

# A cap below the list's length: only a window around the selection is
# drawn, the rest announced above and below.
set_config '{"schema_version": 1, "general": {"max_rendered_rows": 20}}'
all_pods || return
xkey G
E2E_WAIT=5 wait_for "the last row to be visible after G" visible_sel
contains "rows above are announced" "$(xtext '[data-role="tern-kube.overflow"]')" "earlier rows"
xkey g g
E2E_WAIT=5 wait_for "the first row to be visible after gg" visible_sel
contains "rows below are announced" "$(xtext '[data-role="tern-kube.overflow"]')" "more rows"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
	ctl key j >/dev/null
done
sleep 0.5
E2E_WAIT=5 wait_for "the selection to stay visible while j moves past the window" visible_sel
contains "rows above are announced after j" "$(xtext '[data-role="tern-kube.overflow"]')" "earlier rows"
before=$(xsel)
click_text '↓*' "$EX [data-role='tern-kube.overflow']"
E2E_WAIT=5 wait_for "the selection to stay visible after paging" visible_sel
[ "$(xsel)" != "$before" ] || fail "clicking the more-rows note did not page (still on $before)"
explore_close
