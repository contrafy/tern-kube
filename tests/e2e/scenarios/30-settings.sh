# Settings block and config onboarding, on the sandbox's own config file
# (never the user's). Plugin load wrote the stub (only $schema and
# schema_version) into the fresh sandbox; the block opens on it, toggles a
# boolean, keeps $schema first, and resets the key so the file returns to
# the stub. A reload never overwrites an existing file and recreates a
# deleted one.
ST="[data-surface='plugin.tern-kube.settings']"
CFG=$E2E_SB/xdg/tern-kube/config.json
SCHEMA_URL=https://raw.githubusercontent.com/contrafy/tern-kube/master/schema/config.schema.json
STUB=$(printf '{\n  "$schema": "%s",\n  "schema_version": 1\n}' "$SCHEMA_URL")
settings_cleanup() {
	printf '%s\n' "$STUB" >"$CFG"
}
trap settings_cleanup EXIT

E2E_WAIT=10 wait_for "the stub written at plugin load" test -f "$CFG"
eq "the stub holds only \$schema and schema_version" "$(cat "$CFG")" "$STUB"

ctl plugins run plugin.tern-kube.settings >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
contains "shows the config path" "$(alltext "$ST *" | tr '\n' ' ')" "$CFG"
contains "loads the stub" "$(alltext "$ST *" | tr '\n' ' ')" "loaded"

ctl key enter >/dev/null
E2E_WAIT=10 wait_for "the edit to land" sh -c "jq -e '.general.native_default == false' '$CFG'"
eq "enter flips native_default" "$(jq -r '.general.native_default' "$CFG")" false
eq "\$schema stays first" "$(jq -c 'keys_unsorted' "$CFG")" '["$schema","schema_version","general"]'
eq "\$schema is kept" "$(jq -r '.["$schema"]' "$CFG")" "$SCHEMA_URL"
contains "confirms the save" "$(alltext "$ST *" | tr '\n' ' ')" "Saved."

ctl key r >/dev/null
sleep 1
eq "r resets to the default, back to the stub" "$(cat "$CFG")" "$STUB"

ctl key escape >/dev/null
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST"

MINE='{"schema_version": 1, "general": {"max_rows": 42}}'
printf '%s\n' "$MINE" >"$CFG"
dev reload >/dev/null 2>&1
sleep 2
eq "a plugin load never overwrites an existing file" "$(cat "$CFG")" "$MINE"

rm -f "$CFG"
dev reload >/dev/null 2>&1
E2E_WAIT=10 wait_for "the stub after a reload" test -f "$CFG"
sleep 0.5
eq "a plugin load recreates a deleted file as the stub" "$(cat "$CFG")" "$STUB"
