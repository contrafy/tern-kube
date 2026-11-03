#!/bin/sh
# Multi-cluster compare against two kind clusters (scripts/cluster.sh create
# && scripts/cluster.sh create-peer), through .sandbox/kubeconfig-mc only:
#   explore   driver.luau replays Explore's compare routes with real kubectl
#             answers (object, list, Secret, all contexts with an unreachable
#             third context added to a throwaway copy of the kubeconfig);
#   cli       bin/tern-kube-drift against both contexts (matrix cells, v1
#             output unchanged for one context, exit codes 1 and 2);
#   readonly  nothing in either cluster was written by the runs above.
# The world (tests/integration/manifests/compare: a.yaml in
# kind-tern-kube-dev, b.yaml in kind-tern-kube-dev2) is recreated in
# namespace tern-test-mc each run. Evidence lands in .sandbox/compare-it.
#
#   sh tests/integration/compare/run.sh [explore] [cli]   (default: both)
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$REPO" || exit 2
MC=$(sh scripts/cluster.sh mc-kubeconfig-path) || exit 2
KUBECONFIG=$MC
export KUBECONFIG
unset KUBECTL_EXTERNAL_DIFF
A=kind-tern-kube-dev
B=kind-tern-kube-dev2
DOWN=kind-tern-kube-down
NS=tern-test-mc
LUAU=$REPO/.tools/bin/luau
CLI=$REPO/bin/tern-kube-drift
M=$REPO/tests/integration/manifests/compare
OUT=$REPO/.sandbox/compare-it
MC3=$OUT/kubeconfig-3
T=$REPO/tests/integration/compare/.transcripts

sections=${*:-explore cli}
pass=0
failed=0
ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$*"
}
bad() {
	failed=$((failed + 1))
	printf 'FAIL %s\n' "$*"
}
die() {
	printf 'compare: %s\n' "$*" >&2
	exit 2
}

kc() { # kc CONTEXT ARGS...
	ctx_=$1
	shift
	kubectl --kubeconfig "$MC" --context "$ctx_" "$@"
}

command -v jq >/dev/null 2>&1 || die "jq is required"
rm -rf "$OUT" "$T"
mkdir -p "$OUT" "$T"
chmod 700 "$OUT"

# --- World -------------------------------------------------------------------

for pair in "$A a.yaml" "$B b.yaml"; do
	# shellcheck disable=SC2086 # "context file" pairs split on purpose
	set -- $pair
	kc "$1" delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null || die "cannot delete $NS in $1"
	kc "$1" apply -f "$M/$2" >/dev/null || die "cannot apply $2 to $1"
	kc "$1" -n "$NS" rollout status deployment --timeout=180s >/dev/null ||
		printf 'note: deployments in %s/%s not ready; spec, labels and annotations still compared\n' "$1" "$NS"
done

# A third context whose API server refuses connections, in a private copy.
(umask 077 && cp "$MC" "$MC3")
if ! {
	kubectl --kubeconfig "$MC3" config set-cluster "$DOWN" --server=https://127.0.0.1:1 >/dev/null &&
		kubectl --kubeconfig "$MC3" config set-credentials "$DOWN" --token=unused >/dev/null &&
		kubectl --kubeconfig "$MC3" config set-context "$DOWN" --cluster="$DOWN" --user="$DOWN" --namespace="$NS" >/dev/null
}; then
	die "cannot write $MC3"
fi

# What a read-only run must leave alone. Deployments keep reconciling their
# status (and with it resourceVersion) while pods start, so they are
# compared by generation, labels and annotations; everything else by
# resourceVersion.
snapshot() {
	for ctx in "$A" "$B"; do
		kc "$ctx" -n "$NS" get configmaps,secrets,services -o \
			jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.resourceVersion}{"\n"}{end}' | sed "s|^|$ctx |"
		kc "$ctx" -n "$NS" get deployments -o \
			jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.generation} {.metadata.labels} {.metadata.annotations}{"\n"}{end}' |
			sed "s|^|$ctx |"
	done | sort
}
snapshot >"$OUT/before.txt" || die "cannot snapshot $NS"

# --- Explore -----------------------------------------------------------------

hexof() {
	od -An -v -tx1 | tr -d ' \n'
}

