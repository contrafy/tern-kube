#!/bin/sh
# Guards the usage views against kubectl/server drift: the plugin's own
# jsonpath reads (pods, pod metrics, nodes, node metrics, all pods) of the
# tern-test-usage world must parse and join into rows where every running
# pod has metrics, cpu-burner sits at its CPU limit, sidecar-init's
# effective request is its first init's, and each node's committed requests
# equal `kubectl describe node` plus the pod-level requests describe leaves
# out. Applies the usage fixture world and metrics-server first (idempotent,
# a fresh CI cluster has neither) and waits for the first metrics window;
# only read-only commands run after that. Pinned to the sandbox kubeconfig
# and the kind context.
#
#   sh tests/integration/usage/check.sh
set -eu

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
CTX=kind-tern-kube-dev
NS=tern-test-usage
LUAU=$REPO/.tools/bin/luau
WAIT_SECONDS=120
PODS=4

cd "$REPO"
KUBECONFIG=$(sh scripts/cluster.sh kubeconfig-path)
export KUBECONFIG

kc() {
	kubectl --context "$CTX" "$@"
}

kc apply -k tests/integration/manifests/metrics-server >/dev/null
kc apply -f tests/integration/manifests/00-namespaces.yaml -f tests/integration/manifests/usage >/dev/null
kc wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout="${WAIT_SECONDS}s" >/dev/null

# A pod appears in `kubectl top` only after its first full metrics window.
waited=0
until [ "$(kc top pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "$PODS" ]; do
	if [ "$waited" -ge "$WAIT_SECONDS" ]; then
		echo "usage check: fewer than $PODS pods with metrics in $NS after ${WAIT_SECONDS}s" >&2
		exit 1
	fi
	sleep 3
	waited=$((waited + 3))
done

# The generated drivers must sit next to check.luau: luau resolves requires
# relative to the requiring file.
WORK=$(mktemp -d "$REPO/tests/integration/usage/.work.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

{
	printf -- '--!strict\n'
	printf 'require("../check").argv("%s", "%s", "%s")\n' "$KUBECONFIG" "$CTX" "$NS"
	printf 'return nil\n'
} >"$WORK/argv.luau"
"$LUAU" "$WORK/argv.luau" >"$WORK/argv.txt"

reads=0
while read -r name cmd; do
	eval "$cmd" >"$WORK/$name.txt"
	reads=$((reads + 1))
done <"$WORK/argv.txt"
[ "$reads" -eq 5 ] || {
	echo "usage check: expected 5 plugin reads, got $reads" >&2
	exit 1
}
kc describe nodes >"$WORK/describe.txt"

# Long-bracket level that cannot occur in the text, as scripts/fixtures/embed.sh does.
embed() {
	eq="="
	while grep -qF "]$eq" "$1"; do
		eq="$eq="
	done
	printf '[%s[\n' "$eq"
	cat "$1"
	printf ']%s]' "$eq"
}

{
	printf -- '--!strict\n'
	printf 'require("../check").check({\n'
	printf '\tnamespace = "%s",\n' "$NS"
	for name in pods podmetrics nodes nodemetrics allpods describe; do
		printf '\t%s = ' "$name"
		embed "$WORK/$name.txt"
		printf ',\n'
	done
	printf '})\n'
	printf 'return nil\n'
} >"$WORK/main.luau"

"$LUAU" "$WORK/main.luau"
echo "usage check: ok"
