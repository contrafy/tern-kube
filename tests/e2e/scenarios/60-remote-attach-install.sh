# Remote host attach and install (scripts/e2e.sh --remote): the window is
# connected to the disposable Linux host, the e2e snapshot is the plugin its
# daemon loaded (the host half of every remote scenario), and a new pane
# there gets the plugin's spawn environment (TKUBE_SPOOL, from the remote
# daemon) and TERN_EXE, the Tern binary the guard calls on remote hosts.
host_row() { # FIELD of the remote host's row in the window's host list
	ctl state | jq -r --arg n "$TK_REMOTE_NAME" --arg f "$1" '.hosts.hosts[]? | select(.name == $n) | .[$f] // empty'
}
connected() {
	[ "$(host_row state)" = Connected ]
}
E2E_WAIT=30 wait_for "$TK_REMOTE_NAME to connect" connected || return

# `tern remote setup` installs the build service's current Tern, which may
# be newer than this machine's; both halves must speak one protocol line.
local_tern=$(TERN_CONFIG_DIR="$E2E_SB/cfg" TERN_DAEMON_SOCKET="$E2E_SB/d.sock" "${TERN_BIN:-tern}" --version | awk '{ print $2 }')
remote_tern=$(host_row tern)
note "Tern here $local_tern, on $TK_REMOTE_NAME $remote_tern"
eq "remote Tern on the same minor line" "${remote_tern%.*}" "${local_tern%.*}"

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$E2E_SB/pkg/plugin.toml")
plugins=$(rsh '"$HOME/.local/bin/tern" plugin list')
contains "remote daemon loaded the snapshot" "$plugins" "tern-kube $version"
contains "remote plugin ready" "$plugins" "ready"
eq "remote link points at the copied snapshot" \
	"$(rsh 'cat "$HOME/.config/tern/plugins/tern-kube.path"')" "/home/tk/tern-kube-pkg"
eq "remote copy is the snapshot" "$(rsh 'cat "$HOME/tern-kube-pkg/plugin/host.luau"' | cksum)" \
	"$(cksum <"$E2E_SB/pkg/plugin/host.luau")"

remote_switch || return
focused_id() {
	ctl state | jq -r '.focused.id'
}
not_focused() {
	[ "$(focused_id)" != "$1" ]
}
first=$(focused_id)
trap 'ctl close >/dev/null 2>&1' EXIT
ctl tab new >/dev/null
E2E_WAIT=10 wait_for "a new remote tab" not_focused "$first" || return
E2E_WAIT=15 wait_for "the new tab's prompt" host_shown "$TK_REMOTE_NAME" || return
sh_line 'echo TK60 $TERN_EXE $TKUBE_SPOOL'
expect_grid "TK60 /home/tk/.local/share/tern/build/tern /home/tk/.local/state/tern/plugin-data/tern-kube/spool"
