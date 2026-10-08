#!/bin/sh
# Tests for the kube-lens shell guard (shell/kube-lens-guard and the zsh, bash
# and fish activation snippets). No Tern and no cluster: a fake `tern` plays
# the approve block and a fake `kubectl` records what would have run. Each
# case asserts the property the guard exists for: a mutation runs only after
# a matching approval, exactly as typed; everything else is untouched.
#
#   sh tests/shell/guard/run.sh      (or: make test-shell-guard)

set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
here=$repo/tests/shell/guard
core=$repo/shell/kube-lens-guard
luau=${LUAU:-$repo/.tools/bin/luau}
case $luau in
/*) ;;
*) luau=$PWD/$luau ;;
esac

root=$(mktemp -d "${TMPDIR:-/tmp}/klg-test.XXXXXX") || exit 2
root=$(cd -P "$root" && pwd -P)
trap 'rm -rf "$root"' EXIT

# Only the fakes and the shells under test are reachable: never a real tern
# or kubectl (shells are linked one by one because a real tern may share
# their directory).
mkdir -p "$root/shellbin" "$root/home"
shells=
for s in zsh bash fish dash; do
	p=$(command -v "$s" 2>/dev/null) || continue
	ln -s "$p" "$root/shellbin/$s"
	shells="$shells $s"
done
PATH=$here/bin:$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin
HOME=$root/home
XDG_CONFIG_HOME=$root/home/.config
XDG_DATA_HOME=$root/home/.local/share
XDG_CACHE_HOME=$root/home/.cache
export PATH HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
unset KUBECONFIG TERN_BIN KUBE_LENS_GUARD_TIMEOUT ZDOTDIR FAKE_READ_STDIN BASH_ENV ENV PROMPT_COMMAND
FAKE_DIR=$root/fake
export FAKE_DIR

pass=0
failed=0
skipped=0
case_name=

ok() {
	pass=$((pass + 1))
}

bad() {
	failed=$((failed + 1))
	printf 'FAIL [%s] %s\n' "$case_name" "$*"
	if [ -s "$root/out" ]; then
		sed 's/^/    | /' "$root/out"
	fi
}

skip() {
	skipped=$((skipped + 1))
	printf 'SKIP [%s] %s\n' "$case_name" "$*"
}

# Fresh fake state, spool and work dir; the environment of a new Tern pane.
fresh() {
	case_name=$1
	rm -rf "$FAKE_DIR" "$root/spool" "$root/work"
	mkdir -p "$FAKE_DIR" "$root/work/my dir/sub" "$root/work/kust"
	echo kind-dev >"$FAKE_DIR/context"
	mkdir -m 755 "$root/spool"
	printf 'kind: ConfigMap\n' >"$root/work/my dir/a b.yaml"
	printf '{"kind":"Secret"}\n' >"$root/work/my dir/c.json"
	printf 'not a manifest\n' >"$root/work/my dir/notes.txt"
	printf 'kind: Pod\n' >"$root/work/my dir/sub/nested.yml"
	printf 'resources: [x.yaml]\n' >"$root/work/kust/kustomization.yaml"
	printf 'kind: Service\n' >"$root/work/kust/x.yaml"
	TERM_PROGRAM=tern
	TERN_PANE=4294967309
	KUBE_LENS_SPOOL=$root/spool
	export TERM_PROGRAM TERN_PANE KUBE_LENS_SPOOL
	unset KUBECONFIG KUBE_LENS_GUARD_TIMEOUT TERN_BIN FAKE_READ_STDIN
	cd "$root/work" || exit 2
	: >"$root/out"
}

mode() {
	echo "$1" >"$FAKE_DIR/tern-mode"
}

# run_code SHELL CODE ARGS...: runs CODE in SHELL (no rc files) with ARGS as
# its positional arguments ($argv in fish); output in $root/out, status in $st.
run_code() {
	sh_=$1
	code_=$2
	shift 2
	case $sh_ in
	zsh) zsh -f -c "$code_" zsh "$@" ;;
	bash) bash --norc --noprofile -c "$code_" bash "$@" ;;
	fish) fish --no-config -c "$code_" -- "$@" ;;
	dash) dash -c "$code_" dash "$@" ;;
	esac >"$root/out" 2>&1 <"${STDIN_FILE:-/dev/null}"
	st=$?
}

# Code that sources the snippet of SHELL and runs `kubectl ARGS...` (dash has
# no snippet: it runs the core directly, as the zsh/bash/fish functions do).
kcode() {
	case $1 in
	zsh | bash) printf '%s' 'source "$KLG_SNIP"; kubectl "$@"' ;;
	fish) printf '%s' 'source $KLG_SNIP; kubectl $argv' ;;
	dash) printf '%s' '"$KLG_CORE" kubectl "$@"' ;;
	esac
}

# run_k SHELL ARGS...: `kubectl ARGS...` through the guard in SHELL.
run_k() {
	sh_k=$1
	shift
	run_code "$sh_k" "$(kcode "$sh_k")" "$@"
}

expect_status() {
	if [ "$st" = "$1" ]; then ok; else bad "$2: exit $st, want $1"; fi
}

expect_out() {
	if grep -E -q -- "$1" "$root/out"; then ok; else bad "$2: output lacks /$1/"; fi
}

expect_no_out() {
	if grep -E -q -- "$1" "$root/out"; then bad "$2: output has /$1/"; else ok; fi
}

# launch_group SHELL ARGS...: like run_k, but replaces the current (sub)shell
# with the kubectl call running as the leader of a new process group whose id
# is this (sub)shell's pid, with SIGINT/SIGQUIT at their defaults, as in a
# terminal's foreground job. Without job control (dash ignores `set -m` with
# no terminal) a background job starts with both ignored and a shell cannot
# trap a signal ignored on entry, so perl (on macOS and the Linux runners)
# sets them up explicitly.
launch_group() {
	sh_l=$1
	shift
	code_l=$(kcode "$sh_l")
	case $sh_l in
	zsh) set -- zsh -f -c "$code_l" zsh "$@" ;;
	bash) set -- bash --norc --noprofile -c "$code_l" bash "$@" ;;
	fish) set -- fish --no-config -c "$code_l" -- "$@" ;;
	dash) set -- dash -c "$code_l" dash "$@" ;;
	esac
	exec perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' "$@"
}

expect_not_run() {
	if [ -e "$FAKE_DIR/call-1" ]; then bad "$1: kubectl ran: $(tr '\0' ' ' <"$FAKE_DIR/call-1")"; else ok; fi
}

expect_no_tern() {
	if [ -e "$FAKE_DIR/tern-calls" ]; then bad "$1: tern was invoked"; else ok; fi
}

# expect_ran ARGS...: kubectl ran exactly once, with exactly ARGS.
expect_ran() {
	what_=$1
	shift
	printf '%s\0' "$@" >"$root/want"
	if [ ! -e "$FAKE_DIR/call-1" ]; then
		bad "$what_: kubectl did not run"
	elif [ -e "$FAKE_DIR/call-2" ]; then
		bad "$what_: kubectl ran more than once"
	elif cmp -s "$root/want" "$FAKE_DIR/call-1"; then
		ok
	else
		bad "$what_: kubectl argv $(tr '\0' '|' <"$FAKE_DIR/call-1"), want $(tr '\0' '|' <"$root/want")"
	fi
}

# The spool holds no request/response left behind (cancel markers allowed).
expect_spool_clean() {
	left=$(cd "$root/spool" 2>/dev/null && ls -A | grep -v '^cancel-')
	if [ -z "$left" ]; then ok; else bad "$1: spool not cleaned: $left"; fi
}

req() {
	cat "$FAKE_DIR/req.json"
}

reqtool() {
	(cd "$here" && "$luau" request.luau -a "$@")
}

sha256_() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# The request is valid JSON with the documented keys, carries ARGS as argv
# and a fingerprint equal to the documented canonical string's sha256.
expect_request() {
	what_=$1
	shift
	if [ ! -s "$FAKE_DIR/req.json" ]; then
		bad "$what_: no request reached tern"
		return
	fi
	if [ -x "$luau" ]; then
		if msg_=$(reqtool strict "$(req)" 2>&1); then ok; else bad "$what_: request keys: $msg_"; fi
		if msg_=$(reqtool argv "$(req)" "$@" 2>&1); then ok; else bad "$what_: request argv: $msg_"; fi
		for canon_ in canon canon-plugin; do
			want_fp=$(reqtool "$canon_" "$(req)" | sha256_)
			want_fp=${want_fp%% *}
			if req | grep -q "\"fingerprint\":\"$want_fp\""; then ok; else bad "$what_: fingerprint is not sha256 of the $canon_ string"; fi
		done
	else
		skip "$what_: request checks need $luau (make bootstrap)"
	fi
	if req | grep -Eq '"nonce":"[0-9a-f]{32}"'; then ok; else bad "$what_: nonce is not 32 lowercase hex"; fi
	if [ "$(cat "$FAKE_DIR/req-mode")" = -rw------- ]; then ok; else bad "$what_: request mode $(cat "$FAKE_DIR/req-mode")"; fi
	if [ "$(cat "$FAKE_DIR/spool-mode")" = drwx------ ]; then ok; else bad "$what_: spool mode $(cat "$FAKE_DIR/spool-mode")"; fi
}

req_field() {
	reqtool field "$(req)" "$1" 2>/dev/null
}

expect_field() {
	got_=$(req_field "$1")
	if [ "$got_" = "$2" ]; then ok; else bad "$3: request $1 = '$got_', want '$2'"; fi
}

expect_files() { # what, then the expected sorted paths
	what_=$1
	shift
	reqtool files "$(req)" >"$root/got-files" 2>&1
	: >"$root/want-files"
	for f_ in "$@"; do printf '%s\n' "$f_" >>"$root/want-files"; done
	if cmp -s "$root/got-files" "$root/want-files"; then ok; else bad "$what_: request files: $(tr '\n' '|' <"$root/got-files")"; fi
}

W=$root/work

# Behavior of the core, identical whichever shell calls it.
core_cases() {
	sh=$1

	fresh "$sh pass-through"
	printf 'line one\n\tbinary\001 bytes\n' >"$root/stdin"
	echo 7 >"$FAKE_DIR/exit"
	unset TERM_PROGRAM TERN_PANE KUBE_LENS_SPOOL
	FAKE_READ_STDIN=1
	export FAKE_READ_STDIN
	STDIN_FILE=$root/stdin run_k "$sh" get pods -o 'jsonpath={.items[*]}' 'a b' '' --selector='x in (a,b)'
	expect_status 7 "exit status of a non-guarded verb"
	expect_ran "non-guarded argv" get pods -o 'jsonpath={.items[*]}' 'a b' '' --selector='x in (a,b)'
	if cmp -s "$root/stdin" "$FAKE_DIR/stdin-1"; then ok; else bad "stdin not passed through unchanged"; fi
	expect_no_tern "non-guarded verb"
	[ -z "$(cat "$root/out")" ] && ok || bad "non-guarded verb printed guard output"

	for args in "rollout status deploy/web" "-n kube-system get pods" "--context=prod logs -f web" "diff -f x.yaml" "apply-set foo"; do
		fresh "$sh pass-through: $args"
		# shellcheck disable=SC2086
		run_k "$sh" $args
		expect_status 0 "$args"
		# shellcheck disable=SC2086
		expect_ran "$args" $args
		expect_no_tern "$args"
	done

	fresh "$sh server dry-run needs no approval"
	unset TERM_PROGRAM
	run_k "$sh" apply -f 'my dir/a b.yaml' --dry-run=server
	expect_status 0 "dry-run apply"
	expect_ran "dry-run apply" apply -f 'my dir/a b.yaml' --dry-run=server
	expect_no_tern "dry-run apply"

	fresh "$sh approve apply -f path with spaces"
	echo 5 >"$FAKE_DIR/exit"
	run_k "$sh" apply -f 'my dir/a b.yaml' -n 'team a'
	expect_status 5 "exit status forwarded after approval"
	expect_ran "approved argv" apply -f 'my dir/a b.yaml' -n 'team a'
	expect_request "apply request" kubectl apply -f 'my dir/a b.yaml' -n 'team a'
	expect_files "apply file" "$W/my dir/a b.yaml"
	expect_field context kind-dev "apply request"
	expect_field context_source current-context "apply request"
	expect_field namespace 'team a' "apply request"
	expect_field kubeconfig null "apply request"
	expect_field cwd "$W" "apply request"
	expect_field pane 4294967309 "apply request"
	expect_field program "$here/bin/kubectl" "apply request"
	expect_field timeout_s 600 "apply request"
	expect_spool_clean "after approval"
	want_call="open --wait $root/spool/$(sed -n 's/.*"nonce":"\([0-9a-f]*\)".*/req-\1.json/p' "$FAKE_DIR/req.json")"
	if [ "$(cat "$FAKE_DIR/tern-calls")" = "$want_call" ]; then ok; else bad "tern open argv: $(cat "$FAKE_DIR/tern-calls")"; fi

	fresh "$sh -f directory"
	run_k "$sh" apply --filename 'my dir'
	expect_status 0 "apply dir"
	expect_files "dir lists only top-level manifests" "$W/my dir/a b.yaml" "$W/my dir/c.json"
	fresh "$sh -f directory -R"
	run_k "$sh" apply -Rf "$W/my dir/"
	expect_status 0 "apply dir -R"
	expect_ran "apply dir -R argv" apply -Rf "$W/my dir/"
	expect_files "-R recurses" "$W/my dir/a b.yaml" "$W/my dir/c.json" "$W/my dir/sub/nested.yml"
	fresh "$sh -f comma list and -k"
	run_k "$sh" apply -f 'my dir/a b.yaml,my dir/sub/nested.yml' -k kust
	expect_status 0 "apply -f list -k"
	expect_files "-f splits commas, -k hashes the dir" "$W/kust/kustomization.yaml" "$W/kust/x.yaml" "$W/my dir/a b.yaml" "$W/my dir/sub/nested.yml"
	expect_request "multi-input request" kubectl apply -f 'my dir/a b.yaml,my dir/sub/nested.yml' -k kust

	fresh "$sh argv escaping"
	weird=$(printf 'q"b\\s\tt\nn\001c\033e ü 日本 %%s')
	# The fake tern cannot decode JSON escapes, so the context stays quote-free.
	run_k "$sh" delete configmap "$weird" --context 'ctx x/ü'
	expect_status 0 "approve odd argv"
	expect_ran "odd argv executed verbatim" delete configmap "$weird" --context 'ctx x/ü'
	expect_request "odd argv request" kubectl delete configmap "$weird" --context 'ctx x/ü'

	fresh "$sh --context"
	run_k "$sh" scale deploy/web --replicas=3 --context=kind-other
	expect_status 0 "scale with --context"
	expect_field context kind-other "--context"
	expect_field context_source flag "--context"
	[ -e "$FAKE_DIR/ctx-calls" ] && bad "--context still asked kubectl for the current context" || ok

	fresh "$sh KUBECONFIG"
	KUBECONFIG="$root/kube a:$root/kube b"
	export KUBECONFIG
	run_k "$sh" rollout restart deploy/web
	expect_status 0 "restart with KUBECONFIG"
	expect_field kubeconfig "$root/kube a:$root/kube b" "KUBECONFIG"
	if grep -qF "$root/kube a:$root/kube b config current-context" "$FAKE_DIR/ctx-calls"; then ok; else bad "context resolved without the user's KUBECONFIG"; fi
	if [ "$(cat "$FAKE_DIR/env-1")" = "$root/kube a:$root/kube b" ]; then ok; else bad "kubectl ran without the user's KUBECONFIG"; fi
	fresh "$sh --kubeconfig"
	run_k "$sh" delete pod x --kubeconfig "$root/kc"
	expect_status 0 "delete with --kubeconfig"
	if grep -qF -- "--kubeconfig $root/kc config current-context" "$FAKE_DIR/ctx-calls"; then ok; else bad "context resolved without --kubeconfig"; fi

	for verb in "delete pod web-0" "scale deploy/web --replicas=0" "rollout restart deploy/web" "-n prod delete ns prod" "delete --context=x pod y"; do
		fresh "$sh deny: $verb"
		mode deny
		# shellcheck disable=SC2086
		run_k "$sh" $verb
		expect_status 1 "denied $verb"
		expect_out 'denied' "denied $verb"
		expect_not_run "denied $verb"
		expect_spool_clean "denied $verb"
	done

	# The block denies on its own when mutations are disabled; the user must
	# learn why, and control characters in the reason never reach the terminal.
	fresh "$sh deny with reason"
	mode denyreason
	run_k "$sh" delete pod web-0
	expect_status 1 "denied with reason"
	expect_out 'denied in Tern: Mutations are disabled\[31m \(mutations.enabled is false\)$' "reason printed"
	expect_not_run "denied with reason"
	expect_spool_clean "denied with reason"

	for f in '-f -' '--filename=-' '-f=-' '-f-' '--filename -' '-Rf -' '-f a.yaml,-'; do
		fresh "$sh stdin refused: $f"
		# shellcheck disable=SC2086
		run_k "$sh" apply $f
		expect_status 1 "$f"
		expect_out 'stdin' "$f message"
		expect_not_run "$f"
		expect_no_tern "$f"
	done
	fresh "$sh /dev/stdin refused"
	run_k "$sh" apply -f /dev/stdin
	expect_status 1 "/dev/stdin"
	expect_out 'not a regular file' "/dev/stdin message"
	expect_not_run "/dev/stdin"
	fresh "$sh URL refused"
	run_k "$sh" apply -f https://example.com/x.yaml
	expect_status 1 "URL"
	expect_out 'remote manifests' "URL message"
	expect_not_run "URL"
	fresh "$sh missing file refused"
	run_k "$sh" apply -f nope.yaml
	expect_status 1 "missing file"
	expect_out 'no such file' "missing file message"
	expect_not_run "missing file"

	for m in "timeout:no decision within 1s" "noresp:without an approval response" "fail:failed \\(exit 3\\)" \
		"wrongnonce:nonce mismatch" "tamper:fingerprint mismatch" "drift:context changed" \
		"stale:fingerprint mismatch" "old:outside the" "dup:repeats 'decision'"; do
		name=${m%%:*}
		fresh "$sh refusal: $name"
		if [ "$name" = timeout ]; then
			mode hang
			KUBE_LENS_GUARD_TIMEOUT=1
			export KUBE_LENS_GUARD_TIMEOUT
		else
			mode "$name"
		fi
		run_k "$sh" apply -f 'my dir/a b.yaml'
		expect_status 1 "$name"
		expect_out "${m#*:}" "$name message"
		expect_out 'nothing was executed' "$name says nothing ran"
		expect_not_run "$name"
		expect_spool_clean "$name"
		case $name in
		timeout | fail) ls "$root/spool"/cancel-* >/dev/null 2>&1 && ok || bad "$name left no cancel marker for the block" ;;
		esac
	done

	fresh "$sh context lookup fails"
	: >"$FAKE_DIR/ctx-fail"
	run_k "$sh" delete pod x
	expect_status 1 "no current context"
	expect_out 'could not resolve the current kubectl context' "no current context message"
	expect_not_run "no current context"
	expect_no_tern "no current context"

	fresh "$sh tern missing"
	TERN_BIN=$root/no-such-tern
	export TERN_BIN
	run_k "$sh" delete pod x
	expect_status 1 "tern missing"
	expect_out "failed \\(exit 127\\)" "tern missing message"
	expect_not_run "tern missing"

	for v in TERM_PROGRAM TERN_PANE KUBE_LENS_SPOOL; do
		fresh "$sh outside Tern: no $v"
		unset "$v"
		run_k "$sh" delete pod x
		expect_status 1 "no $v"
		case $v in
		KUBE_LENS_SPOOL) expect_out 'Open a new Tern pane' "no $v message" ;;
		*) expect_out 'not a Tern pane' "no $v message" ;;
		esac
		expect_not_run "no $v"
		expect_no_tern "no $v"
	done
	fresh "$sh outside Tern: other terminal"
	TERM_PROGRAM=iTerm.app
	run_k "$sh" scale deploy/web --replicas=1
	expect_status 1 "other terminal"
	expect_not_run "other terminal"

	fresh "$sh unknown flag before the verb"
	run_k "$sh" --some-new-flag x delete pod y
	expect_status 1 "unknown flag before delete"
	expect_out 'cannot tell which kubectl command' "ambiguity message"
	expect_not_run "unknown flag before delete"
	fresh "$sh command-local flag before rollout restart"
	run_k "$sh" rollout -f x.yaml restart
	expect_status 1 "-f between rollout and restart"
	expect_not_run "-f between rollout and restart"
	fresh "$sh unknown flag, no mutating verb"
	run_k "$sh" --some-new-flag x get pods
	expect_status 0 "unknown flag before get"
	expect_ran "unknown flag before get" --some-new-flag x get pods
	fresh "$sh value flag swallowing the verb"
	run_k "$sh" -n delete get pods
	expect_status 0 "-n delete get"
	expect_no_tern "-n delete get is a get in namespace delete"

	fresh "$sh Ctrl-C"
	mode hang
	KUBE_LENS_GUARD_TIMEOUT=30
	export KUBE_LENS_GUARD_TIMEOUT
	# Ctrl-C reaches the whole foreground process group (see launch_group).
	(launch_group "$sh" apply -f 'my dir/a b.yaml' >"$root/out" 2>&1 </dev/null) &
	pid=$!
	i=0
	while [ $i -lt 100 ] && ! ls "$root/spool"/req-*.json >/dev/null 2>&1; do
		sleep 0.1
		i=$((i + 1))
	done
	kill -s INT -- "-$pid" 2>/dev/null || bad "Ctrl-C: no process group $pid to signal"
	wait "$pid"
	st=$?
	unset KUBE_LENS_GUARD_TIMEOUT
	i=0
	while [ $i -lt 50 ] && ls "$root/spool"/req-*.json >/dev/null 2>&1; do
		sleep 0.1
		i=$((i + 1))
	done
	expect_status 130 "Ctrl-C"
	expect_not_run "Ctrl-C"
	ls "$root/spool"/cancel-* >/dev/null 2>&1 && ok || bad "Ctrl-C left no cancel marker for the block"
	expect_spool_clean "Ctrl-C"
	sleep 0.3
	expect_not_run "Ctrl-C (late)"
	if pgrep -f 'sleep 1797' >/dev/null 2>&1; then
		bad "Ctrl-C left the waiting tern open running"
		pkill -f 'sleep 1797'
	else ok; fi
}

