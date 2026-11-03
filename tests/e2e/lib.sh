# Helpers for the Tern-in-the-loop scenarios (sourced by scripts/e2e.sh).
# Everything goes through scripts/dev-tern.sh against the sandbox in
# TK_TERN_SANDBOX; nothing here touches the default Tern or a real cluster.

E2E_REPO=${E2E_REPO:?}
E2E_FIX="$E2E_REPO/tests/fixtures"
E2E_DEV="$E2E_REPO/scripts/dev-tern.sh"
E2E_SB=${TK_TERN_SANDBOX:?}
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
	tail -n +"$(($1 + 1))" "$(daemon_log)" | grep 'tern-kube lens.view' | grep 'finished=true' |
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
	sh_line "tk_fake '$E2E_FIX/$1'"
}

real() {
	sh_line tk_real
}

# Back to one shell pane: splits a failed scenario left open (Explore, quick
# actions) are closed right-most first, so the original pane survives.
reset_pane() {
	i=0
	while [ "$(ctl state | jq '.panes | length')" -gt 1 ] && [ $i -lt 8 ]; do
		ctl focus right >/dev/null
		ctl close >/dev/null
		sleep 0.4
		i=$((i + 1))
	done
	# The survivor is the left-most pane; a click there gives it the keyboard.
	[ $i -gt 0 ] && ctl click 30 600 >/dev/null
	real
	sh_line clear
}

# restart_window [START ARGS...]: quit the sandbox window and start it again
# (e.g. with --gui-path), relink the snapshot plugin, back at one clear shell
# pane. The window keeps running after the calling scenario's subshell.
# A window attaches to any daemon still holding the socket, environment and
# all, so the restart fails unless the new window runs a new daemon.
restart_window() {
	reset_pane
	old=$(daemon_pids)
	dev stop >/dev/null || {
		fail "the old window or daemon ($old) did not stop"
		return 1
	}
	dev start "$@" >"$E2E_SB/window.out" 2>&1 &
	E2E_WAIT=30 wait_for "the sandbox window" ctl ready || {
		cat "$E2E_SB/window.out" >&2
		return 1
	}
	new=$(daemon_pids)
	if [ -z "$new" ] || [ "$new" = "$old" ]; then
		fail "the restarted window has no new daemon (before: $old, after: $new)"
		return 1
	fi
	dev link "$E2E_SB/pkg" >/dev/null 2>&1 || {
		fail "cannot link the plugin"
		return 1
	}
	E2E_WAIT=30 wait_for "the first prompt" ctl ready || return 1
	ctl resize 1280 800 >/dev/null
	sleep 1
	reset_pane
}

daemon_pids() {
	dev pids daemon
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
	has '.sf-block[data-role="lens.plugin.tern-kube.kubectl"]' || fail "block not claimed by tern-kube"
}

native() {
	claimed && { has '[data-role="tern-kube.header"]' || fail "no native view (raw shown)"; }
}

raw() {
	claimed && { lacks '[data-role="tern-kube.header"]' || fail "native view shown, raw expected"; }
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

# --- Explore block and quick actions ------------------------------------------

EX="[data-surface='plugin.tern-kube.explore']"

# xtext [SEL]: text inside the Explore block (SEL relative to it).
xtext() {
	alltext "$EX ${1:-*}" | tr '\n' ' '
}

# The first cell of the selected Explore row.
xsel() {
	texts "$EX .tk-sel .tk-c" | jq -r '.[0] // empty'
}

# xkey KEY...: send keys to the focused pane (the Explore block once open).
xkey() {
	for k in "$@"; do
		ctl key "$k" >/dev/null
	done
	sleep 0.4
}

x_loaded() {
	! printf '%s' "$(xtext '[data-role="tern-kube.explore-header"] *')" | grep -q 'fetching via'
}

# xwait TEXT [SEL]: wait until the Explore block shows TEXT (and no fetch runs).
xwait() {
	E2E_WAIT=${E2E_WAIT:-15} wait_for "Explore to show \"$1\"" x_has "$1" "${2:-*}"
}

x_has() {
	x_loaded && case $(xtext "$2") in *"$1"*) true ;; *) false ;; esac
}

