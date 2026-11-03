# Live, two clusters (E2E_MC=1): Explore tkm-web in kind-tern-kube-dev, x,
# pick kind-tern-kube-dev2: the differences (replicas, image, label tier),
# both provenance lines, and Y copies both pinned commands. Read-only.
. "$E2E_REPO/tests/e2e/compare.sh"

mc_object "$MCA" deploy tkm-web deployment || return
mc_pick_first || return
E2E_WAIT=20 xwait "differs" '[data-role="tern-kube.compare-status"] *' || return
contains "header names the object" "$(xtext)" "Comparing deployment/tkm-web in $MCNS"
t=$(xtext)
contains "replicas differ" "$t" "spec.replicas 2 -> 3"
contains "image differs" "$t" "nginx:1.27-alpine -> nginx:1.28-alpine"
contains "label tier only in the base" "$t" "metadata.labels.tier frontend"
sides=$(mc_sides)
contains "base provenance" "$sides" "base $MCA"
contains "other provenance" "$sides" "other $MCB"
contains "fetch time shown" "$sides" "fetched"

xkey Y
copied=$(clip)
eq "Y copies one command per side" "$(printf '%s\n' "$copied" | grep -c '^kubectl ')" 2
contains "base command pinned" "$copied" "--context $MCA -n $MCNS get deployments.v1.apps --field-selector metadata.name=tkm-web -o json"
contains "other command pinned" "$copied" "--context $MCB -n $MCNS get deployments.v1.apps --field-selector metadata.name=tkm-web -o json"
contains "commands carry the kubeconfig" "$copied" "--kubeconfig $MC_KUBECONFIG"
explore_close
