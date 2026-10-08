#!/bin/sh
# Rebuilds the fixture world on the disposable kind cluster and captures real
# kubectl output into tests/fixtures/real/<scenario>/<key>.{txt,stderr,exit}.
#
#   scripts/fixtures/capture.sh          delete and rebuild every tern-test-* namespace, then capture
#   scripts/fixtures/capture.sh --reuse  keep the existing world (faster; ages and restart counts drift)
#
# Keys follow tests/bin/kubectl: argv minus connection flags (--context,
# --kubeconfig, -n/--namespace, --cluster, --user), joined by "_", "/" -> "+".
# Because -n is dropped from keys, each namespace gets its own scenario dir.
# Every fixture is listed in tests/fixtures/real/MANIFEST.tsv with its full argv.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFESTS=$ROOT/tests/integration/manifests
OUT=$ROOT/tests/fixtures/real
MANIFEST=$OUT/MANIFEST.tsv
KIND=${KIND:-$ROOT/.tools/bin/kind}
KUBECTL=${KUBECTL:-kubectl}
CLUSTER=kube-lens-dev
NODE=$CLUSTER-control-plane
IMAGES="registry.k8s.io/pause:3.10 busybox:1.37 registry.k8s.io/metrics-server/metrics-server:v0.9.0"

APPS=tern-test-apps
BATCH=tern-test-batch
CRDNS=tern-test-crd
EDGE=tern-test-edge
EMPTY=tern-test-empty
MUTATE=tern-test-mutate
WORLD_LABEL=lens.example.com/fixture-world=true

die() {
	printf 'capture: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '==> %s\n' "$*" >&2
}

reuse=0
case ${1:-} in
"") ;;
--reuse) reuse=1 ;;
*) die "usage: $0 [--reuse]" ;;
esac

KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable; run scripts/cluster.sh create"
export KUBECONFIG
# Reproducible client output: no kuberc preferences, default diff, short temp paths.
KUBERC=off
TMPDIR=/tmp
export KUBERC TMPDIR
unset KUBECTL_EXTERNAL_DIFF KUBECTL_EXPLICIT_LOCAL_PERMISSIONS 2>/dev/null || true

k() {
	"$KUBECTL" "$@"
}

version_of() {
	sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n 1
}

CLIENT_VERSION=$(k version --client -o json | version_of)
SERVER_VERSION=$(k get --raw /version | version_of)
[ -n "$CLIENT_VERSION" ] && [ -n "$SERVER_VERSION" ] || die "could not determine kubectl/server versions"

wait_until() {
	desc=$1
	limit=$2
	shift 2
	waited=0
	until "$@" >/dev/null 2>&1; do
		[ "$waited" -lt "$limit" ] || die "timed out after ${limit}s waiting for $desc"
		sleep 2
		waited=$((waited + 2))
	done
	log "ready: $desc (${waited}s)"
}

preload_images() {
	arch=$(docker exec "$NODE" uname -m)
	case $arch in
	aarch64 | arm64) arch=arm64 ;;
	x86_64 | amd64) arch=amd64 ;;
	*) die "unsupported node arch $arch" ;;
	esac
	tmp=$(mktemp -d)
	for img in $IMAGES; do
		if docker exec "$NODE" crictl inspecti "$img" >/dev/null 2>&1; then
			continue
		fi
		docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null || {
			log "warning: could not pull $img; the node will pull it itself"
			continue
		}
		archive=$tmp/image.tar
		if docker save --platform "linux/$arch" -o "$archive" "$img" 2>/dev/null; then
			"$KIND" load image-archive --name "$CLUSTER" "$archive" >/dev/null
		else
			"$KIND" load docker-image --name "$CLUSTER" "$img" >/dev/null ||
				log "warning: could not preload $img; the node will pull it itself"
		fi
		rm -f "$archive"
	done
	rm -rf "$tmp"
}

# Namespace deletion stalls while any aggregated API (metrics.k8s.io) is
# unavailable, so metrics-server must be healthy before anything is deleted.
install_metrics_server() {
	log "installing metrics-server"
	k apply -k "$MANIFESTS/metrics-server" >/dev/null
	k rollout status deployment/metrics-server -n kube-system --timeout=180s >/dev/null
	k wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s >/dev/null
}

