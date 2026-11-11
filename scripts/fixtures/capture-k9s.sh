#!/bin/sh
# Captures kubectl output for the k9s-parity lens views (rollout history,
# config get-contexts, api-resources, auth can-i) into
# tests/fixtures/kubectl/k9s/<name>.{txt,stderr,exit} for the lens specs.
#
#   scripts/fixtures/capture-k9s.sh
#
# The script builds its own scratch namespace tern-test-k9s (deleted again on
# exit, also on failure): Deployments with several revisions, a DaemonSet, a
# StatefulSet, ConfigMaps and two ServiceAccounts bound only by namespaced
# RoleBindings. No cluster-scoped object is written. The ctx-* captures run
# against a private multi-context kubeconfig in a temp dir (removed on exit),
# passed through the environment so MANIFEST.tsv never contains its path.
# Every capture is listed with its argv in MANIFEST.tsv. Hand-written
# fixtures live in synthetic/ and are left untouched.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=$ROOT/tests/fixtures/kubectl/k9s
MANIFEST=$OUT/MANIFEST.tsv
KUBECTL=${KUBECTL:-kubectl}
CONTEXT=kind-tern-kube-dev
NS=tern-test-k9s
VIEWER=system:serviceaccount:$NS:viewer
LIMITED=system:serviceaccount:$NS:limited

die() {
	printf 'capture-k9s: %s\n' "$*" >&2
	exit 1
}

KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable; run scripts/cluster.sh create"
export KUBECONFIG
KUBERC=off
TMPDIR=/tmp
export KUBERC TMPDIR
unset KUBECTL_EXTERNAL_DIFF KUBECTL_EXPLICIT_LOCAL_PERMISSIONS 2>/dev/null || true

k() {
	"$KUBECTL" --context "$CONTEXT" "$@"
}

version_of() {
	sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n 1
}

CLIENT_VERSION=$(k version --client -o json | version_of)
SERVER_VERSION=$(k get --raw /version | version_of)
[ -n "$CLIENT_VERSION" ] && [ -n "$SERVER_VERSION" ] || die "could not determine kubectl/server versions"

argv_string() {
	line=kubectl
	for arg in "$@"; do
		case $arg in
		*[!A-Za-z0-9_./=:,+-]*) arg="'$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'" ;;
		esac
		line="$line $arg"
	done
	printf '%s' "$line"
}

# Refuses anything but the four read-only verbs captured here.
guard() {
	words="" prev=""
	for arg in "$@"; do
		case $arg in
		-*) ;;
		*)
			case $prev in
			--context | -n | --namespace | -o | -l | --as | --as-group) ;;
			*) words="$words $arg" ;;
			esac
			;;
		esac
		prev=$arg
	done
	case "$words " in
	" rollout history "* | " config get-contexts "* | " api-resources "* | " auth can-i "*) return 0 ;;
	esac
	die "refusing command: $(argv_string "$@")"
}

mismatches=0

# run_cap NAME EXPECTED_EXIT KUBECONFIG_FILE KUBECTL_ARGS... (args verbatim)
run_cap() {
	name=$1 expect=$2 kc=$3
	shift 3
	guard "$@"
	base=$OUT/$name
	[ ! -e "$base.txt" ] && [ ! -e "$base.stderr" ] || die "duplicate fixture name $name"
	set +e
	(cd "$OUT" && KUBECONFIG=$kc "$KUBECTL" "$@") >"$base.txt" 2>"$base.stderr"
	status=$?
	set -e
	[ -s "$base.stderr" ] || rm -f "$base.stderr"
	[ -s "$base.txt" ] || rm -f "$base.txt"
	[ "$status" = 0 ] || printf '%s\n' "$status" >"$base.exit"
	printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(argv_string "$@")" "$status" \
		"$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
	if [ "$status" != "$expect" ]; then
		mismatches=$((mismatches + 1))
		printf 'capture-k9s: UNEXPECTED exit %s (wanted %s): %s\n' "$status" "$expect" "$(argv_string "$@")" >&2
		[ -f "$base.stderr" ] && sed 's/^/    /' "$base.stderr" >&2
	fi
	return 0
}

# cap NAME EXPECTED_EXIT KUBECTL_ARGS... (sandbox kubeconfig, context pinned)
cap() {
	name=$1 expect=$2
	shift 2
	run_cap "$name" "$expect" "$KUBECONFIG" --context "$CONTEXT" "$@"
}

# capctx NAME EXPECTED_EXIT KUBECONFIG_FILE KUBECTL_ARGS... (no pinned context)
capctx() {
	run_cap "$@"
}

# expanded NAME: tab-expanded copy of a --revision text capture
expanded() {
	expand -t 8 "$OUT/$1.txt" >"$OUT/$1.expanded.txt"
}

TMPKC=""
cleanup() {
	[ -z "$TMPKC" ] || rm -rf "$TMPKC"
	k delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
}

if k get namespace "$NS" >/dev/null 2>&1; then
	k delete namespace "$NS" --wait=true --timeout=180s >/dev/null
