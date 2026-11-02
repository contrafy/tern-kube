#!/bin/sh
# Captures kubectl output for the Track 1 verbs (rollout undo/pause/resume,
# patch, label, annotate, cordon, uncordon, drain, edit) into
# tests/fixtures/kubectl/track1/<name>.{txt,stderr,exit} for the preview
# library specs.
#
#   scripts/fixtures/capture-track1.sh
#
# The script builds its own scratch namespace tern-test-t1 (deleted again on
# exit, also on failure), gives the Deployment, DaemonSet and StatefulSet a
# second revision with `kubectl set image` inside it, and then runs only
# read-only commands (`get`, `rollout history`), server/client dry runs and
# offline `patch --local` conversions: nothing outside tern-test-t1 changes,
# and the node is never really cordoned or drained. Drain runs are limited by
# --pod-selector to pods labelled tern-t1=yes and always carry --timeout (a
# PodDisruptionBudget makes a server dry run retry forever without one).
# Every capture is listed with its argv in MANIFEST.tsv. The edit inputs are
# written to edit-input/ and converted from there.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=$ROOT/tests/fixtures/kubectl/track1
MANIFEST=$OUT/MANIFEST.tsv
KUBECTL=${KUBECTL:-kubectl}
CONTEXT=kind-tern-kube-dev
NS=tern-test-t1
NODE=tern-kube-dev-control-plane

die() {
	printf 'capture-track1: %s\n' "$*" >&2
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

# Refuses anything that could persist a change: reads (`get`, `rollout
# history`), dry runs and `--local` only; a namespace flag must name $NS.
guard() {
	words="" dry=0 prev=""
	for arg in "$@"; do
		case $prev in
		-n | --namespace) [ "$arg" = "$NS" ] || die "namespace outside $NS: $arg" ;;
		esac
		case $arg in
		--dry-run=server | --dry-run=client | --local) dry=1 ;;
		--namespace=*) [ "${arg#--namespace=}" = "$NS" ] || die "namespace outside $NS: $arg" ;;
		-*) ;;
		*)
			case $prev in
			--context | -n | --namespace | -p | -l | -f) ;;
			*) words="$words $arg" ;;
			esac
			;;
		esac
		prev=$arg
	done
	case $words in
	" get "* | " rollout history "*) return 0 ;;
	esac
	[ "$dry" = 1 ] || die "refusing non-preview command: $(argv_string "$@")"
}

mismatches=0

# cap NAME EXPECTED_EXIT KUBECTL_ARGS... (context is always pinned)
cap() {
	name=$1 expect=$2
	shift 2
	set -- --context "$CONTEXT" "$@"
	guard "$@"
	base=$OUT/$name
	[ ! -e "$base.txt" ] && [ ! -e "$base.stderr" ] || die "duplicate fixture name $name"
	set +e
	(cd "$OUT" && "$KUBECTL" "$@") >"$base.txt" 2>"$base.stderr"
	status=$?
	set -e
	[ -s "$base.stderr" ] || rm -f "$base.stderr"
	[ -s "$base.txt" ] || rm -f "$base.txt"
	[ "$status" = 0 ] || printf '%s\n' "$status" >"$base.exit"
	printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(argv_string "$@")" "$status" \
		"$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
	if [ "$status" != "$expect" ]; then
		mismatches=$((mismatches + 1))
		printf 'capture-track1: UNEXPECTED exit %s (wanted %s): %s\n' "$status" "$expect" "$(argv_string "$@")" >&2
		[ -f "$base.stderr" ] && sed 's/^/    /' "$base.stderr" >&2
	fi
	return 0
}