delete_world() {
	log "deleting fixture world"
	k delete namespace -l "$WORLD_LABEL" --wait=true --timeout=300s >/dev/null
	k delete crd -l "$WORLD_LABEL" --wait=true --timeout=120s >/dev/null
}

delete_mutate_namespace() {
	k delete namespace "$MUTATE" --ignore-not-found --wait=true --timeout=300s >/dev/null
}

# Go durations ("1m20s") and kubectl ages ("80s", "2m3s", "5m") in seconds.
to_seconds() {
	expr=$(printf '%s' "$1" | sed -n -E '/^([0-9]+h)?([0-9]+m)?([0-9]+s)?$/p' |
		sed -E 's/([0-9]+)h/\1*3600+/; s/([0-9]+)m/\1*60+/; s/([0-9]+)s/\1+/; s/\+$//')
	[ -n "$expr" ] && echo $(($expr))
}

# The crashloop pod is Running or Error for an instant at every restart. Hold
# captures that show it until it has just entered a back-off with at least
# CRASHLOOP_QUIET seconds left, so every fixture sees CrashLoopBackOff.
CRASHLOOP_QUIET=15
crashloop_quiet() {
	pod="pod/crashloop -n $APPS"
	# shellcheck disable=SC2086
	reason=$(k get $pod -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')
	[ "$reason" = CrashLoopBackOff ] || return 1
	# shellcheck disable=SC2086
	backoff=$(k get $pod -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' |
		sed -n 's/^back-off \([0-9hms]*\) .*/\1/p')
	# shellcheck disable=SC2086
	ago=$(k get $pod --no-headers | sed -n 's/.*(\([0-9hms]*\) ago).*/\1/p')
	backoff=$(to_seconds "$backoff") && ago=$(to_seconds "$ago") || return 1
	[ $((backoff - ago)) -ge "$CRASHLOOP_QUIET" ]
}

image_pull_backoff() {
	reason=$(k get pods -n "$APPS" -l app=broken-image -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}')
	[ "$reason" = ImagePullBackOff ]
}

pod_unschedulable() {
	reason=$(k get pod pending -n "$APPS" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}')
	[ "$reason" = Unschedulable ]
}

metrics_ready() {
	k top nodes --no-headers | grep -q . &&
		[ "$(k top pods -n "$APPS" --no-headers | grep -c .)" -ge 4 ] &&
		[ "$(k top pods -n "$EDGE" --no-headers | grep -c .)" -ge 2 ] &&
		[ "$(k top pods -n kube-system --no-headers | grep -c '^metrics-server-')" -ge 1 ]
}

build_world() {
	log "applying fixture world"
	k apply -f "$MANIFESTS/00-namespaces.yaml" >/dev/null
	k apply -f "$MANIFESTS/crd/crd.yaml" >/dev/null
	k wait --for=condition=Established crd/widgets.lens.example.com --timeout=60s >/dev/null
	k apply -f "$MANIFESTS/apps" -f "$MANIFESTS/batch" -f "$MANIFESTS/edge" -f "$MANIFESTS/crd/widgets.yaml" >/dev/null

	log "waiting for steady state"
	k rollout status deployment/web -n "$APPS" --timeout=180s >/dev/null
	k rollout status statefulset/db -n "$APPS" --timeout=180s >/dev/null
	k rollout status daemonset/node-agent -n "$APPS" --timeout=180s >/dev/null
	k wait --for=condition=Ready pod --all -n "$EDGE" --timeout=180s >/dev/null
	k wait --for=condition=Complete job/done-job -n "$BATCH" --timeout=180s >/dev/null
	k wait --for=condition=Failed job/fail-job -n "$BATCH" --timeout=180s >/dev/null
	wait_until "pending pod unschedulable" 60 pod_unschedulable
	wait_until "broken-image in ImagePullBackOff" 180 image_pull_backoff
	wait_until "crashloop in a back-off with ${CRASHLOOP_QUIET}s left" 420 crashloop_quiet
	wait_until "metrics-server serving pod and node metrics" 300 metrics_ready
}

fixture_key() {
	key=""
	skip=0
	for arg in "$@"; do
		if [ "$skip" = 1 ]; then
			skip=0
			continue
		fi
		case $arg in
		--context | --kubeconfig | -n | --namespace | --cluster | --user)
			skip=1
			continue
			;;
		--context=* | --kubeconfig=* | --namespace=* | --cluster=* | --user=* | -n?*)
			continue
			;;
		esac
		part=$(printf '%s' "$arg" | tr '/' '+')
		if [ -z "$key" ]; then
			key=$part
		else
			key=${key}_$part
		fi
	done
	printf '%s' "$key"
}

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

