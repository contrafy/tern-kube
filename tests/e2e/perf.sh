# In-window timings for docs/performance.md (sourced by scripts/e2e.sh
# --perf). The lens logs `view_ms` (capture build + render, or render alone
# once the capture is cached) and `lua_kb` (Lua heap) for every view.

PERF_RUNS=${PERF_RUNS:-20}

now_ms() {
	perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
}

# p50/p95/max (nearest rank) of numbers on stdin.
stats() {
	sort -n | awk '{ v[NR] = $1 } END {
		if (NR == 0) { print "no samples"; exit }
		p50 = v[int((NR * 50 + 99) / 100)]; p95 = v[int((NR * 95 + 99) / 100)]
		printf "n=%d p50=%.2f p95=%.2f max=%.2f\n", NR, p50, p95, v[NR]
	}'
}

# First finished view after each run of LINE: the initial native render.
initial_views() { # initial_views LINE
	for _ in $(seq "$PERF_RUNS"); do
		mark=$(log_lines)
		lens "$1"
		view_ms_since "$mark" | head -1
	done
}

# Views triggered by clicks: capture cached, query + render only.
click_views() { # click_views TEXT SEL
	mark=$(log_lines)
	for _ in $(seq "$PERF_RUNS"); do
		click_text "$1" "$2" >/dev/null
	done
	view_ms_since "$mark"
}

echo "PERF ($PERF_RUNS runs each; view_ms from the plugin log)"
# FAKE: deterministic synthetic tables (a read-only cluster has no 1000 pods).
fake synthetic/rows-100
echo "  100 rows initial render (build + render): $(initial_views 'kubectl get pods -A -o wide' | stats)"
echo "  100 rows sort click: $(click_views 'AGE*' '.tk-grid .tk-h' | stats)"
fake synthetic/rows-1000
echo "  1000 rows initial render (build + render): $(initial_views 'kubectl get pods -A -o wide' | stats)"
echo "  1000 rows sort click (query + render 500): $(click_views 'AGE*' '.tk-grid .tk-h' | stats)"
echo "  1000 rows filter chip toggle: $(click_views 'Problems*' '[data-role="tern-kube.chips"] .sf-act' | stats)"
echo "  Lua heap during the run: max $(tail -n +"$((log_start + 1))" "$(daemon_log)" | sed -n 's/.*lua_kb=\([0-9]*\).*/\1/p' | sort -n | tail -1) KB"

# Wall time of one whole command in the window, lens included.
fake synthetic/rows-1000
t0=$(now_ms)
lens 'kubectl get pods -A -o wide'
echo "  1000 rows end-to-end in the window (type, run, finish, render, settle; includes 0.6 s fixed waits): $(($(now_ms) - t0)) ms"

# Live cluster: the lens' share next to kubectl's own runtime.
real
echo "  live kubectl get pods -A, initial render: $(initial_views 'kubectl get pods -A' | stats)"
samples=""
for _ in $(seq "$PERF_RUNS"); do
	t0=$(now_ms)
	KUBECONFIG="$E2E_KUBECONFIG" "$E2E_REAL_KUBECTL" get pods -A >/dev/null 2>&1
	samples="$samples $(($(now_ms) - t0))"
done
# shellcheck disable=SC2086
echo "  real kubectl get pods -A on kind, outside Tern (ms): $(printf '%s\n' $samples | stats)"
