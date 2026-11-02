# Live, two clusters (E2E_MC=1): an object present on one side only.
# tkm-only-a compared from kind-tern-kube-dev is missing in dev2; tkm-only-b
# compared from kind-tern-kube-dev2 is missing in dev. Read-only.
. "$E2E_REPO/tests/e2e/compare.sh"

mc_object "$MCA" deploy tkm-only-a deployment || return
mc_pick_first || return
E2E_WAIT=20 xwait "missing in $MCB" '[data-role="tern-kube.compare-status"] *' || return
contains "present side shown" "$(xtext)" "tkm-only-a"
explore_close

# From the peer: the picker's only other context is kind-tern-kube-dev.
mc_object "$MCB" deploy tkm-only-b deployment || return
xkey x
E2E_WAIT=15 wait_for "the picker" has "$EX [data-role='tern-kube.compare-picker']" || return
contains "picker offers the base cluster" "$(xtext "[data-role='tern-kube.compare-picker'] *")" "$MCA"
xkey enter
E2E_WAIT=20 xwait "missing in $MCA" '[data-role="tern-kube.compare-status"] *' || return
contains "base is the peer" "$(mc_sides)" "base $MCB"
explore_close
