# Live: the lens offers Decode values on `get secret -o yaml` and `-o json`
# only with security.show_secret_values, never on describe (kubectl prints
# sizes only). The card is display-only, the YAML/tree keeps base64, and the
# choice lives only in the click action: after a plugin reload the same
# command starts hidden. Secret tk-e2e-decode (fake values)
# lives in tern-test-mutate and is deleted at the end; the config goes back
# to the stub.
DSEC=tk-e2e-decode
decode_cleanup() {
	kc -n "$MNS" delete secret "$DSEC" --ignore-not-found --wait=true >/dev/null 2>&1
	config_reset
}
trap decode_cleanup EXIT

kc -n "$MNS" delete secret "$DSEC" --ignore-not-found --wait=true >/dev/null 2>&1
kc -n "$MNS" create secret generic "$DSEC" --from-literal=password=hunter2-fake-e2e \
	--from-literal=username=tk-e2e-user >/dev/null || {
	fail "cannot create Secret $DSEC"
	return
}
B64=$(jp "$MNS" "secret/$DSEC" '{.data.password}')
[ -n "$B64" ] || {
	fail "Secret $DSEC has no data.password"
	return
}
CARD='[data-role="tern-kube.secret-decoded"]'
chips() {
	alltext '.sf-block-body .sf-act' | tr '\n' ' '
}
card_gone() {
	lacks "$CARD"
}
# Every text node of the block: `blocktext` reads only the block's own text,
# which the tree cuts at 200 characters.
btext() {
	ltext '.sf-block *'
}

# Config off: masked, no chip on any output.
config_reset
for out in yaml json; do
	lens "kubectl get secret $DSEC -n $MNS -o $out"
	native
	excludes "no chip while masked (-o $out)" "$(chips)" "Decode values"
	lacks "$CARD" || fail "decoded card while masked (-o $out)"
done

set_config '{"schema_version": 1, "security": {"show_secret_values": true}}'

# -o yaml: chip, card on click, YAML stays base64.
lens "kubectl get secret $DSEC -n $MNS -o yaml"
native
contains "yaml chip" "$(chips)" "Decode values"
lacks "$CARD" || fail "yaml decoded before the click"
excludes "yaml not decoded by default" "$(btext)" "hunter2-fake-e2e"
click_text 'Decode values' || return
has "$CARD" || fail "yaml chip did not decode"
contains "yaml decoded value" "$(alltext "$CARD *")" "hunter2-fake-e2e"
contains "yaml banner" "$(btext)" "display only: not copied, saved or logged"
contains "yaml stays base64" "$(alltext '.sf-block-body .sf-code')" "$B64"
contains "yaml hide chip" "$(chips)" "Hide decoded"

# The choice lives only in the block's click actions: no plugin state keeps
# it, so after a plugin reload the same command starts hidden. (Tern 0.9.16
# does not redraw an existing lens block on reload; a card already shown
# stays until Hide decoded.) Nothing decoded reaches the log.
dev reload >/dev/null 2>&1
sleep 1.5
lens "kubectl get secret $DSEC -n $MNS -o yaml"
native
contains "yaml chip after a reload" "$(chips)" "Decode values"
lacks "$CARD" || fail "decoded values shown again after a plugin reload"
excludes "nothing decoded in the log" "$(cat "$(daemon_log)")" "hunter2-fake-e2e"

# -o json (one object: its tree directly): chip, card above the tree.
lens "kubectl get secret $DSEC -n $MNS -o json"
native
contains "json chip" "$(chips)" "Decode values"
lacks "$CARD" || fail "json decoded before the click"
click_text 'Decode values' || return
has "$CARD" || fail "json chip did not decode"
contains "json decoded value" "$(alltext "$CARD *")" "hunter2-fake-e2e"
contains "json tree stays base64" "$(alltext '.sf-block-body .sf-tree *')" "$B64"
click_text 'Hide decoded' || return
lacks "$CARD" || fail "json Hide decoded did not hide"

# describe: sizes only, nothing to decode.
lens "kubectl describe secret $DSEC -n $MNS"
native
excludes "no chip on describe" "$(chips)" "Decode values"
lacks "$CARD" || fail "decoded card on describe"
excludes "describe never decodes" "$(btext)" "hunter2-fake-e2e"
