#!/bin/sh
# Disposable kind clusters for tern-kube development and fixture capture.
#
#   scripts/cluster.sh create              create (or adopt) kind cluster tern-kube-dev and
#                                          apply the quick-action toolbox (tern-test-mutate)
#   scripts/cluster.sh delete              delete it (and the merged kubeconfig)
#   scripts/cluster.sh kubeconfig-path     print the sandbox kubeconfig after verifying it
#   scripts/cluster.sh create-peer         create (or adopt) the second cluster tern-kube-dev2
#                                          and write the merged two-context kubeconfig
#   scripts/cluster.sh delete-peer         delete the second cluster and both of its kubeconfigs
#   scripts/cluster.sh mc-kubeconfig-path  print the merged kubeconfig after verifying it
#   scripts/cluster.sh status              show both clusters, contexts and node state
#
# The only kubeconfigs this script ever reads or writes are .sandbox/kubeconfig
# (context kind-tern-kube-dev), .sandbox/kubeconfig-dev2 (kind-tern-kube-dev2)
# and .sandbox/kubeconfig-mc (both, current-context kind-tern-kube-dev; the
# multi-cluster compare tests use it). Every subcommand except create/delete
# refuses to proceed unless each file it uses holds exactly its contexts, and
# every API server matches the one kind reports for the cluster it manages.
# An ambient KUBECONFIG pointing anywhere else is rejected rather than
# silently overridden.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KIND=${KIND:-$ROOT/.tools/bin/kind}
KUBECTL=${KUBECTL:-kubectl}
CLUSTER=tern-kube-dev
CONTEXT=kind-$CLUSTER
PEER=tern-kube-dev2
PEER_CONTEXT=kind-$PEER
SANDBOX=$ROOT/.sandbox
KUBECONFIG_PATH=$SANDBOX/kubeconfig
PEER_KUBECONFIG=$SANDBOX/kubeconfig-dev2
MC_KUBECONFIG=$SANDBOX/kubeconfig-mc
NODE_IMAGE=${KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}

die() {
	printf 'cluster: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s create|delete|kubeconfig-path|create-peer|delete-peer|mc-kubeconfig-path|status\n' "$0" >&2
	exit 2
}

require_tools() {
	[ -x "$KIND" ] || die "missing $KIND: run 'make bootstrap'"
	command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found (set KUBECTL=...)"
	command -v docker >/dev/null 2>&1 || die "docker not found"
	docker info >/dev/null 2>&1 || die "docker daemon is not reachable; start Docker"
}

refuse_foreign_kubeconfig() {
	case ${KUBECONFIG:-} in
	'' | "$KUBECONFIG_PATH" | "$PEER_KUBECONFIG" | "$MC_KUBECONFIG") ;;
	*) die "KUBECONFIG is set to '$KUBECONFIG'; this script only operates on $SANDBOX/kubeconfig*. Unset it or point it there." ;;
	esac
}

# exists CLUSTER
exists() {
	"$KIND" get clusters 2>/dev/null | grep -qx "$1"
}

# kind_server CLUSTER
kind_server() {
	"$KIND" get kubeconfig --name "$1" | sed -n 's/^ *server: *//p' | head -n 1
}

# kc_at FILE ARGS...
kc_at() {
	file_=$1
	shift
	"$KUBECTL" --kubeconfig "$file_" "$@"
}

kc() {
	kc_at "$KUBECONFIG_PATH" "$@"
}

# check_server FILE CONTEXT CLUSTER: the context's API server is the kind
# cluster's own, on loopback.
check_server() {
	server=$(kc_at "$1" config view -o jsonpath="{.clusters[?(@.name==\"$2\")].cluster.server}")
	expected=$(kind_server "$3")
	[ -n "$expected" ] || die "kind returned no API server for '$3'"
	[ "$server" = "$expected" ] || die "API server of $2 in $1 ($server) is not the kind cluster's ($expected)"
	case $server in
	https://127.0.0.1:*) ;;
	*) die "API server $server is not a local kind endpoint" ;;
	esac
}

# verify_single CLUSTER CONTEXT FILE
verify_single() {
	exists "$1" || die "kind cluster '$1' does not exist; run '$0 $(create_verb "$1")'"
	[ -f "$3" ] || die "missing $3; run '$0 $(create_verb "$1")'"
	contexts=$(kc_at "$3" config get-contexts -o name)
	[ "$contexts" = "$2" ] || die "$3 must contain exactly one context '$2' (found: $(printf '%s' "$contexts" | tr '\n' ' '))"
	current=$(kc_at "$3" config current-context 2>/dev/null || true)
	[ "$current" = "$2" ] || die "current-context in $3 is '$current', expected '$2'"
	check_server "$3" "$2" "$1"
}

create_verb() {
	if [ "$1" = "$PEER" ]; then echo create-peer; else echo create; fi
}

verify() {
	verify_single "$CLUSTER" "$CONTEXT" "$KUBECONFIG_PATH"
}

verify_peer() {
	verify_single "$PEER" "$PEER_CONTEXT" "$PEER_KUBECONFIG"
}

