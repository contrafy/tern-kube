#!/bin/sh
# Captures the two-cluster compare fixtures for plugin/lib/compare and the
# GitOps matrix specs into tests/fixtures/real/compare/:
#
#   {a,b}-<kind>-<name>.json      get <kind> <name> -o json per context
#   {a,b}-deployments-list.json   get deployments -o json
#   {a,b}-mixed-list.json         get configmaps,secrets,services,deployments -o json
#   {a,b}-diff-source.out|.exit   kubectl diff -f source/app.yaml (exit kept)
#   b-deployment-tkm-only-a.stderr  NotFound of an object only cluster A has
#   b-fieldsel-tkm-only-a.json    the same absence via --field-selector (exit 0)
#   config-view.json              kubectl config view -o json (both contexts)
#   config-view-3.json            plus an unreachable third context
#   source/app.yaml               copy of the diffed GitOps source
#   MANIFEST.tsv                  file, context, argv, exit, versions
#
#   sh scripts/fixtures/capture-compare.sh
#
# Needs both sandbox clusters (scripts/cluster.sh create && scripts/cluster.sh
# create-peer) and talks to them only through the merged sandbox kubeconfig.
# Writes only to namespace tern-test-mc, which is recreated in both clusters
# from tests/integration/manifests/compare/{a,b}.yaml (cluster A =
# kind-tern-kube-dev, B = kind-tern-kube-dev2); everything after that is
# read-only. Secrets hold test values only; the kube-root-ca.crt certificate
# is replaced by REDACTED and config view never prints credentials.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFESTS=$ROOT/tests/integration/manifests/compare
OUT=$ROOT/tests/fixtures/real/compare
MANIFEST=$OUT/MANIFEST.tsv
KUBECTL=${KUBECTL:-kubectl}
A=kind-tern-kube-dev
B=kind-tern-kube-dev2
NS=tern-test-mc

die() {
	printf 'capture-compare: %s\n' "$*" >&2
	exit 1
}

KUBECONFIG=$("$ROOT/scripts/cluster.sh" mc-kubeconfig-path) ||
	die "both sandbox clusters are needed; run scripts/cluster.sh create && scripts/cluster.sh create-peer"
export KUBECONFIG
KUBERC=off
TMPDIR=/tmp
export KUBERC TMPDIR
unset KUBECTL_EXTERNAL_DIFF KUBECTL_EXPLICIT_LOCAL_PERMISSIONS 2>/dev/null || true

[ -f "$MANIFESTS/a.yaml" ] && [ -f "$MANIFESTS/b.yaml" ] && [ -f "$MANIFESTS/source/app.yaml" ] ||
	die "missing $MANIFESTS/{a.yaml,b.yaml,source/app.yaml}"

k() {
	ctx=$1
	shift
	"$KUBECTL" --context "$ctx" "$@"
}

version_of() {
	sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n 1
}

CLIENT_VERSION=$(k "$A" version --client -o json | version_of)
SERVER_VERSION=$(k "$A" get --raw /version | version_of)
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

redact() {
	sed 's/\("ca\.crt": \)".*"/\1"REDACTED"/'
}

mismatches=0

# cap FILE EXPECTED_EXIT CONTEXT KUBECTL_ARGS... (read verbs only; CONTEXT
# "" for config view, which reads the kubeconfig and talks to no cluster).
# stdout goes to FILE (dropped when empty on failure), non-empty stderr to
# <FILE without extension>.stderr; diff exit statuses to .exit.
cap() {
	file=$1 expect=$2 ctx=$3
	shift 3
	case $1 in get | diff | config) ;; *) die "cap only runs get, diff and config view" ;; esac
	base=$OUT/${file%.*}
	if [ -n "$ctx" ]; then set -- --context "$ctx" "$@"; fi
	set +e
	(cd "$MANIFESTS" && "$KUBECTL" "$@") >"$base.tmp" 2>"$base.err"
	status=$?
	set -e
	redact <"$base.tmp" >"$OUT/$file"
	rm -f "$base.tmp"
	[ "$status" = 0 ] || [ -s "$OUT/$file" ] || rm -f "$OUT/$file"
	if [ -s "$base.err" ]; then mv "$base.err" "$base.stderr"; else rm -f "$base.err"; fi
	case " $* " in *" diff "*) printf '%s\n' "$status" >"$base.exit" ;; esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$ctx" "$(argv_string "$@")" "$status" \
		"$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
	if [ "$status" != "$expect" ]; then
		mismatches=$((mismatches + 1))
		printf 'capture-compare: UNEXPECTED exit %s (wanted %s): %s\n' "$status" "$expect" "$(argv_string "$@")" >&2
	fi
}

