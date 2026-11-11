# GitOps drift report: Y copies the equivalent tern-kube-drift command
# (-R for a recursive directory source, -n for namespace-less documents
# when the rest agree), and the toast carries the command's notes. A
# throwaway git repository; objects in tern-test-gitops-cli-e2e, deleted on
# exit.
GNS=tern-test-gitops-cli-e2e
CREPO=$E2E_SB/cli-repo
cli_cleanup() {
	kc delete namespace "$GNS" --ignore-not-found --wait=false >/dev/null 2>&1
	rm -rf "$CREPO"
}
trap cli_cleanup EXIT

rm -rf "$CREPO"
mkdir -p "$CREPO/apps/sub"
cat >"$CREPO/apps/web.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tk-e2e-cli-web
  namespace: $GNS
data:
  mode: production
EOF
# No namespace: the report resolves it in the target's namespace, so the
# command pins it with -n.
cat >"$CREPO/apps/sub/plain.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tk-e2e-cli-plain
data:
  a: b
EOF
git -C "$CREPO" init -q -b main
git -C "$CREPO" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$CREPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init

kc create namespace "$GNS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$CREPO/apps/web.yaml" >/dev/null
kc -n "$GNS" patch configmap tk-e2e-cli-web --type merge -p '{"data":{"mode":"debug"}}' >/dev/null

sh_line "cd '$CREPO'"
lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-cli-web -n $GNS"
native
click_text tk-e2e-cli-web '.tk-grid .tk-c'
click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act'
explore_open || return
xwait "tk-e2e-cli-web" || return
xkey ctrl+g
E2E_WAIT=30 xwait "Drift sources" || return
xkey enter
E2E_WAIT=30 xwait "Drift of" || return
E2E_WAIT=30 xwait "Missing in cluster" || return
contains "copy chip listed" "$(xtext)" "Copy CLI command (Y)"

cli_toast() { alltext '.toast span' | tr '\n' ' '; }
cli_copied() { case $(cli_toast) in *"Copied tern-kube-drift command"*) true ;; *) false ;; esac; }
xkey Y
E2E_WAIT=10 wait_for "the copy toast" cli_copied || return
cmd=$(clip)
contains "command names the CLI" "$cmd" "tern-kube-drift"
contains "recursive directory source" "$cmd" "-R -f"
contains "namespace-less documents pinned" "$cmd" "-n $GNS"
contains "context pinned" "$cmd" "kind-tern-kube-dev"
# The lens pane's kubeconfig is known (pane record), so the command pins it
# and the toast has no "uses your shell's KUBECONFIG" note (design rule 5).
contains "kubeconfig pinned" "$cmd" "--kubeconfig $E2E_KUBECONFIG"
excludes "no shell KUBECONFIG note" "$(cli_toast)" "your shell's KUBECONFIG"

explore_close_all
sh_line "cd '$E2E_REPO'"
