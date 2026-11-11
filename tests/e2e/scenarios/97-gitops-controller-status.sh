# Argo CD status without a running controller: the vendored CRDs
# (scripts/fixtures/gitops-crds.sh, removed on exit only when this run
# installed them) and one Application whose status is written by hand,
# deploying apps/ of a throwaway repository whose origin matches its
# repoURL. The source chooser counts the controller, the report shows its
# status card and the self-heal revert risk, and the drifted object's view
# names the owning app. Objects in tern-test-gitops-ctl-e2e.
GNS=tern-test-gitops-ctl-e2e
RREPO=$E2E_SB/ctl-repo
CRD_MARK=$E2E_SB/gitops-crds.installed
REMOTE=https://github.com/example/tk-e2e-ctl.git
ctl_cleanup() {
	kc delete namespace "$GNS" --ignore-not-found --wait=false >/dev/null 2>&1
	rm -rf "$RREPO"
	"$E2E_REPO/scripts/fixtures/gitops-crds.sh" remove-if-installed "$CRD_MARK" >/dev/null 2>&1
}
trap ctl_cleanup EXIT

"$E2E_REPO/scripts/fixtures/gitops-crds.sh" install "$CRD_MARK" >/dev/null || {
	fail "gitops CRDs did not install"
	return 1
}

rm -rf "$RREPO"
mkdir -p "$RREPO/apps"
cat >"$RREPO/apps/web.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tk-e2e-ctl-web
  namespace: $GNS
  labels:
    app.kubernetes.io/instance: ${GNS}_tk-e2e-app
data:
  mode: production
EOF
git -C "$RREPO" init -q -b main
git -C "$RREPO" remote add origin "$REMOTE"
git -C "$RREPO" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$RREPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init

kc create namespace "$GNS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$RREPO/apps/web.yaml" >/dev/null
kc -n "$GNS" patch configmap tk-e2e-ctl-web --type merge -p '{"data":{"mode":"debug"}}' >/dev/null
# The Application CRD has no status subresource: status applies as written.
kc apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tk-e2e-app
  namespace: $GNS
spec:
  project: default
  source:
    repoURL: $REMOTE
    path: apps
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: $GNS
  syncPolicy:
    automated:
      selfHeal: true
status:
  sync:
    status: OutOfSync
  health:
    status: Healthy
EOF

sh_line "cd '$RREPO'"
lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-ctl-web -n $GNS"
native
click_text tk-e2e-ctl-web '.tk-grid .tk-c'
click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act'
explore_open || return
xwait "tk-e2e-ctl-web" || return

xkey ctrl+g
E2E_WAIT=30 xwait "Drift sources" || return
E2E_WAIT=30 xwait "Argo CD / Flux controller" || return
contains "chooser counts the controller" "$(xtext)" "1 Argo CD / Flux controller"
xkey enter
E2E_WAIT=30 xwait "Drift of" || return
E2E_WAIT=30 wait_for "the controller card" has "$EX [data-role='tern-kube.gitops-controller-status']" || return
card=$(xtext "[data-role='tern-kube.gitops-controller-status'] *")
contains "card names the app" "$card" "Argo CD app tk-e2e-app"
contains "card shows sync status" "$card" "OutOfSync"
contains "self-heal revert risk" "$(xtext "[data-role='tern-kube.gitops-controller-risk'] *")" \
	"Argo CD self-heal is on: changes applied outside Git are reverted"

# esc leaves the report for the object view it was opened from.
xkey escape
E2E_WAIT=20 wait_for "the object's controller line" has "$EX [data-role='tern-kube.gitops-controller']" || return
contains "object line names the owner" "$(xtext "[data-role='tern-kube.gitops-controller'] *")" "Argo CD app tk-e2e-app"

explore_close_all
sh_line "cd '$E2E_REPO'"