# Behavior of the zsh/bash/fish activation snippets.
snippet_cases() {
	sh=$1
	case $sh in
	zsh | bash) src='source "$KLG_SNIP"' ;;
	fish) src='source $KLG_SNIP' ;;
	esac
	case $sh in
	zsh) hook='for f_ in $precmd_functions; do $f_; done' ;;
	bash) hook='eval "$PROMPT_COMMAND"' ;;
	fish) hook='emit fish_prompt' ;;
	esac
	case $sh in
	fish) last_status='echo source-status=$status' ;;
	*) last_status='echo source-status=$?' ;;
	esac

	fresh "$sh existing kubectl function is preserved"
	case $sh in
	fish) pre='function kubectl; echo user-function $argv; end' ;;
	*) pre='kubectl() { echo user-function "$@"; }' ;;
	esac
	run_code "$sh" "$pre
$src
$last_status
kubectl delete pod x"
	expect_out 'not installed' "conflict message"
	expect_out 'user-function delete pod x' "user function still runs"
	expect_out 'source-status=1' "source reports the conflict"
	expect_not_run "conflict"

	fresh "$sh existing kubectl alias is preserved"
	case $sh in
	zsh) pre="alias kubectl='echo user-alias'" ;;
	bash) pre="shopt -s expand_aliases; alias kubectl='echo user-alias'" ;;
	fish) pre="abbr -a kubectl 'echo user-abbr'" ;;
	esac
	run_code "$sh" "$pre
