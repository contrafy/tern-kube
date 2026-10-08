# shellcheck shell=sh
# Headless host for the approve block's pure session (sourced by run.sh).
# The session decides; this file only executes its effects against the real
# kubectl (pinned to .sandbox kubeconfigs) and records results in a
# transcript that driver.luau replays. Nothing here talks to Tern.
#
#   tk_begin NAME ARG      start a session for block arg ARG (URL or request path)
#   tk_pump                execute pending effects until the session waits for the user
#   tk_key NAME [TEXT] · tk_type TEXT · tk_action ACT [VALUE] · tk_tick ALIVE CANCELLED
#   tk_expect VAR VALUE · tk_expect_has VAR TEXT · tk_note TEXT
#
# Inputs (env): TK_KUBECONFIG (host kubeconfig the block resolves),
# TK_PREVIEW_MS, TK_EXEC_MS, TK_MUTATIONS_ENABLED (true|false),
# TK_SHOW_SECRETS (true|false), TK_REQUEST (guard request file), TK_PANES.

TK_REPO=${TK_REPO:?}
TK_LUAU=$TK_REPO/.tools/bin/luau
TK_ROOT=.sandbox/mutate-it
TK_SPOOL=$TK_REPO/$TK_ROOT/spool
TK_HOME=$TK_REPO/$TK_ROOT/home
TK_FAILS=${TK_FAILS:-0}

tk_hex() {
	od -An -v -tx1 | tr -d ' \n'
}

tk_unhex() {
	xxd -r -p
}

tk_log() {
	printf '%s\n' "$*" >>"$TK_W/evidence.log"
}

tk_note() {
	printf '  - %s\n' "$*"
	tk_log "# $*"
}

tk_regen() {
	{
		cat "$TK_W/head.part"
		cat "$TK_W/events.part"
		printf '}}\nreturn T\n'
	} >"$TK_W/transcript.luau"
}

tk_event() {
	printf '%s\n' "$1" >>"$TK_W/events.part"
	tk_regen
}

tk_begin() { # NAME ARG
	TK_NAME=$1
	TK_W=$TK_REPO/$TK_ROOT/$1
	rm -rf "$TK_W"
	mkdir -p "$TK_W" "$TK_SPOOL" "$TK_HOME/.kube"
	cp "$TK_REPO/.sandbox/kubeconfig" "$TK_HOME/.kube/config"
	TK_DONE=0
	: >"$TK_W/events.part"
	: >"$TK_W/effects.log"
	: >"$TK_W/audit.log"
	req=
	if [ -n "${TK_REQUEST:-}" ]; then
		req="request = \"$(tk_hex <"$TK_REQUEST")\","
	fi
	panes=${TK_PANES:-'"7"'}
	cat >"$TK_W/head.part" <<EOF
local T = { init = {
	arg = "$(printf '%s' "$2" | tk_hex)",
	now = $(date +%s),
	kubectl = "$(printf '%s' "$(command -v kubectl)" | tk_hex)",
	kubeconfig = "$(printf '%s' "${TK_KUBECONFIG:-$TK_REPO/.sandbox/kubeconfig}" | tk_hex)",
	home = "$(printf '%s' "$TK_HOME" | tk_hex)",
	spool = "$(printf '%s' "$TK_SPOOL" | tk_hex)",
	$req
	panes = { $panes },
	previewTimeoutMs = ${TK_PREVIEW_MS:-30000},
	execTimeoutMs = ${TK_EXEC_MS:-120000},
	mutationsEnabled = ${TK_MUTATIONS_ENABLED:-true},
	showSecretValues = ${TK_SHOW_SECRETS:-false},
}, events = {
EOF
	tk_regen
	printf '\n== %s\n' "$1"
	tk_log "== $1 $2"
	tk_pump
}

tk_result() { # TAG GEN STATUS TIMED_OUT OUTFILE ERRFILE
	tk_event "{ t = \"result\", tag = \"$1\", gen = $2, status = $3, timed_out = $4, now = $(date +%s), stdout = \"$(tk_hex <"$5")\", stderr = \"$(tk_hex <"$6")\" },"
}

tk_runproc() { # TAG GEN TIMEOUT_MS CWD STDINHEX -- argv...
	tag=$1 gen=$2 tmo=$3 cwd=$4 inhex=$5
	shift 6
	rm -f "$TK_W/timedout"
	tk_log "\$ (cwd $cwd) $*"
	(
		cd "$cwd" || exit 125
		if [ -n "$inhex" ]; then
			printf '%s' "$inhex" | tk_unhex | exec "$@"
		else
			exec "$@" </dev/null
		fi
	) >"$TK_W/out" 2>"$TK_W/err" &
	pid=$!
	secs=$(awk "BEGIN { print $tmo / 1000 }")
	(
		trap 'kill "$s" 2>/dev/null; exit 0' TERM
		sleep "$secs" &
		s=$!
		wait "$s"
		pkill -9 -P "$pid" 2>/dev/null
		kill -9 "$pid" 2>/dev/null && : >"$TK_W/timedout"
	) >/dev/null 2>&1 &
	wd=$!
	wait "$pid" 2>/dev/null
	st=$?
	kill "$wd" 2>/dev/null
	wait "$wd" 2>/dev/null
	if [ -e "$TK_W/timedout" ]; then
		tk_log "  -> timed out after ${tmo}ms"
		tk_result "$tag" "$gen" -1 true "$TK_W/out" "$TK_W/err"
	else
		tk_log "  -> exit $st; stderr: $(head -c 300 "$TK_W/err" | tr '\n' ' ')"
		tk_result "$tag" "$gen" "$st" false "$TK_W/out" "$TK_W/err"
	fi
}

tk_effect() { # INDEX TYPE ...
	TK_DONE=$1
	kind=$2
	shift 2
	printf '%s %s\n' "$kind" "$*" >>"$TK_W/effects.log"
	case $kind in
	run)
		tk_runproc "$@"
		;;
	write)
		tag=$1 gen=$2 path=$3 texthex=$4
		shift 5
		if printf '%s' "$texthex" | tk_unhex >"$path"; then
			tk_log "wrote $path: $(tr '\n' ' ' <"$path")"
			tk_runproc "$tag" "$gen" 5000 / '' -- "$@"
		else
			printf 'cannot write\n' >"$TK_W/err"
			: >"$TK_W/out"
			tk_result "$tag" "$gen" 1 false "$TK_W/out" "$TK_W/err"
		fi
		;;
	read)
		tag=$1 gen=$2
		shift 3
		files=
		for p in "$@"; do
			files="$files{ path = \"$(printf '%s' "$p" | tk_hex)\", text = \"$(tk_hex <"$p")\" },"
		done
		tk_event "{ t = \"read\", tag = \"$tag\", gen = $gen, now = $(date +%s), files = { $files } },"
		;;
	audit)
		printf '%s' "$1" >>"$TK_W/audit.log"
		;;
	remove)
		rm -f "$1"
		;;
	esac
}

