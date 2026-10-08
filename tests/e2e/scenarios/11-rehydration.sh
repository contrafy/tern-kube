# Live: after a plugin reload the old block rehydrates on the next click.
lens 'kubectl get pods -n tern-test-apps'
native
dev reload >/dev/null 2>&1
sleep 1
click_text NAME '.kl-grid .kl-h'
eq "sorted after reload" "$(texts '.kl-grid .kl-h' | jq -r '.[0]')" "NAME ▲"
contains "first row" "$(texts '.kl-grid .kl-c' | jq -r '.[0]')" "broken-image-"