verify_mc() {
	verify
	verify_peer
	[ -f "$MC_KUBECONFIG" ] || die "missing $MC_KUBECONFIG; run '$0 create-peer'"
	contexts=$(kc_at "$MC_KUBECONFIG" config get-contexts -o name | sort | tr '\n' ' ')
	[ "$contexts" = "$CONTEXT $PEER_CONTEXT " ] ||
		die "$MC_KUBECONFIG must contain exactly the contexts '$CONTEXT' and '$PEER_CONTEXT' (found: $contexts)"
	current=$(kc_at "$MC_KUBECONFIG" config current-context 2>/dev/null || true)
	[ "$current" = "$CONTEXT" ] || die "current-context in $MC_KUBECONFIG is '$current', expected '$CONTEXT'"
	check_server "$MC_KUBECONFIG" "$CONTEXT" "$CLUSTER"
	check_server "$MC_KUBECONFIG" "$PEER_CONTEXT" "$PEER"
}

# ensure_cluster CLUSTER CONTEXT FILE: create it, or adopt an existing one
# (exporting its kubeconfig when the file is missing).
ensure_cluster() {
	mkdir -p "$SANDBOX"
	chmod 700 "$SANDBOX"
	if exists "$1"; then
		if [ ! -f "$3" ]; then
			"$KIND" export kubeconfig --name "$1" --kubeconfig "$3" >/dev/null
		fi
	else
		if [ -f "$3" ]; then
			contexts=$(kc_at "$3" config get-contexts -o name)
			[ -z "$contexts" ] || [ "$contexts" = "$2" ] || die "$3 holds foreign contexts; refusing to modify it"
		fi
		"$KIND" create cluster --name "$1" --image "$NODE_IMAGE" --kubeconfig "$3" --wait 180s
	fi
	chmod 600 "$3"
	verify_single "$1" "$2" "$3"
	kc_at "$3" wait --for=condition=Ready node --all --timeout=180s >/dev/null
}

# Rebuilt from the two verified single-context files every time, so it can
# never carry a context neither of them has.
write_mc() {
	tmp=$MC_KUBECONFIG.tmp.$$
	(umask 077 && KUBECONFIG="$KUBECONFIG_PATH:$PEER_KUBECONFIG" "$KUBECTL" config view --flatten --raw >"$tmp")
	kc_at "$tmp" config use-context "$CONTEXT" >/dev/null
	chmod 600 "$tmp"
	mv "$tmp" "$MC_KUBECONFIG"
	verify_mc
}

# Shell/logs/port-forward target for the quick-action e2e scenarios
# (Deployment + Service tk-qa-shell). Idempotent.
apply_toolbox() {
	kc apply -f "$ROOT/tests/integration/manifests/mutate/namespace.yaml" >/dev/null
	kc apply -f "$ROOT/tests/integration/manifests/qa/toolbox.yaml" >/dev/null
	kc rollout status deployment/tk-qa-shell -n tern-test-mutate --timeout=180s >/dev/null
}

cmd_create() {
	ensure_cluster "$CLUSTER" "$CONTEXT" "$KUBECONFIG_PATH"
	apply_toolbox
	printf 'cluster %s ready; KUBECONFIG=%s\n' "$CLUSTER" "$KUBECONFIG_PATH"
}

cmd_create_peer() {
	verify
	ensure_cluster "$PEER" "$PEER_CONTEXT" "$PEER_KUBECONFIG"
	write_mc
	printf 'cluster %s ready; KUBECONFIG=%s (both clusters: %s)\n' "$PEER" "$PEER_KUBECONFIG" "$MC_KUBECONFIG"
}

# delete_cluster CLUSTER FILE
delete_cluster() {
	if exists "$1"; then
		"$KIND" delete cluster --name "$1" --kubeconfig "$2"
	else
		printf 'cluster %s does not exist\n' "$1"
	fi
	rm -f "$2" "$MC_KUBECONFIG"
}

# status_one CLUSTER CONTEXT FILE
status_one() {
	if ! exists "$1"; then
		printf 'cluster %s: absent\n' "$1"
		return 0
	fi
	verify_single "$1" "$2" "$3"
	printf 'cluster %s: present\nkubeconfig: %s\ncontext: %s\nserver: %s\n' \
		"$1" "$3" "$2" "$(kind_server "$1")"
	kc_at "$3" get nodes -o wide
}

cmd_status() {
	status_one "$CLUSTER" "$CONTEXT" "$KUBECONFIG_PATH"
	status_one "$PEER" "$PEER_CONTEXT" "$PEER_KUBECONFIG"
	if exists "$CLUSTER" && exists "$PEER"; then
		if [ -f "$MC_KUBECONFIG" ]; then
			verify_mc
			printf 'merged kubeconfig: %s (%s, %s)\n' "$MC_KUBECONFIG" "$CONTEXT" "$PEER_CONTEXT"
		else
			printf 'merged kubeconfig: missing; run %s create-peer\n' "$0"
		fi
	fi
}

[ $# -eq 1 ] || usage
refuse_foreign_kubeconfig
require_tools
case $1 in
create) cmd_create ;;
delete) delete_cluster "$CLUSTER" "$KUBECONFIG_PATH" ;;
kubeconfig-path)
	verify
	printf '%s\n' "$KUBECONFIG_PATH"
	;;
create-peer) cmd_create_peer ;;
delete-peer) delete_cluster "$PEER" "$PEER_KUBECONFIG" ;;
mc-kubeconfig-path)
	verify_mc
	printf '%s\n' "$MC_KUBECONFIG"
	;;
status) cmd_status ;;
*) usage ;;
esac