mismatches=0

# cap SCENARIO EXPECTED_EXIT KUBECTL_ARGS...
cap() {
	scenario=$1
	expect=$2
	shift 2
	key=$(fixture_key "$@")
	dir=$OUT/$scenario
	base=$dir/$key
	mkdir -p "$dir"
	[ ! -e "$base.txt" ] && [ ! -e "$base.stderr" ] || die "duplicate fixture key $scenario/$key"
	set +e
	(cd "$MANIFESTS" && "$KUBECTL" "$@") >"$base.txt" 2>"$base.stderr"
	status=$?
	set -e
	[ -s "$base.stderr" ] || rm -f "$base.stderr"
	if [ ! -s "$base.txt" ] && [ -f "$base.stderr" ]; then
		rm -f "$base.txt"
	fi
	[ "$status" = 0 ] || printf '%s\n' "$status" >"$base.exit"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$scenario" "$key" "$(argv_string "$@")" "$status" \
		"$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
	if [ "$status" != "$expect" ]; then
		mismatches=$((mismatches + 1))
		printf 'capture: UNEXPECTED exit %s (wanted %s): %s\n' "$status" "$expect" "$(argv_string "$@")" >&2
		[ -f "$base.stderr" ] && sed 's/^/    /' "$base.stderr" >&2
	fi
	return 0
}

capture_cluster() {
	s=cluster
	cap $s 0 version
	cap $s 0 api-resources
	cap $s 0 get nodes
	cap $s 0 get nodes -o wide
	cap $s 0 get nodes --show-labels
	cap $s 0 get nodes -o json
	cap $s 0 get no
	cap $s 0 get namespaces
	cap $s 0 get ns
	cap $s 0 get crd
	cap $s 0 get crd widgets.lens.example.com -o yaml
	cap $s 0 describe node
	cap $s 0 describe node "$NODE"
	cap $s 0 top nodes
}

capture_apps() {
	s=ns-apps
	n="-n $APPS"
	wait_until "crashloop in a back-off with ${CRASHLOOP_QUIET}s left" 420 crashloop_quiet
	# shellcheck disable=SC2086
	{
		cap $s 0 get pods $n
		cap $s 0 get po $n
		cap $s 0 get pods $n -o wide
		cap $s 0 get pods $n --show-labels
		cap $s 0 get pods $n -l app=web
		cap $s 0 get pods $n --selector=app=db -o wide
		cap $s 0 get pods $n --no-headers
		cap $s 0 get pods $n -o json
		cap $s 0 get pods $n -o yaml
		cap $s 0 get pods $n -o name
		cap $s 0 get pods $n -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
		cap $s 0 get pods $n --sort-by=.metadata.name
		cap $s 0 get pods $n '--sort-by=.status.containerStatuses[0].restartCount'
		cap $s 0 get pod crashloop $n
		cap $s 0 get pods crashloop pending $n
		cap $s 0 get pod/crashloop $n
		cap $s 0 get pod crashloop $n -o yaml
		cap $s 0 get deployments $n
		cap $s 0 get deploy $n
		cap $s 0 get deploy $n -o wide
		cap $s 0 get deployment web $n -o yaml
		cap $s 0 get services $n
		cap $s 0 get svc $n
		cap $s 0 get svc $n -o wide
		cap $s 0 get endpointslices $n
		cap $s 0 get endpoints $n
		cap $s 0 get ingress $n
		cap $s 0 get ing $n -o wide
		cap $s 0 get statefulsets $n
		cap $s 0 get sts $n -o wide
		cap $s 0 get daemonsets $n
		cap $s 0 get ds $n -o wide
		cap $s 0 get replicasets $n
		cap $s 0 get rs $n -o wide
		cap $s 0 get configmaps $n
		cap $s 0 get secrets $n
		cap $s 0 get secret app-secret $n -o yaml
		cap $s 0 get events $n
		cap $s 0 get events $n --sort-by=.lastTimestamp
		cap $s 0 get all $n
		cap $s 0 get pods,svc $n
		cap $s 0 describe pods $n
		cap $s 0 get deploy,rs,pods $n
		cap $s 0 describe pod crashloop $n
		cap $s 0 describe pod pending $n
		cap $s 0 describe deployment web $n
		cap $s 0 describe svc web $n
		cap $s 0 describe ingress web $n
		cap $s 0 top pods $n
		cap $s 0 top pods $n --containers
	}
}