$src
kube-lens-guard-status"
	expect_out 'not installed' "alias conflict message"
	expect_no_out 'kubectl function:' "alias conflict installs nothing"

	fresh "$sh re-sourcing is not a conflict"
	run_code "$sh" "$src
$src
kube-lens-guard-status"
	expect_no_out 'not installed' "re-source"
	expect_out "kubectl function: kube-lens guard \\($sh\\)" "status after re-source"
	expect_out 'guarded verbs ask for approval' "status in a Tern pane"

	fresh "$sh k alias reaches the guard"
	mode deny
	case $sh in
	zsh) pre='alias k=kubectl' ;;
	bash) pre='shopt -s expand_aliases; alias k=kubectl' ;;
	fish) pre='alias k kubectl' ;;
	esac
	run_code "$sh" "$src
$pre
eval 'k delete pod x'"
	expect_status 1 "k delete denied"
	expect_out 'denied' "k delete went through the guard"
	expect_not_run "k alias"

	fresh "$sh command kubectl bypass"
	case $sh in
	fish) run_code "$sh" "$src; command kubectl \$argv" delete pod x ;;
	*) run_code "$sh" "$src; command kubectl \"\$@\"" delete pod x ;;
	esac
	expect_status 0 "command kubectl"
	expect_ran "command kubectl runs immediately" delete pod x
	expect_no_tern "command kubectl"

	fresh "$sh guard not sourced"
	case $sh in
	fish) run_code "$sh" 'kubectl $argv' delete pod x ;;
	*) run_code "$sh" 'kubectl "$@"' delete pod x ;;
	esac
	expect_ran "without the snippet kubectl is unguarded" delete pod x
	expect_no_tern "guard not sourced"

	fresh "$sh guard core missing"
	rm -rf "$root/copy"
	cp -R "$repo/shell" "$root/copy"
	rm "$root/copy/kube-lens-guard"
	case $sh in
	fish) run_code "$sh" "source $root/copy/kube-lens.fish; kubectl \$argv" get pods ;;
	*) run_code "$sh" "source '$root/copy/kube-lens.$sh'; kubectl \"\$@\"" get pods ;;
	esac
	expect_status 127 "core missing"
	expect_out 'is missing, so kubectl was not run' "core missing message"
	expect_not_run "core missing"

	fresh "$sh pane env record"
	pane_file=$root/spool/pane-$TERN_PANE.env
	case $sh in
	fish) assign() { printf 'set -gx KUBECONFIG %s' "$1"; } ;;
	*) assign() { printf 'export KUBECONFIG=%s' "$1"; } ;;
	esac
	run_code "$sh" "$src
