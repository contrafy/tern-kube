# Live: Explore opened from a lens row of a command pinned with --context
# (provenance "command flag"), then every list key against the real cluster.
lens 'kubectl --context kind-tern-kube-dev get pods -n tern-test-apps'
native
click_text db-0 '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
hdr=$(xtext '[data-role="tern-kube.explore-header"] *')
contains "live badge" "$hdr" "Live"
contains "pinned context" "$hdr" "context kind-tern-kube-dev"
contains "provenance" "$hdr" "(command flag)"
contains "pinned target is confirmed" "$hdr" "confirmed"
excludes "no inferred warning" "$hdr" "inferred"

# esc walks back to the list, keeping the row the lens opened.
xkey escape
xwait 'crashloop' '.tk-grid *'
eq "esc keeps the row" "$(xsel)" db-0
cols=$(count "$EX .tk-grid .tk-h")
names=$(texts "$EX .tk-grid .tk-c" | jq -c --argjson n "$cols" '[to_entries[] | select(.key % $n == 0) | .value]')
xkey G
# The list may be windowed to the block height, so the last of all 7 pods is
# compared with the last name in the window after G.
last=$(texts "$EX .tk-grid .tk-c" | jq -r --argjson n "$cols" '[to_entries[] | select(.key % $n == 0) | .value] | .[-1]')
eq "G selects the last row" "$(xsel)" "$last"
xkey g g
eq "gg selects the first row" "$(xsel)" "$(printf '%s' "$names" | jq -r '.[0]')"
xkey j
eq "j moves down" "$(xsel)" "$(printf '%s' "$names" | jq -r '.[1]')"
xkey k
eq "k moves up" "$(xsel)" "$(printf '%s' "$names" | jq -r '.[0]')"
first=$(xsel)
xkey enter
xwait "Object pod/$first"
xkey escape
xwait "$first" '.tk-grid *'

# / filters as you type; enter keeps the filter, esc at the root clears it.
xkey /
ctl type crash >/dev/null
xkey enter
eq "filter keeps matches" "$(texts "$EX .tk-grid .tk-c" | jq -c --argjson n "$cols" '[to_entries[] | select(.key % $n == 0) | .value]')" '["crashloop"]'
eq "filter selects the match" "$(xsel)" crashloop
xkey escape
eq "esc clears the filter" "$(texts "$EX .tk-grid .tk-c" | jq -c --argjson n "$cols" '[to_entries[] | select(.key % $n == 0) | .value]')" "$names"

# r is the only way data is re-read.
runs=$(grep -c 'tern-kube explore.run' "$(daemon_log)")
xkey r
more_runs() { [ "$(grep -c 'tern-kube explore.run' "$(daemon_log)")" -gt "$runs" ]; }
E2E_WAIT=10 wait_for "r to re-run the query" more_runs
xwait 'fetched just now'

xkey c
xwait 'kind-tern-kube-dev' '[data-role="tern-kube.explore-contexts"] *'
xkey escape
xkey n
xwait 'all namespaces' '[data-role="tern-kube.explore-namespaces"] *'
xkey escape
xkey :
xwait 'below' '[data-role="tern-kube.explore-kinds"] *'
xkey /
ctl type deploy >/dev/null
xkey enter
xwait 'deployments' '[data-role="tern-kube.explore-kinds"] *'
xkey escape

xkey g g
xkey d
xwait "Describe pod/$first"
xkey escape
xkey y
xwait "Object pod/$first"
xkey escape
xkey L
xwait "Logs pod/$first"
xkey escape
xkey R
xwait "Relations pod/$first"
xkey escape

xkey Y
sleep 0.3
contains "Y copies the pinned view command" "$(clip)" "--context kind-tern-kube-dev"
contains "Y copies the list command" "$(clip)" "get pods"

xkey '?'
E2E_WAIT=5 wait_for "help layer" has "$EX [data-role='tern-kube.explore-help']"
contains "help lists shift+f" "$(xtext "[data-role='tern-kube.explore-help'] *")" "shift+f"
xkey escape
E2E_WAIT=5 wait_for "help to close" lacks "$EX [data-role='tern-kube.explore-help']"
explore_close
