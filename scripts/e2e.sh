#!/bin/sh
# End-to-end tests in a real, isolated Tern window (`make e2e`). Local only:
# needs Tern, jq, a desktop session and the disposable kind cluster
# kube-lens-dev (scripts/cluster.sh create); skipped with a message when
# `tern` is not installed.
#
#   scripts/e2e.sh [--only GLOB] [--shots] [--perf] [--keep]
#
# Scenarios (tests/e2e/scenarios/*.sh) run the real kubectl, read-only, with
# KUBECONFIG=.sandbox/kubeconfig against the tern-test-* world. The few cases
# a live read-only cluster cannot produce (mutation results, 1000+ rows,
# 16 MiB output) switch the pane to the fake kubectl serving recorded
# fixtures and say so in the scenario. --shots writes
# docs/screenshots/m1-*.png, --perf prints in-window timings for
# docs/performance.md, --keep leaves the window running.
#
# The window runs in its own sandbox (KL_E2E_SANDBOX, default
# /tmp/kl-tern-e2e) with a snapshot copy of plugin/, so edits made while it
# runs do not reload the plugin under test.

set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tern_bin=${TERN_BIN:-tern}

if ! command -v "$tern_bin" >/dev/null 2>&1; then
	echo "e2e: SKIPPED: \`$tern_bin\` is not installed; the e2e suite drives a real Tern window."
	exit 0
fi
command -v jq >/dev/null 2>&1 || {
	echo "e2e: jq is required" >&2
	exit 2
}

only="*"
shots=0
perf=0
keep=0
while [ $# -gt 0 ]; do
	case $1 in
	--only)
		only=$2
		shift
		;;
	--shots) shots=1 ;;
	--perf) perf=1 ;;
	--keep) keep=1 ;;
	*)
		sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
		exit 2
		;;
	esac
	shift
done

export KL_TERN_SANDBOX="${KL_E2E_SANDBOX:-/tmp/kl-tern-e2e}"
export E2E_REPO="$repo"
# shellcheck source=../tests/e2e/lib.sh
. "$repo/tests/e2e/lib.sh"

# Safety before any window starts: the real kubectl must talk to kind only.
kubeconfig="$repo/.sandbox/kubeconfig"
real_kubectl=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$repo/tests/bin\$" | paste -sd: -) command -v kubectl || true)
need() {
	echo "e2e: $*" >&2
	exit 1
}
[ -n "$real_kubectl" ] || need "kubectl not found on PATH"
[ -f "$kubeconfig" ] || need "$kubeconfig missing: run scripts/cluster.sh create"
[ "$(KUBECONFIG=$kubeconfig "$real_kubectl" config current-context 2>/dev/null)" = kind-kube-lens-dev ] ||
	need "$kubeconfig is not context kind-kube-lens-dev"
KUBECONFIG=$kubeconfig "$real_kubectl" --request-timeout=5s get --raw /readyz >/dev/null 2>&1 ||
	need "kind-kube-lens-dev is not reachable (start Docker; scripts/cluster.sh status)"
KUBECONFIG=$kubeconfig "$real_kubectl" --request-timeout=5s get pod crashloop -n tern-test-apps >/dev/null 2>&1 ||
	need "the tern-test-* world is missing: sh scripts/fixtures/capture.sh --reuse"
export E2E_REAL_KUBECTL="$real_kubectl" E2E_KUBECONFIG="$kubeconfig"

cleanup() {
	clip_restore
	if [ $keep = 0 ]; then
		dev stop >/dev/null 2>&1
		i=0
		while [ -n "${window_pid:-}" ] && kill -0 "$window_pid" 2>/dev/null && [ $i -lt 40 ]; do
			sleep 0.25
			i=$((i + 1))
		done
		[ -n "${window_pid:-}" ] && kill "$window_pid" 2>/dev/null
		sleep 0.5
		rm -rf "$E2E_SB" 2>/dev/null || { sleep 1 && rm -rf "$E2E_SB"; }
	else
		echo "e2e: window kept running (KL_TERN_SANDBOX=$E2E_SB sh scripts/dev-tern.sh stop)"
	fi
}

dev stop >/dev/null 2>&1
rm -rf "$E2E_SB"
mkdir -p "$E2E_SB"
cp -R "$repo/plugin" "$E2E_SB/plugin"
clip_save
trap cleanup EXIT
trap 'exit 130' INT TERM

dev start >"$E2E_SB/window.out" 2>&1 &
window_pid=$!
E2E_WAIT=30 wait_for "the sandbox window" ctl ready || {
	cat "$E2E_SB/window.out" >&2
	exit 1
}
dev link "$E2E_SB/plugin" >/dev/null 2>&1 || need "cannot link the plugin"
E2E_WAIT=30 wait_for "the first prompt" ctl ready || exit 1
ctl resize 1280 800 >/dev/null
sleep 1

# Same check inside the pane the scenarios type into.
sh_line clear
sh_line 'print -r -- KL_CHECK $(command -v kubectl) $(kubectl config current-context)'
ctl expect "\"KL_CHECK $real_kubectl kind-kube-lens-dev\"" | grep -q '"ok":true' ||
	need "the sandbox pane does not run $real_kubectl against kind-kube-lens-dev"
log_start=$(log_lines)

failed=""
passed=0
for f in "$repo"/tests/e2e/scenarios/*.sh; do
	name=$(basename "$f" .sh)
	# shellcheck disable=SC2254
	case $name in
	$only) ;;
	*) continue ;;
	esac
	echo "RUN  $name"
	if (
		reset_pane
		. "$f"
		exit $E2E_FAILED
	); then
		passed=$((passed + 1))
		echo "ok   $name"
	else
		failed="$failed $name"
		echo "FAIL $name"
		ctl shot "e2e-fail-$name" >/dev/null 2>&1 && echo "     shot: $E2E_SB/target/shots/tern/live/e2e-fail-$name.png"
		ctl key escape >/dev/null 2>&1
		ctl key ctrl+c >/dev/null 2>&1
	fi
done

# Whole-run checks: the sheet parsed and no view or event fell back to raw.
if grep -q 'plugin style sheet has errors sheet="plugin:local:kube-lens' "$(window_log)"; then
	failed="$failed stylesheet"
	echo "FAIL stylesheet: $(grep -o 'message: "[^"]*"' "$(window_log)" | head -3)"
fi
if tail -n +"$((log_start + 1))" "$(daemon_log)" | grep -q 'kube-lens .* failed; showing raw'; then
	failed="$failed lens-errors"
	echo "FAIL lens errors:"
	tail -n +"$((log_start + 1))" "$(daemon_log)" | grep 'failed; showing raw' | head -5
fi

if [ $shots = 1 ]; then
	(
		reset_pane
		. "$repo/tests/e2e/shots.sh"
	) || failed="$failed shots"
fi
if [ $perf = 1 ]; then
	(
		reset_pane
		. "$repo/tests/e2e/perf.sh"
	) || failed="$failed perf"
fi

if [ -n "$failed" ]; then
	echo "e2e: $passed passed; FAILED:$failed"
	exit 1
fi
echo "e2e: $passed passed"
