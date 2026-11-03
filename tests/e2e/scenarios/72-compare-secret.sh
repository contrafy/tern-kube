# Live, two clusters (E2E_MC=1): comparing Secret tkm-secret never shows a
# value (raw, base64 or via last-applied-configuration) by default, only
# which keys changed; with security.show_secret_values the values show.
. "$E2E_REPO/tests/e2e/compare.sh"
trap config_reset EXIT

mc_object "$MCA" secret tkm-secret secret || return
mc_pick_first || return
E2E_WAIT=20 xwait "differs" '[data-role="tern-kube.compare-status"] *' || return
t=$(xtext)
contains "changed value masked" "$t" "<redacted, changed>"
contains "unchanged value masked" "$t" "<redacted>"
contains "key names stay visible" "$t" "password"
contains "masking notice" "$t" "Secret values are masked"
excludes "no raw value" "$t" "s3cret"
excludes "no base64 value" "$t" "czNjcmV0"
excludes "no last-applied" "$t" "last-applied-configuration"
explore_close

set_config '{"schema_version": 1, "security": {"show_secret_values": true}}'
mc_object "$MCA" secret tkm-secret secret || return
mc_pick_first || return
E2E_WAIT=20 xwait "differs" '[data-role="tern-kube.compare-status"] *' || return
t=$(xtext)
# Values as the object view shows them: base64 data (or decoded, if shown so).
case $t in *czNjcmV0LUE=* | *s3cret-A*) ;; *) fail "base value not shown when allowed" ;; esac
case $t in *czNjcmV0LUI=* | *s3cret-B*) ;; *) fail "other value not shown when allowed" ;; esac
explore_close
