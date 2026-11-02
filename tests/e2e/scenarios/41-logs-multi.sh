# Live: logs of every tk-logmix pod and container at once (`-l --all-containers
# --prefix --timestamps`): source chips with counts, the time and source
# columns, By time merging the per-pod blocks kubectl prints into time order;
# then `logs deploy/tk-logmix`, whose Found/Defaulted lines are notices, not
# rows.
lens "kubectl logs -n $LNS -l app=tk-logmix --all-containers --prefix --timestamps --tail=15"
logs_native || return
eq "time and source columns" "$(texts '.tk-grid .tk-h')" '["TIME","SOURCE","LEVEL","MESSAGE"]'
chips=$(ltext '[data-role="tern-kube.chips"] *')
contains "source chips" "$chips" "SOURCE"
contains "a pod·container chip with its count" "$chips" "·app "
contains "a crashy source" "$chips" "·crashy "
contains "counts pods and containers" "$(ltext '[data-role="tern-kube.header"] *')" "2 pods · 3 containers"

sorted() { [ "$(column_texts 1 4 | jq -c '. == sort')" = true ]; }
before=$(column_texts 1 4)
click_text 'By time' '[data-role="tern-kube.chips"] .sf-act' || return
sorted || fail "By time: TIME column not in time order: $(column_texts 1 4)"
[ "$before" != "$(column_texts 1 4)" ] || note "kubectl already printed these lines in time order"

lens "kubectl logs -n $LNS deploy/tk-logmix --tail=5"
logs_native || return
notices=$(ltext '[data-role="tern-kube.notices"] *')
contains "Found notice" "$notices" "Found 2 pods, using pod/tk-logmix-"
contains "Defaulted notice" "$notices" 'Defaulted container "app" out of: app, side, crashy'
grid=$(ltext '.tk-grid *')
excludes "no Found row" "$grid" "Found 2 pods"
excludes "no Defaulted row" "$grid" "Defaulted container"
# The Defaulted line names the other containers: one Run-in-split chip each.
actions=$(ltext '[data-role="tern-kube.logs-actions"] *')
contains "side variant" "$actions" "▸ side"
contains "crashy variant" "$actions" "▸ crashy"
