#!/bin/sh
# Captures real mutation-preview output (kubectl diff, server dry runs) against
# the existing fixture world (built by scripts/fixtures/capture.sh) into
# tests/fixtures/real/mutate-preview/<key>.{txt,stderr,exit} for the mutation
# specs. Only `diff` and `--dry-run=server` verbs run, only in tern-test-*
# namespaces (plus cluster-scoped dry runs): nothing in the cluster changes.
#
#   scripts/fixtures/capture-mutate-preview.sh
#
# Keys follow tests/bin/kubectl (argv minus connection flags, joined by "_",
# "/" -> "+"); every fixture is listed with its full argv in
# tests/fixtures/real/mutate-preview/MANIFEST.tsv. Commands run in
# tests/integration/manifests, so -f paths are relative to it; the inputs live
# in tests/integration/manifests/preview/ and are never applied.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFESTS=$ROOT/tests/integration/manifests
OUT=$ROOT/tests/fixtures/real/mutate-preview
MANIFEST=$OUT/MANIFEST.tsv
KUBECTL=${KUBECTL:-kubectl}
CONTEXT=kind-tern-kube-dev

die() {
	printf 'capture-mutate-preview: %s\n' "$*" >&2
	exit 1
}

KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable; run scripts/cluster.sh create"
export KUBECONFIG
KUBERC=off
TMPDIR=/tmp
export KUBERC TMPDIR
unset KUBECTL_EXTERNAL_DIFF KUBECTL_EXPLICIT_LOCAL_PERMISSIONS 2>/dev/null || true

version_of() {
	sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n 1
}

CLIENT_VERSION=$("$KUBECTL" --context "$CONTEXT" version --client -o json | version_of)
SERVER_VERSION=$("$KUBECTL" --context "$CONTEXT" get --raw /version | version_of)
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

# Refuses anything that could persist a change: the verb must be `diff`, or
# the argv must carry --dry-run=server; a namespace flag must name tern-test-*.
guard() {
	verb="" dry=0 prev=""
	for arg in "$@"; do
		case $prev in
		-n | --namespace)
			case $arg in tern-test-*) ;; *) die "namespace outside tern-test-*: $arg" ;; esac
			;;
		esac
		case $arg in
		--dry-run=server) dry=1 ;;
		--namespace=*)
			case ${arg#--namespace=} in tern-test-*) ;; *) die "namespace outside tern-test-*: $arg" ;; esac
			;;
		-*) ;;
		*) [ -n "$verb" ] || case $prev in --context | -n | --namespace) ;; *) verb=$arg ;; esac ;;
		esac
		prev=$arg
	done
	[ "$verb" = diff ] || [ "$dry" = 1 ] || die "refusing non-preview command: $(argv_string "$@")"
}

mismatches=0

# cap EXPECTED_EXIT KUBECTL_ARGS... (context is always pinned)
cap() {
	expect=$1
	shift
	set -- --context "$CONTEXT" "$@"
	guard "$@"
	key=$(fixture_key "$@")
	base=$OUT/$key
	[ ! -e "$base.txt" ] && [ ! -e "$base.stderr" ] || die "duplicate fixture key $key"
	set +e
	(cd "$MANIFESTS" && "$KUBECTL" "$@") >"$base.txt" 2>"$base.stderr"
	status=$?
	set -e
	[ -s "$base.stderr" ] || rm -f "$base.stderr"
	if [ ! -s "$base.txt" ] && [ -f "$base.stderr" ]; then
		rm -f "$base.txt"
	fi
	[ "$status" = 0 ] || printf '%s\n' "$status" >"$base.exit"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' mutate-preview "$key" "$(argv_string "$@")" "$status" \
		"$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
	if [ "$status" != "$expect" ]; then
		mismatches=$((mismatches + 1))
		printf 'capture-mutate-preview: UNEXPECTED exit %s (wanted %s): %s\n' "$status" "$expect" "$(argv_string "$@")" >&2
		[ -f "$base.stderr" ] && sed 's/^/    /' "$base.stderr" >&2
	fi
	return 0
}

rm -rf "$OUT"
mkdir -p "$OUT"
printf 'scenario\tkey\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

# create + modify + unchanged in one namespace
cap 1 diff -n tern-test-apps -f preview/apps-mix.yaml
cap 0 apply -n tern-test-apps --dry-run=server -f preview/apps-mix.yaml
# CRD objects: modify + create (name with a dot), then prune shows a delete
cap 1 diff -n tern-test-crd -f preview/widgets.yaml
cap 1 diff -n tern-test-crd -f preview/widgets.yaml --prune -l app=widgets \
	--prune-allowlist=lens.example.com/v1alpha1/Widget
# cluster-scoped creates (empty namespace segment in diff names)
cap 1 diff -f preview/cluster-scoped.yaml
# server dry runs of the other families
cap 0 delete pods -l app=web -n tern-test-apps --dry-run=server
cap 0 delete namespace tern-test-empty --dry-run=server
cap 0 scale deployment/web --replicas=3 -n tern-test-apps --dry-run=server
cap 0 create job nightly-report-manual-preview --from=cronjob/nightly-report -n tern-test-batch --dry-run=server
# a preview the caller is not allowed to run (blocked tier)
cap 1 delete pod crashloop -n tern-test-apps --dry-run=server --as=system:serviceaccount:tern-test-apps:default

if grep -rlE 'BEGIN (RSA |EC )?PRIVATE KEY|BEGIN CERTIFICATE|client-key-data|token:' "$OUT" >/dev/null 2>&1; then
	die "credential material leaked into $OUT"
fi
[ "$mismatches" = 0 ] || die "$mismatches capture(s) exited unexpectedly"
printf '==> captured %s fixtures into %s\n' "$(($(wc -l <"$MANIFEST") - 1))" "$OUT" >&2
