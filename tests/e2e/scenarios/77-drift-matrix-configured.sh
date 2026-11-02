# Live, two clusters (E2E_MC=1): compare.contexts adds a "Configured" row
# to the picker of both features; a name the kubeconfig does not have is
# flagged, not dropped.
. "$E2E_REPO/tests/e2e/compare.sh"
MREPO=$E2E_SB/mc-repo
trap 'rm -rf "$MREPO"; config_reset' EXIT

set_config '{"schema_version": 1, "compare": {"contexts": ["kind-tern-kube-dev2", "tk-e2e-nope"]}}'

rm -rf "$MREPO"
mkdir -p "$MREPO/apps"
cp "$E2E_REPO/tests/integration/manifests/compare/source/app.yaml" "$MREPO/apps/"
git -C "$MREPO" init -q -b main
git -C "$MREPO" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$MREPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init

sh_line "cd '$MREPO'"
mc_object "$MCA" deploy tkm-web deployment || return
xkey x
E2E_WAIT=15 xwait "Configured: kind-tern-kube-dev2, tk-e2e-nope" "[data-role='tern-kube.compare-picker'] *" || return
contains "unknown name flagged in Explore" "$(xtext "[data-role='tern-kube.compare-picker'] *")" "not in this kubeconfig: tk-e2e-nope"
xkey escape
xkey ctrl+g
E2E_WAIT=30 xwait "Drift sources" || return
xkey enter
E2E_WAIT=30 xwait "Drift of" || return
xkey x
E2E_WAIT=15 xwait "Configured: kind-tern-kube-dev2, tk-e2e-nope" "[data-role='tern-kube.compare-picker'] *" || return
contains "unknown name flagged in GitOps" "$(xtext "[data-role='tern-kube.compare-picker'] *")" "not in this kubeconfig: tk-e2e-nope"
explore_close
sh_line "cd '$E2E_REPO'"
