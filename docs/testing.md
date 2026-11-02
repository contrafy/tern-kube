# Testing

Four layers, cheapest first. CI (`.github/workflows/ci.yml`) runs the first
three; e2e needs Tern, which is closed beta, and stays local.

| Layer | Command | Needs | CI |
| --- | --- | --- | --- |
| Unit, lint, types | `make check` | `make bootstrap` | macOS arm64, Linux x86_64 |
| Shell suites | `make test-shell-aliases test-shell-guard test-shell-drift` | zsh, bash, fish (dash optional) | macOS arm64, Linux x86_64 |
| Integration | `tests/integration/*/` scripts | Docker, kind cluster | Linux x86_64 |
| End to end | `make e2e` | Tern, jq, desktop session, kind cluster | no |

## Safety rules

- The real `kubectl` only ever runs with `KUBECONFIG=.sandbox/kubeconfig`,
  context `kind-tern-kube-dev`. `scripts/cluster.sh` refuses any other
  `KUBECONFIG` and verifies that the file holds exactly that context and
  that its API server is the local kind endpoint.
- Mutations only in `tern-test-*` namespaces (plus cluster-scoped objects
  named `tern-test-*` where a test needs them, and the kind node, which e2e
  scenarios 27 and 29 cordon and always uncordon on exit). Never a real
  cluster.
- Tern only in a sandbox under `/tmp` via `scripts/dev-tern.sh` (it refuses
  other paths): `TERN_CONFIG_DIR` and `TERN_DAEMON_SOCKET` always point into
  the sandbox; `tern ctl` always with `--control <sandbox>/ctl.sock`. Never
  the user's own Tern config, daemon, shell rc files or kube contexts.
- Shell suites put only fakes and the shells under test on `PATH`, with a
  temporary `HOME`; they never reach a real `tern` or `kubectl`.

## Unit tests

`make check` = `fmt-check` (StyLua), `lint` (selene), `typecheck` (luau-lsp
with the pinned `tern.d.luau`), `test-runner-selfcheck`, `test`, `bench`.

- Specs: `tests/unit/**/*.spec.luau`, run by `tests/run.luau` under the
  standalone `luau` (no filesystem: `make test` passes the spec list).
  `make test FILTER=<substring>` runs matching tests only.
- They cover `plugin/lib/**` only; that is why the library must not touch
  the `tern` global ([architecture.md](architecture.md)).
- `tests/selfcheck/check.sh` proves failing, crashing and unloadable specs
  turn the run red.
- `make bench` (`scripts/bench.luau`) fails only on gross regressions;
  numbers are in [performance.md](performance.md).

TDD: write the failing spec first; name tests after the reason, not the
mechanism.

## Shell suites

- `tests/shell/aliases/run.sh`: `scripts/tern-kube-aliases` in zsh, bash
  and fish (missing shells are skipped and counted).
- `tests/shell/guard/run.sh`: the guard core and activation files in zsh,
  bash, fish (core also under dash) with a fake `tern` playing the approve
  block and a fake `kubectl` recording argv. Also checks the embedded flag
  table matches `plugin/lib/kubectl/flags.luau` (`make guard-flags` to
  regenerate).
- `tests/shell/drift/run.sh`: `bin/tern-kube-drift` against golden
  `kubectl diff` output; `SHELLS="dash bash"` picks the shells.

## Integration (kind)

```sh
make bootstrap                      # includes kind and helm
sh scripts/cluster.sh create        # cluster tern-kube-dev, .sandbox/kubeconfig
sh tests/integration/mutate/rbac.sh create
sh tests/integration/mutate/run.sh [SCENARIO...]
sh tests/integration/drift-rbac/run.sh [--keep]
sh tests/integration/gitops/roundtrip.sh
sh tests/integration/logs/check.sh
sh tests/integration/events/check.sh
sh tests/integration/helm/template-compat.sh
sh scripts/cluster.sh delete
```

- `mutate/run.sh` drives the approve block's pure session through
  `harness.sh` with real kubectl results (apply, diff, scale, restart,
  typed delete, cancel, stale file, context/server drift, RBAC-denied dry
  run, timeout, CronJob quick grant, guard round trip with a fake `tern`,
  Secret redaction in a real apply diff, palette apply prompt, guard deny
  with `mutations.enabled=false`).
  Evidence per scenario: `.sandbox/mutate-it/<scenario>/`.
