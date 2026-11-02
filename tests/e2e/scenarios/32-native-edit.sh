# Native editing (Tern 0.9 BlockDef.features edit/undo) in the Settings value
# field and the approve block's replicas, path and typed-confirmation fields:
# a click places the caret, a shift-arrow selection is replaced by typing,
# paste replaces a selection or inserts at the caret, cmd+z undoes through the
# block's own history. The typed delete needs the exact token: Enter with any
# other text (an edited or a pasted near-miss) never deletes. Objects:
# tern-test-mutate tk-e2e-web, deleted at the end; the sandbox config file is
# restored.
ST="[data-surface='plugin.tern-kube.settings']"
CFG=$E2E_SB/xdg/tern-kube/config.json
cp "$CFG" "$E2E_SB/config.before-edit"
# Lenses use the config cached at the last read (docs/configuration.md), so
# the restored file only reaches later scenarios' lenses after a reload
# (max_rows 777 would cap scenario 40's logs).
edit_cleanup() {
	cp "$E2E_SB/config.before-edit" "$CFG"
	dev reload >/dev/null 2>&1
	e2e_objects_delete
}
trap edit_cleanup EXIT

# field SURFACE: the field's own text (prompt and placeholder left out).
field() {
	ctl tree "$1 .sf-input" | jq -r '.nodes[0] as $n |
		if ($n.class | test("\\bempty\\b")) then "" else $n.text end' |
		sed -E 's/^[^=>#]*(= |>|#)//'
}
caret_x() {
	ctl tree "$1 .sf-caret" | jq -r '.nodes[0].rect[0] // empty'
}
field_y() {
	ctl tree "$1 .sf-input" | jq -r '.nodes[0].rect | .[1] + .[3] / 2'
}
# click_at SURFACE N: click between character N and N+1 of a field whose
# caret sits at offset END (x END_X) and offset 0 (x START_X).
click_at() {
	x=$(awk -v s="$START_X" -v e="$END_X" -v n="$END" -v i="$2" 'BEGIN { printf "%.1f", s + (e - s) / n * i }')
	ctl click "$x" "$(field_y "$1")" >/dev/null
	sleep 0.4
}
# measure SURFACE: START_X/END_X/END for a field whose caret is at its end.
measure() {
	END_X=$(caret_x "$1")
	END=$(field "$1" | awk '{ print length($0) }')
	xkey home
	START_X=$(caret_x "$1")
	xkey end
}
paste() {
	printf '%s' "$1" | pbcopy
	xkey cmd+v
}
field_is() { [ "$(field "$1")" = "$2" ]; }

# --- Settings value field -----------------------------------------------------
ctl plugins run plugin.tern-kube.settings >/dev/null
E2E_WAIT=15 wait_for "the settings block" has "$ST" || return
xkey j e
E2E_WAIT=5 wait_for "the max_rows editor" has "$ST .sf-input.focused" || return
eq "the editor starts with the value" "$(field "$ST")" 20000
measure "$ST"
xkey shift+left shift+left
ctl type 9 >/dev/null
sleep 0.3
eq "typing replaces a shift-arrow selection" "$(field "$ST")" 2009
xkey cmd+z
eq "cmd+z undoes the replacement" "$(field "$ST")" 20000
click_at "$ST" 1
ctl type 7 >/dev/null
sleep 0.3
eq "a click places the caret" "$(field "$ST")" 270000
xkey cmd+a
paste 4242
eq "paste replaces the selection" "$(field "$ST")" 4242
xkey cmd+z
eq "cmd+z undoes the paste" "$(field "$ST")" 270000
xkey end
paste 1
eq "paste inserts at the caret" "$(field "$ST")" 2700001
xkey cmd+a
paste 777
xkey enter
E2E_WAIT=10 wait_for "the edited value saved" sh -c "jq -e '.general.max_rows == 777' '$CFG'"
lacks "$ST .sf-input.focused" || fail "the field keeps the focus after enter"
xkey escape
E2E_WAIT=10 wait_for "the settings block to close" lacks "$ST"