fi
trap cleanup EXIT
trap 'exit 130' INT TERM

k get crd widgets.lens.example.com >/dev/null 2>&1 ||
	k apply -f "$ROOT/tests/integration/manifests/crd/crd.yaml" >/dev/null

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hist
  namespace: $NS
  labels: {app: hist}
  annotations:
    kubernetes.io/change-cause: initial pause 3.10
spec:
  replicas: 1
  selector:
    matchLabels: {app: hist}
  template:
    metadata:
      labels: {app: hist}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fresh
  namespace: $NS
  labels: {app: fresh}
spec:
  replicas: 1
  selector:
    matchLabels: {app: fresh}
  template:
    metadata:
      labels: {app: fresh}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds
  namespace: $NS
spec:
  selector:
    matchLabels: {app: ds}
  template:
    metadata:
      labels: {app: ds}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sts
  namespace: $NS
spec:
  replicas: 1
  serviceName: sts
  selector:
    matchLabels: {app: sts}
  template:
    metadata:
      labels: {app: sts}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: $NS
spec:
  selector: {app: hist}
  ports:
    - port: 80
---
apiVersion: v1
kind: ConfigMap
metadata: {name: cm-a, namespace: $NS}
data: {k: a}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: cm-b, namespace: $NS}
data: {k: b}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: cm-c, namespace: $NS}
data: {k: c}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: viewer, namespace: $NS}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: limited, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: viewer-view, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
subjects:
  - {kind: ServiceAccount, name: viewer, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: limited, namespace: $NS}
rules:
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [cm-a, cm-b]
    verbs: [get, update]
  - apiGroups: [apps]
    resources: [deployments/scale]
    verbs: [patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: limited, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: limited}
subjects:
  - {kind: ServiceAccount, name: limited, namespace: $NS}
EOF

status_of() {
	k -n "$NS" rollout status "$1" --timeout=180s >/dev/null
}

status_of deployment/hist
status_of deployment/fresh
status_of daemonset/ds
status_of statefulset/sts
# Annotating after the template change keeps revision 1's cause: the
# controller copies the cause onto the newest ReplicaSet only.
k -n "$NS" set image deploy/hist pause=registry.k8s.io/pause:3.9 >/dev/null
k -n "$NS" annotate --overwrite deploy/hist "kubernetes.io/change-cause=downgrade to 3.9 (it's a test)" >/dev/null
status_of deployment/hist
k -n "$NS" set env deploy/hist MODE=x >/dev/null
status_of deployment/hist
# One DaemonSet revision that changes both the image and the environment.
k -n "$NS" patch daemonset/ds -p '{"spec":{"template":{"spec":{"containers":[{"name":"pause","image":"registry.k8s.io/pause:3.9","env":[{"name":"A","value":"1"}]}]}}}}' >/dev/null
k -n "$NS" set image statefulset/sts pause=registry.k8s.io/pause:3.9 >/dev/null
status_of daemonset/ds
status_of statefulset/sts
DS_POD=$(k -n "$NS" get pods -l app=ds -o jsonpath='{.items[0].metadata.name}')
[ -n "$DS_POD" ] || die "no ds pod"

# Private multi-context kubeconfig (never the sandbox file itself).
TMPKC=$(mktemp -d)
MULTI=$TMPKC/multi.kubeconfig
EMPTY=$TMPKC/empty.kubeconfig
k config view --raw --minify --flatten >"$MULTI"
printf 'apiVersion: v1\nkind: Config\n' >"$EMPTY"
kc() {
	"$KUBECTL" config --kubeconfig "$MULTI" "$@" >/dev/null
}
kc set-context tk-apps --cluster="$CONTEXT" --user="$CONTEXT" --namespace=tern-test-apps
kc set-context "tk spaced" --cluster="$CONTEXT" --user="$CONTEXT"
kc set-context tk-broken --cluster=nowhere --user=nobody --namespace=x
kc set-context "arn:aws:eks:us-east-1:123456789012:cluster/prod" --cluster="$CONTEXT" --user="$CONTEXT"
kc use-context "$CONTEXT"

mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -type f -exec rm -f {} +
printf 'name\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

