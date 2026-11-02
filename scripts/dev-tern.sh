#!/bin/sh
# Isolated Tern for developing tern-kube. Every command runs against a
# sandbox (default /tmp/tk-tern, override with TK_TERN_SANDBOX) and never
# touches the default Tern config, daemon socket or logs.
#
#   start [--fake | --gui-path] [--shell zsh|fish|bash] [--print]
#                     run the sandbox window in the foreground (keep it in a
#                     long-lived terminal/service). Shells and the daemon
#                     always get KUBECONFIG=.sandbox/kubeconfig and a neutral
#                     login shell, zsh by default (sandbox ZDOTDIR, no user
#                     rc files); --shell fish reads only <sandbox>/xdg/fish/
#                     config.fish (no history), --shell bash runs a wrapper
#                     that skips the profile files for <sandbox>/bash/bashrc.
#                     The daemon reads tern-kube config from <sandbox>/xdg,
#                     never the user's.
#                     Default: the real kubectl, refused unless that
#                     kubeconfig's context is kind-tern-kube-dev. --fake puts
#                     tests/bin (fake kubectl and kubecolor) first on PATH. In
#                     a pane, `tk_fake [DIR]` and `tk_real` switch.
#                     --gui-path starts the window and daemon with the PATH
#                     a Dock/Finder (launchd) start has,
#                     /usr/bin:/bin:/usr/sbin:/sbin, and no TKUBE_KUBECTL;
#                     panes still get the sandbox rc. --print shows the
#                     environment. TK_DEV_KUBE_EDITOR sets KUBE_EDITOR in
#                     every pane and split (sandbox rc files)
#   link [DIR]        point <sandbox>/cfg/plugins/tern-kube.path at the repo root
#                     (or DIR, e.g. a snapshot copy) and reload the daemon
#   unlink            remove the link and reload
#   reload            reload the sandbox daemon's plugins
#   list              plugins of the sandbox daemon
#   ctl ARGS...       tern ctl against the sandbox control socket, killed
#                     after TK_CTL_TIMEOUT seconds (default 60)
#   wait-ready [SECS] wait until the window answers `ready` (default 30 s)
#   run LINE          type LINE and Enter into the focused pane
#   expect TEXT       wait until a plugin surface shows TEXT
#   shot NAME [DEST]  screenshot the window; prints the PNG path (copied to
#                     DEST when given)
#   logs [daemon|window]  print the sandbox log path
#   pids window|daemon  pids of the sandbox window or daemon
#   stop              quit the sandbox window and its daemon (TERM, then
#                     KILL, whatever does not exit)
#   clean             stop, then delete the sandbox
#   env               print the sandbox environment as shell assignments
#
# start writes <sandbox>/cfg/omp/state.json with omp management off, so a
# fresh sandbox never offers to install omp.

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
# helm run by the plugin (and in panes) keeps its config, cache and
# repositories in the sandbox, never the user's helm directories.
export HELM_CONFIG_HOME="$sb/helm/config"
export HELM_CACHE_HOME="$sb/helm/cache"
export HELM_DATA_HOME="$sb/helm/data"
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

# bounded SECS CMD...: CMD, sent TERM after SECS. A window that is quitting
# can accept control connections and never answer; no caller may hang on it.
bounded() {
	_b_secs=$1
	shift
	"$@" &
	_b_pid=$!
	(
		trap 'kill "$_b_sleep" 2>/dev/null; exit 0' TERM
		sleep "$_b_secs" &
		_b_sleep=$!
		wait "$_b_sleep"
		kill -s TERM "$_b_pid" 2>/dev/null
	) >/dev/null 2>&1 &
	_b_watch=$!
	_b_rc=0
	wait "$_b_pid" || _b_rc=$?
	kill "$_b_watch" 2>/dev/null || true
	wait "$_b_watch" 2>/dev/null || true
	return $_b_rc
}

