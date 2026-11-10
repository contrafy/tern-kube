#!/bin/sh
# Tests for the tern-kube shell guard (shell/tern-kube-guard and the zsh, bash
# and fish activation snippets). No Tern and no cluster: a fake `tern` plays
# the approve block and a fake `kubectl` records what would have run. Each
# case asserts the property the guard exists for: a mutation runs only after
# a matching approval, exactly as typed; everything else is untouched.
#
#   sh tests/shell/guard/run.sh      (or: make test-shell-guard)

set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
here=$repo/tests/shell/guard
core=$repo/shell/tern-kube-guard
luau=${LUAU:-$repo/.tools/bin/luau}
case $luau in
/*) ;;
*) luau=$PWD/$luau ;;
esac

root=$(mktemp -d "${TMPDIR:-/tmp}/tkg-test.XXXXXX") || exit 2
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

# The user's editor for `kubectl edit` cases: records its argv (one word per
# line) in editor-argv and its run count in editor-runs, then edits the last
# argument as $FAKE_DIR/editor-mode says: change (k: v -> k: edited, the
# default), append (a new line each run), comment (adds a `#` line only),
# none, fail (exit 3).
cat >"$root/ed" <<'EOF'
#!/bin/sh
d=${FAKE_DIR:?FAKE_DIR is required}
printf '%s\n' "$@" >"$d/editor-argv"
for f in "$@"; do :; done
n=$(($(cat "$d/editor-runs" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/editor-runs"
case $(cat "$d/editor-mode" 2>/dev/null || echo change) in
change) sed 's/^  k: v$/  k: edited/' "$f" >"$d/ed.tmp" && cat "$d/ed.tmp" >"$f" ;;
append) printf '  r%s: x\n' "$n" >>"$f" ;;
comment) printf '# a note\n' >>"$f" ;;
none) ;;
fail) exit 3 ;;
esac
EOF
chmod +x "$root/ed"
# A tern reachable only through TERN_EXE/TERN_BIN, and a PATH without any
# tern: where `tern remote setup` installs is often missing from login PATHs.
mkdir -p "$root/exe" "$root/kbin"
cp "$here/bin/tern" "$root/exe/tern"
ln -s "$here/bin/kubectl" "$root/kbin/kubectl"
guard_path=$here/bin:$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin
no_tern_path=$root/kbin:$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin
PATH=$guard_path
HOME=$root/home
XDG_CONFIG_HOME=$root/home/.config
XDG_DATA_HOME=$root/home/.local/share
XDG_CACHE_HOME=$root/home/.cache
export PATH HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
unset KUBECONFIG TERN_BIN TERN_EXE TKUBE_GUARD_TIMEOUT ZDOTDIR FAKE_READ_STDIN BASH_ENV ENV PROMPT_COMMAND \
	KUBE_EDITOR EDITOR TKUBE_EDIT_DIR TKUBE_EDIT_REAL
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
	rm -rf "$FAKE_DIR" "$root/spool" "$root/work" "$root/tmp" "$root/audit.log"
	mkdir -p "$FAKE_DIR" "$root/work/my dir/sub" "$root/work/kust" "$root/tmp"
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
	TKUBE_SPOOL=$root/spool
	TMPDIR=$root/tmp
	export TERM_PROGRAM TERN_PANE TKUBE_SPOOL TMPDIR
	unset KUBECONFIG TKUBE_GUARD_TIMEOUT TERN_BIN TERN_EXE FAKE_READ_STDIN KUBE_EDITOR EDITOR TKUBE_EDIT_DIR
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
	zsh | bash) printf '%s' 'source "$TKG_SNIP"; kubectl "$@"' ;;
	fish) printf '%s' 'source $TKG_SNIP; kubectl $argv' ;;
	dash) printf '%s' '"$TKG_CORE" kubectl "$@"' ;;
	esac
}

# run_status SHELL: `tern-kube-guard status` from SHELL.
run_status() {
	case $1 in
	fish) run_code fish '$TKG_CORE status' ;;
	*) run_code "$1" '"$TKG_CORE" status' ;;
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
	unset TERM_PROGRAM TERN_PANE TKUBE_SPOOL
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
			TKUBE_GUARD_TIMEOUT=1
			export TKUBE_GUARD_TIMEOUT
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
	expect_out 'TERN_EXE' "tern missing names TERN_EXE"

	fresh "$sh TERN_EXE when tern is not on PATH"
	mode approve
	TERN_EXE=$root/exe/tern
	export TERN_EXE
	PATH=$no_tern_path
	run_k "$sh" delete pod x
	PATH=$guard_path
	expect_status 0 "TERN_EXE approval"
	expect_ran "TERN_EXE approval" delete pod x
	if grep -q '^open --wait ' "$FAKE_DIR/tern-calls" 2>/dev/null; then ok; else bad "TERN_EXE tern was not invoked"; fi

	fresh "$sh TERN_BIN wins over TERN_EXE"
	mode approve
	TERN_EXE=$root/no-such-tern
	TERN_BIN=$root/exe/tern
	export TERN_EXE TERN_BIN
	PATH=$no_tern_path
	run_k "$sh" delete pod x
	PATH=$guard_path
	expect_status 0 "TERN_BIN over TERN_EXE"
	expect_ran "TERN_BIN over TERN_EXE" delete pod x

	fresh "$sh broken TERN_EXE is named in the refusal"
	TERN_EXE=$root/no-such-tern
	export TERN_EXE
	run_k "$sh" delete pod x
	expect_status 1 "broken TERN_EXE"
	expect_out 'tern from TERN_EXE' "refusal names TERN_EXE as the source"
	expect_not_run "broken TERN_EXE"

	for src in PATH TERN_EXE TERN_BIN; do
		fresh "$sh status names the tern source: $src"
		case $src in
		TERN_EXE) TERN_EXE=$root/exe/tern want=$root/exe/tern ;;
		TERN_BIN) TERN_EXE=$root/no-such-tern TERN_BIN=$root/exe/tern want=$root/exe/tern ;;
		*) want=$here/bin/tern ;;
		esac
		if [ "$src" != PATH ]; then export TERN_EXE; fi
		if [ "$src" = TERN_BIN ]; then export TERN_BIN; fi
		run_status "$sh"
		if grep -qxF "tern: $want ($src)" "$root/out"; then ok; else bad "status line for $src"; fi
	done
	fresh "$sh status: TERN_EXE not found"
	TERN_EXE=$root/no-such-tern
	export TERN_EXE
	run_status "$sh"
	expect_out "^tern: $root/no-such-tern not found \\(TERN_EXE;" "status for a missing TERN_EXE"

	for v in TERM_PROGRAM TERN_PANE TKUBE_SPOOL; do
		fresh "$sh outside Tern: no $v"
		unset "$v"
		run_k "$sh" delete pod x
		expect_status 1 "no $v"
		case $v in
		TKUBE_SPOOL) expect_out 'Open a new Tern pane' "no $v message" ;;
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

	# MUT-F1: kubens between the preview and kubectl changes where a command
	# without -n runs; the request and its fingerprint stay equal, so the
	# namespace and user the block previewed are checked right before exec.
	fresh "$sh namespace switched after approval"
	echo team-a >"$FAKE_DIR/ctx-namespace"
	mode nsdrift
	run_k "$sh" delete cm x
	expect_status 1 "namespace switched"
	expect_out "now defaults to namespace 'team-b', but the approval previewed 'team-a'" "namespace switch message"
	expect_out 'nothing was executed' "namespace switch says nothing ran"
	expect_not_run "namespace switched"
	expect_spool_clean "namespace switched"

	fresh "$sh namespace switched before the preview"
	echo team-a >"$FAKE_DIR/ctx-namespace"
	mode nsearly
	run_k "$sh" delete cm x
	expect_status 0 "previewed namespace is the current one"
	expect_ran "previewed namespace is the current one" delete cm x

	fresh "$sh namespace switch with -n"
	echo team-a >"$FAKE_DIR/ctx-namespace"
	mode nsdrift
	run_k "$sh" delete cm x -n team-a
	expect_status 0 "explicit -n ignores the context namespace"
	expect_ran "explicit -n ignores the context namespace" delete cm x -n team-a

	fresh "$sh user switched after approval"
	mode userdrift
	run_k "$sh" delete cm x -n team-a
	expect_status 1 "user switched"
	expect_out "now uses user 'mallory', but the approval previewed 'kind-dev'" "user switch message"
	expect_not_run "user switched"

	fresh "$sh approval without namespace and user"
	mode nokeys
	run_k "$sh" delete cm x
	expect_status 1 "older block"
	expect_out 'does not name the namespace and user it previewed' "older block message"
	expect_not_run "older block"

	fresh "$sh context unreadable at approval"
	: >"$FAKE_DIR/view-fail"
	run_k "$sh" delete cm x
	expect_status 1 "context unreadable"
	expect_out "cannot read context 'kind-dev' from the kubeconfig" "context unreadable message"
	expect_not_run "context unreadable"

	fresh "$sh --kubeconfig reaches the namespace check"
	run_k "$sh" --kubeconfig /k/alt delete cm x
	expect_status 0 "--kubeconfig"
	if grep -qF -- '--kubeconfig /k/alt config view --minify --context kind-dev' "$FAKE_DIR/view-calls" 2>/dev/null; then ok; else bad "namespace check ignored --kubeconfig: $(cat "$FAKE_DIR/view-calls" 2>/dev/null)"; fi

	# MUT-F5: the block closed before kubectl ran; the guard appends the
	# outcome record it was given, filling in only the needles (the fake's
	# template repeats one, escaped, inside argv).
	for m in 0:executed 4:failed; do
		fresh "$sh outcome recorded: ${m#*:}"
		echo "${m%%:*}" >"$FAKE_DIR/exit"
		run_k "$sh" delete cm x
		expect_status "${m%%:*}" "outcome ${m#*:}"
		expect_ran "outcome ${m#*:}" delete cm x
		if [ "$(wc -l <"$root/audit.log" 2>/dev/null | tr -d ' ')" = 1 ] &&
			grep -Eq '^\{"v":1,"decided_at":[0-9]+,"decision":"'"${m#*:}"'","mode":"guard","op":"fake","argv":\["\\"exit_code\\":@"\],"exit_code":'"${m%%:*}"',"started_at":[0-9]+,"finished_at":[0-9]+\}$' "$root/audit.log"; then
			ok
		else
			bad "outcome ${m#*:}: audit log $(cat "$root/audit.log" 2>/dev/null)"
		fi
	done

	fresh "$sh no outcome template"
	mode noaudit
	run_k "$sh" delete cm x
	expect_status 0 "no template"
	expect_ran "no template" delete cm x
	if [ -e "$root/audit.log" ]; then bad "no template: wrote $(cat "$root/audit.log")"; else ok; fi

	fresh "$sh Ctrl-C while kubectl runs"
	: >"$FAKE_DIR/run-sleep"
	(launch_group "$sh" delete cm x >"$root/out" 2>&1 </dev/null) &
	pid=$!
	i=0
	while [ $i -lt 100 ] && [ ! -e "$FAKE_DIR/call-1" ]; do
		sleep 0.1
		i=$((i + 1))
	done
	kill -s INT -- "-$pid" 2>/dev/null || bad "Ctrl-C while kubectl runs: no process group $pid to signal"
	wait "$pid"
	st=$?
	expect_status 130 "Ctrl-C while kubectl runs"
	if grep -q '"decision":"failed",.*"exit_code":130,' "$root/audit.log" 2>/dev/null; then ok; else bad "Ctrl-C while kubectl runs: audit log $(cat "$root/audit.log" 2>/dev/null)"; fi
	expect_no_out 'nothing was executed' "Ctrl-C while kubectl runs is not a guard cancel"
	if pgrep -f 'sleep 1798' >/dev/null 2>&1; then
		bad "Ctrl-C left kubectl running"
		pkill -f 'sleep 1798'
	else ok; fi

	fresh "$sh Ctrl-C"
	mode hang
	TKUBE_GUARD_TIMEOUT=30
	export TKUBE_GUARD_TIMEOUT
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
	unset TKUBE_GUARD_TIMEOUT
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
	zsh | bash) src='source "$TKG_SNIP"' ;;
	fish) src='source $TKG_SNIP' ;;
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
tern-kube-guard-status"
	expect_out 'not installed' "alias conflict message"
	expect_no_out 'kubectl function:' "alias conflict installs nothing"

	fresh "$sh re-sourcing is not a conflict"
	run_code "$sh" "$src
$src
tern-kube-guard-status"
	expect_no_out 'not installed' "re-source"
	expect_out "kubectl function: tern-kube guard \\($sh\\)" "status after re-source"
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
	rm "$root/copy/tern-kube-guard"
	case $sh in
	fish) run_code "$sh" "source $root/copy/tern-kube.fish; kubectl \$argv" get pods ;;
	*) run_code "$sh" "source '$root/copy/tern-kube.$sh'; kubectl \"\$@\"" get pods ;;
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
	unset TKUBE_SPOOL
	run_code "$sh" "$src
$hook"
	[ -z "$(ls -A "$root/spool")" ] && ok || bad "pane record written without TKUBE_SPOOL"

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
		post='functions -q _tern_kube_pane_env; and echo hook-left; type -t kubectl'
		;;
	esac
	run_code "$sh" "$pre
$src
tern-kube-guard-uninstall
$post
$hook
ls '$root/spool' > '$root/snap1'"
	expect_out 'tern-kube guard removed' "uninstall message"
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
		expect_out '^_tern_kube_pane_env\|$' "hook appended once"
	fi
}

# The verbs added with track 1: each is guarded with its own flag table,
# passes through only when it cannot change the cluster, and --patch-file is
# fingerprinted as an exact input file.
verb_cases() {
	sh=$1

	for args in "rollout undo deploy/web --to-revision 2" "rollout pause deploy/web" "rollout resume -f kust/x.yaml" \
		'patch deploy/web --type merge -p {"spec":{}}' "label pods --field-selector status.phase=Running tier=web" \
		"annotate cm/x note=hi --overwrite" "cordon node1" "uncordon -l role=x" \
		"drain node1 --pod-selector app=web --timeout 4m" "-n prod label cm/x a=b"; do
		fresh "$sh approve: $args"
		# shellcheck disable=SC2086
		run_k "$sh" $args
		expect_status 0 "approved $args"
		# shellcheck disable=SC2086
		expect_ran "approved $args" $args
		# shellcheck disable=SC2086
		expect_request "$args request" kubectl $args
		expect_spool_clean "approved $args"
	done
	fresh "$sh rollout resume -f is an input"
	run_k "$sh" rollout resume -f kust/x.yaml
	expect_files "resume -f file" "$W/kust/x.yaml"

	for args in "rollout undo deploy/web" "patch node/n1 -p {}" "label ns/prod a=b" "annotate cm/x a=b" \
		"cordon node1" "uncordon node1" "drain node1 --ignore-daemonsets" "rollout pause deploy/web" "rollout resume deploy/web"; do
		fresh "$sh deny: $args"
		mode deny
		# shellcheck disable=SC2086
		run_k "$sh" $args
		expect_status 1 "denied $args"
		expect_out 'denied in Tern; nothing was executed' "denied $args"
		expect_not_run "denied $args"
		expect_spool_clean "denied $args"
	done

	# Outside a Tern pane a guarded command is refused, so running here proves
	# that it passed through without approval.
	for args in "rollout undo deploy/web --to-revision 2 --dry-run=server" "patch deploy/web --type merge -p {} --dry-run=client" \
		"label pods --field-selector a=b x=y --dry-run=server" "annotate cm/x --resource-version 5 n=v --dry-run=server" \
		"cordon -l a=b --dry-run=server" "uncordon node1 --dry-run=server" \
		"drain node1 --pod-selector app=web --timeout 10s --dry-run=server" "patch -f kust/x.yaml --local -p {} -o yaml" \
		"label --local -f kust/x.yaml a=b" "annotate cm/x --list" "label cm/x --list=true" "annotate --local=1 -f kust/x.yaml a=b"; do
		fresh "$sh pass-through: $args"
		unset TERM_PROGRAM
		# shellcheck disable=SC2086
		run_k "$sh" $args
		expect_status 0 "$args"
		# shellcheck disable=SC2086
		expect_ran "$args" $args
		expect_no_tern "$args"
	done
	for args in "rollout pause deploy/web --dry-run=server" "rollout resume deploy/web --dry-run=client" \
		"label cm/x a=b --local=false" "label cm/x a=b --list=false" "patch deploy/web -p {} --bogus --dry-run=server" \
		"cordon node1 --local" "drain node1 --dry-run=none" "annotate cm/x n=v --dry-run" "rollout undo deploy/web --list"; do
		fresh "$sh needs approval: $args"
		unset TERM_PROGRAM
		# shellcheck disable=SC2086
		run_k "$sh" $args
		expect_status 1 "$args"
		expect_out 'not a Tern pane' "$args is guarded"
		expect_not_run "$args"
	done

	for args in "label cm/x a=b" "annotate cm/x a=b" "patch deploy/web -p {}" "cordon n1" "uncordon n1" "drain n1" \
		"edit cm/x" "rollout undo deploy/web"; do
		fresh "$sh unknown flag before: $args"
		# shellcheck disable=SC2086
		run_k "$sh" --some-new-flag x $args
		expect_status 1 "unknown flag before $args"
		expect_out 'cannot tell which kubectl command' "unknown flag before $args"
		expect_not_run "unknown flag before $args"
		expect_no_tern "unknown flag before $args"
	done

	fresh "$sh --patch-file"
	printf '{"spec":{}}\n' >"$W/my dir/p,q.json"
	run_k "$sh" patch deploy/web --patch-file 'my dir/p,q.json'
	expect_status 0 "patch-file approved"
	expect_ran "patch-file argv" patch deploy/web --patch-file 'my dir/p,q.json'
	expect_request "patch-file request" kubectl patch deploy/web --patch-file 'my dir/p,q.json'
	expect_files "--patch-file is listed exactly, never split on commas" "$W/my dir/p,q.json"
	fresh "$sh --patch-file with -f"
	run_k "$sh" patch -f 'my dir/a b.yaml' --patch-file="$W/my dir/c.json"
	expect_status 0 "patch-file with -f"
	expect_files "patch file and manifest" "$W/my dir/a b.yaml" "$W/my dir/c.json"
	fresh "$sh --patch-file changed after approval"
	mode stale
	run_k "$sh" patch deploy/web --patch-file 'my dir/c.json'
	expect_status 1 "patch file changed"
	expect_out 'fingerprint mismatch' "patch file changed"
	expect_not_run "patch file changed"
	for f in '--patch-file -' '--patch-file=-'; do
		fresh "$sh patch from stdin refused: $f"
		# shellcheck disable=SC2086
		run_k "$sh" patch deploy/web $f
		expect_status 1 "$f"
		expect_out 'stdin \(--patch-file -\)' "$f message"
		expect_not_run "$f"
		expect_no_tern "$f"
	done
	for m in "/dev/stdin|not a regular file" "my dir|not a regular file" "https://example.com/p.json|remote patch files" \
		"nope.json|no such file"; do
		fresh "$sh --patch-file ${m%%|*} refused"
		run_k "$sh" patch deploy/web --patch-file "${m%%|*}"
		expect_status 1 "--patch-file ${m%%|*}"
		expect_out "${m#*|}" "--patch-file ${m%%|*} message"
		expect_not_run "--patch-file ${m%%|*}"
	done

	fresh "$sh status lists the verbs"
	case $sh in
	fish) run_code fish '$TKG_CORE status' ;;
	*) run_code "$sh" '"$TKG_CORE" status' ;;
	esac
	expect_out '^guarded verbs: annotate, apply, cordon, delete, drain, edit \(after you save\), label, patch, rollout restart, rollout undo, rollout pause, rollout resume, scale, uncordon$' "status verbs"
}

# The copy of an unapproved edit that the hook saved in TMPDIR.
denied_copy() {
	ls "$root/tmp"/kubectl-edit-denied-* 2>/dev/null
}

expect_not_applied() {
	if [ -e "$FAKE_DIR/edit-applied" ]; then bad "$1: kubectl applied the edit"; else ok; fi
}

expect_saved_copy() {
	n_=$(denied_copy | wc -l | tr -d ' ')
	if [ "$n_" = 1 ] && grep -q '^  k: edited$' "$(denied_copy)"; then ok; else bad "$1: $n_ saved copies of the edit"; fi
}

expect_tmp_clean() {
	left=$(cd "$root/tmp" && ls -A | grep -v '^kubectl-edit-denied-')
	if [ -z "$left" ]; then ok; else bad "$1: TMPDIR not cleaned: $left"; fi
}

edit_fresh() {
	fresh "$1"
	KUBE_EDITOR=$root/ed
	export KUBE_EDITOR
}

# `kubectl edit`: the hook asks for approval after each save; kubectl applies
# only an approved file and finds its own bytes back otherwise.
edit_cases() {
	sh=$1

	edit_fresh "$sh edit approved"
	run_k "$sh" edit cm/x -n team
	expect_status 0 "edit approved"
	expect_out '^configmap/x edited$' "kubectl applied the edit"
	if grep -q '^  k: edited$' "$FAKE_DIR/edit-applied" 2>/dev/null; then ok; else bad "kubectl did not apply the edited text"; fi
	expect_ran "edit argv" edit cm/x -n team
	expect_request "edit request" kubectl edit cm/x -n team
	expect_field namespace team "edit request"
	file_=$(sed -n 1p "$FAKE_DIR/edit-files")
	if [ "$(tail -n 1 "$FAKE_DIR/editor-argv")" = "$file_" ]; then ok; else bad "the editor did not get kubectl's file"; fi
	reqtool edit "$(req)" >"$root/got-edit" 2>&1
	orig_=$(sed -n 2p "$root/got-edit")
	if [ "$(sed -n 1p "$root/got-edit")" = "$file_" ]; then ok; else bad "edit.file is not kubectl's file: $(cat "$root/got-edit")"; fi
	case $orig_ in
	"$root/tmp"/tkube-edit.*/original.yaml) ok ;;
	*) bad "edit.original is not in the private edit dir: $orig_" ;;
	esac
	expect_files "edit files" "$file_" "$orig_"
	sha_=$(sha256_ <"$FAKE_DIR/edit-round-1")
	sha_=${sha_%% *}
	if req | grep -qF "{\"path\":\"$orig_\",\"size\":$(wc -c <"$FAKE_DIR/edit-round-1" | tr -d ' '),\"sha256\":\"$sha_\"}"; then ok; else bad "edit.original is not kubectl's first serialization"; fi
	expect_spool_clean "edit approved"
	expect_tmp_clean "edit approved"

	for m in none comment; do
		edit_fresh "$sh edit unchanged ($m)"
		echo "$m" >"$FAKE_DIR/editor-mode"
		run_k "$sh" edit cm/x
		expect_status 0 "unchanged ($m)"
		expect_out '^Edit cancelled, no changes made.$' "unchanged ($m)"
		expect_no_tern "unchanged ($m) needs no approval"
		expect_tmp_clean "unchanged ($m)"
	done

	edit_fresh "$sh edit denied"
	mode deny
	run_k "$sh" edit cm/x
	# MUT-F6: kubectl itself exits 0 ("Edit cancelled"); `edit && next` must
	# not continue after a denial, as with every other guarded verb.
	expect_status 1 "edit denied exits 1 like every denial"
	expect_out 'denied in Tern; the object was not changed' "deny message"
	expect_out '^Edit cancelled, no changes made.$' "kubectl found its own bytes"
	expect_out 'your edit is saved at' "copy message"
	expect_not_applied "edit denied"
	expect_saved_copy "edit denied"
	expect_spool_clean "edit denied"
	expect_tmp_clean "edit denied"
	if [ -e "$root/audit.log" ]; then bad "edit denied wrote an outcome: $(cat "$root/audit.log")"; else ok; fi

	# MUT-F5: kubectl applies after the hook's approval; its exit status is
	# the outcome.
	edit_fresh "$sh edit outcome recorded"
	run_k "$sh" edit cm/x
	expect_status 0 "edit outcome"
	if grep -Eq '"decision":"executed",.*"exit_code":0,"started_at":[0-9]+,"finished_at":[0-9]+\}$' "$root/audit.log" 2>/dev/null; then ok; else bad "edit outcome: audit log $(cat "$root/audit.log" 2>/dev/null)"; fi

	# MUT-F1: kubectl edit loaded the kubeconfig when it started; an approval
	# previewed against a namespace switched since then is refused.
	edit_fresh "$sh edit: namespace switched while editing"
	echo team-a >"$FAKE_DIR/ctx-namespace"
	mode nsearly
	run_k "$sh" edit cm/x
	expect_status 1 "edit namespace switched"
	expect_out "now defaults to namespace 'team-a', but the approval previewed 'team-b'" "edit namespace switched message"
	expect_not_applied "edit namespace switched"

	for m in "hang:no decision within 1s" "stale:fingerprint mismatch" "drift:context changed"; do
		name=${m%%:*}
		edit_fresh "$sh edit refused: $name"
		mode "$name"
		[ "$name" = hang ] && TKUBE_GUARD_TIMEOUT=1 && export TKUBE_GUARD_TIMEOUT
		run_k "$sh" edit cm/x
		expect_status 1 "edit refused: $name"
		expect_out "${m#*:}" "edit refused: $name message"
		expect_out 'the edit was not applied' "edit refused: $name says so"
		expect_out 'problem with the editor' "edit refused: $name fails kubectl's editor"
		expect_not_applied "edit refused: $name"
		if [ "$(denied_copy | wc -l | tr -d ' ')" = 1 ]; then ok; else bad "edit refused: $name saved no copy"; fi
		expect_spool_clean "edit refused: $name"
		expect_tmp_clean "edit refused: $name"
	done

	edit_fresh "$sh edit: kubectl reopens a rejected edit"
	echo 1 >"$FAKE_DIR/edit-reject"
	echo append >"$FAKE_DIR/editor-mode"
	run_k "$sh" edit cm/x
	expect_status 0 "second round approved"
	expect_out 'is invalid' "first round rejected"
	if [ "$(wc -l <"$FAKE_DIR/reqs" | tr -d ' ')" = 2 ]; then ok; else bad "want one request per changed round"; fi
	o1_=$(sed -n 1p "$FAKE_DIR/reqs" | sed 's/.*"original":"\([^"]*\)".*/\1/')
	o2_=$(sed -n 2p "$FAKE_DIR/reqs" | sed 's/.*"original":"\([^"]*\)".*/\1/')
	h1_=$(sed -n 1p "$FAKE_DIR/reqs" | sed "s|.*\"path\":\"$o1_\",\"size\":[0-9]*,\"sha256\":\"\([0-9a-f]*\)\".*|\1|")
	h2_=$(sed -n 2p "$FAKE_DIR/reqs" | sed "s|.*\"path\":\"$o2_\",\"size\":[0-9]*,\"sha256\":\"\([0-9a-f]*\)\".*|\1|")
	if [ "$o1_" = "$o2_" ] && [ "$h1_" = "$h2_" ] && [ ${#h1_} = 64 ]; then ok; else bad "round 2 must keep round 1's original ($o1_ $h1_ / $o2_ $h2_)"; fi
	if grep -q '^  r2: x$' "$FAKE_DIR/edit-applied" 2>/dev/null; then ok; else bad "round 2 edit not applied"; fi

	edit_fresh "$sh edit: editor exits 3"
	echo fail >"$FAKE_DIR/editor-mode"
	run_k "$sh" edit cm/x
	expect_status 1 "editor failure"
	expect_out 'problem with the editor' "editor failure"
	expect_no_tern "editor failure"
	expect_not_applied "editor failure"
	expect_tmp_clean "editor failure"

	edit_fresh "$sh edit: EDITOR with arguments"
	unset KUBE_EDITOR
	EDITOR="$root/ed --wait"
	export EDITOR
	run_k "$sh" edit cm/x
	expect_status 0 "EDITOR with --wait"
	if [ "$(sed -n 1p "$FAKE_DIR/editor-argv")" = --wait ] && [ "$(wc -l <"$FAKE_DIR/editor-argv" | tr -d ' ')" = 2 ]; then ok; else bad "EDITOR not split like kubectl: $(tr '\n' '|' <"$FAKE_DIR/editor-argv")"; fi
	if [ -e "$FAKE_DIR/edit-applied" ]; then ok; else bad "EDITOR edit not applied"; fi

	edit_fresh "$sh edit: TMPDIR with a space"
	mkdir "$root/tmp/t mp"
	TMPDIR="$root/tmp/t mp"
	run_k "$sh" edit cm/x
	expect_status 1 "TMPDIR with a space"
	expect_out 'TMPDIR contains whitespace' "TMPDIR message"
	expect_not_run "TMPDIR with a space"
	if [ -e "$FAKE_DIR/editor-runs" ]; then bad "the editor opened before the refusal"; else ok; fi

	edit_fresh "$sh edit: nested"
	TKUBE_EDIT_DIR=$root/tmp
	export TKUBE_EDIT_DIR
	run_k "$sh" edit cm/x
	expect_status 1 "nested edit"
	expect_out 'nested edits are not supported' "nested message"
	expect_not_run "nested edit"

	edit_fresh "$sh edit: unknown flag"
	run_k "$sh" edit cm/x --dry-run=server
	expect_status 1 "edit --dry-run"
	expect_out 'cannot be previewed' "edit --dry-run message"
	expect_not_run "edit --dry-run"

	edit_fresh "$sh edit outside Tern"
	unset TERN_PANE
	run_k "$sh" edit cm/x
	expect_status 1 "edit outside Tern"
	expect_not_run "edit outside Tern"

	edit_fresh "$sh edit without tern"
	TERN_BIN=$root/no-such-tern
	export TERN_BIN
	run_k "$sh" edit cm/x
	expect_status 1 "edit without tern"
	expect_out 'is not on PATH' "edit without tern message"
	expect_not_run "edit without tern"

	edit_fresh "$sh edit: core path with a space"
	rm -rf "$root/co re"
	cp -R "$repo/shell" "$root/co re"
	TKG_SNIP="$root/co re/tern-kube.$sh" TKG_CORE="$root/co re/tern-kube-guard" run_k "$sh" edit cm/x
	expect_status 0 "core with a space"
	if [ -e "$FAKE_DIR/edit-applied" ]; then ok; else bad "edit through a core path with a space not applied"; fi

	edit_fresh "$sh edit Ctrl-C"
	mode hang
	TKUBE_GUARD_TIMEOUT=30
	export TKUBE_GUARD_TIMEOUT
	(launch_group "$sh" edit cm/x >"$root/out" 2>&1 </dev/null) &
	pid=$!
	i=0
	while [ $i -lt 100 ] && ! ls "$root/spool"/req-*.json >/dev/null 2>&1; do
		sleep 0.1
		i=$((i + 1))
	done
	kill -s INT -- "-$pid" 2>/dev/null || bad "edit Ctrl-C: no process group $pid to signal"
	wait "$pid"
	st=$?
	i=0
	while [ $i -lt 50 ] && { ls -d "$root/tmp"/tkube-edit.* >/dev/null 2>&1 || [ -z "$(denied_copy)" ]; }; do
		sleep 0.1
		i=$((i + 1))
	done
	unset TKUBE_GUARD_TIMEOUT
	[ "$st" != 0 ] && ok || bad "edit Ctrl-C exited 0"
	expect_not_applied "edit Ctrl-C"
	expect_saved_copy "edit Ctrl-C"
	expect_spool_clean "edit Ctrl-C"
	# A kubectl killed by Ctrl-C leaves its own temp file, as the real one does.
	if ls -d "$root/tmp"/tkube-edit.* >/dev/null 2>&1; then bad "edit Ctrl-C left the edit dir"; else ok; fi
	if pgrep -f 'sleep 1797' >/dev/null 2>&1; then
		bad "edit Ctrl-C left the waiting tern open running"
		pkill -f 'sleep 1797'
	else ok; fi
}

for sh in $shells; do
	TKG_SNIP=$repo/shell/tern-kube.$sh
	TKG_CORE=$core
	export TKG_SNIP TKG_CORE
	core_cases "$sh"
	[ "$sh" = dash ] || snippet_cases "$sh"
	verb_cases "$sh"
	edit_cases "$sh"
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