# --- Approve: replicas prompt -------------------------------------------------
e2e_objects
lens "kubectl --context kind-tern-kube-dev get deploy tk-e2e-web -n $MNS"
native
click_text tk-e2e-web '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/tk-e2e-web'
xkey shift+s
approve_open || return
a_input || return
ctl type 123 >/dev/null
sleep 0.3
measure "$AP"
xkey shift+left
ctl type 9 >/dev/null
sleep 0.3
eq "replicas: selection replaced" "$(field "$AP")" 129
xkey cmd+z
eq "replicas: undo" "$(field "$AP")" 123
click_at "$AP" 1
ctl type 5 >/dev/null
sleep 0.3
eq "replicas: click places the caret" "$(field "$AP")" 1523
xkey cmd+a
paste 2
eq "replicas: paste replaces the selection" "$(field "$AP")" 2
xkey enter
a_ready || return
contains "the edited count is previewed" "$(atext)" "replicas 1 → 2"
xkey escape
approve_closed || return
eq "the cancelled scale changed nothing" "$(jp $MNS deploy/tk-e2e-web '{.spec.replicas}')" 1

# --- Approve: typed delete confirmation ----------------------------------------
# In the 1280x800 test window the field sits below the block's fold, where a
# click lands outside the window, so the caret moves with Home (a native edit).
xkey ctrl+d
approve_open || return
a_ready || return
ctl type tk-e2e-web >/dev/null
sleep 0.3
xkey shift+left shift+left shift+left
ctl type WEB >/dev/null
sleep 0.3
eq "typed: selection replaced" "$(field "$AP")" tk-e2e-WEB
xkey enter
sleep 1
eq "Enter with an edited token never deletes" "$(jp $MNS deploy/tk-e2e-web '{.metadata.name}')" tk-e2e-web
xkey cmd+z cmd+z
eq "typed: undo restores the token" "$(field "$AP")" tk-e2e-web
xkey home
ctl type x >/dev/null
sleep 0.3
eq "typed: home moves the caret" "$(field "$AP")" xtk-e2e-web
xkey enter
sleep 1
eq "Enter with a prefixed token never deletes" "$(jp $MNS deploy/tk-e2e-web '{.metadata.name}')" tk-e2e-web
xkey cmd+a
paste 'tk-e2e-web '
xkey enter
sleep 1
eq "Enter with a pasted trailing space never deletes" "$(jp $MNS deploy/tk-e2e-web '{.metadata.name}')" tk-e2e-web
xkey backspace
eq "typed: the exact token" "$(field "$AP")" tk-e2e-web
xkey enter
a_done || return
E2E_WAIT=20 wait_for "tk-e2e-web to be gone" absent $MNS deploy/tk-e2e-web
xkey escape
approve_closed || return
explore_close

# --- Approve: apply path prompt -------------------------------------------------
work=$E2E_SB/edit
mkdir -p "$work/manifests"
sh_line "cd '$work' && clear"
ctl plugins run plugin.tern-kube.apply >/dev/null
approve_open || return
a_input || return
ctl type manifests/xx >/dev/null
sleep 0.3
xkey shift+left shift+left
ctl type a.yaml >/dev/null
sleep 0.3
eq "path: selection replaced" "$(field "$AP")" manifests/a.yaml
xkey cmd+a
paste manifests/b.yam
measure "$AP"
click_at "$AP" 9
ctl type Z >/dev/null
sleep 0.3
eq "path: click places the caret" "$(field "$AP")" manifestsZ/b.yam
xkey cmd+z
eq "path: undo" "$(field "$AP")" manifests/b.yam
xkey end
ctl type l >/dev/null
sleep 0.3
eq "path: end, then typing appends" "$(field "$AP")" manifests/b.yaml
xkey escape
approve_closed
sh_line "cd '$E2E_REPO' && clear"
rm -rf "$work"
