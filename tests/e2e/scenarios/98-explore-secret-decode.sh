# Live: Explore's object view of a Secret decodes its values only on z, only
# with security.show_secret_values, in a separate display-only card (the tree
# keeps kubectl's base64), with control bytes escaped and binary as a hex
# dump; leaving the view or reopening it hides them again. Secret
# tk-e2e-decode (fake values) lives in tern-test-mutate and is deleted at the
# end; the config goes back to the stub.
DSEC=tk-e2e-decode
DDIR=$E2E_SB/decode-values
decode_cleanup() {
	kc -n "$MNS" delete secret "$DSEC" --ignore-not-found --wait=true >/dev/null 2>&1
	rm -rf "$DDIR"
	config_reset
}
trap decode_cleanup EXIT

rm -rf "$DDIR"
mkdir -p "$DDIR"
printf 'hunter2-fake-e2e' >"$DDIR/password"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBfakeE2E\n-----END CERTIFICATE-----\n' >"$DDIR/tls.crt"
printf '\000\001\002\377\376\211PNG\r\n\032\n' >"$DDIR/blob.bin"
printf 'user=admin \033]0;pwned\007\033[31mred text here and more' >"$DDIR/ansi"
: >"$DDIR/empty"
kc -n "$MNS" delete secret "$DSEC" --ignore-not-found --wait=true >/dev/null 2>&1
kc -n "$MNS" create secret generic "$DSEC" \
	--from-file=password="$DDIR/password" --from-file=tls.crt="$DDIR/tls.crt" \
	--from-file=blob.bin="$DDIR/blob.bin" --from-file=ansi="$DDIR/ansi" \
	--from-file=empty="$DDIR/empty" >/dev/null || {
	fail "cannot create Secret $DSEC"
	return
}
B64=$(jp "$MNS" "secret/$DSEC" '{.data.password}')
[ -n "$B64" ] || {
	fail "Secret $DSEC has no data.password"
	return
}
ESC=$(printf '\033')
CARD="[data-role='tern-kube.secret-decoded']"

decode_open() {
	lens "kubectl get secret $DSEC -n $MNS"
	native
	click_text "$DSEC" '.tk-grid .tk-c' || return 1
	click_text 'Explore live' || return 1
	explore_open || return 1
	xwait "Object secret/$DSEC"
}

# Config off: values masked, no chip, z explains how to show them.
config_reset
decode_open || return
t=$(xtext)
excludes "no decode chip while masked" "$t" "Decode values"
excludes "base64 masked" "$t" "$B64"
xkey z
toast=$(alltext '.toast span' | tr '\n' ' ')
contains "z toast names the setting" "$toast" "security.show_secret_values"
lacks "$EX $CARD" || fail "decoded card shown while values are masked"
excludes "nothing decoded while masked" "$(xtext)" "hunter2-fake-e2e"
explore_close

# Config on: base64 in the tree, decoded only after z.
set_config '{"schema_version": 1, "security": {"show_secret_values": true}}'
decode_open || return
t=$(xtext)
contains "decode chip" "$t" "Decode values (z)"
contains "tree keeps base64" "$t" "$B64"
excludes "not decoded by default" "$t" "hunter2-fake-e2e"
lacks "$EX $CARD" || fail "decoded card shown before z"

xkey z
xwait "Decoded values" || return
card=$(xtext "$CARD *")
contains "decoded password" "$card" "hunter2-fake-e2e"
contains "PEM shown" "$card" "-----BEGIN CERTIFICATE-----"
has "$EX $CARD .sf-code" || fail "multi-line value not in a code block"
contains "hex dump of binary" "$card" "|......PNG....|"
contains "binary kind" "$card" "binary"
contains "ESC escaped" "$card" '\x1b]0;pwned'
contains "empty value" "$card" "(empty)"
excludes "no raw ESC anywhere" "$(xtext)" "$ESC"
contains "hide chip" "$(xtext)" "Hide decoded (z)"
contains "tree still base64" "$(xtext)" "$B64"
contains "display-only banner" "$(xtext)" "display only: not copied, saved or logged"

# z again hides; the chip toggles too.
xkey z
lacks "$EX $CARD" || fail "z did not hide the decoded values"
click_text 'Decode values (z)' || return
has "$EX $CARD" || fail "the chip did not decode"

# Leaving the view (describe, then back) hides them.
xkey d
xwait "Describe secret/$DSEC" || return
xkey escape
xwait "Object secret/$DSEC" || return
lacks "$EX $CARD" || fail "decoded values survived leaving the view"
excludes "nothing decoded after leaving" "$(xtext)" "hunter2-fake-e2e"

# esc + reopen: a new view starts hidden.
xkey z
has "$EX $CARD" || fail "z did not decode again"
explore_close
decode_open || return
lacks "$EX $CARD" || fail "decoded values survived reopening"
excludes "nothing decoded after reopening" "$(xtext)" "hunter2-fake-e2e"
explore_close