tk_pump() {
	# Luau's require resolves neither symlinked directories (.sandbox may be
	# one) nor paths above the filesystem root, so the driver loads a copy of
	# the transcript from the gitignored .transcripts/ next to itself.
	tk_mods=$TK_REPO/tests/integration/mutate/.transcripts
	mkdir -p "$tk_mods"
	while :; do
		before=$TK_DONE
		cp "$TK_W/transcript.luau" "$tk_mods/$TK_NAME.luau"
		"$TK_LUAU" "$TK_REPO/tests/integration/mutate/driver.luau" -a "$TK_NAME" "$TK_DONE" >"$TK_W/driver.out" 2>"$TK_W/driver.err" || {
			echo "driver failed:" >&2
			cat "$TK_W/driver.err" >&2
			return 1
		}
		# shellcheck disable=SC1091
		. "$TK_W/driver.out"
		[ "$TK_DONE" = "$before" ] && break
	done
	printf '%s\n' "$S_view" >"$TK_W/view.txt"
	tk_log "state: phase=$S_phase tier=$S_tier token=$S_token steps=[$S_steps] reasons=[$S_reasons] errors=[$S_errors] confirm_error=[$S_confirm_error]"
	printf '    phase=%s tier=%s steps=[%s]\n' "$S_phase" "${S_tier:--}" "$S_steps"
	[ -n "$S_errors" ] && printf '    errors: %s\n' "$S_errors"
	[ -n "$S_confirm_error" ] && printf '    refused: %s\n' "$S_confirm_error"
	return 0
}

tk_key() { # NAME [TEXT]
	if [ -n "${2:-}" ]; then
		tk_event "{ t = \"key\", name = \"$1\", text = \"$2\", now = $(date +%s) },"
	else
		tk_event "{ t = \"key\", name = \"$1\", now = $(date +%s) },"
	fi
	tk_log "user: key $1"
	tk_pump
}

tk_type() { # TEXT (letters, digits, - . / :)
	text=$1
	tk_log "user: types $text"
	while [ -n "$text" ]; do
		rest=${text#?}
		ch=${text%"$rest"}
		text=$rest
		tk_event "{ t = \"key\", name = \"$ch\", text = \"$ch\", now = $(date +%s) },"
	done
	tk_pump
}

tk_action() { # ACT [VALUE]
	tk_event "{ t = \"action\", act = \"$1\", value = \"${2:-}\", now = $(date +%s) },"
	tk_log "user: action $1 ${2:-}"
	tk_pump
}

tk_tick() { # ALIVE CANCELLED
	tk_event "{ t = \"tick\", now = $(date +%s), paneAlive = $1, cancelled = $2 },"
	tk_pump
}

tk_fail() {
	TK_FAILS=$((TK_FAILS + 1))
	printf '    FAIL: %s\n' "$*"
	tk_log "FAIL: $*"
}

tk_ok() {
	printf '    ok: %s\n' "$*"
	tk_log "ok: $*"
}

tk_expect() { # VAR VALUE
	eval "v=\${S_$1-}"
	if [ "$v" = "$2" ]; then tk_ok "$1 = $2"; else tk_fail "$1: expected '$2', got '$v'"; fi
}

tk_expect_has() { # VAR TEXT
	eval "v=\${S_$1-}"
	case $v in
	*"$2"*) tk_ok "$1 has '$2'" ;;
	*) tk_fail "$1: expected to contain '$2', got '$v'" ;;
	esac
}

tk_check() { # DESCRIPTION COMMAND...
	d=$1
	shift
	if "$@" >>"$TK_W/evidence.log" 2>&1; then tk_ok "$d"; else tk_fail "$d"; fi
}

tk_effects_has() { # TYPE
	if grep -q "^$1 " "$TK_W/effects.log"; then tk_ok "effect $1 emitted"; else tk_fail "no $1 effect"; fi
}

tk_effects_lacks() { # TYPE [TAG]
	if grep -q "^$1 ${2:-}" "$TK_W/effects.log"; then tk_fail "unexpected $1 ${2:-} effect"; else tk_ok "no $1 ${2:-} effect"; fi
}