# ---- world (writes only to tern-test-mc) -----------------------------------
for ctx in "$A" "$B"; do
	k "$ctx" delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null
done
k "$A" apply -f "$MANIFESTS/a.yaml" >/dev/null
k "$B" apply -f "$MANIFESTS/b.yaml" >/dev/null
for d in tkm-web tkm-api tkm-only-a; do
	k "$A" -n "$NS" rollout status "deployment/$d" --timeout=180s >/dev/null
done
for d in tkm-web tkm-api tkm-only-b; do
	k "$B" -n "$NS" rollout status "deployment/$d" --timeout=180s >/dev/null
done

# ---- capture (read-only from here on) --------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/source"
cp "$MANIFESTS/source/app.yaml" "$OUT/source/app.yaml"
printf 'file\tcontext\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

for side in a b; do
	if [ "$side" = a ]; then ctx=$A; else ctx=$B; fi
	cap "$side-deployment-tkm-web.json" 0 "$ctx" get deployment tkm-web -n "$NS" -o json
	cap "$side-deployment-tkm-api.json" 0 "$ctx" get deployment tkm-api -n "$NS" -o json
	cap "$side-service-tkm-web.json" 0 "$ctx" get service tkm-web -n "$NS" -o json
	cap "$side-configmap-tkm-config.json" 0 "$ctx" get configmap tkm-config -n "$NS" -o json
	cap "$side-secret-tkm-secret.json" 0 "$ctx" get secret tkm-secret -n "$NS" -o json
	cap "$side-deployments-list.json" 0 "$ctx" get deployments -n "$NS" -o json
	cap "$side-mixed-list.json" 0 "$ctx" get configmaps,secrets,services,deployments -n "$NS" -o json
done
cap a-configmap-tkm-flags.json 0 "$A" get configmap tkm-flags -n "$NS" -o json
cap a-diff-source.out 0 "$A" diff -n "$NS" -f source/app.yaml
cap b-diff-source.out 1 "$B" diff -n "$NS" -f source/app.yaml
cap b-deployment-tkm-only-a.json 1 "$B" get deployment tkm-only-a -n "$NS" -o json
cap b-fieldsel-tkm-only-a.json 0 "$B" get deployments.v1.apps --field-selector metadata.name=tkm-only-a -n "$NS" -o json
cap config-view.json 0 "" config view -o json

# A context whose server refuses connections (port 1), kept in a throwaway
# kubeconfig listed after the merged one.
down=$(mktemp /tmp/tk-compare-down.XXXXXX)
trap 'rm -f "$down"' EXIT INT TERM
"$KUBECTL" config set-cluster kind-tern-kube-down --server=https://127.0.0.1:1 --kubeconfig "$down" >/dev/null
"$KUBECTL" config set-context kind-tern-kube-down --cluster=kind-tern-kube-down --kubeconfig "$down" >/dev/null
MC=$KUBECONFIG
KUBECONFIG=$MC:$down
cap config-view-3.json 0 "" config view -o json
KUBECONFIG=$MC

if grep -rlE 'BEGIN (RSA |EC )?(PRIVATE KEY|CERTIFICATE)' "$OUT" >/dev/null 2>&1 ||
	grep -rhoE '"(client-key-data|client-certificate-data|certificate-authority-data|token)": "[^"]*"' "$OUT" |
	grep -v '"DATA+OMITTED"$' | grep -q .; then
	die "credential material leaked into $OUT"
fi
[ "$mismatches" = 0 ] || die "$mismatches capture(s) exited unexpectedly"
printf '==> captured %s fixtures into %s\n' "$(($(wc -l <"$MANIFEST") - 1))" "$OUT" >&2