$hook
cp '$pane_file' '$root/snap1'
$(assign "'$root/kc one'")
$hook
cp '$pane_file' '$root/snap2'
rm '$pane_file'
$hook
ls '$root/spool' > '$root/snap3'
$(assign "'$root/kc two'")
$hook
cp '$pane_file' '$root/snap4'"
	printf 'kubeconfig=\n' >"$root/want"
	cmp -s "$root/want" "$root/snap1" && ok || bad "first prompt record: $(cat "$root/snap1" 2>&1)"
	printf 'kubeconfig=%s\n' "$root/kc one" >"$root/want"
	cmp -s "$root/want" "$root/snap2" && ok || bad "record after KUBECONFIG change: $(cat "$root/snap2" 2>&1)"
	grep -q '^pane-' "$root/snap3" && bad "record rewritten although KUBECONFIG did not change" || ok
	printf 'kubeconfig=%s\n' "$root/kc two" >"$root/want"
	cmp -s "$root/want" "$root/snap4" && ok || bad "record after second change: $(cat "$root/snap4" 2>&1)"
	[ "$(ls -l "$pane_file" | cut -c1-10)" = -rw------- ] && ok || bad "pane record mode $(ls -l "$pane_file")"
	[ -z "$(cd "$root/spool" && ls -A | grep -v '^pane-[0-9]*\.env$')" ] && ok || bad "pane record left temp files: $(ls -A "$root/spool")"

	fresh "$sh pane env record outside Tern"
	unset TERN_PANE
	run_code "$sh" "$src
