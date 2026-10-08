# Helpers for the Tern-in-the-loop scenarios (sourced by scripts/e2e.sh).
# Everything goes through scripts/dev-tern.sh against the sandbox in
# KL_TERN_SANDBOX; nothing here touches the default Tern or a real cluster.

E2E_REPO=${E2E_REPO:?}
E2E_FIX="$E2E_REPO/tests/fixtures"
E2E_DEV="$E2E_REPO/scripts/dev-tern.sh"
E2E_SB=${KL_TERN_SANDBOX:?}
E2E_FAILED=0

dev() {
	sh "$E2E_DEV" "$@"
}

ctl() {
	dev ctl "$@"
}

note() {
	printf '  %s\n' "$*"
}

fail() {
	printf '  FAIL %s\n' "$*"
	E2E_FAILED=1
	return 1
}

# --- Queries -----------------------------------------------------------------

# Visible matches of a selector: count, texts (JSON array), rect centers.
count() {
	ctl tree "$1" | jq -r '.count // 0'
}

texts() {
	ctl tree "$1" | jq -c '[.nodes[]?.text]'
}

alltext() {
	ctl tree "$1" | jq -r '[.nodes[]?.text // empty] | join("\n")'
}

daemon_log() {
	dev logs daemon
}

window_log() {
	dev logs window
}

log_lines() {
	wc -l <"$(daemon_log)" | tr -d ' '
}

# view_ms values logged after line $1 of the daemon log, for finished views.
view_ms_since() {
	tail -n +"$(($1 + 1))" "$(daemon_log)" | grep 'kube-lens lens.view' | grep 'finished=true' |
		sed -n 's/.*view_ms=\([0-9.]*\).*/\1/p'
}

# --- Waiting -----------------------------------------------------------------

# wait_for DESCRIPTION CMD...: retry CMD for up to E2E_WAIT seconds.
wait_for() {
	what=$1
	shift
	i=0
	limit=$((${E2E_WAIT:-10} * 4))
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -ge $limit ] && {
			fail "timed out waiting for $what"
			return 1
		}
		sleep 0.25
	done
}

has() { # has SEL [N]: at least N (default 1) visible matches
	[ "$(count "$1")" -ge "${2:-1}" ]
}

lacks() {
	[ "$(count "$1")" -eq 0 ]
}

idle() {
	[ "$(ctl state | jq -r '.focused.running == null and .focused.busy == false')" = true ]
}

# --- Driving -----------------------------------------------------------------

# type_line LINE: type a line and Enter into the focused pane.
type_line() {
	dev run "$1" >/dev/null
}

# sh_line LINE: a shell-only line (export, clear), waited for.
sh_line() {
	type_line "$1"
	wait_for "shell" idle
}

# The pane runs the real kubectl against kind by default. fake DIR switches
# it to the fake kubectl serving tests/fixtures/DIR (only for what a
# read-only live cluster cannot produce); real switches back.
fake() {
	sh_line "kl_fake '$E2E_FIX/$1'"
}

real() {
	sh_line kl_real
}

reset_pane() {
	real
	sh_line clear
}

# Text of the lens blocks, raw output included (raw text is not grid text).
blocktext() {
	ctl tree '.sf-block' | jq -r '[.nodes[]?.text // empty] | join(" ")'
}

# lens LINE: clear the pane, run LINE, wait for it to finish and the view to
# settle; the block is then the only one in the pane.
lens() {
	sh_line clear
	type_line "$1"
	wait_for "command to finish: $1" idle
	sleep 0.4
	top
}

top() {
	ctl scroll 100000 >/dev/null
	sleep 0.2
}

# click_text TEXT [SEL]: click the visible element of SEL (default: any
# clickable) whose text is exactly TEXT (a trailing * matches a prefix), then
# let the view re-render.
click_text() {
	sel=${2:-.sf-act}
	xy=$(ctl tree "$sel" | jq -r --arg t "$1" '
		def hit: if ($t | endswith("*")) then ((.text // "") | startswith($t[:-1])) else .text == $t end;
		[.nodes[]? | select(hit)][0].rect // empty | "\(.[0] + .[2] / 2) \(.[1] + .[3] / 2)"')
	[ -n "$xy" ] || {
		fail "no visible \"$1\" in $sel"
		return 1
	}
	# shellcheck disable=SC2086
	ctl click $xy >/dev/null
	sleep 0.5
	top
}

# --- Assertions --------------------------------------------------------------

eq() { # eq WHAT GOT WANT
	[ "$2" = "$3" ] || fail "$1: got $2, want $3"
}

contains() { # contains WHAT HAYSTACK NEEDLE
	case $2 in
	*"$3"*) ;;
	*) fail "$1: \"$3\" not in: $(printf '%s' "$2" | head -c 400)" ;;
	esac
}

excludes() {
	case $2 in
	*"$3"*) fail "$1: \"$3\" must not appear" ;;
	*) ;;
	esac
}

claimed() {
	has '.sf-block[data-role="lens.plugin.kube-lens.kubectl"]' || fail "block not claimed by kube-lens"
}

native() {
	claimed && { has '[data-role="kube-lens.header"]' || fail "no native view (raw shown)"; }
}

raw() {
	claimed && { lacks '[data-role="kube-lens.header"]' || fail "native view shown, raw expected"; }
}

# --- Clipboard (the sandbox window copies to the real pasteboard) -----------

E2E_CLIP=""

clip_save() {
	command -v pbpaste >/dev/null 2>&1 || return 0
	E2E_CLIP="$E2E_SB/clipboard.saved"
	pbpaste >"$E2E_CLIP" 2>/dev/null || true
}

clip_restore() {
	[ -n "$E2E_CLIP" ] && [ -f "$E2E_CLIP" ] && pbcopy <"$E2E_CLIP" 2>/dev/null || true
}

clip() {
	pbpaste 2>/dev/null || true
}
