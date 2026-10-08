# Performance (M1)

Measured 2026-10-08 on an Apple M5 (24 GB RAM), macOS 27.0.1, Tern 0.6.2
(4b3ed42), kubectl v1.34.1 client, kind cluster `kube-lens-dev` (node
v1.37.0) on Docker Desktop.

## PRD targets

| Target (PRD section 7) | Measured | Status |
| --- | --- | --- |
| Initial native render, 100 rows: p50 <= 50 ms, p95 <= 150 ms | in window p50 6.1 ms, p95 6.9 ms | met |
| 1000 rows, filter/sort p95 <= 100 ms | in window sort p95 11.2 ms, filter p95 11.8 ms | met |
| Rendered rows capped (suggested 500), overflow shown | 500 rows per page, page chips | met |
| No I/O in open/line/finish/view | lens only records lines; no process, file or network calls | met |
| Bounded parsing | native view up to 20000 lines / 16 MiB, raw beyond (see below) | met |

## In-window measurements (live Tern)

`scripts/e2e.sh --perf` drives the isolated sandbox window. The lens logs, for
every `view` call, `view_ms` (capture build + render, measured with
`os.clock` inside the plugin) and `lua_kb` (Lua heap, `gcinfo()`). 20 runs
per row:

| Case | Data | p50 ms | p95 ms | max ms |
| --- | --- | --- | --- | --- |
| Initial render, 100 rows (build + render) | synthetic `get pods -A -o wide` | 6.09 | 6.88 | 6.88 |
| Sort click, 100 rows (query + render) | same | 1.26 | 2.01 | 2.66 |
| Initial render, 1000 rows (build + render page 1) | synthetic, 1000 rows | 51.00 | 57.03 | 60.53 |
| Sort click, 1000 rows (query + render 500) | same | 7.96 | 11.21 | 12.48 |
| Filter chip (Problems) toggle, 1000 rows | same | 7.43 | 11.75 | 13.57 |
| Initial render, live `kubectl get pods -A` (21 pods) | kind cluster | 1.48 | 1.66 | 1.87 |

The 100/1000-row cases use the fake kubectl serving
`tests/fixtures/synthetic/rows-{100,1000}` (a read-only kind cluster has no
1000 pods); the last row is the real kubectl against kind.

Peak Lua heap of the plugin VM over the whole perf run (dozens of 1000-row
blocks alive in the pane): 63.7 MB (`lua_kb` max). One 1000-row capture plus
its rendered page holds about 5 MB (standalone bench below).

## Overhead versus plain kubectl

The lens adds no work while kubectl runs except appending lines (`line`
callbacks: 0.08 ms per 1000 lines, M0 matrix). After kubectl exits, one
`view` call builds the capture and renders it. Next to kubectl's own runtime:

| Command | kubectl alone (outside Tern, 20 runs) | Lens time added (p50 / p95) |
| --- | --- | --- |
| `kubectl get pods -A` on kind (21 pods) | p50 42 ms, p95 46 ms | 1.5 / 1.7 ms (about 4%) |
| 1000-row `get pods -A -o wide` | not measurable on kind (fixture) | 51 / 57 ms |

Clicks (sort, filter, page, inspector) reuse the cached capture and cost only
query + render (p95 about 11 ms at 1000 rows). Tern's own layout and paint of
the view are not included; `tern ctl perf` was not used for this report.

## Large output

Parsing is linear in lines (about 15 us per line in the plugin VM, 5 us in
standalone luau), and Tern does not feed more output until `view` returns.
Before M1 hardening, 200000 generated rows (16.4 MB) made every streaming
`view` rebuild the capture (about 1 s each at 65000 lines), stalling the pane.
Now (`plugin/host.luau`):

- above 20000 lines or 16 MiB the lens stops recording, frees the lines and
  shows raw (`overflow=true` in the log); the 200000-row command finishes in
  about 1 s with the lens attached (e2e scenario `12-large-output`);
- while a command still runs, the view is rebuilt only up to 2000 lines, then
  stays raw until the command finishes;
- 15000 rows (under the limit) render natively in one 227 ms `view` at finish.

## Standalone benchmark (`make bench`, part of `make check`)

`scripts/bench.luau` runs in standalone luau over the embedded fixtures, 30
samples after 3 warm-ups, and fails only when a p95 exceeds a generous limit
(several times the budgets) so CI catches gross regressions, not noise:

| Case | p50 ms | p95 ms | Limit (p95) |
| --- | --- | --- | --- |
| 100 rows: build + render | 1.89 | 2.40 | 50 |
| 100 rows: build + render, row open | 1.83 | 2.42 | 50 |
| 1000 rows: build | 14.46 | 15.79 | 200 |
| 1000 rows: sort + filter + problems | 1.30 | 1.42 | 100 |
| 1000 rows: render sorted (500 cap) | 4.22 | 4.82 | 200 |
| 1000 rows: render Inspect | 0.02 | 0.03 | 100 |
| `-o json` (7 pods): build + render | 0.91 | 1.49 | 100 |
| `-o yaml` (7 pods): build + render | 0.55 | 0.63 | 100 |
| `describe pods`: build + render | 0.74 | 1.15 | 100 |

Memory: at most 5.0 MB per 1000-row capture plus rendered view (heap growth
while holding 10 of them, divided by 10; includes uncollected garbage, so an
upper bound), limit 64 MB.

## Methodology and reproduction

```sh
make bench                         # standalone, deterministic inputs
sh scripts/e2e.sh --only none --perf   # in-window numbers (needs Tern + kind)
```

- In-window numbers come from the plugin's own `os.clock` around `view`, read
  from the sandbox daemon log; they exclude Tern's IPC, layout and paint.
- Each initial-render sample is the first finished `view` after a fresh run
  of the command; click samples are every `view` after a click.
- p50/p95 are nearest-rank over the samples.
- The kubectl baseline runs the same real kubectl binary with the sandbox
  kubeconfig outside Tern, timed with `Time::HiRes`.