$hook"
	[ -z "$(ls -A "$root/spool")" ] && ok || bad "pane record written outside a Tern pane"
	fresh "$sh pane env record without spool"
	unset KUBE_LENS_SPOOL
	run_code "$sh" "$src
$hook"
	[ -z "$(ls -A "$root/spool")" ] && ok || bad "pane record written without KUBE_LENS_SPOOL"

	fresh "$sh uninstall"
	case $sh in
	zsh)
		pre='precmd_functions=(user_hook); user_hook() { :; }'
		post='print -r -- "hooks=${precmd_functions[*]}"; whence -w kubectl'
		;;
	bash)
		pre="PROMPT_COMMAND='history -a;'"
		post='printf "hooks=%s\n" "$PROMPT_COMMAND"; type -t kubectl'
		;;
	fish)
		pre='true'
		post='functions -q _kube_lens_pane_env; and echo hook-left; type -t kubectl'
		;;
	esac
	run_code "$sh" "$pre
$src
kube-lens-guard-uninstall
$post
$hook
ls '$root/spool' > '$root/snap1'"
	expect_out 'kube-lens guard removed' "uninstall message"
	case $sh in
	zsh) expect_out '^hooks=user_hook$' "precmd hook removed, user hook kept" ;;
	bash) expect_out '^hooks=history -a;$' "PROMPT_COMMAND restored exactly" ;;
	fish) expect_no_out 'hook-left' "fish_prompt handler removed" ;;
	esac
	expect_out '(^kubectl: command$|^file$)' "kubectl is the plain command again"
	grep -q '^pane-' "$root/snap1" && bad "pane hook still runs after uninstall" || ok

	if [ "$sh" = bash ]; then
		fresh "bash PROMPT_COMMAND is appended, not replaced"
		run_code bash "PROMPT_COMMAND='echo user-pc'
