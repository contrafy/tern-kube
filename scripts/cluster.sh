#!/bin/sh
# Disposable kind cluster for kube-lens development and fixture capture.
#
#   scripts/cluster.sh create           create (or adopt) kind cluster kube-lens-dev
#   scripts/cluster.sh delete           delete it
#   scripts/cluster.sh kubeconfig-path  print the sandbox kubeconfig after verifying it
#   scripts/cluster.sh status           show cluster, context and node state
#
# The only kubeconfig this script ever reads or writes is .sandbox/kubeconfig.
# Every subcommand except create/delete refuses to proceed unless that file
# holds exactly one context, kind-kube-lens-dev, whose API server matches the
# one kind reports for the cluster it manages. An ambient KUBECONFIG pointing
# anywhere else is rejected rather than silently overridden.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KIND=${KIND:-$ROOT/.tools/bin/kind}
KUBECTL=${KUBECTL:-kubectl}
CLUSTER=kube-lens-dev
CONTEXT=kind-$CLUSTER
SANDBOX=$ROOT/.sandbox
KUBECONFIG_PATH=$SANDBOX/kubeconfig
NODE_IMAGE=${KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}

die() {
	printf 'cluster: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s create|delete|kubeconfig-path|status\n' "$0" >&2
	exit 2
}

require_tools() {
	[ -x "$KIND" ] || die "missing $KIND: run 'make bootstrap'"
	command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found (set KUBECTL=...)"
	command -v docker >/dev/null 2>&1 || die "docker not found"
	docker info >/dev/null 2>&1 || die "docker daemon is not reachable; start Docker"
}

refuse_foreign_kubeconfig() {
	if [ -n "${KUBECONFIG:-}" ] && [ "$KUBECONFIG" != "$KUBECONFIG_PATH" ]; then
		die "KUBECONFIG is set to '$KUBECONFIG'; this script only operates on $KUBECONFIG_PATH. Unset it or point it there."
	fi
}

cluster_exists() {
	"$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

kind_server() {
	"$KIND" get kubeconfig --name "$CLUSTER" | sed -n 's/^ *server: *//p' | head -n 1
}

kc() {
	"$KUBECTL" --kubeconfig "$KUBECONFIG_PATH" "$@"
}

verify() {
	cluster_exists || die "kind cluster '$CLUSTER' does not exist; run '$0 create'"
	[ -f "$KUBECONFIG_PATH" ] || die "missing $KUBECONFIG_PATH; run '$0 create'"
	contexts=$(kc config get-contexts -o name)
	[ "$contexts" = "$CONTEXT" ] || die "$KUBECONFIG_PATH must contain exactly one context '$CONTEXT' (found: $(printf '%s' "$contexts" | tr '\n' ' '))"
	current=$(kc config current-context 2>/dev/null || true)
	[ "$current" = "$CONTEXT" ] || die "current-context in $KUBECONFIG_PATH is '$current', expected '$CONTEXT'"
	server=$(kc config view -o jsonpath="{.clusters[?(@.name==\"$CONTEXT\")].cluster.server}")
	expected=$(kind_server)
	[ -n "$expected" ] || die "kind returned no API server for '$CLUSTER'"
	[ "$server" = "$expected" ] || die "API server in $KUBECONFIG_PATH ($server) is not the kind cluster's ($expected)"
	case $server in
	https://127.0.0.1:*) ;;
	*) die "API server $server is not a local kind endpoint" ;;
	esac
}

cmd_create() {
	mkdir -p "$SANDBOX"
	chmod 700 "$SANDBOX"
	if cluster_exists; then
		if [ ! -f "$KUBECONFIG_PATH" ]; then
			"$KIND" export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG_PATH" >/dev/null
		fi
	else
		if [ -f "$KUBECONFIG_PATH" ]; then
			contexts=$(kc config get-contexts -o name)
			[ -z "$contexts" ] || [ "$contexts" = "$CONTEXT" ] || die "$KUBECONFIG_PATH holds foreign contexts; refusing to modify it"
		fi
		"$KIND" create cluster --name "$CLUSTER" --image "$NODE_IMAGE" \
			--kubeconfig "$KUBECONFIG_PATH" --wait 180s
	fi
	chmod 600 "$KUBECONFIG_PATH"
	verify
	kc wait --for=condition=Ready node --all --timeout=180s >/dev/null
	printf 'cluster %s ready; KUBECONFIG=%s\n' "$CLUSTER" "$KUBECONFIG_PATH"
}

cmd_delete() {
	if cluster_exists; then
		"$KIND" delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG_PATH"
	else
		printf 'cluster %s does not exist\n' "$CLUSTER"
	fi
	rm -f "$KUBECONFIG_PATH"
}

cmd_status() {
	if ! cluster_exists; then
		printf 'cluster %s: absent\n' "$CLUSTER"
		return 0
	fi
	verify
	printf 'cluster %s: present\nkubeconfig: %s\ncontext: %s\nserver: %s\n' \
		"$CLUSTER" "$KUBECONFIG_PATH" "$CONTEXT" "$(kind_server)"
	kc get nodes -o wide
}

[ $# -eq 1 ] || usage
refuse_foreign_kubeconfig
require_tools
case $1 in
create) cmd_create ;;
delete) cmd_delete ;;
kubeconfig-path)
	verify
	printf '%s\n' "$KUBECONFIG_PATH"
	;;
status) cmd_status ;;
*) usage ;;
esac