# Every control call is bounded (default 60 s, TK_CTL_TIMEOUT): `ctl expect`
# and `ctl ready` wait up to 20 s on their own.
ctl_within() { # SECS ARGS...
	_c_secs=$1
	shift
	bounded "$_c_secs" "$tern_bin" ctl --control "$ctl_sock" "$@" || {
		_c_rc=$?
		[ $_c_rc = 143 ] && echo "dev-tern: tern ctl $* gave no answer within ${_c_secs}s" >&2
		return $_c_rc
	}
}

ctl() {
	ctl_within "${TK_CTL_TIMEOUT:-60}" "$@"
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

# Pids of the sandbox window (`tern --control <sb>/ctl.sock DIR`, not the
# `tern ctl --control ...` clients) and of its daemon (`tern daemon --socket
# <sb>/d.sock`). Anchored so a caller whose command line names the sandbox
# never matches.
window_pids() {
	pgrep -f -- "^[^ ]*tern --control $ctl_sock( |\$)" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

daemon_pids() {
	pgrep -f -- "^[^ ]*tern daemon --socket $sb/d.sock\$" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

# wait_gone LISTER STEPS: until LISTER prints nothing, at most STEPS x 0.25 s.
wait_gone() {
	_w=0
	while [ -n "$($1)" ] && [ $_w -lt "$2" ]; do
		sleep 0.25
		_w=$((_w + 1))
	done
}

# terminate LISTER WHAT: TERM, then KILL, waiting up to 10 s after each.
terminate() {
	for _sig in TERM KILL; do
		_p=$($1)
		[ -n "$_p" ] || return 0
		# shellcheck disable=SC2086
		kill -s $_sig $_p 2>/dev/null || true
		wait_gone "$1" 40
	done
	_p=$($1)
	[ -z "$_p" ] && return 0
	echo "dev-tern: $2 $_p did not exit" >&2
	return 1
}

# Tern offers to install and manage omp (a 200 MB download, then a link
# where the user's shell finds omp) in every fresh config dir. The state
# file is what Settings > General > omp > "Managed by Tern" off writes.
seed_omp_state() {
	mkdir -p "$TERN_CONFIG_DIR/omp"
	printf '{\n  "managed": false,\n  "checked": 0,\n  "no_build": false,\n  "offered": true\n}\n' \
		>"$TERN_CONFIG_DIR/omp/state.json"
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
export HELM_CONFIG_HOME='$HELM_CONFIG_HOME'
export HELM_CACHE_HOME='$HELM_CACHE_HOME'
export HELM_DATA_HOME='$HELM_DATA_HOME'
EOF
	# Panes and splits get KUBE_EDITOR only from here (Tern filters the launch
	# environment); scenarios that drive `kubectl edit` set a scripted editor.
	if [ -n "${TK_DEV_KUBE_EDITOR:-}" ]; then
		echo "export KUBE_EDITOR='$TK_DEV_KUBE_EDITOR'" >>"$zdot/.zshenv"
	fi
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

# The same for fish (--shell fish): fish reads $XDG_CONFIG_HOME/fish/
# config.fish in every instance, login, interactive and `-c` alike, and the
# sandbox XDG_CONFIG_HOME hides the user's. History would still go to the
# user's data dir, so it is off.
write_fish_config() { # $1 = 1 to start in fake mode, $2 = kubectl for Explore
	mkdir -p "$sb/xdg/fish"
	cat >"$sb/xdg/fish/config.fish" <<EOF
set -g fish_history ''
set -g fish_greeting
set -gx KUBECONFIG '$kubeconfig'
set -gx KUBERC off
set -e KUBECTL_EXTERNAL_DIFF
set -gx TKUBE_KUBECTL '$2'
function fish_prompt
	printf '%s > ' (basename \$PWD)
end
function tk_real
	set -e TKUBE_FAKE_FIXTURES TKUBE_FAKE_ROWS
	while set -l i (contains -i -- '$fake_bin' \$PATH)
		set -e PATH[\$i]
	end
end
function tk_fake
	tk_real
	test -n "\$argv[1]"; and set -gx TKUBE_FAKE_FIXTURES \$argv[1]
	set -gx PATH '$fake_bin' \$PATH
end
EOF
	if [ -n "${TK_DEV_KUBE_EDITOR:-}" ]; then
		echo "set -gx KUBE_EDITOR '$TK_DEV_KUBE_EDITOR'" >>"$sb/xdg/fish/config.fish"
	fi
	if [ "$1" = 1 ]; then
		echo "tk_fake" >>"$sb/xdg/fish/config.fish"
	else
		echo "tk_real" >>"$sb/xdg/fish/config.fish"
	fi
}

# The same for bash (--shell bash). A login bash reads only the user's
# profile files, so SHELL is a wrapper that drops -l/--login and runs bash
# with the sandbox rc instead: --rcfile for interactive shells (panes, the
# PATH probe's -l -i -c), BASH_ENV for -c (quick-action splits); the rc
# unsets BASH_ENV so scripts started from the pane do not read it again.
# Panes start as `bash --posix -l` with ENV naming Tern's shell integration
# (POSIX mode reads ENV), but macOS's /bin/bash 3.2 ignores ENV there: the
# wrapper drops --posix and the rc sources the integration last, with
# KITTY_BASH_INJECT=no-rc so it does not read the rc again.
write_bash_rc() { # $1 = 1 to start in fake mode, $2 = kubectl for Explore
	mkdir -p "$sb/bash"
	cat >"$sb/bash/bashrc" <<EOF
unset BASH_ENV
HISTFILE='$sb/bash/history'
PS1='\W \\$ '
export KUBECONFIG='$kubeconfig'
export KUBERC=off
unset KUBECTL_EXTERNAL_DIFF
export TKUBE_KUBECTL='$2'
tk_real() {
	unset TKUBE_FAKE_FIXTURES TKUBE_FAKE_ROWS
	PATH=\$(printf '%s' "\$PATH" | tr ':' '\n' | grep -vxF '$fake_bin' | paste -sd: -)
	hash -r
}
tk_fake() {
	tk_real
	[ -n "\${1:-}" ] && export TKUBE_FAKE_FIXTURES="\$1"
	PATH='$fake_bin':\$PATH
	hash -r
}
EOF
	if [ -n "${TK_DEV_KUBE_EDITOR:-}" ]; then
		echo "export KUBE_EDITOR='$TK_DEV_KUBE_EDITOR'" >>"$sb/bash/bashrc"
	fi
	if [ "$1" = 1 ]; then
		echo "tk_fake" >>"$sb/bash/bashrc"
	else
		echo "tk_real" >>"$sb/bash/bashrc"
	fi
	cat >>"$sb/bash/bashrc" <<'EOF'
if [ -n "${TK_DEV_KSI:-}" ]; then
	_tk_ksi=$TK_DEV_KSI
	unset TK_DEV_KSI
	. "$_tk_ksi"
	unset _tk_ksi
fi
EOF
	cat >"$sb/bash/bash" <<EOF
#!/bin/sh
posix=0
n=\$#
while [ \$n -gt 0 ]; do
	a=\$1
	shift
	n=\$((n - 1))
	case \$a in
	-l | --login) ;;
	--posix) posix=1 ;;
	*) set -- "\$@" "\$a" ;;
	esac
done
export BASH_SILENCE_DEPRECATION_WARNING=1
if [ \$posix = 1 ]; then
	export TK_DEV_KSI="\${ENV:-}" KITTY_BASH_INJECT=no-rc
	unset ENV
fi
BASH_ENV='$sb/bash/bashrc' exec /bin/bash --noprofile --rcfile '$sb/bash/bashrc' "\$@"
EOF
	chmod 0755 "$sb/bash/bash"
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
	shell=zsh
	while [ $# -gt 0 ]; do
		case $1 in
		--fake) fake=1 ;;
		--gui-path) gui=1 ;;
		--print) print=1 ;;
		--shell)
			shell=${2:-}
			[ $# -gt 1 ] && shift
			;;
		*)
			echo "dev-tern: start [--fake | --gui-path] [--shell zsh|fish|bash] [--print]" >&2
			exit 2
			;;
		esac
		shift
	done
	case $shell in
	zsh) login_shell=/bin/zsh ;;
	fish)
		login_shell=$(command -v fish) || {
			echo "dev-tern: --shell fish: fish is not on PATH" >&2
			exit 1
		}
		;;
	bash) login_shell="$sb/bash/bash" ;;
	*)
		echo "dev-tern: --shell must be zsh, fish or bash, not '$shell'" >&2
		exit 2
		;;
	esac
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
	export SHELL="$login_shell"
	if [ $fake = 1 ]; then
		# The window, its daemon and its shells see the fake kubectl first;
		# the Explore block honors TKUBE_KUBECTL, so nothing in the
		# sandbox reaches a cluster.
		export TKUBE_KUBECTL="$fake_bin/kubectl"
		export PATH="$fake_bin:$PATH"
		write_zdotdir 1 "$TKUBE_KUBECTL"
		write_fish_config 1 "$TKUBE_KUBECTL"
		write_bash_rc 1 "$TKUBE_KUBECTL"
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
		write_fish_config 0 "$real"
		write_bash_rc 0 "$real"
	fi
	if [ $gui = 1 ]; then
		# Tern started from the Dock/Finder: launchd's minimal PATH and no
		# TKUBE_KUBECTL; tern-kube must find kubectl through the login shell
		# (the sandbox rc of the login shell) or the common install dirs.
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
	seed_omp_state
	# Shots land in <cwd>/target/shots: keep them in the sandbox.
	cd "$sb"
	exec "$tern_bin" --control "$ctl_sock" "$repo"
	;;
