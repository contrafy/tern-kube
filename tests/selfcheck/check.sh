#!/bin/sh
# Proves the runner detects failures: a green `make test` is only meaningful if
# failing, crashing and unloadable specs turn it red. Run from the repo root.
set -eu

LUAU=${LUAU:-.tools/bin/luau}
status=0

fail() {
	printf 'selfcheck: %s\n' "$*" >&2
	status=1
}

# expect_run EXPECTED_EXIT(0|nonzero) DESCRIPTION ARGS... ; output in $out
expect_run() {
	want=$1
	what=$2
	shift 2
	if out=$("$LUAU" tests/run.luau -a "$@" 2>&1); then
		code=0
	else
		code=1
	fi
	if [ "$want" = 0 ] && [ "$code" != 0 ]; then
		fail "$what: expected success, got failure"
		printf '%s\n' "$out" >&2
	elif [ "$want" != 0 ] && [ "$code" = 0 ]; then
		fail "$what: expected failure, got success"
		printf '%s\n' "$out" >&2
	fi
}

expect_output() {
	case "$out" in
	*"$1"*) ;;
	*) fail "output lacks: $1" ;;
	esac
}

expect_run nonzero "failing fixture" tests/selfcheck/failing.luau
expect_output "FAIL tests/selfcheck/failing.luau :: selfcheck > fails toBe"
expect_output 'expected "actual-value" to be "expected-value"'
expect_output "FAIL tests/selfcheck/failing.luau :: selfcheck > fails toEqual deep"
expect_output "values differ at <root>.spec.replicas"
expect_output "FAIL tests/selfcheck/failing.luau :: selfcheck > fails toThrow"
expect_output "FAIL tests/selfcheck/failing.luau :: selfcheck > raises a runtime error"
expect_output "PASS tests/selfcheck/failing.luau :: selfcheck > passing control"
expect_output "1 passed, 4 failed, 5 ran"

expect_run nonzero "unloadable fixture" tests/selfcheck/broken.luau
expect_output "FAIL tests/selfcheck/broken.luau :: <load>"
expect_output "broken spec fixture"

expect_run 0 "filter selecting the passing test" "passing control" tests/selfcheck/failing.luau
expect_output "1 passed, 0 failed, 1 ran"

expect_run nonzero "filter matching nothing" "no-such-test" tests/selfcheck/failing.luau
expect_output "no tests matched"

expect_run nonzero "no spec files"
expect_output "no spec files given"

if [ "$status" = 0 ]; then
	printf 'selfcheck: runner detects failures correctly\n'
fi
exit "$status"
