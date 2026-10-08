# shellcheck shell=sh
# Headless host for the approve block's pure session (sourced by run.sh).
# The session decides; this file only executes its effects against the real
# kubectl (pinned to .sandbox kubeconfigs) and records results in a
# transcript that driver.luau replays. Nothing here talks to Tern.
#
#   kl_begin NAME ARG      start a session for block arg ARG (URL or request path)
#   kl_pump                execute pending effects until the session waits for the user
#   kl_key NAME [TEXT] · kl_type TEXT · kl_action ACT [VALUE] · kl_tick ALIVE CANCELLED
#   kl_expect VAR VALUE · kl_expect_has VAR TEXT · kl_note TEXT
#
# Inputs (env): KL_KUBECONFIG (host kubeconfig the block resolves),
# KL_PREVIEW_MS, KL_EXEC_MS, KL_MUTATIONS_ENABLED (true|false),
# KL_SHOW_SECRETS (true|false), KL_REQUEST (guard request file), KL_PANES.

KL_REPO=${KL_REPO:?}
KL_LUAU=$KL_REPO/.tools/bin/luau
KL_ROOT=.sandbox/mutate-it
KL_SPOOL=$KL_REPO/$KL_ROOT/spool
KL_HOME=$KL_REPO/$KL_ROOT/home
KL_FAILS=${KL_FAILS:-0}

kl_hex() {
	od -An -v -tx1 | tr -d ' \n'
}

kl_unhex() {
	xxd -r -p
}

kl_log() {
	printf '%s\n' "$*" >>"$KL_W/evidence.log"
}

kl_note() {
	printf '  - %s\n' "$*"
	kl_log "# $*"
}

kl_regen() {
	{
		cat "$KL_W/head.part"
		cat "$KL_W/events.part"
		printf '}}\nreturn T\n'
	} >"$KL_W/transcript.luau"
}

kl_event() {
	printf '%s\n' "$1" >>"$KL_W/events.part"
	kl_regen
}

kl_begin() { # NAME ARG
	KL_NAME=$1
	KL_W=$KL_REPO/$KL_ROOT/$1
	rm -rf "$KL_W"
	mkdir -p "$KL_W" "$KL_SPOOL" "$KL_HOME/.kube"
	cp "$KL_REPO/.sandbox/kubeconfig" "$KL_HOME/.kube/config"
	KL_DONE=0
	: >"$KL_W/events.part"
	: >"$KL_W/effects.log"
	: >"$KL_W/audit.log"
	req=
	if [ -n "${KL_REQUEST:-}" ]; then
		req="request = \"$(kl_hex <"$KL_REQUEST")\","
	fi
	panes=${KL_PANES:-'"7"'}
	cat >"$KL_W/head.part" <<EOF
local T = { init = {
	arg = "$(printf '%s' "$2" | kl_hex)",
	now = $(date +%s),
	kubectl = "$(printf '%s' "$(command -v kubectl)" | kl_hex)",
	kubeconfig = "$(printf '%s' "${KL_KUBECONFIG:-$KL_REPO/.sandbox/kubeconfig}" | kl_hex)",
	home = "$(printf '%s' "$KL_HOME" | kl_hex)",
	spool = "$(printf '%s' "$KL_SPOOL" | kl_hex)",
	$req
	panes = { $panes },
	previewTimeoutMs = ${KL_PREVIEW_MS:-30000},
	execTimeoutMs = ${KL_EXEC_MS:-120000},
	mutationsEnabled = ${KL_MUTATIONS_ENABLED:-true},
	showSecretValues = ${KL_SHOW_SECRETS:-false},
}, events = {
EOF
	kl_regen
	printf '\n== %s\n' "$1"
	kl_log "== $1 $2"
	kl_pump
}

kl_result() { # TAG GEN STATUS TIMED_OUT OUTFILE ERRFILE
	kl_event "{ t = \"result\", tag = \"$1\", gen = $2, status = $3, timed_out = $4, now = $(date +%s), stdout = \"$(kl_hex <"$5")\", stderr = \"$(kl_hex <"$6")\" },"
}

kl_runproc() { # TAG GEN TIMEOUT_MS CWD STDINHEX -- argv...
	tag=$1 gen=$2 tmo=$3 cwd=$4 inhex=$5
	shift 6
	rm -f "$KL_W/timedout"
	kl_log "\$ (cwd $cwd) $*"
	(
		cd "$cwd" || exit 125
		if [ -n "$inhex" ]; then
			printf '%s' "$inhex" | kl_unhex | exec "$@"
		else
			exec "$@" </dev/null
		fi
	) >"$KL_W/out" 2>"$KL_W/err" &
	pid=$!
	secs=$(awk "BEGIN { print $tmo / 1000 }")
	(
		trap 'kill "$s" 2>/dev/null; exit 0' TERM
		sleep "$secs" &
		s=$!
		wait "$s"
		pkill -9 -P "$pid" 2>/dev/null
		kill -9 "$pid" 2>/dev/null && : >"$KL_W/timedout"
	) >/dev/null 2>&1 &
	wd=$!
	wait "$pid" 2>/dev/null
	st=$?
	kill "$wd" 2>/dev/null
	wait "$wd" 2>/dev/null
	if [ -e "$KL_W/timedout" ]; then
		kl_log "  -> timed out after ${tmo}ms"
		kl_result "$tag" "$gen" -1 true "$KL_W/out" "$KL_W/err"
	else
		kl_log "  -> exit $st; stderr: $(head -c 300 "$KL_W/err" | tr '\n' ' ')"
		kl_result "$tag" "$gen" "$st" false "$KL_W/out" "$KL_W/err"
	fi
}

kl_effect() { # INDEX TYPE ...
	KL_DONE=$1
	kind=$2
	shift 2
	printf '%s %s\n' "$kind" "$*" >>"$KL_W/effects.log"
	case $kind in
	run)
		kl_runproc "$@"
		;;
	write)
		tag=$1 gen=$2 path=$3 texthex=$4
		shift 5
		if printf '%s' "$texthex" | kl_unhex >"$path"; then
			kl_log "wrote $path: $(tr '\n' ' ' <"$path")"
			kl_runproc "$tag" "$gen" 5000 / '' -- "$@"
		else
			printf 'cannot write\n' >"$KL_W/err"
			: >"$KL_W/out"
			kl_result "$tag" "$gen" 1 false "$KL_W/out" "$KL_W/err"
		fi
		;;
	read)
		tag=$1 gen=$2
		shift 3
		files=
		for p in "$@"; do
			files="$files{ path = \"$(printf '%s' "$p" | kl_hex)\", text = \"$(kl_hex <"$p")\" },"
		done
		kl_event "{ t = \"read\", tag = \"$tag\", gen = $gen, now = $(date +%s), files = { $files } },"
		;;
	audit)
		printf '%s' "$1" >>"$KL_W/audit.log"
		;;
	remove)
		rm -f "$1"
		;;
	esac
}

