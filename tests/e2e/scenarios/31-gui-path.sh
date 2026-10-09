# Regression: Tern started from the Dock/Finder (launchd) runs plugins with
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, where tern.process.run found no
# kubectl (/usr/local/bin, /opt/homebrew/bin) and Explore showed a Lua
# traceback twice. The window restarts with `dev-tern.sh start --gui-path`
# (no TKUBE_KUBECTL either); tern-kube must take PATH from the login shell
# (the sandbox zsh), run kubectl by its absolute path, report where it found
# it in Settings > Status, and turn a missing kubectl into one actionable
# card. The normal window comes back at the end.
ST="[data-surface='plugin.tern-kube.settings']"
CFG=$E2E_SB/xdg/tern-kube/config.json
GUI_PATH=/usr/bin:/bin:/usr/sbin:/sbin
cp "$CFG" "$E2E_SB/config.before-gui" 2>/dev/null || true
gui_cleanup() {
	if [ -f "$E2E_SB/config.before-gui" ]; then
		cp "$E2E_SB/config.before-gui" "$CFG"
	fi
	restart_window >/dev/null
}
trap gui_cleanup EXIT

from=$(log_lines)
restart_window --gui-path || return
read_shell() { tail -n +"$((from + 1))" "$(daemon_log)" | grep -q 'tern-kube shell env read'; }
E2E_WAIT=10 wait_for "the login-shell PATH read" read_shell || return

# Explore from a lens row loads live data through the resolved kubectl.
lens "kubectl get pods -n tern-test-apps"
native
click_text 'db-0' '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
xwait 'fetched'
excludes "no Lua traceback" "$(xtext)" "stack traceback"
excludes "kubectl was found" "$(xtext)" "kubectl not found"
explore_close

# Settings > Status names the absolute kubectl, its source and the shell read.
ctl plugins run plugin.tern-kube.settings >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
ctl key tab >/dev/null
stext() { alltext "$ST *" | tr '\n' ' ' | tr -s ' '; }
status_has() { case $(stext) in *"$1"*) true ;; *) false ;; esac; }
E2E_WAIT=10 wait_for "the kubectl status" status_has "$E2E_REAL_KUBECTL from" || return
status=$(stext)
case $status in
*"$E2E_REAL_KUBECTL from your shell's PATH"* | *"$E2E_REAL_KUBECTL from a common install location"*) ;;
*) fail "kubectl source: $(printf '%s' "$status" | grep -o "$E2E_REAL_KUBECTL.\{0,60\}" | head -1)" ;;
esac
contains "the shell read is reported" "$status" "read from /bin/zsh"
contains "Tern's own PATH is the launchd one" "$status" "$GUI_PATH"
ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST"

# A kubectl that cannot be found: one card naming the launch PATH, with
# Open Settings (kubectl selected) and Retry, which recovers once fixed.
jq '. + {kubectl: "kubectl-tk-missing"}' "$E2E_SB/config.before-gui" >"$CFG"
click_text 'Explore live'
explore_open || return
xwait 'kubectl (kubectl-tk-missing) not found'
x=$(xtext)
contains "names Tern's launch PATH" "$x" "launched with ($GUI_PATH)"
excludes "no Lua traceback" "$x" "stack traceback"
eq "the error appears once" "$(alltext "$EX [data-role='tern-kube.error']" | grep -c 'not found')" 1
excludes "the dock does not repeat it" "$(alltext "$EX [data-role='tern-kube.explore-dock'] *" | tr '\n' ' ')" "not found"
click_text 'Open Settings' "$EX .sf-act"
E2E_WAIT=10 wait_for "Settings from the card" has "$ST" || return
contains "kubectl is selected" "$(stext)" "kubectl = kubectl-tk-missing"
cp "$E2E_SB/config.before-gui" "$CFG"
ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST"
click_text 'Retry' "$EX .sf-act"
xwait 'Object pod/db-0'
xwait 'fetched'
excludes "Retry recovered" "$(xtext)" "not found"
explore_close
