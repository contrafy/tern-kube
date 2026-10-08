#!/bin/sh
# Isolated Tern for developing kube-lens. Every command runs against a
# sandbox (default /tmp/kl-tern, override with KL_TERN_SANDBOX) and never
# touches the default Tern config, daemon socket or logs.
#
#   start [--print]   run the sandbox window in the foreground (keep it in a
#                     long-lived terminal/service); --print shows the command
#   link              point <sandbox>/cfg/plugins/kube-lens.path at plugin/
#                     and reload the sandbox daemon
#   unlink            remove the link and reload
#   reload            reload the sandbox daemon's plugins
#   list              plugins of the sandbox daemon
#   ctl ARGS...       tern ctl against the sandbox control socket
#   logs [daemon|window]  print the sandbox log path
#   stop              quit the sandbox window and its daemon
#   clean             stop, then delete the sandbox
#   env               print the sandbox environment as shell assignments

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sb=${KL_TERN_SANDBOX:-/tmp/kl-tern}
tern_bin=${TERN_BIN:-tern}

case $sb in
/tmp/?* | /private/tmp/?* | "$repo"/.sandbox/?*) ;;
*)
	echo "dev-tern: refusing sandbox outside /tmp or $repo/.sandbox: $sb" >&2
	exit 2
	;;
esac

export TERN_CONFIG_DIR="$sb/cfg"
export TERN_DAEMON_SOCKET="$sb/d.sock"
export STENCIL_LOG_DIR="$sb/logs"
export STENCIL_LOG="${STENCIL_LOG:-warn,stencil=info,tern::plugin=debug}"
unset TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_PANE TERN_PANE_SOCKET
ctl_sock="$sb/ctl.sock"

ctl() {
	"$tern_bin" ctl --control "$ctl_sock" "$@"
}

daemon_pids() {
	pgrep -f -- "$sb/d.sock" 2>/dev/null || true
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case $cmd in
start)
	mkdir -p "$TERN_CONFIG_DIR" "$STENCIL_LOG_DIR"
	if [ "${1:-}" = "--print" ]; then
		printf 'TERN_CONFIG_DIR=%s TERN_DAEMON_SOCKET=%s STENCIL_LOG_DIR=%s STENCIL_LOG=%s KUBE_LENS_KUBECTL=%s PATH=%s:$PATH %s --control %s %s\n' \
			"$TERN_CONFIG_DIR" "$TERN_DAEMON_SOCKET" "$STENCIL_LOG_DIR" "$STENCIL_LOG" "$repo/tests/bin/kubectl" "$repo/tests/bin" \
			"$tern_bin" "$ctl_sock" "$repo"
		exit 0
	fi
	# The window, its daemon and (unless shell rc files reorder PATH) its
	# shells see the fake kubectl first; the Explore block also honors
	# KUBE_LENS_KUBECTL, so nothing in the sandbox reaches a real cluster.
	export KUBE_LENS_KUBECTL="${KUBE_LENS_KUBECTL:-$repo/tests/bin/kubectl}"
	export PATH="$repo/tests/bin:$PATH"
	exec "$tern_bin" --control "$ctl_sock" "$repo"
	;;
link)
	mkdir -p "$TERN_CONFIG_DIR/plugins"
	printf '%s\n' "$repo/plugin" >"$TERN_CONFIG_DIR/plugins/kube-lens.path"
	"$tern_bin" plugin reload
	;;
unlink)
	rm -f "$TERN_CONFIG_DIR/plugins/kube-lens.path"
	"$tern_bin" plugin reload
	;;
reload)
	"$tern_bin" plugin reload "$@"
	;;
list)
	"$tern_bin" plugin list "$@"
	;;
ctl)
	ctl "$@"
	;;
logs)
	case ${1:-daemon} in
	daemon) echo "$STENCIL_LOG_DIR/tern-daemon.log" ;;
	window) echo "$STENCIL_LOG_DIR/tern.log" ;;
	*)
		echo "dev-tern: logs daemon|window" >&2
		exit 2
		;;
	esac
	;;
stop)
	ctl quit >/dev/null 2>&1 || true
	i=0
	while [ -n "$(daemon_pids)" ] && [ $i -lt 20 ]; do
		sleep 0.25
		i=$((i + 1))
	done
	pids=$(daemon_pids)
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null || true
	fi
	;;
clean)
	"$0" stop
	rm -rf "$sb"
	;;
env)
	printf 'TERN_CONFIG_DIR=%s\nTERN_DAEMON_SOCKET=%s\nSTENCIL_LOG_DIR=%s\nSTENCIL_LOG=%s\n' \
		"$TERN_CONFIG_DIR" "$TERN_DAEMON_SOCKET" "$STENCIL_LOG_DIR" "$STENCIL_LOG"
	;;
*)
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	[ -z "$cmd" ] && exit 0
	exit 2
	;;
esac