capture_batch() {
	s=ns-batch
	n="-n $BATCH"
	# shellcheck disable=SC2086
	{
		cap $s 0 get pods $n
		cap $s 0 get jobs $n
		cap $s 0 get jobs $n -o wide
		cap $s 0 get cronjobs $n
		cap $s 0 get cj $n -o wide
		cap $s 0 get all $n
		cap $s 0 get events $n
		cap $s 0 describe job fail-job $n
		cap $s 0 describe cronjob nightly-report $n
	}
}

capture_crd() {
	s=ns-crd
	n="-n $CRDNS"
	# shellcheck disable=SC2086
	{
		cap $s 0 get widgets $n
		cap $s 0 get wd $n
		cap $s 0 get widgets.lens.example.com $n
		cap $s 0 get widgets $n -o wide
		cap $s 0 get widgets $n -o json
		cap $s 0 get widgets $n -o yaml
		cap $s 0 get widget gizmo $n
		cap $s 0 describe widget gizmo $n
		cap $s 0 get lens $n
	}
}

capture_edge() {
	s=ns-edge
	n="-n $EDGE"
	# shellcheck disable=SC2086
	{
		cap $s 0 get pods $n
		cap $s 0 get pods $n -o wide
		cap $s 0 get pods $n --show-labels
		cap $s 0 get pod labels-odd $n -o yaml
		cap $s 0 get pod labels-odd $n -o json
		cap $s 0 describe pod labels-odd $n
		cap $s 0 get configmap unicode-config $n -o yaml
		cap $s 0 top pods $n --containers
	}
}

capture_empty() {
	s=ns-empty
	n="-n $EMPTY"
	# shellcheck disable=SC2086
	{
		cap $s 0 get pods $n
		cap $s 0 get all $n
		cap $s 0 get events $n
		cap $s 0 get pods $n -o json
	}
}

capture_all_namespaces() {
	s=all-namespaces
	wait_until "crashloop in a back-off with ${CRASHLOOP_QUIET}s left" 420 crashloop_quiet
	cap $s 0 get pods -A
	cap $s 0 get pods --all-namespaces
	cap $s 0 get pods -A -o wide
	cap $s 0 get pods -A --no-headers
	cap $s 0 get pods -A --show-labels
	cap $s 0 get pods -A -l app=web
	cap $s 0 get deploy -A
	cap $s 0 get svc -A
	cap $s 0 get svc -A -o wide
	cap $s 0 get events -A
	cap $s 0 get events -A --sort-by=.lastTimestamp
	cap $s 0 get all -A
	cap $s 0 get jobs -A
	cap $s 0 get cronjobs -A
	cap $s 0 get ingress -A
	cap $s 0 get sts -A
	cap $s 0 get ds -A
	cap $s 0 get rs -A
	cap $s 0 get endpointslices -A
	cap $s 0 get configmaps -A
	cap $s 0 get widgets -A
	cap $s 0 top pods -A
}

capture_read_errors() {
	s=errors
	wait_until "crashloop in a back-off with ${CRASHLOOP_QUIET}s left" 420 crashloop_quiet
	cap $s 1 get foos
	cap $s 1 get pod does-not-exist -n "$APPS"
	cap $s 1 get pods does-not-exist crashloop -n "$APPS"
	cap $s 1 describe pod does-not-exist -n "$APPS"
	cap $s 0 get pods -n tern-test-does-not-exist
	cap $s 1 get secrets -n "$APPS" --as=system:serviceaccount:$APPS:default
	cap $s 1 get pods -n "$APPS" --server=https://127.0.0.1:1 --request-timeout=5s
	cap errors-context 1 --context does-not-exist get pods -n "$APPS"
}

