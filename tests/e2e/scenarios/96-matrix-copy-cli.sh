# Live, two clusters (E2E_MC=1): the drift matrix's "Copy CLI command"
# chip copies one tern-kube-drift command with a --context per column, base
# first, and the toast lists objects the CLI also reports as unmanaged
# (declared elsewhere in the repository).
[ "${E2E_MC:-0}" = 1 ] || {
	note "skipped: needs the peer cluster (E2E_MC=1)"
	return 0
}
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
contains "matrix offers the copy chip" "$(xtext)" "Copy CLI command"

click_text 'Copy CLI command*' || return
mc_copied() { case $(toast_text) in *"Copied tern-kube-drift command"*) true ;; *) false ;; esac; }
E2E_WAIT=10 wait_for "the copy toast" mc_copied || return
cmd=$(clip)
contains "command names the CLI" "$cmd" "tern-kube-drift"
contains "base context first" "$cmd" "--context $MCA --context $MCB"
excludes "no deployed-values refusal for a manifest source" "$(toast_text)" "renders only with values files"

explore_close_all
sh_line "cd '$E2E_REPO'"
