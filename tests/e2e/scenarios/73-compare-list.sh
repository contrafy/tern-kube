# Live, two clusters (E2E_MC=1): the Deployments list of tern-test-mc
# compared: one row per object, a column per context, f filters, and enter
# opens the pairwise diff from the fetched lists without running kubectl.
. "$E2E_REPO/tests/e2e/compare.sh"

MATRIX="[data-role='tern-kube.compare-matrix']"

mc_object "$MCA" deploy tkm-web deployment || return
xkey escape
xwait 'tkm-api' "$XT *" || return
mc_pick_first || return
E2E_WAIT=20 wait_for "the list matrix" has "$EX $MATRIX" || return
E2E_WAIT=20 xwait "changed" "$MATRIX *" || return
cells=$(mc_cells compare-matrix)
contains "tkm-api is same" "$cells" '"same"'
contains "tkm-web is changed" "$cells" '"changed"'
contains "tkm-only-a is missing" "$cells" '"missing"'
contains "tkm-only-b is extra" "$cells" '"extra"'
contains "counts line" "$(xtext '[data-role="tern-kube.compare-counts"] *')" "1 same, 1 changed, 1 missing, 1 extra"

# f: differs only (same rows hidden), then presence, then all again.
xkey f
cells=$(mc_cells compare-matrix)
excludes "f (differs) hides same rows" "$cells" '"same"'
contains "f (differs) keeps changed rows" "$cells" '"changed"'
xkey f
cells=$(mc_cells compare-matrix)
excludes "f (missing or extra) hides changed rows" "$cells" '"changed"'
contains "f (missing or extra) keeps missing rows" "$cells" '"missing"'
xkey f
contains "f (all) shows every row again" "$(mc_cells compare-matrix)" '"same"'

# /: the tkm-web row, enter: the pairwise diff from the lists already fetched.
xkey /
ctl type tkm-web >/dev/null
xkey enter
runs=$(explore_runs)
xkey enter
E2E_WAIT=10 xwait "differs" '[data-role="tern-kube.compare-status"] *' || return
contains "drill-in diff" "$(xtext)" "spec.replicas 2 -> 3"
eq "enter ran no kubectl" "$(explore_runs)" "$runs"
explore_close