kl_pump() {
	# Luau's require resolves neither symlinked directories (.sandbox may be
	# one) nor paths above the filesystem root, so the driver loads a copy of
	# the transcript from the gitignored .transcripts/ next to itself.
	kl_mods=$KL_REPO/tests/integration/mutate/.transcripts
	mkdir -p "$kl_mods"
	while :; do
		before=$KL_DONE
		cp "$KL_W/transcript.luau" "$kl_mods/$KL_NAME.luau"
		"$KL_LUAU" "$KL_REPO/tests/integration/mutate/driver.luau" -a "$KL_NAME" "$KL_DONE" >"$KL_W/driver.out" 2>"$KL_W/driver.err" || {
			echo "driver failed:" >&2
			cat "$KL_W/driver.err" >&2
			return 1
		}
		# shellcheck disable=SC1091
		. "$KL_W/driver.out"
		[ "$KL_DONE" = "$before" ] && break
	done
	printf '%s\n' "$S_view" >"$KL_W/view.txt"
	kl_log "state: phase=$S_phase tier=$S_tier token=$S_token steps=[$S_steps] reasons=[$S_reasons] errors=[$S_errors] confirm_error=[$S_confirm_error]"
	printf '    phase=%s tier=%s steps=[%s]\n' "$S_phase" "${S_tier:--}" "$S_steps"
	[ -n "$S_errors" ] && printf '    errors: %s\n' "$S_errors"
	[ -n "$S_confirm_error" ] && printf '    refused: %s\n' "$S_confirm_error"
	return 0
}

kl_key() { # NAME [TEXT]
	if [ -n "${2:-}" ]; then
		kl_event "{ t = \"key\", name = \"$1\", text = \"$2\", now = $(date +%s) },"
	else
		kl_event "{ t = \"key\", name = \"$1\", now = $(date +%s) },"
	fi
	kl_log "user: key $1"
	kl_pump
}

kl_type() { # TEXT (letters, digits, - . / :)
	text=$1
	kl_log "user: types $text"
	while [ -n "$text" ]; do
		rest=${text#?}
		ch=${text%"$rest"}
		text=$rest
		kl_event "{ t = \"key\", name = \"$ch\", text = \"$ch\", now = $(date +%s) },"
	done
	kl_pump
}

kl_action() { # ACT [VALUE]
	kl_event "{ t = \"action\", act = \"$1\", value = \"${2:-}\", now = $(date +%s) },"
	kl_log "user: action $1 ${2:-}"
	kl_pump
}

kl_tick() { # ALIVE CANCELLED
	kl_event "{ t = \"tick\", now = $(date +%s), paneAlive = $1, cancelled = $2 },"
	kl_pump
}

kl_fail() {
	KL_FAILS=$((KL_FAILS + 1))
	printf '    FAIL: %s\n' "$*"
	kl_log "FAIL: $*"
}

kl_ok() {
	printf '    ok: %s\n' "$*"
	kl_log "ok: $*"
}

kl_expect() { # VAR VALUE
	eval "v=\${S_$1-}"
	if [ "$v" = "$2" ]; then kl_ok "$1 = $2"; else kl_fail "$1: expected '$2', got '$v'"; fi
}

kl_expect_has() { # VAR TEXT
	eval "v=\${S_$1-}"
	case $v in
	*"$2"*) kl_ok "$1 has '$2'" ;;
	*) kl_fail "$1: expected to contain '$2', got '$v'" ;;
	esac
}

kl_check() { # DESCRIPTION COMMAND...
	d=$1
	shift
	if "$@" >>"$KL_W/evidence.log" 2>&1; then kl_ok "$d"; else kl_fail "$d"; fi
}

kl_effects_has() { # TYPE
	if grep -q "^$1 " "$KL_W/effects.log"; then kl_ok "effect $1 emitted"; else kl_fail "no $1 effect"; fi
}

kl_effects_lacks() { # TYPE [TAG]
	if grep -q "^$1 ${2:-}" "$KL_W/effects.log"; then kl_fail "unexpected $1 ${2:-} effect"; else kl_ok "no $1 ${2:-} effect"; fi
}
