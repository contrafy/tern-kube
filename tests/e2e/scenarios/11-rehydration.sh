# Live: after a plugin reload the old block rehydrates on the next click.
lens 'kubectl get pods -n tern-test-apps'
native
dev reload >/dev/null 2>&1
sleep 1
click_text NAME '.tk-grid .tk-h'
eq "sorted after reload" "$(texts '.tk-grid .tk-h' | jq -r '.[0]')" "NAME ▲"
contains "first row" "$(texts '.tk-grid .tk-c' | jq -r '.[0]')" "broken-image-"
