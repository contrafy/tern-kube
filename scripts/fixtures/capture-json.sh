#!/bin/sh
# Captures read-only `kubectl get ... -o json` output of the existing fixture
# world (built by scripts/fixtures/capture.sh) into
# tests/fixtures/real/json-world/<scenario>/<key>.txt for the Explore relation
# specs. Nothing in the cluster is created, changed or deleted.
#
#   scripts/fixtures/capture-json.sh
#
# Keys follow scripts/fixtures/capture.sh (argv minus connection flags, joined
# by "_", "/" -> "+"); every fixture is listed with its full argv in
# tests/fixtures/real/json-world/MANIFEST.tsv. Secrets are only ever listed
# with `-o name`: their data never reaches a fixture.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=$ROOT/tests/fixtures/real/json-world
MANIFEST=$OUT/MANIFEST.tsv
KUBECTL=${KUBECTL:-kubectl}

KINDS="deployments replicasets pods services endpointslices ingresses jobs cronjobs statefulsets daemonsets"

die() {
	printf 'capture-json: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '==> %s\n' "$*" >&2
}

KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable; run scripts/cluster.sh create"
export KUBECONFIG
KUBERC=off
export KUBERC

k() {
	"$KUBECTL" "$@"
}

version_of() {
	sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n 1
}

CLIENT_VERSION=$(k version --client -o json | version_of)
SERVER_VERSION=$(k get --raw /version | version_of)
[ -n "$CLIENT_VERSION" ] && [ -n "$SERVER_VERSION" ] || die "could not determine kubectl/server versions"

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

# cap SCENARIO KUBECTL_ARGS...
cap() {
	scenario=$1
	shift
	case " $* " in
	*" secret"*)
		case " $* " in
		*" -o name "*) ;;
		*) die "refusing to capture secrets without -o name: $(argv_string "$@")" ;;
		esac
		;;
	esac
	key=$(fixture_key "$@")
	dir=$OUT/$scenario
	mkdir -p "$dir"
	[ ! -e "$dir/$key.txt" ] || die "duplicate fixture key $scenario/$key"
	k "$@" >"$dir/$key.txt" || die "failed: $(argv_string "$@")"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$scenario" "$key" "$(argv_string "$@")" 0 \
		"$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
}

capture_namespace() {
	scenario=$1
	ns=$2
	shift 2
	for kind in $KINDS "$@"; do
		cap "$scenario" get "$kind" -n "$ns" -o json
	done
	# kube-root-ca.crt carries the cluster CA certificate: listed by name only.
	cap "$scenario" get configmaps -n "$ns" --field-selector=metadata.name!=kube-root-ca.crt -o json
	cap "$scenario" get configmaps -n "$ns" -o name
	cap "$scenario" get secrets -n "$ns" -o name
}

scan_for_credentials() {
	log "scanning json fixtures for credentials"
	found=0
	if grep -rIl -E 'BEGIN [A-Z ]*(CERTIFICATE|PRIVATE KEY)|client-key-data|client-certificate-data|certificate-authority-data|eyJhbGciOi|"kind": "Secret"' "$OUT"; then
		found=1
	fi
	for field in client-key-data client-certificate-data certificate-authority-data; do
		value=$(sed -n "s/^ *$field: *//p" "$KUBECONFIG" | head -n 1 | cut -c 1-48)
		[ -n "$value" ] || continue
		if grep -rIlF "$value" "$OUT"; then
			found=1
		fi
	done
	[ "$found" = 0 ] || die "credential material found in json fixtures (files listed above)"
}

main() {
	log "capturing into $OUT"
	rm -rf "$OUT"
	mkdir -p "$OUT"
	printf 'scenario\tkey\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

	cap cluster get nodes -o json
	capture_namespace ns-apps tern-test-apps
	capture_namespace ns-batch tern-test-batch
	capture_namespace ns-edge tern-test-edge
	capture_namespace ns-crd tern-test-crd widgets
	scan_for_credentials

	count=$(($(wc -l <"$MANIFEST") - 1))
	log "captured $count json fixtures (kubectl $CLIENT_VERSION, server $SERVER_VERSION)"
}

main; exit $?
