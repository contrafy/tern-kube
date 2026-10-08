#!/bin/sh
# Regenerates tests/fixtures/synthetic/rows-<N>/ with scripts/fixtures/synth.luau.
# Output is deterministic: same seed, same bytes. Keys follow tests/bin/kubectl.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
LUAU=${LUAU:-$ROOT/.tools/bin/luau}
OUT=$ROOT/tests/fixtures/synthetic
MANIFEST=$OUT/MANIFEST.tsv
SEED=20261008

[ -x "$LUAU" ] || {
	printf 'synth: missing %s; run make bootstrap\n' "$LUAU" >&2
	exit 1
}

find "$OUT" -mindepth 1 -maxdepth 1 ! -name README.md -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$OUT"
printf 'scenario\tkey\targv\trows\tseed\n' >"$MANIFEST"

gen() {
	rows=$1
	key=$2
	argv=$3
	shift 3
	dir=$OUT/rows-$rows
	mkdir -p "$dir"
	"$LUAU" "$ROOT/scripts/fixtures/synth.luau" -a "$rows" "$SEED" "$@" >"$dir/$key.txt"
	printf 'rows-%s\t%s\t%s\t%s\t%s\n' "$rows" "$key" "$argv" "$rows" "$SEED" >>"$MANIFEST"
}

for rows in 100 1000; do
	gen "$rows" get_pods "kubectl get pods"
	gen "$rows" get_pods_-o_wide "kubectl get pods -o wide" wide
	gen "$rows" get_pods_-A "kubectl get pods -A" all
	gen "$rows" get_pods_-A_-o_wide "kubectl get pods -A -o wide" all wide
done
