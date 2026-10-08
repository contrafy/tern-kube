#!/bin/sh
# Export round-trip proof: every real JSON fixture (tests/fixtures/real/
# json-world), cleaned and emitted as YAML, must parse back through kubectl
# into exactly the cleaned object; a synthetic ConfigMap covers every quoting
# and block-scalar edge. Client-side dry-run only (nothing reaches the API
# server's storage), pinned to the sandbox kubeconfig and kind context. The
# fixture world's Widget CRD is applied first: client-side parsing of the CRD
# fixture still needs the server to know the kind (a fresh CI cluster does
# not).
#
#   tests/integration/gitops/roundtrip.sh
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
KC=$REPO/.sandbox/kubeconfig
CTX=kind-tern-kube-dev
LUAU=$REPO/.tools/bin/luau
DRIVER=tests/integration/gitops/roundtrip.luau
[ -f "$KC" ] || { echo "missing $KC: run scripts/cluster.sh up" >&2; exit 2; }
KUBECONFIG=$KC
export KUBECONFIG

cd "$REPO" || exit 2
kubectl --context "$CTX" apply -f tests/integration/manifests/crd/crd.yaml >/dev/null || exit 2
kubectl --context "$CTX" wait --for condition=Established --timeout=60s \
	-f tests/integration/manifests/crd/crd.yaml >/dev/null || exit 2
make -s fixtures >/dev/null || exit 2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tern-kube-roundtrip.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

fails=0
n=0
for fixture in $("$LUAU" "$DRIVER" -a list) @edge; do
	n=$((n + 1))
	yaml=$WORK/$n.yaml
	if ! "$LUAU" "$DRIVER" -a emit "$fixture" >"$yaml"; then
		echo "FAIL $fixture: emit" >&2
		fails=$((fails + 1))
		continue
	fi
	# The edge object carries fields no schema knows; only YAML parsing is under test there.
	validate=strict
	[ "$fixture" = @edge ] && validate=false
	if ! out=$(kubectl --context "$CTX" create --dry-run=client --validate="$validate" -o json -f "$yaml" 2>"$WORK/err"); then
		echo "FAIL $fixture: kubectl: $(cat "$WORK/err")" >&2
		fails=$((fails + 1))
		continue
	fi
	if ! "$LUAU" "$DRIVER" -a compare "$fixture" "$out"; then
		echo "FAIL $fixture: emitted YAML: $yaml" >&2
		cp "$yaml" "${TMPDIR:-/tmp}/tern-kube-roundtrip-failed-$n.yaml"
		fails=$((fails + 1))
	fi
done

if [ "$fails" -gt 0 ]; then
	echo "$fails of $n round-trips failed" >&2
	exit 1
fi
echo "all $n round-trips identical"
