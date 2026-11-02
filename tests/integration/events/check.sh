#!/bin/sh
# Guards the events model against kubectl/server format drift: the real
# `get events -o json` and `kubectl events -o json` of tern-test-apps must
# decode into events that each name their involved object and carry a
# parseable last-seen time. Applies the apps fixture world first (idempotent,
# a fresh CI cluster has none) and waits until it has produced events; only
# read-only commands run after that. Pinned to the sandbox kubeconfig and the
# kind context.
#
#   sh tests/integration/events/check.sh
set -eu

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
CTX=kind-tern-kube-dev
NS=tern-test-apps
LUAU=$REPO/.tools/bin/luau
WAIT_SECONDS=120

cd "$REPO"
KUBECONFIG=$(sh scripts/cluster.sh kubeconfig-path)
export KUBECONFIG

kc() {
	kubectl --context "$CTX" "$@"
}

kc apply -f tests/integration/manifests/00-namespaces.yaml -f tests/integration/manifests/apps >/dev/null

waited=0
until [ -n "$(kc get events -n "$NS" -o jsonpath='{.items[*].metadata.uid}')" ]; do
	if [ "$waited" -ge "$WAIT_SECONDS" ]; then
		echo "events check: no events in $NS after ${WAIT_SECONDS}s" >&2
		exit 1
	fi
	sleep 2
	waited=$((waited + 2))
done

# The generated driver must sit next to check.luau: luau resolves requires
# relative to the requiring file.
WORK=$(mktemp -d "$REPO/tests/integration/events/.work.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

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

kc get events -n "$NS" -o json >"$WORK/get.json"
kc events -n "$NS" -o json >"$WORK/events.json"

{
	printf -- '--!strict\n'
	printf 'local check = require("../check")\n'
	printf 'check({\n'
	printf '\t{ form = "kubectl get events -n %s -o json", text = ' "$NS"
	embed "$WORK/get.json"
	printf ' },\n'
	printf '\t{ form = "kubectl events -n %s -o json", text = ' "$NS"
	embed "$WORK/events.json"
	printf ' },\n'
	printf '})\n'
	printf 'return nil\n'
} >"$WORK/main.luau"

"$LUAU" "$WORK/main.luau"
echo "events check: ok"
