#!/bin/sh
# Isolated Tern for developing tern-kube. Every command runs against a
# sandbox (default /tmp/tk-tern, override with TK_TERN_SANDBOX) and never
# touches the default Tern config, daemon socket or logs.
#
#   start [--fake | --gui-path] [--print]
#                     run the sandbox window in the foreground (keep it in a
#                     long-lived terminal/service). Shells and the daemon
#                     always get KUBECONFIG=.sandbox/kubeconfig and a neutral
#                     zsh (sandbox ZDOTDIR, no user rc files); the daemon reads
#                     tern-kube config from <sandbox>/xdg, never the user's.
#                     Default: the real kubectl, refused unless that
#                     kubeconfig's context is kind-tern-kube-dev. --fake puts
#                     tests/bin (fake kubectl and kubecolor) first on PATH. In
#                     a pane, `tk_fake [DIR]` and `tk_real` switch.
#                     --gui-path starts the window and daemon with the PATH
#                     a Dock/Finder (launchd) start has,
#                     /usr/bin:/bin:/usr/sbin:/sbin, and no TKUBE_KUBECTL;
#                     panes still get the sandbox zsh rc. --print shows the
#                     environment
#   link [DIR]        point <sandbox>/cfg/plugins/tern-kube.path at the repo root
#                     (or DIR, e.g. a snapshot copy) and reload the daemon
#   unlink            remove the link and reload
#   reload            reload the sandbox daemon's plugins
#   list              plugins of the sandbox daemon
#   ctl ARGS...       tern ctl against the sandbox control socket
#   wait-ready [SECS] wait until the window answers `ready` (default 30 s)
#   run LINE          type LINE and Enter into the focused pane
#   expect TEXT       wait until a plugin surface shows TEXT
#   shot NAME [DEST]  screenshot the window; prints the PNG path (copied to
#                     DEST when given)
#   logs [daemon|window]  print the sandbox log path
#   stop              quit the sandbox window and its daemon
#   clean             stop, then delete the sandbox
#   env               print the sandbox environment as shell assignments

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sb=${TK_TERN_SANDBOX:-/tmp/tk-tern}
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
window_log="${STENCIL_LOG:-warn,stencil=info,tern::plugin=debug}"
# CLI calls (ctl, plugin reload) log to stderr; only the window logs verbosely.
export STENCIL_LOG=warn
# Inherited from a surrounding Tern pane; they describe the user's Tern.
unset TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_PANE TERN_PANE_SOCKET TERN_BLOB_DIR \
	TERN_COMPLETE TERN_IDENTITY TERN_LENSES TERM_PROGRAM TERM_PROGRAM_VERSION
ctl_sock="$sb/ctl.sock"
kubeconfig="$repo/.sandbox/kubeconfig"
fake_bin="$repo/tests/bin"
zdot="$sb/zsh"

ctl() {
	"$tern_bin" ctl --control "$ctl_sock" "$@"
}

# `tern ctl` joins its words into one scenario line; a quoted string keeps
# spaces and shell metacharacters as one argument.
quoted() {
	case $1 in
	*'"'*)
		echo "dev-tern: double quotes are not supported in scenario strings: $1" >&2
		exit 2
		;;
	esac
	printf '"%s"' "$1"
}

daemon_pids() {
	pgrep -f -- "$sb/d.sock" 2>/dev/null || true
}