- `drift-rbac/run.sh` proves `examples/ci/rbac-drift-readonly.yaml` is
  sufficient and cannot mutate.
- `gitops/roundtrip.sh` emits every real JSON fixture as YAML and checks
  `kubectl create --dry-run=client` reads back the same object.
- `logs/check.sh` applies the `tk-logmix` Deployment (`tern-test-logs`, 2
  pods x `app`/`side`/`crashy`), runs the real `kubectl logs` forms (pod,
  `deploy/x`, `-l --prefix --timestamps`, `--all-containers`, `-p`, a bad
  `-c`) and feeds each output through the lens parser
  (`tests/integration/logs/check.luau`): no kubectl diagnostic becomes a
  record, sources are the expected pods and containers, JSON error lines are
  `error`, failed forms give notices only. It guards against kubectl format
  drift.
- `events/check.sh` applies the apps world, waits for events in
  `tern-test-apps`, and decodes the real `get events -o json` and
  `kubectl events -o json` with `lib/events/model`: every event names its
  involved object and has a parseable last-seen time.
- `helm/template-compat.sh` installs the Helm fixture releases with the
  pinned `.tools/bin/helm` in `tern-test-helm-compat`, runs the release
  extras template against every revision and decodes each output with the
  plugin parser (`tests/integration/helm/compat.luau`), so a helm bump that
  changes Go quoting, the release fields read, or what `--reuse-values`
  stores as chart defaults fails here. Evidence: `.sandbox/helm-compat/`;
  the namespace is deleted on exit unless `KEEP=1`.

In CI each script runs only when it exists on the branch; on failure the
evidence (without kubeconfigs) and `kind export logs` are uploaded.

## End to end (local only)

`make e2e` (`scripts/e2e.sh [--only GLOB] [--shots] [--perf] [--keep]`)
starts an isolated Tern window (sandbox `TK_E2E_SANDBOX`, default
`/tmp/tk-tern-e2e`) with a snapshot copy of `plugin/` and `shell/`, then runs
`tests/e2e/scenarios/*.sh` against the kind cluster, asserting with
`tern ctl` (`plugins expect`, `click`, `key`, `tree`). Scenarios 01-17 are
read-only; 18-22 mutate only `tk-e2e-*` objects in `tern-test-mutate` (and
Jobs they create in `tern-test-batch`), 23 works in its own
`tern-test-gitops-ui` namespace and a throwaway git repository. 24-29 cover
the guarded verbs of 0.2.0 on `tk-e2e-*` objects: label and annotate from
lens chips (24), patch (25) and rollout undo, pause and resume (26) from
Explore keys, cordon, uncordon and drain of the kind node (27; drain is
limited to `tk-e2e-web` with `--pod-selector`, and the node is uncordoned on
exit), Explore `e` edit approved and denied (28) and the shell guard on the
new verbs (29). Every pane and split runs `kubectl edit` with
`KUBE_EDITOR=<sandbox>/kube-editor` (via `TK_DEV_KUBE_EDITOR`), which runs
the `<sandbox>/edit-script` a scenario writes and fails without one. 30
edits only the sandbox's config file, 31 restarts the window and its daemon
with a Dock-like `PATH`, and 32 (native editing) edits the sandbox config
and deletes its own `tk-e2e-web`; all clean up on exit. 40-49 cover the
logs lens and events (0.3.0), read-only: the logs lens on `tk-logmix` (40),
multi-source `-l --prefix --timestamps` and `deploy/x` notices (41), `logs -f`
raw while running and native after Ctrl-C (42), Follow in split, Run in split
typed into an interactive split and the refusal of a kubeconfig path with a
quote (43), a 25 000-line fake log with the ring, pages and the First error
context view (44), kubectl errors staying raw (45), the Explore events
timeline `v`/`V` (46), `kubectl events`/`get events` tables (47), event
watches (48) and Explore logs `L` (49). 50-55 cover Helm (0.4.0) on a
shared world (`tests/e2e/helm.sh`: releases in `tern-test-helm-e2e` and
`tern-test-helm-e2e-b`, installed with the pinned helm and `HELM_*_HOME`
under the sandbox): the releases route with status badges and filters
(50), release detail, the five values modes, notes, hooks and manifest
with Secrets masked (51), history and revision diffs with masked value
changes (52), rollback through the approve block, the stale refusal and the
typed pending-release preview (53; shop-a is rebuilt on exit), object to
release relations and the lens Helm chip (54), and chart auto-detect drift
in a throwaway git repository (55). The runner deletes both namespaces
unless `--keep`. Scenarios that need
output a read-only cluster cannot produce switch the pane to the fake
`tests/bin/kubectl`. `--shots` regenerates `docs/screenshots/`
(`E2E_SHOTS="m3b m4"` limits it to some groups; `t1` is the 0.2.0 verbs and
`t2` the 0.3.0 logs and events views, `t3` the 0.4.0 Helm views, all dark
only) and then runs
`make shots-optimize` (pngquant quality floor 95, then lossless oxipng;
idempotent, only `docs/screenshots/*.png`), `--perf`
prints timings for [performance.md](performance.md). It exits 0 with
"SKIPPED" when `tern` is not installed.

