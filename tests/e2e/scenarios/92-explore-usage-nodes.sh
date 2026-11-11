# Live: the palette command Tern Kube: Resource usage opens the nodes usage
# view (read-only). Tiles name the ready nodes and the pod capacity; %CPU REQ
# matches `kubectl describe node` plus the pod-level requests kubectl leaves
# out; enter lists the node's pods; % toggles pods <-> nodes.
uns=tern-test-usage
node=tern-kube-dev-control-plane

E2E_WAIT=120 wait_for "metrics for $uns" kc top pods -n "$uns" || return

ctl plugins run plugin.tern-kube.usage >/dev/null
explore_open || return
E2E_WAIT=20 xwait "usage · nodes" || return
t=$(xtext)
contains "Nodes tile" "$t" "1 / 1"
contains "Pods tile against allocatable" "$t" "/ 110"
contains "node row" "$(xnames)" "$node"

# The shell's %CPU REQ: describe's millicores plus pod-level pods' requests,
# over allocatable, rounded like the view.
desc=$(kc describe node "$node" | awk '/^Allocated resources:/ {a=1} a && $1 == "cpu" {print $2; exit}')
pl=$(kc get pods -A -o jsonpath='{range .items[*]}{.spec.resources.requests.cpu}{"\n"}{end}' | awk '
	/m$/ {sub("m", ""); s += $1; next}
	/./ {s += $1 * 1000}
	END {print s + 0}')
alloc=$(kc get node "$node" -o jsonpath='{.status.allocatable.cpu}')
want=$(awk -v d="${desc%m}" -v p="$pl" -v a="$alloc" 'BEGIN {
	if (a ~ /m$/) { sub("m", "", a) } else { a *= 1000 }
	printf "%d%%", (d + p) * 100 / a + 0.5 }')
contains "%CPU REQ matches describe + pod-level" "$(texts "$EX .sf-tbl-row.sel > .sf-tbl-c" | jq -r '.[4]')" "$want"

xkey enter
E2E_WAIT=20 xwait "usage · pods · node $node" || return
contains "the node's pods" "$(xtext "$XT *")" "cpu-burner"
xkey %
E2E_WAIT=20 xwait "usage · nodes" || return
xkey %
E2E_WAIT=20 xwait "usage · pods" || return
explore_close_all