# tk_need KEY TIMEOUT_MS ARGV...: run one read-only kubectl call the driver
# asked for, with the timeout Explore gives it, and record the answer.
tk_need() {
	key_=$1
	ms_=$2
	shift 2
	[ "$1" = kubectl ] || die "driver asked to run '$1'"
	kcfg_=
	prev_=
	for w_ in "$@"; do
		[ "$prev_" = --kubeconfig ] && kcfg_=$w_
		case $w_ in
		apply | create | delete | patch | edit | replace | scale | rollout | label | annotate | drain | cordon | uncordon | taint | set | exec | run | debug | cp | port-forward | attach | proxy)
			die "driver asked for a non-read-only call: $*"
			;;
		esac
		prev_=$w_
	done
	[ "$kcfg_" = "$MC" ] || [ "$kcfg_" = "$MC3" ] || die "driver asked for kubeconfig '$kcfg_': $*"
	secs_=$(((ms_ + 999) / 1000))
	[ "$secs_" -gt 0 ] || secs_=30
	start_=$(date +%s)
	"$@" >"$T/stdout" 2>"$T/stderr" &
	pid_=$!
	(sleep "$secs_" && kill "$pid_" 2>/dev/null) &
	dog_=$!
	wait "$pid_"
	rc_=$?
	kill "$dog_" 2>/dev/null
	wait "$dog_" 2>/dev/null
	took_=$(($(date +%s) - start_))
	timed_=false
	[ "$rc_" -gt 128 ] && [ "$took_" -ge "$secs_" ] && timed_=true
	printf '%s rc=%s %ss timed_out=%s\n' "$*" "$rc_" "$took_" "$timed_" >>"$OUT/explore-runs.log"
	case " $* " in
	*" --context $DOWN "*)
		if [ "$took_" -le "$secs_" ]; then
			ok "unreachable context answered within query_timeout_ms (${took_}s <= ${secs_}s): $*"
		else
			bad "unreachable context took ${took_}s (query_timeout_ms ${ms_}): $*"
		fi
		;;
	esac
	printf '\t["%s"] = { status = %d, out = "%s", err = "%s", timedOut = %s },\n' \
		"$key_" "$rc_" "$(hexof <"$T/stdout")" "$(hexof <"$T/stderr")" "$timed_" >>"$T/body"
}

tk_ok() {
	ok "explore $1"
}

tk_fail() {
	bad "explore $1: $2"
}

run_explore() {
	: >"$T/body"
	round=0
	while :; do
		{
			printf -- '--!strict\n-- Generated by run.sh: kubectl answers keyed by hex(argv joined by NUL).\nreturn {\n'
			cat "$T/body"
			printf '}\n'
		} >"$T/answers.luau"
		if ! lines=$("$LUAU" tests/integration/compare/driver.luau -a "$MC" "$MC3" 2>"$T/driver.err"); then
			bad "explore driver: $(cat "$T/driver.err")"
			return
		fi
		case $lines in
		tk_need*)
			round=$((round + 1))
			[ "$round" -le 40 ] || {
				bad "explore driver still needs answers after 40 rounds"
				return
			}
			eval "$lines"
			;;
		*)
			eval "$lines"
			return
			;;
		esac
	done
}

# --- CLI ---------------------------------------------------------------------

SRC=$M/source

# drift KUBECONFIG OUTFILE ARGS...: sets $rc.
drift() {
	k_=$1
	o_=$2
	shift 2
	KUBECONFIG=$k_ "$CLI" --kubeconfig "$k_" -f "$SRC" -n "$NS" "$@" >"$OUT/$o_" 2>"$OUT/$o_.err"
	rc=$?
}

expect_rc() { # expect_rc WHAT WANT OUTFILE
	if [ "$rc" = "$2" ]; then ok "$1: exit $rc"; else bad "$1: exit $rc, want $2 ($(head -c 400 "$OUT/$3.err"))"; fi
}

same() { # same WHAT GOT WANT
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi
}

# cells NAME KIND FILE: the row's cell states in context order.
cells() {
	jq -r --arg n "$1" --arg k "$2" \
		'[.matrix[] | select(.name == $n and .kind == $k) | .cells[].state] | join(" ")' "$OUT/$3"
}

expect_cells() { # expect_cells NAME KIND FILE WANT
	same "cli $3: $2/$1" "$(cells "$1" "$2" "$3")" "$4"
}

