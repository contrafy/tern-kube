# Live: top nodes (metrics-server).
lens 'kubectl top nodes'
native
eq "headers" "$(texts '.kl-grid .kl-h')" '["NAME","CPU(cores)","CPU(%)","MEMORY(bytes)","MEMORY(%)"]'
eq "node" "$(texts '.kl-grid .kl-c' | jq -r '.[0]')" kube-lens-dev-control-plane
