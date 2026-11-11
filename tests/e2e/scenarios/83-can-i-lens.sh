# Live: the can-i lens. Admin `get pods` answers YES; the default service
# account's `delete pods` answers NO without an exit badge (an answer, not a
# failure); `-q` answers from the exit status; an unknown verb answers with
# its warning. A scenario-created ServiceAccount with a Role limited to
# resourceNames tk-e2e-cm lists its rules: Resource Names column, VERB facet,
# Explore chips hidden with a note. Admin --list shows `*.*` as all.
trap 'kc -n "$MNS" delete sa/tk-e2e-limited role/tk-e2e-limited rolebinding/tk-e2e-limited --ignore-not-found >/dev/null 2>&1' EXIT
kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: tk-e2e-limited, namespace: $MNS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: tk-e2e-limited, namespace: $MNS}
rules:
  - {apiGroups: [""], resources: [configmaps], resourceNames: [tk-e2e-cm], verbs: [get, update]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: tk-e2e-limited, namespace: $MNS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: tk-e2e-limited}
subjects: [{kind: ServiceAccount, name: tk-e2e-limited, namespace: $MNS}]
YAML

lens "kubectl --context kind-tern-kube-dev auth can-i get pods -n tern-test-apps"
native
has '[data-role="tern-kube.cani-yes"]' || fail "admin get pods is not YES"
contains "explore chip on yes" "$(alltext '.sf-block *')" "Explore pods"

lens "kubectl --context kind-tern-kube-dev --as=system:serviceaccount:tern-test-apps:default auth can-i delete pods -n tern-test-apps"
native
has '[data-role="tern-kube.cani-no"]' || fail "default SA delete pods is not NO"
lacks '[data-role="tern-kube.exit"]' || fail "a no answer shows an exit badge"
contains "impersonation note" "$(alltext '.sf-block *')" "Explore runs as the context's own user"

lens "kubectl --context kind-tern-kube-dev auth can-i list pods -q"
native
has '[data-role="tern-kube.cani-yes"]' || fail "-q yes not read from the exit status"

lens "kubectl --context kind-tern-kube-dev auth can-i frob pods"
native
has '[data-role="tern-kube.cani-yes"]' || fail "unknown verb not answered"
contains "unknown verb warning" "$(alltext '.sf-block *')" "not a known verb"

lens "kubectl --context kind-tern-kube-dev --as=system:serviceaccount:$MNS:tk-e2e-limited auth can-i --list -n $MNS"
native
contains "resource names column" "$(column_texts 3 4)" "[tk-e2e-cm]"
# Facet groups carry a role, not their key, in the DOM: name them by label.
contains "VERB facet" "$(texts '[data-role="tern-kube.facet-label"]')" '"VERB"'
contains "explore hidden note" "$(alltext '.sf-block *')" "Explore runs as the context's own user"
click_text configmaps '.tk-grid .tk-c'
excludes "no explore chip when impersonating" "$(texts '[data-role="tern-kube.inspector"] .sf-act')" "Explore"

lens "kubectl --context kind-tern-kube-dev auth can-i --list"
native
# The note is a muted span inside the cell: the cell reads "*.* all".
contains "admin wildcard noted all" "$(column_texts 1 4)" '"*.* all"'
contains "all note" "$(texts '.tk-grid .tk-c .sf-t-muted')" '"all"'
