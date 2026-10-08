# GitOps against a throwaway git repository (never the user's): diff a live
# ConfigMap that drifted from its manifest (lens chip, two clicks), a drift
# report with changed / missing / unmanaged objects, export of the unmanaged
# object into the repository, and a branch + commit (no push, no PR).
# Objects live in tern-test-gitops-ui and are deleted at the end.
GNS=tern-test-gitops-ui
GREPO=$E2E_SB/gitops-repo
gitops_cleanup() {
	kc delete namespace "$GNS" --ignore-not-found --wait=false >/dev/null 2>&1
	rm -rf "$GREPO" "$GREPO.git"
}
trap gitops_cleanup EXIT

rm -rf "$GREPO" "$GREPO.git"
mkdir -p "$GREPO/apps"
cp "$E2E_REPO"/tests/e2e/gitops/ui/*.yaml "$GREPO/apps/"
git -C "$GREPO" init -q -b main
git -C "$GREPO" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$GREPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init
git init -q --bare "$GREPO.git"
git -C "$GREPO" remote add origin "$GREPO.git"
git -C "$GREPO" config user.name e2e
git -C "$GREPO" config user.email e2e@example.invalid

kc create namespace "$GNS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "$GREPO/apps/web.yaml" -f "$GREPO/apps/service.yaml" >/dev/null
kc -n "$GNS" patch configmap web-config --type merge -p '{"data":{"mode":"debug"}}' >/dev/null
kc -n "$GNS" create configmap tk-e2e-stray --from-literal=a=b >/dev/null

sh_line "cd '$GREPO'"
lens "kubectl --context kind-tern-kube-dev get configmap web-config -n $GNS"
native
click_text web-config '.tk-grid .tk-c'
click_text 'Diff vs manifest' '[data-role="tern-kube.inspector"] .sf-act'
explore_open || return
E2E_WAIT=30 xwait "MODIFY" || return
contains "diff shows the live drift" "$(xtext '[data-role="tern-kube.gitops-diff"] *')" "debug"
contains "diff shows the manifest value" "$(xtext '[data-role="tern-kube.gitops-diff"] *')" "production"

xkey ctrl+g
E2E_WAIT=30 xwait "Drift sources" || return
contains "repository indexed" "$(xtext)" "4 manifests in 3 files"
xkey enter
E2E_WAIT=30 xwait "Drift of" || return
E2E_WAIT=30 xwait "Missing in cluster" || return
report=$(xtext)
contains "changed object" "$report" "web-config"
contains "missing object" "$report" "pending"
contains "unmanaged object" "$report" "tk-e2e-stray"

explore_close
lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-stray -n $GNS"
click_text tk-e2e-stray '.tk-grid .tk-c'
click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act'
explore_open || return
xwait "tk-e2e-stray" || return
xkey E
E2E_WAIT=20 xwait "Write 4 files" || return
contains "default layout for a repository without one" "$(xtext)" "<namespace>/<kind>/<name>.yaml"
xkey w
xwait "Write 4 files under" || return
xkey y
E2E_WAIT=20 xwait "Wrote 4 files" || return
f=$(git -C "$GREPO" status --porcelain -uall | sed -n 's/^?? //p' | grep 'configmap/tk-e2e-stray' | head -1)
contains "export wrote the object's file" "$f" "manifests/$GNS/configmap/tk-e2e-stray"
exported=$(cat "$GREPO/$f" 2>/dev/null)
contains "export kept the data" "$exported" "a: b"
excludes "export dropped server fields" "$exported" "resourceVersion"
excludes "export dropped the uid" "$exported" "uid:"

xkey b
E2E_WAIT=20 xwait "Run " || return
contains "push is off by default" "$(xtext)" "Push: off"
contains "pull request is off by default" "$(xtext)" "Pull request: off"
xkey enter
E2E_WAIT=20 xwait "Done: committed on" || return
eq "commit made on a new branch" "$(git -C "$GREPO" rev-list --count HEAD)" 2
contains "commit holds the export" "$(git -C "$GREPO" show --name-only --format= HEAD)" "tk-e2e-stray"
eq "nothing pushed" "$(git -C "$GREPO.git" for-each-ref --count=1 refs/heads | wc -l | tr -d ' ')" 0
explore_close
sh_line "cd '$E2E_REPO'"