contains() { # contains WHAT FILE NEEDLE
	if grep -qF -- "$3" "$OUT/$2"; then ok "$1"; else bad "$1: \"$3\" not in $2"; fi
}

run_cli() {
	[ -x "$CLI" ] || die "missing $CLI"
	# One context: byte-identical to the current-context run (JSON v1).
	for fmt in text markdown json; do
		drift "$MC" "single-$fmt.implicit" --format "$fmt" --unmanaged deployments
		rc_implicit=$rc
		drift "$MC" "single-$fmt" --context "$A" --format "$fmt" --unmanaged deployments
		expect_rc "cli --context $A --format $fmt (unmanaged tkm-only-a is drift)" 1 "single-$fmt"
		if [ "$rc" = "$rc_implicit" ] && cmp -s "$OUT/single-$fmt" "$OUT/single-$fmt.implicit"; then
			ok "cli one --context equals the current-context run ($fmt)"
		else
			bad "cli one --context differs from the current-context run ($fmt, exit $rc vs $rc_implicit)"
		fi
	done
	same "cli one context: JSON version" "$(jq -r .version "$OUT/single-json")" 1

	drift "$MC" pair.json --context "$A" --context "$B" --format json --unmanaged deployments
	expect_rc "cli two contexts json" 1 pair.json
	same "cli two contexts: version and context statuses" \
		"$(jq -r '[.version, (.contexts | map(.context + "=" + .status) | join(","))] | join(" ")' "$OUT/pair.json")" \
		"2 $A=ok,$B=ok"
	expect_cells tkm-web Deployment pair.json "insync modify"
	expect_cells tkm-api Deployment pair.json "insync insync"
	expect_cells tkm-web Service pair.json "insync insync"
	expect_cells tkm-config ConfigMap pair.json "insync modify"
	expect_cells tkm-flags ConfigMap pair.json "insync create"
	expect_cells tkm-only-a Deployment pair.json "unmanaged absent"
	expect_cells tkm-only-b Deployment pair.json "absent unmanaged"

	drift "$MC" all.json --all-contexts --format json --unmanaged deployments
	expect_rc "cli --all-contexts json" 1 all.json
	same "cli --all-contexts: every context, in kubeconfig order" "$(jq -c '[.contexts[].context]' "$OUT/all.json")" "[\"$A\",\"$B\"]"
	same "cli --all-contexts: matrix equals both --context flags" \
		"$(jq -c .matrix "$OUT/all.json")" "$(jq -c .matrix "$OUT/pair.json")"

	drift "$MC" pair.txt --context "$A" --context "$B" --format text
	expect_rc "cli two contexts text" 1 pair.txt
	contains "cli text: matrix heading" pair.txt "across 2 contexts"
	contains "cli text: in sync cell" pair.txt "in sync"
	contains "cli text: per-context section" pair.txt "=== [$B] modify Deployment.apps $NS/tkm-web"

	drift "$MC" pair.md --context "$A" --context "$B" --format markdown
	expect_rc "cli two contexts markdown" 1 pair.md
	contains "cli markdown: matrix row" pair.md "tkm-web"
	contains "cli markdown: per-context details" pair.md "<details>"

	drift "$MC3" down.json --context "$A" --context "$B" --context "$DOWN" --format json
	expect_rc "cli with an unreachable context" 2 down.json
	same "cli unreachable context is an error column, the others still run" \
		"$(jq -r '.contexts | map(.status) | join(",")' "$OUT/down.json")" "ok,ok,error"
	expect_cells tkm-web Deployment down.json "insync modify error"

	drift "$MC" dup.txt --context "$A" --context "$A"
	expect_rc "cli duplicate --context is a usage error" 2 dup.txt
}

for s in $sections; do
	case $s in
	explore) run_explore ;;
	cli) run_cli ;;
	*) die "unknown section '$s' (explore, cli)" ;;
	esac
done

# --- Read-only -----------------------------------------------------------------

snapshot >"$OUT/after.txt" || die "cannot snapshot $NS"
if cmp -s "$OUT/before.txt" "$OUT/after.txt"; then
	ok "read-only: $(wc -l <"$OUT/before.txt" | tr -d ' ') objects in both clusters unchanged"
else
	bad "read-only: objects changed: $(diff "$OUT/before.txt" "$OUT/after.txt" | head -n 10)"
fi

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