cleanup() {
	k delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

k get node "$NODE" >/dev/null || die "node $NODE not found"
if k get namespace "$NS" >/dev/null 2>&1; then
	k delete namespace "$NS" --wait=true --timeout=180s >/dev/null
fi
trap cleanup EXIT
trap 'exit 130' INT TERM

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels: {tern-t1-owner: capture}
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels: {t1app: web}
  template:
    metadata:
      labels: {t1app: web, tern-t1: "yes"}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: c
          image: registry.k8s.io/pause:3.9
          imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: one
  labels: {tern-t1-owner: capture}
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels: {t1app: one}
  template:
    metadata:
      labels: {t1app: one, tern-t1: "yes"}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: c
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
  namespace: $NS
spec:
  minAvailable: 2
  selector:
    matchLabels: {t1app: web}
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ds
  namespace: $NS
spec:
  selector:
    matchLabels: {t1app: ds}
  template:
    metadata:
      labels: {t1app: ds, tern-t1: "yes"}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: c
          image: registry.k8s.io/pause:3.9
          imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
  namespace: $NS
spec:
  replicas: 1
  serviceName: db
  selector:
    matchLabels: {t1app: db}
  template:
    metadata:
      labels: {t1app: db, tern-t1: "yes"}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: c
          image: registry.k8s.io/pause:3.9
          imagePullPolicy: IfNotPresent
---
apiVersion: v1
kind: Pod
metadata:
  name: bare
  namespace: $NS
  labels: {t1app: bare, tern-t1: "yes"}
spec:
  terminationGracePeriodSeconds: 1
  containers:
    - name: c
      image: registry.k8s.io/pause:3.10
      imagePullPolicy: IfNotPresent
---
apiVersion: v1
kind: Pod
metadata:
  name: ed
  namespace: $NS
  labels: {t1app: ed, tern-t1: "yes"}
spec:
  terminationGracePeriodSeconds: 1
  volumes:
    - name: scratch
      emptyDir: {}
  containers:
    - name: c
      image: registry.k8s.io/pause:3.10
      imagePullPolicy: IfNotPresent
      volumeMounts:
        - {name: scratch, mountPath: /scratch}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm
  namespace: $NS
  labels: {a: b}
  annotations: {note: a}
data:
  k: v
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm2
  namespace: $NS
  labels: {a: b}
data:
  k: v
---
apiVersion: v1
kind: Secret
metadata:
  name: creds
  namespace: $NS
type: Opaque
stringData:
  user: fixture-user
  pass: fixture-pass
---
apiVersion: lens.example.com/v1alpha1
kind: Widget
metadata:
  name: w1
  namespace: $NS
spec:
  color: blue
  size: 3
EOF

wait_rollouts() {
	k -n "$NS" rollout status deployment/web --timeout=180s >/dev/null
	k -n "$NS" rollout status deployment/one --timeout=180s >/dev/null
	k -n "$NS" rollout status daemonset/ds --timeout=180s >/dev/null
	k -n "$NS" rollout status statefulset/db --timeout=180s >/dev/null
}

wait_rollouts
k -n "$NS" set image deployment/web c=registry.k8s.io/pause:3.10 >/dev/null
k -n "$NS" set image daemonset/ds c=registry.k8s.io/pause:3.10 >/dev/null
k -n "$NS" set image statefulset/db c=registry.k8s.io/pause:3.10 >/dev/null
wait_rollouts
k -n "$NS" wait --for=condition=Ready pod/bare pod/ed --timeout=180s >/dev/null
# The PDB must have observed both web pods healthy, so the block comes from
# minAvailable and not from an unsettled budget.
i=0
until [ "$(k -n "$NS" get pdb web -o jsonpath='{.status.currentHealthy}')" = 2 ]; do
	i=$((i + 1))
	[ "$i" -le 60 ] || die "PodDisruptionBudget web never saw 2 healthy pods"
	sleep 2
done

rm -rf "$OUT"
mkdir -p "$OUT/edit-input"
printf 'name\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

# Edit inputs: the original as `kubectl edit` writes it (comment header) and
# edited variants, one object, a two-object List, a rename and broken YAML.
cat >"$OUT/edit-input/original.yaml" <<EOF
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: lens.example.com/v1alpha1
kind: Widget
metadata:
  name: w1
  namespace: $NS
  resourceVersion: "1234"
  labels:
    app: widgets
spec:
  color: blue
  size: 3
  ratio: 1.50
  enabled: yes
  tags: []
  extra: {}
  owner: team-a
EOF
cat >"$OUT/edit-input/edited.yaml" <<EOF
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: lens.example.com/v1alpha1
kind: Widget
metadata:
  name: w1
  namespace: $NS
  resourceVersion: "1234"
  labels:
    app: widgets
    tier: gold
spec:
  color: blue
  size: 4
  ratio: 1.50
  enabled: yes
  tags: [a]
  owner: team-a
EOF
cat >"$OUT/edit-input/original-list.yaml" <<EOF
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
items:
- apiVersion: v1
  data:
    k: v
  kind: ConfigMap
  metadata:
    name: cm
    namespace: $NS
    resourceVersion: "100"
- apiVersion: v1
  data:
    k: v
  kind: ConfigMap
  metadata:
    name: cm2
    namespace: $NS
    resourceVersion: "101"
kind: List
metadata:
  resourceVersion: ""
EOF
cat >"$OUT/edit-input/edited-list.yaml" <<EOF
apiVersion: v1
items:
- apiVersion: v1
  data:
    k: "on"
    added: "1"
  kind: ConfigMap
  metadata:
    name: cm
    namespace: $NS
    resourceVersion: "100"
- apiVersion: v1
  data:
    k: v
  kind: ConfigMap
  metadata:
    name: cm2
    namespace: $NS
    resourceVersion: "101"
kind: List
metadata:
  resourceVersion: ""
EOF
cat >"$OUT/edit-input/edited-renamed.yaml" <<EOF
apiVersion: lens.example.com/v1alpha1
kind: Widget
metadata:
  name: w9
  namespace: $NS
  resourceVersion: "1234"
  labels:
    app: widgets
spec:
  color: blue
  size: 3
  ratio: 1.50
  enabled: yes
  tags: []
  extra: {}
  owner: team-a
EOF
cat >"$OUT/edit-input/edited-invalid.yaml" <<EOF
apiVersion: lens.example.com/v1alpha1
kind: Widget
metadata:
  name: w1
  namespace: $NS
spec:
  color: [blue
EOF

# rollout undo: revision lists, target templates, live objects, dry runs
cap rollout-history-deploy 0 rollout history deployment/web -n "$NS"
cap rollout-history-ds 0 rollout history daemonset/ds -n "$NS"
cap rollout-history-sts 0 rollout history statefulset/db -n "$NS"
cap rollout-history-selector 0 rollout history deployment -l tern-t1-owner=capture -n "$NS"
cap rollout-history-deploy-rev1-json 0 rollout history deployment/web --revision=1 -o json -n "$NS"
cap rollout-history-ds-rev1-json 0 rollout history daemonset/ds --revision=1 -o json -n "$NS"
cap rollout-history-sts-rev1-json 0 rollout history statefulset/db --revision=1 -o json -n "$NS"
cap rollout-history-deploy-rev9-json 1 rollout history deployment/web --revision=9 -o json -n "$NS"
cap get-deploy-web-json 0 get deployment/web -o json -n "$NS"
cap get-ds-json 0 get daemonset/ds -o json -n "$NS"
cap get-sts-json 0 get statefulset/db -o json -n "$NS"
cap undo-deploy-server 0 rollout undo deployment/web --dry-run=server -n "$NS"
cap undo-deploy-server-json 0 rollout undo deployment/web --dry-run=server -o json -n "$NS"
cap undo-deploy-to9-server 1 rollout undo deployment/web --to-revision=9 --dry-run=server -n "$NS"
cap undo-single-server 1 rollout undo deployment/one --dry-run=server -n "$NS"
cap undo-ds-server 0 rollout undo daemonset/ds --dry-run=server -n "$NS"
cap undo-sts-server 0 rollout undo statefulset/db --dry-run=server -n "$NS"
cap pause-dry-run 1 rollout pause deployment/web --dry-run=server -n "$NS"

# label / annotate / patch: before (`get -o json`) and after (dry run -o json)
cap get-cm-json 0 get configmap cm cm2 -o json -n "$NS"
cap label-cm-cm2-json 0 label configmap cm cm2 x=y --dry-run=server -o json -n "$NS"
cap label-cm-cm2 0 label configmap cm cm2 x=y --dry-run=server -n "$NS"
cap label-not-labeled 0 label configmap/cm a=b --dry-run=server -n "$NS"
cap label-unlabeled 0 label configmap/cm a- --dry-run=server -n "$NS"
cap label-conflict 1 label configmap/cm a=c --dry-run=server -n "$NS"
cap label-overwrite-json 0 label configmap/cm a=c --overwrite --dry-run=server -o json -n "$NS"
cap label-selector-none 0 label configmap -l a=zzz x=y --dry-run=server -n "$NS"
cap annotate-cm-json 0 annotate configmap/cm note=b --overwrite --dry-run=server -o json -n "$NS"
cap annotate-cm 0 annotate configmap/cm note=b --overwrite --dry-run=server -n "$NS"
cap patch-cm-json 0 patch configmap/cm -p '{"data":{"k":"v2"}}' --dry-run=server -o json -n "$NS"
cap patch-cm 0 patch configmap/cm -p '{"data":{"k":"v2"}}' --dry-run=server -n "$NS"
cap patch-cm-nochange 0 patch configmap/cm -p '{"data":{"k":"v"}}' --dry-run=server -n "$NS"
cap patch-multi-json 0 patch configmap cm cm2 -p '{"data":{"k":"v3"}}' --dry-run=server -o json -n "$NS"
cap patch-deploy-replicas-json 0 patch deployment/web -p '{"spec":{"replicas":3}}' --dry-run=server -o json -n "$NS"
cap get-secret-json 0 get secret/creds -o json -n "$NS"
cap patch-secret-json 0 patch secret/creds -p '{"stringData":{"pass":"rotated"}}' --dry-run=server -o json -n "$NS"
cap get-widget-json 0 get widget/w1 -o json -n "$NS"
cap patch-widget-merge-json 0 patch widget/w1 --type merge -p '{"spec":{"size":4}}' --dry-run=server -o json -n "$NS"
cap patch-widget-strategic 1 patch widget/w1 -p '{"spec":{"size":4}}' --dry-run=server -n "$NS"

# cordon / uncordon (node never really changes)
cap get-node-json 0 get node "$NODE" -o json
cap cordon-server 0 cordon "$NODE" --dry-run=server
cap uncordon-server 0 uncordon "$NODE" --dry-run=server

# drain: client (sorted list, pre-flight policy) and server (Eviction API)
cap drain-client-ok 0 drain "$NODE" --pod-selector=tern-t1=yes --ignore-daemonsets --delete-emptydir-data --force --dry-run=client
cap drain-client-preflight 1 drain "$NODE" --pod-selector=tern-t1=yes --dry-run=client
cap drain-server-preflight 1 drain "$NODE" --pod-selector=tern-t1=yes --dry-run=server --timeout=20s
cap drain-server-ok 0 drain "$NODE" '--pod-selector=tern-t1=yes,t1app!=web' --ignore-daemonsets --delete-emptydir-data --force --dry-run=server --timeout=30s
cap drain-server-pdb-timeout 1 drain "$NODE" --pod-selector=tern-t1=yes --ignore-daemonsets --delete-emptydir-data --force --dry-run=server --timeout=8s
cap drain-server-disable-eviction 1 drain "$NODE" '--pod-selector=tern-t1=yes,t1app!=web' --ignore-daemonsets --delete-emptydir-data --force --disable-eviction --dry-run=server --timeout=6s
cap drain-server-nopods 0 drain "$NODE" --pod-selector=t1app=none --dry-run=server --timeout=10s

# edit: offline manifest -> JSON conversions (the preview's `convert` step)
cap convert-original 0 patch --local --type=merge -p '{}' -f edit-input/original.yaml -o json
cap convert-edited 0 patch --local --type=merge -p '{}' -f edit-input/edited.yaml -o json
cap convert-original-list 0 patch --local --type=merge -p '{}' -f edit-input/original-list.yaml -o json
cap convert-edited-list 0 patch --local --type=merge -p '{}' -f edit-input/edited-list.yaml -o json
cap convert-edited-renamed 0 patch --local --type=merge -p '{}' -f edit-input/edited-renamed.yaml -o json
cap convert-edited-invalid 1 patch --local --type=merge -p '{}' -f edit-input/edited-invalid.yaml -o json

if grep -rlE 'BEGIN (RSA |EC )?PRIVATE KEY|BEGIN CERTIFICATE|client-key-data|client-certificate-data' "$OUT" >/dev/null 2>&1; then
	die "credential material leaked into $OUT"
fi
[ "$mismatches" = 0 ] || die "$mismatches capture(s) exited unexpectedly"
printf '==> captured %s fixtures into %s\n' "$(($(wc -l <"$MANIFEST") - 1))" "$OUT" >&2
