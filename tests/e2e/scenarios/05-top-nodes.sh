# Live: top nodes (metrics-server).
lens 'kubectl top nodes'
native
eq "headers" "$(texts '.tk-grid .tk-h')" '["NAME","CPU(cores)","CPU(%)","MEMORY(bytes)","MEMORY(%)"]'
eq "node" "$(texts '.tk-grid .tk-c' | jq -r '.[0]')" tern-kube-dev-control-plane
