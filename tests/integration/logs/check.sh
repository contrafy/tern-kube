#!/bin/sh
# Guards the logs lens parser against kubectl format drift: runs the real
# `kubectl logs` forms of the track 2 plan (section 3) against tk-logmix on
# the kind sandbox and feeds each output (stdout, stderr, exit status)
# through tests/integration/logs/check.luau, which asserts no kubectl
# diagnostic becomes a record, the expected sources, JSON error lines
# classified `error`, and failed forms producing notices only.
#
#   sh tests/integration/logs/check.sh
#
# Only the sandbox kubeconfig (scripts/cluster.sh kubeconfig-path) and the
# kind-tern-kube-dev context are used; only namespace tern-test-logs is
# touched. The namespace stays: it is part of the fixture world e2e uses.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
LUAU=${LUAU:-$ROOT/.tools/bin/luau}
CTX=kind-tern-kube-dev
NS=${TK_LOGS_NAMESPACE:-tern-test-logs}
CHECK=tests/integration/logs/check.luau

die() {
	printf 'logs check: %s\n' "$*" >&2
	exit 1
}

[ "$NS" = tern-test-logs ] || die "refusing namespace $NS (only tern-test-logs)"
[ -x "$LUAU" ] || die "missing $LUAU; run make bootstrap"
KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable; run scripts/cluster.sh create"
export KUBECONFIG
KUBERC=off
export KUBERC
cd "$ROOT"

k() {
	kubectl --context "$CTX" "$@"
}

k apply -f tests/integration/manifests/00-namespaces.yaml >/dev/null
k apply -f tests/integration/manifests/logs/logmix.yaml >/dev/null

# Both tk-logmix pods run app and side, crashy has exited at least once, and
# app has printed its sampler plus a few ticks (as capture.sh's logmix_ready).
logmix_ready() {
	states=$(k get pods -n "$NS" -l app=tk-logmix -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{range .status.containerStatuses[*]}{.name}={.restartCount}:{.state.running.startedAt}{" "}{end}{"\n"}{end}')
	[ "$(printf '%s\n' "$states" | grep -c .)" = 2 ] || return 1
	printf '%s\n' "$states" | while IFS= read -r line; do
		case $line in
		"|"*) ;;
		*) return 1 ;;
		esac
		case $line in *"app=0:2"*) ;; *) return 1 ;; esac
		case $line in *"side=0:2"*) ;; *) return 1 ;; esac
		case $line in *"crashy=0:"*) return 1 ;; esac
	done || return 1
	p=$(k get pods -n "$NS" -l app=tk-logmix -o name | head -n 1)
	[ "$(k logs -n "$NS" "$p" -c app | grep -c '^WARN tick')" -ge 2 ]
}

waited=0
until logmix_ready >/dev/null 2>&1; do
	[ "$waited" -lt 300 ] || die "timed out after 300s waiting for tk-logmix (2 pods, crashy restarted)"
	sleep 2
	waited=$((waited + 2))
done

pod=$(k get pods -n "$NS" -l app=tk-logmix -o name | LC_ALL=C sort | head -n 1)
pod=${pod#pod/}
[ -n "$pod" ] || die "no tk-logmix pod"

# The generated driver must sit next to check.luau (luau resolves requires
# relative to the requiring file). The output is embedded, not passed as
# arguments: a long-running tk-logmix prints more than ARG_MAX.
WORK=$(mktemp -d "$ROOT/tests/integration/logs/.work.XXXXXX")
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

fails=0
n=0
# run NAME EXPECT kubectl-args...
run() {
	n=$((n + 1))
	printf '%s' "$1" >"$WORK/name"
	printf '%s' "$2" >"$WORK/expect"
	shift 2
	set +e
	k "$@" >"$WORK/out" 2>"$WORK/err"
	status=$?
	set -e
	printf '%s' "$status" >"$WORK/status"
	printf '%s' "kubectl $*" >"$WORK/argv"
	{
		printf -- '--!strict\n'
		printf 'local check = require("../check")\n'
		printf 'check({\n'
		for part in name expect status argv out err; do
			printf '\t'
			embed "$WORK/$part"
			printf ',\n'
		done
		printf '})\n'
		printf 'return nil\n'
	} >"$WORK/main.luau"
	if ! "$LUAU" "$WORK/main.luau"; then
		fails=$((fails + 1))
	fi
}

run "logs POD" pod logs -n "$NS" "$pod"
run "logs POD -c app --timestamps" pod logs -n "$NS" "$pod" -c app --timestamps
run "logs deploy/tk-logmix" found logs -n "$NS" deploy/tk-logmix
run "logs POD --all-containers" unattributed logs -n "$NS" "$pod" --all-containers
run "logs POD --all-containers --prefix --ts" prefixed logs -n "$NS" "$pod" --all-containers --prefix --timestamps
run "logs -l --all-containers --prefix --ts" prefixed logs -n "$NS" -l app=tk-logmix --all-containers --prefix --timestamps
run "logs -l -c app --prefix" prefixed logs -n "$NS" -l app=tk-logmix -c app --prefix
run "logs deploy --all-pods -c app --prefix" prefixed logs -n "$NS" deploy/tk-logmix --all-pods -c app --prefix
run "logs -l (no prefix)" unattributed logs -n "$NS" -l app=tk-logmix
run "logs POD -p -c crashy" previous logs -n "$NS" "$pod" -p -c crashy
run "logs POD -p -c app" failed logs -n "$NS" "$pod" -p -c app
run "logs POD -c nope" failed logs -n "$NS" "$pod" -c nope
run "logs nopod" failed logs -n "$NS" nopod
run "logs -f -l over --max-log-requests" failed logs -n "$NS" -f -l app=tk-logmix --all-containers --prefix --max-log-requests=2

if [ "$fails" -gt 0 ]; then
	die "$fails of $n logs forms failed"
fi
echo "all $n logs forms parsed as expected"
