# Settings block: opens from the palette, toggles a boolean into the
# sandbox's own config file (never the user's), shows the saved state, and
# resets the key so the file returns to defaults.
ST="[data-surface='plugin.kube-lens.settings']"
CFG=$E2E_SB/xdg/kube-lens/config.json
settings_cleanup() {
	rm -f "$CFG"
}
trap settings_cleanup EXIT
rm -f "$CFG"

ctl plugins run plugin.kube-lens.settings >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
contains "shows the config path" "$(alltext "$ST *" | tr '\n' ' ')" "$CFG"
contains "starts from defaults" "$(alltext "$ST *" | tr '\n' ' ')" "no file: defaults"

ctl key enter >/dev/null
E2E_WAIT=10 wait_for "the config file" test -f "$CFG"
sleep 0.5
eq "enter flips native_default" "$(jq -r '.general.native_default' "$CFG")" false
eq "schema version written" "$(jq -r '.schema_version' "$CFG")" 1
contains "confirms the save" "$(alltext "$ST *" | tr '\n' ' ')" "Saved."

ctl key r >/dev/null
sleep 1
eq "r resets to the default" "$(jq -r '.general.native_default // "unset"' "$CFG")" unset

ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST"