# rollout history
cap rh-deploy 0 -n "$NS" rollout history deployment/hist
cap rh-deploy-rev2 0 -n "$NS" rollout history deployment/hist --revision=2
expanded rh-deploy-rev2
cap rh-deploy-rev3 0 -n "$NS" rollout history deployment/hist --revision=3
expanded rh-deploy-rev3
cap rh-deploy-rev2-json 0 -n "$NS" rollout history deployment/hist --revision=2 -o json
cap rh-deploy-rev2-yaml 0 -n "$NS" rollout history deployment/hist --revision=2 -o yaml
cap rh-deploy-json 0 -n "$NS" rollout history deployment/hist -o json
cap rh-deploy-name 0 -n "$NS" rollout history deployment/hist -o name
cap rh-multi 0 -n "$NS" rollout history deployment/hist deployment/fresh
cap rh-all-deploy 0 -n "$NS" rollout history deployment
cap rh-selector 0 -n "$NS" rollout history deployment -l app=hist
cap rh-ds 0 -n "$NS" rollout history daemonset/ds
cap rh-ds-rev2 0 -n "$NS" rollout history ds/ds --revision=2
expanded rh-ds-rev2
cap rh-ds-name 0 -n "$NS" rollout history daemonset/ds -o name
cap rh-sts 0 -n "$NS" rollout history statefulset/sts
cap rh-sts-rev1 0 -n "$NS" rollout history statefulset/sts --revision=1
expanded rh-sts-rev1
cap rh-sts-json 0 -n "$NS" rollout history statefulset/sts --revision=1 -o json
cap rh-notfound 1 -n "$NS" rollout history deployment/nope
cap rh-pod 1 -n "$NS" rollout history "pod/$DS_POD"
cap rh-svc 1 -n "$NS" rollout history svc/web
cap rh-noresource 1 -n "$NS" rollout history
cap rh-bad-revision 1 -n "$NS" rollout history deployment/hist --revision=99
k -n "$NS" rollout undo deployment/hist --to-revision=1 >/dev/null
status_of deployment/hist
cap rh-after-undo 0 -n "$NS" rollout history deployment/hist
cap rh-after-undo-rev1 1 -n "$NS" rollout history deployment/hist --revision=1

# config get-contexts (private kubeconfig via the environment)
capctx ctx-default 0 "$MULTI" config get-contexts
capctx ctx-flag-context 0 "$MULTI" --context tk-apps config get-contexts
capctx ctx-noheaders 0 "$MULTI" config get-contexts --no-headers
capctx ctx-name 0 "$MULTI" config get-contexts -o name
capctx ctx-one 0 "$MULTI" config get-contexts tk-apps
capctx ctx-missing 1 "$MULTI" config get-contexts nope
capctx ctx-yaml 1 "$MULTI" config get-contexts -o yaml
capctx ctx-empty 0 "$EMPTY" config get-contexts

# api-resources
cap ar-default 0 api-resources
cap ar-wide 0 api-resources -o wide
cap ar-name 0 api-resources -o name
cap ar-noheaders 0 api-resources --no-headers
cap ar-namespaced 0 api-resources --namespaced=false
cap ar-apps 0 api-resources --api-group=apps -o wide
cap ar-badgroup 0 api-resources --api-group=nope.example.com
cap ar-explore-wide 0 api-resources --verbs=list -o wide
cap ar-json 0 api-resources -o json
cap ar-cat-lens 0 api-resources --categories=lens -o wide

# auth can-i
cap ci-yes 0 auth can-i get pods -n "$NS"
cap ci-yes-as 0 --as="$VIEWER" -n "$NS" auth can-i list pods
cap ci-no-as 1 --as="$VIEWER" -n "$NS" auth can-i delete pods
cap ci-quiet-yes 0 auth can-i list pods -q -n "$NS"
cap ci-quiet-no 1 --as="$VIEWER" -n default auth can-i list pods -q
cap ci-unknown 0 auth can-i get frobs
cap ci-unknownverb 0 auth can-i frob pods
cap ci-star 0 auth can-i '*' '*'
cap ci-star-as 1 --as="$VIEWER" auth can-i '*' '*'
cap ci-sub 0 --as="$VIEWER" -n "$NS" auth can-i get pods --subresource=log
cap ci-slash 0 --as="$VIEWER" -n "$NS" auth can-i get pods/log
cap ci-nonres 0 --as="$VIEWER" auth can-i get /healthz
cap ci-name-yes 0 --as="$LIMITED" -n "$NS" auth can-i get configmap/cm-a
cap ci-name-no 1 --as="$LIMITED" -n "$NS" auth can-i get configmap/cm-c
cap ci-scale-sub 0 --as="$LIMITED" -n "$NS" auth can-i patch deployments --subresource=scale
cap ci-group 1 --as=nobody --as-group=system:authenticated auth can-i get pods
cap ci-noargs 1 auth can-i
cap ci-list 0 auth can-i --list
cap ci-list-as 0 --as="$VIEWER" -n "$NS" auth can-i --list
cap ci-list-names 0 --as="$LIMITED" -n "$NS" auth can-i --list
cap ci-list-as-noheaders 0 --as="$VIEWER" -n "$NS" auth can-i --list --no-headers
cap ci-list-A 1 --as="$VIEWER" auth can-i --list -A
cap ci-list-json 1 --as="$VIEWER" -n "$NS" auth can-i --list -o json

if grep -rlE 'BEGIN CERTIFICATE|client-key-data|certificate-authority-data|token:|eyJ' "$OUT" >/dev/null 2>&1; then
	die "credential material leaked into $OUT"
fi
[ "$mismatches" = 0 ] || die "$mismatches capture(s) exited unexpectedly"
printf '==> captured %s fixtures into %s\n' "$(($(wc -l <"$MANIFEST") - 1))" "$OUT" >&2
