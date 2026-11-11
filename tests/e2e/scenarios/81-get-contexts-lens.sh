# Live: the get-contexts lens over a private kubeconfig copy (tk-e2e-apps with
# namespace tern-test-apps and a spaced name). The current context carries a
# note, the spaced row stays one row, and "Explore in this context" opens
# Explore on tk-e2e-apps chosen but not confirmed, in tern-test-apps, where the
# web pods list. `-o name` and a missing context close it. The kubeconfig is
# never written.
INS='[data-role="tern-kube.inspector"] .sf-act'
KCFG=$(mktemp -d)/config
trap 'rm -rf "$(dirname "$KCFG")"' EXIT
kc config view --raw --minify --flatten >"$KCFG"
kubectl --kubeconfig "$KCFG" config set-context tk-e2e-apps --cluster=kind-tern-kube-dev \
	--user=kind-tern-kube-dev --namespace=tern-test-apps >/dev/null
kubectl --kubeconfig "$KCFG" config set-context "tk e2e spaced" --cluster=kind-tern-kube-dev \
	--user=kind-tern-kube-dev >/dev/null
sum=$(cksum <"$KCFG")

lens "kubectl --kubeconfig $KCFG config get-contexts"
native
contains "current context noted" "$(alltext)" "current"
eq "spaced name is one row" "$(column_texts 2 5)" '["kind-tern-kube-dev","tk e2e spaced","tk-e2e-apps"]'

click_text tk-e2e-apps '.tk-grid .tk-c'
eq "contexts chips" "$(texts "$INS")" '["Inspect","Explore in this context","Copy name","Close"]'
click_text "Explore in this context" "$INS"
explore_open || return
contains "Explore on the picked context" "$(xtext)" "tk-e2e-apps"
contains "picked, not confirmed" "$(xtext)" "chosen"
contains "row namespace" "$(xtext)" "tern-test-apps"
E2E_WAIT=20 xwait "web" '.tk-grid *' || return
explore_close

lens "kubectl --kubeconfig $KCFG config get-contexts -o name"
native
eq "-o name rows" "$(column_texts 1 1)" '["kind-tern-kube-dev","tk e2e spaced","tk-e2e-apps"]'
lens "kubectl --kubeconfig $KCFG config get-contexts nope"
native
contains "missing context error" "$(alltext)" "context nope not found"
eq "kubeconfig unchanged" "$(cksum <"$KCFG")" "$sum"