explore_open() {
	E2E_WAIT=15 wait_for "Explore block" has "$EX"
}

explore_close() {
	i=0
	while has "$EX" && [ $i -lt 6 ]; do
		ctl key escape >/dev/null
		sleep 0.3
		i=$((i + 1))
	done
	lacks "$EX" || fail "Explore block did not close"
}

pane_count() {
	ctl state | jq '.panes | length'
}

focused_title() {
	ctl state | jq -r '.focused.label // ""'
}

# Wait for a new split whose title (set by the quick action) contains TEXT.
quick_pane() {
	E2E_WAIT=${E2E_WAIT:-15} wait_for "a \"$1\" split" focused_has "$1"
}

focused_has() {
	case $(focused_title) in *"$1"*) true ;; *) false ;; esac
}

# expect_grid TEXT: `ctl expect` itself waits up to 20 s for the grid text.
expect_grid() {
	ctl expect "\"$1\"" | grep -q '"ok":true' || fail "\"$1\" never appeared in a terminal"
}

# --- Mutations (M3) -------------------------------------------------------------
# Mutating scenarios touch only tern-test-mutate (and Jobs they create in
# tern-test-batch), create their own tk-e2e-* objects and delete them again.

AP="[data-surface='plugin.tern-kube.approve']"
MNS=tern-test-mutate

# kc ARGS...: the real kubectl, pinned to the sandbox kubeconfig and kind.
kc() {
	KUBECONFIG=$E2E_REPO/.sandbox/kubeconfig "${E2E_REAL_KUBECTL:-kubectl}" --context kind-tern-kube-dev "$@"
}

# jp NS KIND/NAME JSONPATH: one field of a live object ("" when absent).
jp() {
	kc -n "$1" get "$2" -o jsonpath="$3" 2>/dev/null || true
}

atext() {
	alltext "$AP *" | tr '\n' ' '
}

a_has() {
	case $(atext) in *"$1"*) true ;; *) false ;; esac
}

# await TEXT: wait until the approve block shows TEXT.
await() {
	E2E_WAIT=${E2E_WAIT:-20} wait_for "the approve block to show \"$1\"" a_has "$1"
}

approve_open() {
	E2E_WAIT=15 wait_for "the approve block" has "$AP"
}

approve_closed() {
	E2E_WAIT=10 wait_for "the approve block to close" lacks "$AP"
}

# Phases by their dock hints: input, ready (simple or typed), done.
a_input() { await "enter preview"; }
a_ready() { await "tab next diff"; }
a_done() { await "r requery"; }

# absent NS KIND/NAME: the object does not exist (fails on API errors).
absent() {
	out=$(kc -n "$1" get "$2" -o name --ignore-not-found) && [ -z "$out" ]
}

