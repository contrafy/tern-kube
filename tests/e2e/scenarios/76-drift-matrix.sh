# Live, two clusters (E2E_MC=1): one GitOps source (a throwaway git repo
# holding tests/integration/manifests/compare/source) against both
# contexts. ctrl+g, the source, x, All contexts: the matrix cells; enter on
# the peer's tkm-web cell opens its drift diff, where a (apply) is refused
# because another context is read-only.
. "$E2E_REPO/tests/e2e/compare.sh"
MREPO=$E2E_SB/mc-repo
trap 'rm -rf "$MREPO"' EXIT

rm -rf "$MREPO"
mkdir -p "$MREPO/apps"
cp "$E2E_REPO/tests/integration/manifests/compare/source/app.yaml" "$MREPO/apps/"
git -C "$MREPO" init -q -b main
git -C "$MREPO" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$MREPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init

sh_line "cd '$MREPO'"
mc_object "$MCA" deploy tkm-web deployment || return
xkey ctrl+g
E2E_WAIT=30 xwait "Drift sources" || return
xkey enter
E2E_WAIT=30 xwait "Drift of" || return
xkey x
E2E_WAIT=15 xwait "All contexts (2)" "[data-role='tern-kube.compare-picker'] *" || return
xkey G enter
E2E_WAIT=40 wait_for "the drift matrix" has "$EX [data-role='tern-kube.explore-matrix']" || return
E2E_WAIT=40 xwait "changed +4 -3" || return
m=$(xtext)
contains "in sync cells" "$m" "in sync"
cells=$(texts "$EX .tk-cmp-grid .tk-c")
contains "tkm-flags missing in $MCB" "$cells" '"missing"'
contains "unmanaged cells (tkm-only-a, tkm-only-b)" "$cells" '"unmanaged"'
contains "absent cells" "$cells" '"-"'
contains "per-column summary" "$(xtext '[data-role="tern-kube.compare-counts"] *')" "changed"

# Rows sort by group/Kind/namespace/name: apps/Deployment tkm-web is last;
# the selected column defaults to the first non-base one (the peer).
xkey G enter
E2E_WAIT=20 xwait "in context $MCB" || return
contains "peer drift diff" "$(xtext)" "nginx:1.28-alpine"
xkey a
contains "read-only across contexts" "$(toast_text)" "Switch to $MCB (c) to change it"
# Six routes deep, and esc at the top asks for a second press.
explore_close_all
sh_line "cd '$E2E_REPO'"
