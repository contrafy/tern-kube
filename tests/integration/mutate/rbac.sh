#!/bin/sh
# RBAC fixtures for the mutation integration tests: ServiceAccounts in
# tern-test-mutate and short-lived kubeconfigs for them in .sandbox/rbac/.
#
#   tests/integration/mutate/rbac.sh create   apply SAs/Roles, write kubeconfigs
#   tests/integration/mutate/rbac.sh delete   remove them
#
#   kl-readonly     get/list/watch only: every server dry run is Forbidden
#                   (the "deny dry-run" and "deny apply" cases)
#   kl-no-delete    get/list/watch/create/patch/update but not delete: apply
#                   previews pass, delete previews are Forbidden
#
# Only touches the kind cluster through .sandbox/kubeconfig (verified by
# scripts/cluster.sh) and only namespace tern-test-mutate.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
KC=$(sh "$ROOT/scripts/cluster.sh" kubeconfig-path)
CTX=kind-kube-lens-dev
NS=tern-test-mutate
OUT=$ROOT/.sandbox/rbac

k() {
	KUBECONFIG=$KC kubectl --kubeconfig "$KC" --context "$CTX" "$@"
}

manifest() {
	cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kl-readonly
  namespace: $NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kl-no-delete
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kl-readonly
  namespace: $NS
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kl-no-delete
  namespace: $NS
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kl-readonly
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kl-readonly
subjects:
  - kind: ServiceAccount
    name: kl-readonly
    namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kl-no-delete
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kl-no-delete
subjects:
  - kind: ServiceAccount
    name: kl-no-delete
    namespace: $NS
EOF
}

kubeconfig_for() { # SA
	server=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
	ca=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
	token=$(k -n "$NS" create token "$1" --duration=2h)
	umask 077
	cat >"$OUT/$1.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: kind-kube-lens-dev
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: $1
    user:
      token: $token
contexts:
  - name: $1@kind-kube-lens-dev
    context:
      cluster: kind-kube-lens-dev
      user: $1
      namespace: $NS
current-context: $1@kind-kube-lens-dev
EOF
	echo "$OUT/$1.kubeconfig"
}

case ${1:-} in
create)
	mkdir -p "$OUT"
	manifest | k apply -f -
	kubeconfig_for kl-readonly
	kubeconfig_for kl-no-delete
	;;
delete)
	manifest | k delete --ignore-not-found -f -
	rm -f "$OUT/kl-readonly.kubeconfig" "$OUT/kl-no-delete.kubeconfig"
	;;
*)
	echo "usage: $0 create|delete" >&2
	exit 2
	;;
esac
