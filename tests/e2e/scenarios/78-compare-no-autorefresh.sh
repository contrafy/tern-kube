# Live, two clusters (E2E_MC=1): a compare never refetches by itself. The
# peer's tkm-web is scaled outside Tern; the view keeps 2 -> 3 until r, which
# refetches both sides (fetch times move). Mutates only tern-test-mc in
# kind-tern-kube-dev2 and scales back to 3.
. "$E2E_REPO/tests/e2e/compare.sh"
trap 'kc2 -n "$MCNS" scale deployment/tkm-web --replicas=3 >/dev/null 2>&1' EXIT

mc_object "$MCA" deploy tkm-web deployment || return
mc_pick_first || return
E2E_WAIT=20 xwait "spec.replicas 2 -> 3" || return
before=$(mc_sides | grep -o 'fetched [0-9:]*' | tr '\n' ' ')
runs=$(explore_runs)
kc2 -n "$MCNS" scale deployment/tkm-web --replicas=4 >/dev/null || fail "cannot scale the peer's tkm-web"
sleep 5
contains "unchanged without r" "$(xtext)" "spec.replicas 2 -> 3"
eq "no kubectl run without r" "$(explore_runs)" "$runs"

xkey r
E2E_WAIT=20 xwait "spec.replicas 2 -> 4" || return
after=$(mc_sides | grep -o 'fetched [0-9:]*' | tr '\n' ' ')
[ "$before" != "$after" ] || fail "fetch times did not move ($before)"
[ "$(($(explore_runs) - runs))" -ge 2 ] || fail "r did not refetch both sides"
explore_close