link)
	mkdir -p "$TERN_CONFIG_DIR/plugins"
	dir=$(CDPATH= cd -- "${1:-$repo}" && pwd)
	printf '%s\n' "$dir" >"$TERN_CONFIG_DIR/plugins/tern-kube.path"
	bounded 30 "$tern_bin" plugin reload
	;;
unlink)
	rm -f "$TERN_CONFIG_DIR/plugins/tern-kube.path"
	bounded 30 "$tern_bin" plugin reload
	;;
reload)
	bounded 30 "$tern_bin" plugin reload "$@"
	;;
list)
	bounded 30 "$tern_bin" plugin list "$@"
	;;
ctl)
	ctl "$@"
	;;
wait-ready)
	limit=${1:-30}
	end=$(($(date +%s) + limit))
	until ctl_within 25 ready >/dev/null 2>&1; do
		if [ "$(date +%s)" -ge $end ]; then
			echo "dev-tern: window not ready after ${limit}s" >&2
			exit 1
		fi
		sleep 0.25
	done
	;;
pids)
	case ${1:-} in
	window) window_pids ;;
	daemon) daemon_pids ;;
	*)
		echo "dev-tern: pids window|daemon" >&2
		exit 2
		;;
	esac
	echo
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
	# The daemon outlives its windows (it keeps their panes for the next
	# one), and a new window attaches to whatever daemon holds the socket,
	# with that daemon's environment: a restart (--gui-path) is only real
	# once the old daemon is gone, so stop it and wait for it. A window
	# that ignores `quit` (or never answers it) is terminated.
	[ -n "$(window_pids)" ] && { ctl_within 5 quit >/dev/null 2>&1 || true; }
	wait_gone window_pids 40
	rc=0
	terminate window_pids window || rc=1
	terminate daemon_pids daemon || rc=1
	exit $rc
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
	sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
	[ -z "$cmd" ] && exit 0
	exit 2
	;;
esac