$src
$src
printf 'pc=%s|\n' \"\$PROMPT_COMMAND\""
		expect_out '^pc=echo user-pc$' "user PROMPT_COMMAND kept first"
		expect_out '^_kube_lens_pane_env\|$' "hook appended once"
	fi
}

for sh in $shells; do
	KLG_SNIP=$repo/shell/kube-lens.$sh
	KLG_CORE=$core
	export KLG_SNIP KLG_CORE
	core_cases "$sh"
	[ "$sh" = dash ] || snippet_cases "$sh"
done
for want in zsh bash fish; do
	case " $shells " in
	*" $want "*) ;;
	*)
		case_name=$want
		skip "$want is not installed"
		;;
	esac
done

case_name="flag table"
if [ -x "$luau" ]; then
	if LUAU=$luau sh "$repo/scripts/guard/gen-flags" --check >"$root/out" 2>&1; then ok; else bad "embedded flag table is stale"; fi
else
	skip "gen-flags check needs $luau"
fi

case_name="pass-through overhead"
fresh "$case_name"
unset TERM_PROGRAM
n=40
t_direct=$(bash -c 'TIMEFORMAT=%R; time (for i in $(seq '$n'); do kubectl get pods; done)' 2>&1 >/dev/null)
t_guard=$(bash -c 'TIMEFORMAT=%R; time (for i in $(seq '$n'); do "$1" kubectl get pods -n x -o wide; done)' bash "$core" 2>&1 >/dev/null)
over=$(awk -v d="$t_direct" -v g="$t_guard" -v n="$n" 'BEGIN { printf "%.1f", (g - d) * 1000 / n }')
printf 'pass-through overhead: %s ms per call (guard %ss vs direct %ss for %d calls)\n' "$over" "$t_guard" "$t_direct" "$n"
if awk -v o="$over" 'BEGIN { exit !(o < 25) }'; then ok; else bad "pass-through overhead ${over}ms per call exceeds 25ms"; fi

printf '%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
[ "$failed" = 0 ]