# e2e_manifest REPLICAS LEVEL: a disposable Deployment (pause image) and
# ConfigMap as YAML.
e2e_manifest() {
	cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tk-e2e-web
  namespace: $MNS
  labels: {app: tk-e2e-web}
spec:
  replicas: $1
  selector: {matchLabels: {app: tk-e2e-web}}
  template:
    metadata: {labels: {app: tk-e2e-web}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: web
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
          resources: {limits: {cpu: 50m, memory: 32Mi}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tk-e2e-cm
  namespace: $MNS
data: {LEVEL: $2}
EOF
}

e2e_objects() {
	e2e_manifest 1 info | kc apply -f - >/dev/null
	kc -n "$MNS" rollout status deploy/tk-e2e-web --timeout=60s >/dev/null || fail "tk-e2e-web not ready"
}

e2e_objects_delete() {
	kc -n "$MNS" delete deploy/tk-e2e-web configmap/tk-e2e-cm configmap/tk-e2e-applied \
		--ignore-not-found --wait=true >/dev/null 2>&1
}

# --- Logs and events lens (track 2) ---------------------------------------------
# tern-test-logs holds the tk-logmix Deployment (tests/integration/manifests/
# logs/logmix.yaml): 2 pods x containers app (mixed formats, then a tick a
# second), side (a beat every 3 s) and crashy (panics, restarts).

LNS=tern-test-logs
LOGS="[data-role='tern-kube.logs']"

# The first tk-logmix pod by name; prints nothing and fails when there is
# none. Use as: pod=$(logmix_pod) || { fail "no tk-logmix pod"; return; }
logmix_pod() {
	pod=$(kc -n "$LNS" get pods -l app=tk-logmix -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
	[ -n "$pod" ] && printf '%s' "$pod"
}

# tk-logmix's app container prints a line a second and the logs lens keeps
# the newest 20 000 records, so after about 5.5 h scenario 40 no longer finds
# the container's first lines. logmix_fresh (run once before the scenarios)
# restarts pods older than LOGMIX_MAX_AGE_S and waits until both new pods run
# and crashy has exited once (49 reads its previous instance).
LOGMIX_MAX_AGE_S=14400

logmix_fresh() {
	age=$(kc -n "$LNS" get pods -l app=tk-logmix -o json 2>/dev/null | jq -r '[.items[].status.containerStatuses[]?
		| select(.name == "app") | .state.running.startedAt // empty | fromdateiso8601]
		| if length == 0 then 0 else (now - min | floor) end')
	[ "${age:-0}" -le $LOGMIX_MAX_AGE_S ] && return 0
	note "restarting tk-logmix: its app containers are ${age}s old"
	kc -n "$LNS" rollout restart deployment/tk-logmix >/dev/null || return 1
	i=0
	until kc -n "$LNS" get pods -l app=tk-logmix -o json 2>/dev/null | jq -e '.items
		| length == 2 and all(.[]; .metadata.deletionTimestamp == null
			and ([.status.containerStatuses[]? | select(.name == "app") | .state.running.startedAt // empty
				| fromdateiso8601] | length == 1 and now - .[0] < 600)
			and ([.status.containerStatuses[]? | select(.name == "crashy") | .restartCount][0] // 0) >= 1)' >/dev/null; do
		i=$((i + 1))
		[ $i -lt 90 ] || return 1
		sleep 2
	done
}

# The block shows the logs view (a native view, not the table pipeline).
logs_native() {
	native && { has "$LOGS" || fail "native view is not the logs view"; }
}

# ltext SEL: visible text under SEL on one line.
ltext() {
	alltext "$1" | tr '\n' ' '
}

# column_texts N COLUMNS: cell N of every visible grid row (JSON array).
column_texts() {
	texts '.tk-grid .tk-r .tk-c' | jq -c --argjson n "$1" --argjson w "$2" '[range($n - 1; length; $w) as $i | .[$i]]'
}

# start_line LINE [SECS]: type a long-running command (follow, watch) and let
# it run SECS (default 3) seconds; the block stays at the top.
start_line() {
	sh_line clear
	type_line "$1"
	sleep "${2:-3}"
	top
}

# stop_line: Ctrl-C the running command, wait for the prompt and the view.
stop_line() {
	ctl key ctrl+c >/dev/null
	wait_for "the command to stop" idle
	sleep 0.6
	top
}

E2E_CFG=$E2E_SB/xdg/tern-kube/config.json

# set_config JSON: the sandbox's tern-kube config, read at plugin load.
set_config() {
	printf '%s\n' "$1" >"$E2E_CFG"
	dev reload >/dev/null 2>&1
	sleep 1.5
}

# config_reset: back to the stub a plugin load writes for a missing file.
config_reset() {
	rm -f "$E2E_CFG"
	dev reload >/dev/null 2>&1
	E2E_WAIT=10 wait_for "the config stub" test -f "$E2E_CFG"
	sleep 0.5
}

# --- Remote host (track 4, scripts/e2e.sh --remote) ------------------------------
# The window shows one host's session at a time; each host keeps its panes.
# TK_REMOTE_NAME is the host scripts/remote-host.sh registered.

# host_shown NAME: the window shows NAME's session, focused at an idle prompt.
host_shown() {
	ctl state | jq -e --arg n "$1" '.hosts.current == $n and .focused.prompt == true and .focused.running == null' >/dev/null
}

host_current() {
	[ "$(ctl state | jq -r '.hosts.current')" = "$1" ]
}

# remote_settled: the remote session is at an idle prompt within 3 s
# (no failure recorded otherwise).
remote_settled() {
	_st=0
	until host_shown "$TK_REMOTE_NAME"; do
		_st=$((_st + 1))
		[ $_st -ge 12 ] && return 1
		sleep 0.25
	done
}

# remote_switch: show the remote host's session, back at one clear pane.
# The host keeps its session across windows, so splits a failed scenario
# or an earlier window left there (running, or exited and showing "Shell
# exited") are interrupted or closed first.
remote_switch() {
	ctl remote switch "$TK_REMOTE_NAME" >/dev/null
	E2E_WAIT=30 wait_for "the remote host's session" host_current "$TK_REMOTE_NAME" || return 1
	_rs=0
	while [ $_rs -lt 8 ]; do
		if [ "$(pane_count)" -gt 1 ]; then
			ctl focus right >/dev/null
			ctl close >/dev/null
		elif remote_settled; then
			break
		elif [ "$(ctl state | jq -r '.focused.exited // empty')" = "" ]; then
			ctl key ctrl+c >/dev/null
		else
			ctl close >/dev/null
		fi
		sleep 0.4
		_rs=$((_rs + 1))
	done
	[ $_rs -gt 0 ] && ctl click 30 600 >/dev/null
	E2E_WAIT=15 wait_for "the remote host's prompt" host_shown "$TK_REMOTE_NAME" || return 1
	sh_line clear
}

# local_switch: show this machine's session again.
local_switch() {
	_ls=$(ctl state | jq -r '[.hosts.hosts[]? | select(.address == "")][0].name // empty')
	[ -n "$_ls" ] || {
		fail "no local host in the window's host list"
		return 1
	}
	ctl remote switch "$_ls" >/dev/null
	E2E_WAIT=15 wait_for "the local prompt" host_shown "$_ls"
}

# rsh [SCRIPT]: run SCRIPT (the arguments, else stdin) with `sh -s` on the
# remote host as its user, whatever the login shell.
rsh() {
	if [ $# -gt 0 ]; then
		printf '%s\n' "$*" | sh "$E2E_REPO/scripts/remote-host.sh" run
	else
		sh "$E2E_REPO/scripts/remote-host.sh" run
	fi
}

# --- Helm (track 3) ----------------------------------------------------------------
# The Helm scenarios source tests/e2e/helm.sh for their releases; these two
# namespaces hold them and nothing else.

HNS=tern-test-helm-e2e
HNS2=tern-test-helm-e2e-b

helm_world_down() {
	kc delete namespace "$HNS" "$HNS2" --ignore-not-found --wait=false >/dev/null 2>&1
}

# hsel_has TEXT: the selected Explore row contains TEXT.
hsel_has() {
	case $(texts "$EX .tk-sel .tk-c" | jq -r 'join(" ")') in *"$1"*) true ;; *) false ;; esac
}

# hcol N COLUMNS: cell N of every visible row of the Explore grid (JSON array).
hcol() {
	texts "$EX .tk-grid .tk-r .tk-c" | jq -c --argjson n "$1" --argjson w "$2" '[range($n - 1; length; $w) as $i | .[$i]]'
}

# explore_close_all: esc through a deep Helm route stack until Explore closes.
explore_close_all() {
	i=0
	while has "$EX" && [ $i -lt 20 ]; do
		ctl key escape >/dev/null
		sleep 0.3
		i=$((i + 1))
	done
	lacks "$EX" || fail "Explore block did not close"
}

# xselect TEXT: move the Explore selection down (from the top) to the first
# row containing TEXT.
xselect() {
	xkey g g
	i=0
	until hsel_has "$1"; do
		i=$((i + 1))
		[ $i -le 40 ] || {
			fail "no Explore row with \"$1\""
			return 1
		}
		xkey j
	done
}
