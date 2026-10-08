# Live: -o yaml of a Secret, values masked natively.
lens 'kubectl get secret app-secret -n tern-test-apps -o yaml'
native
has '[data-role="tern-kube.yaml"]' || fail "no yaml view"
contains "banner" "$(alltext '.sf-block-body .sf-text')" "Secret values are masked"
secret=$(KUBECONFIG=$E2E_KUBECONFIG "$E2E_REAL_KUBECTL" get secret app-secret -n tern-test-apps -o 'jsonpath={.data.password}')
[ -n "$secret" ] || fail "secret has no data.password"
code=$(alltext '.sf-block-body .sf-code')
contains "masked value" "$code" "<redacted"
excludes "base64 value" "$code" "$secret"
excludes "last-applied stringData" "$code" "tern-kube-test-not-a-secret"