capture_mutations() {
	log "resetting $MUTATE"
	delete_mutate_namespace
	k apply -f "$MANIFESTS/mutate/namespace.yaml" >/dev/null
	m="-n $MUTATE"
	# shellcheck disable=SC2086
	{
		cap mutate-create 1 diff $m -f mutate/app.yaml
		cap mutate-create 0 apply $m --dry-run=server -f mutate/app.yaml
		cap mutate-create 0 apply $m -f mutate/app.yaml
		cap mutate-create 0 apply $m -f mutate/scratch-pod.yaml
		k rollout status deployment/api $m --timeout=180s >/dev/null
		k wait --for=condition=Ready pod/scratch $m --timeout=120s >/dev/null

		cap mutate-unchanged 0 apply $m -f mutate/app.yaml
		cap mutate-unchanged 0 diff $m -f mutate/app.yaml

		cap mutate-configured 1 diff $m -f mutate/app-v2.yaml
		cap mutate-configured 0 apply $m --dry-run=client -f mutate/app-v2.yaml
		cap mutate-configured 0 apply $m --dry-run=server -f mutate/app-v2.yaml
		cap mutate-configured 0 apply $m -f mutate/app-v2.yaml
		k rollout status deployment/api $m --timeout=180s >/dev/null

		cap mutate-ops 0 scale deployment/api --replicas=3 $m
		k rollout status deployment/api $m --timeout=180s >/dev/null
		cap mutate-ops 0 rollout restart deployment/api $m
		cap mutate-ops 0 rollout status deployment/api $m --timeout=180s
		cap mutate-ops 0 delete pod scratch $m

		cap mutate-delete 0 delete $m -f mutate/app-v2.yaml
	}
}

capture_mutation_errors() {
	s=errors
	m="-n $MUTATE"
	# shellcheck disable=SC2086
	{
		cap $s 1 apply $m -f mutate/invalid.yaml
		cap $s 1 apply $m -f mutate/broken.yaml
		cap $s 1 apply $m -f mutate/does-not-exist.yaml
		cap $s 1 delete $m -f mutate/app-v2.yaml
		cap $s 1 delete pod scratch $m
		cap $s 1 scale deployment/api --replicas=1 $m
		cap $s 1 rollout restart deployment/api $m
	}
}

scan_for_credentials() {
	log "scanning fixtures for credentials"
	found=0
	if grep -rIl -E 'BEGIN [A-Z ]*(CERTIFICATE|PRIVATE KEY)|client-key-data|client-certificate-data|certificate-authority-data|eyJhbGciOi' "$OUT"; then
		found=1
	fi
	for field in client-key-data client-certificate-data certificate-authority-data; do
		value=$(sed -n "s/^ *$field: *//p" "$KUBECONFIG" | head -n 1 | cut -c 1-48)
		[ -n "$value" ] || continue
		if grep -rIlF "$value" "$OUT"; then
			found=1
		fi
	done
	[ "$found" = 0 ] || die "credential material found in fixtures (files listed above)"
}

main() {
	preload_images
	install_metrics_server
	[ "$reuse" = 1 ] || delete_world
	delete_mutate_namespace
	build_world

	log "capturing into $OUT"
	find "$OUT" -mindepth 1 -maxdepth 1 ! -name README.md ! -name json-world ! -name mutate-preview -exec rm -rf {} + 2>/dev/null || true
	mkdir -p "$OUT"
	printf 'scenario\tkey\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

	capture_cluster
	capture_apps
	capture_batch
	capture_crd
	capture_edge
	capture_empty
	capture_all_namespaces
	capture_read_errors
	capture_mutations
	capture_mutation_errors
	scan_for_credentials
	# capture_mutations recreated tern-test-mutate; restore the quick-action
	# toolbox only now so no fixture lists it.
	log "applying the quick-action toolbox"
	k apply -f "$MANIFESTS/qa/toolbox.yaml" >/dev/null
	k rollout status deployment/kl-qa-shell -n "$MUTATE" --timeout=180s >/dev/null

	count=$(($(wc -l <"$MANIFEST") - 1))
	log "captured $count fixtures (kubectl $CLIENT_VERSION, server $SERVER_VERSION)"
	[ "$mismatches" = 0 ] || die "$mismatches capture(s) exited with an unexpected status"
}

# Parsed in full before running, so editing this file mid-run is harmless.
main; exit $?