# A neutral interactive zsh: no user rc files (they may reorder PATH, define
# aliases or switch kube contexts). Tern passes panes only part of the launch
# environment and /etc/zprofile's path_helper rebuilds PATH for login shells,
# so the values are written into the sandbox rc files instead. Two shell
# functions switch a pane: `tk_fake [DIR]` puts the fake kubectl (serving
# fixtures from DIR) first on PATH, `tk_real` removes it again.
write_zdotdir() { # $1 = 1 to start in fake mode, $2 = kubectl for Explore
	mkdir -p "$zdot"
	cat >"$zdot/.zshenv" <<EOF
export KUBECONFIG='$kubeconfig'
export KUBERC=off
unset KUBECTL_EXTERNAL_DIFF
EOF
	cat >"$zdot/.zshrc" <<EOF
HISTFILE='$zdot/history'
PROMPT='%1~ %# '
RPROMPT=''
export KUBECONFIG='$kubeconfig'
export TKUBE_KUBECTL='$2'
tk_real() {
	unset TKUBE_FAKE_FIXTURES TKUBE_FAKE_ROWS
	path=(\${path:#$fake_bin})
	rehash
}
tk_fake() {
	tk_real
	[ -n "\${1:-}" ] && export TKUBE_FAKE_FIXTURES="\$1"
	path=('$fake_bin' \$path)
	rehash
}
EOF
	if [ "$1" = 1 ]; then
		echo "tk_fake" >>"$zdot/.zshrc"
	else
		echo "tk_real" >>"$zdot/.zshrc"
	fi
}

# The real kubectl: first on PATH outside tests/bin.
real_kubectl() {
	PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$fake_bin\$" | paste -sd: -) command -v kubectl || true
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case $cmd in
start)
	fake=0
	print=0
	gui=0
	for a in "$@"; do
		case $a in
		--fake) fake=1 ;;
		--gui-path) gui=1 ;;
		--print) print=1 ;;
		*)
			echo "dev-tern: start [--fake | --gui-path] [--print]" >&2
			exit 2
			;;
		esac
	done
	if [ $fake = 1 ] && [ $gui = 1 ]; then
		echo "dev-tern: --gui-path runs the real kubectl found the way a Dock launch would; it cannot be combined with --fake" >&2
		exit 2
	fi
	mkdir -p "$TERN_CONFIG_DIR" "$STENCIL_LOG_DIR"
	export STENCIL_LOG="$window_log"
	export KUBECONFIG="$kubeconfig"
	export KUBERC=off
	# tern-kube reads $XDG_CONFIG_HOME/tern-kube/config.json; scenarios write it.
	export XDG_CONFIG_HOME="$sb/xdg"
	mkdir -p "$XDG_CONFIG_HOME/tern-kube"
	unset KUBECTL_EXTERNAL_DIFF TKUBE_FAKE_FIXTURES TKUBE_FAKE_ROWS
	export ZDOTDIR="$zdot"
	export SHELL=/bin/zsh
	if [ $fake = 1 ]; then
		# The window, its daemon and its shells see the fake kubectl first;
		# the Explore block honors TKUBE_KUBECTL, so nothing in the
		# sandbox reaches a cluster.
		export TKUBE_KUBECTL="$fake_bin/kubectl"
		export PATH="$fake_bin:$PATH"
		write_zdotdir 1 "$TKUBE_KUBECTL"
	else
		# Real kubectl, but only against the disposable kind cluster.
		real=$(real_kubectl)
		[ -n "$real" ] || {
			echo "dev-tern: kubectl not found on PATH (use --fake)" >&2
			exit 1
		}
		ctx=$("$real" config current-context 2>/dev/null || true)
		[ "$ctx" = kind-tern-kube-dev ] || {
			echo "dev-tern: refusing: $kubeconfig has context '$ctx', not kind-tern-kube-dev (scripts/cluster.sh create, or use --fake)" >&2
			exit 1
		}
		export TKUBE_KUBECTL="$real"
		write_zdotdir 0 "$real"
	fi
	if [ $gui = 1 ]; then
		# Tern started from the Dock/Finder: launchd's minimal PATH and no
		# TKUBE_KUBECTL; tern-kube must find kubectl through the login shell
		# (the sandbox zsh rc, via ZDOTDIR) or the common install dirs.
		# KUBECONFIG stays: without it a failed shell read would fall back
		# to the user's ~/.kube/config. (A sandbox HOME is not an option:
		# Tern then asks to sign in.)
		tern_bin=$(command -v "$tern_bin")
		export PATH=/usr/bin:/bin:/usr/sbin:/sbin
		unset TKUBE_KUBECTL
	fi
	if [ $print = 1 ]; then
		env | grep -E '^(TERN_|STENCIL_|KUBE|TKUBE_|ZDOTDIR=|SHELL=|PATH=)' | sort
		echo "$tern_bin --control $ctl_sock $repo  (cwd $sb)"
		exit 0
	fi
	# Shots land in <cwd>/target/shots: keep them in the sandbox.
	cd "$sb"
	exec "$tern_bin" --control "$ctl_sock" "$repo"
	;;
link)
	mkdir -p "$TERN_CONFIG_DIR/plugins"
	dir=$(CDPATH= cd -- "${1:-$repo}" && pwd)
	printf '%s\n' "$dir" >"$TERN_CONFIG_DIR/plugins/tern-kube.path"
	"$tern_bin" plugin reload
	;;
unlink)
	rm -f "$TERN_CONFIG_DIR/plugins/tern-kube.path"
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
wait-ready)
	limit=${1:-30}
	i=0
	until ctl ready >/dev/null 2>&1; do
		i=$((i + 1))
		if [ $i -ge $((limit * 4)) ]; then
			echo "dev-tern: window not ready after ${limit}s" >&2
			exit 1
		fi
		sleep 0.25
	done
	;;
run)
	ctl run "$(quoted "$*")"
	;;
expect)
	ctl plugins expect "$(quoted "$*")"
	;;
shot)
	name=${1:?shot NAME [DEST]}
	png=$(ctl shot "$name" | sed -n 's/.*"png":"\([^"]*\)".*/\1/p')
	case $png in
	/*) ;;
	?*) png="$sb/$png" ;;
	*)
		echo "dev-tern: shot failed" >&2
		exit 1
		;;
	esac
	if [ $# -ge 2 ]; then
		cp "$png" "$2"
		echo "$2"
	else
		echo "$png"
	fi
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
	printf 'TERN_CONFIG_DIR=%s\nTERN_DAEMON_SOCKET=%s\nSTENCIL_LOG_DIR=%s\nSTENCIL_LOG=%s\nKUBECONFIG=%s\n' \
		"$TERN_CONFIG_DIR" "$TERN_DAEMON_SOCKET" "$STENCIL_LOG_DIR" "$window_log" "$kubeconfig"
	;;
*)
	sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
	[ -z "$cmd" ] && exit 0
	exit 2
	;;
esac