Every `tern ctl` call through `scripts/dev-tern.sh ctl` is bounded: it is
terminated after `TK_CTL_TIMEOUT` seconds (default 60) and says so, because
a quitting window can accept a control connection and never answer.
`plugin reload`/`list` are bounded at 30 s. `stop` quits the window, waits
for it and for the sandbox daemon (which outlives its window on Tern 0.9),
then sends TERM and finally KILL to whatever is left, and exits non-zero if a
process survives. `start` writes `<sandbox>/cfg/omp/state.json` with Tern's
omp management off, so a fresh sandbox never downloads or links omp.

For manual work: `TK_TERN_SANDBOX=/tmp/tk-tern-<name> scripts/dev-tern.sh
start` (in a long-lived terminal), then `link`, `reload`, `ctl ...`, `stop`.
`start --fake` puts the fake kubectl first on `PATH`.

## Fixtures

Never hand-edit captured fixtures; change the inputs and re-run the script.
Then `make fixtures` (`scripts/fixtures/embed.sh`) re-embeds everything into
the gitignored `tests/fixtures/generated.luau` (standalone luau cannot read
files).

| Fixtures | Regenerate | Cluster writes |
| --- | --- | --- |
| `tests/fixtures/real/` | `scripts/fixtures/capture.sh [--reuse]` | rebuilds every `tern-test-*` namespace |
| `tests/fixtures/real/json-world/` | `scripts/fixtures/capture-json.sh` | none |
| `tests/fixtures/real/mutate-preview/` | `scripts/fixtures/capture-mutate-preview.sh` | none (diff, server dry run) |
| `tests/fixtures/kubectl/track1/` | `scripts/fixtures/capture-track1.sh` | creates and deletes `tern-test-t1` (second revisions via `set image`); everything captured is a read, a dry run or `patch --local` |
| `tests/fixtures/drift/` | `scripts/fixtures/capture-drift.sh` | recreates `tern-test-drift`, `tern-test-gitops` |
| `tests/fixtures/gitops/captured/` | `scripts/fixtures/capture-gitops.sh` | none (kustomize/helm render) |
| `tests/fixtures/synthetic/` | `scripts/fixtures/synth.sh` | none (deterministic seed) |
| `tests/fixtures/logs/` | `.tools/bin/luau scripts/fixtures/synth.luau -a logs 200 20261102 [prefix]` (see its header) | none (deterministic seed) |
| `plugin/lib/kubectl/{flags,kinds_data}.luau` | `KUBECONFIG=.sandbox/kubeconfig python3 scripts/kubectl/gen_tables.py`, then StyLua | none |

`scripts/fixtures/capture.sh --world-only` builds the same world (plus
metrics-server and the quick-action toolbox) on a fresh cluster for the e2e
and integration suites without touching any fixture.

Details: `tests/fixtures/real/README.md`. `capture.sh` fails if kubeconfig
certificate, key or token material appears in a fixture; `capture-json.sh`
lists Secrets by name only.
