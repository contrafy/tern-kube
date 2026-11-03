# Helpers for the multi-cluster compare scenarios 70-79 (sourced by them
# after tests/e2e/lib.sh; scripts/e2e.sh runs them only with E2E_MC=1, after
# applying tests/integration/manifests/compare to both clusters). Read-only
# except where a scenario says otherwise.

# shellcheck disable=SC2034 # used by the scenarios that source this file
MCA=kind-tern-kube-dev
MCB=kind-tern-kube-dev2
MCDOWN=kind-tern-kube-down
MCNS=tern-test-mc

# mc_lens CONTEXT RESOURCE [KUBECONFIG]: a lens over the merged kubeconfig.
mc_lens() {
	lens "kubectl --kubeconfig '${3:-$MC_KUBECONFIG}' --context $1 -n $MCNS get $2"
	native
}

# mc_object CONTEXT RESOURCE NAME KIND [KUBECONFIG]: Explore on one object
# of the lens (detail route).
mc_object() {
	mc_lens "$1" "$2" "${5:-}"
	click_text "$3" '.tk-grid .tk-c' || return 1
	click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act' || return 1
	explore_open || return 1
	xwait "Object $4/$3"
}

# mc_pick_first: x, then the first picker row (the other context of the
# two-context kubeconfig); the caller waits for what it expects.
mc_pick_first() {
	xkey x
	E2E_WAIT=15 xwait "$MCB" || return 1
	xkey enter
}

# mc_status: the pairwise status line.
mc_status() {
	xtext '[data-role="tern-kube.compare-status"] *'
}

# mc_sides: the two provenance lines.
mc_sides() {
	xtext '[data-role="tern-kube.compare-side"] *'
}

# mc_kubeconfig3: a private copy of the merged kubeconfig plus context
# kind-tern-kube-down, whose API server (127.0.0.1:1) refuses connections.
mc_kubeconfig3() {
	k3_=$E2E_SB/kubeconfig-3
	(umask 077 && cp "$MC_KUBECONFIG" "$k3_")
	"${E2E_REAL_KUBECTL:-kubectl}" --kubeconfig "$k3_" config set-cluster "$MCDOWN" --server=https://127.0.0.1:1 >/dev/null &&
		"${E2E_REAL_KUBECTL:-kubectl}" --kubeconfig "$k3_" config set-credentials "$MCDOWN" --token=unused >/dev/null &&
		"${E2E_REAL_KUBECTL:-kubectl}" --kubeconfig "$k3_" config set-context "$MCDOWN" --cluster="$MCDOWN" --user="$MCDOWN" >/dev/null &&
		printf '%s' "$k3_"
}

# explore_runs: kubectl runs Explore has logged so far. The daemon logs a
# run when its result arrives, a moment after the view shows it.
explore_runs() {
	sleep 1
	grep -c 'tern-kube explore.run' "$(daemon_log)"
}

# mc_cells ROLE: the cell texts of a compare grid (JSON array), e.g.
# mc_cells compare-matrix.
mc_cells() {
	texts "$EX [data-role='tern-kube.$1'] .tk-c"
}

# toast_text: the visible toasts.
toast_text() {
	alltext '.toast span' | tr '\n' ' '
}
