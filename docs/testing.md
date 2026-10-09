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
  named `tern-test-*` where a test needs them). Never a real cluster.
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

In CI each script runs only when it exists on the branch; on failure the
evidence (without kubeconfigs) and `kind export logs` are uploaded.

## End to end (local only)

`make e2e` (`scripts/e2e.sh [--only GLOB] [--shots] [--perf] [--keep]`)
starts an isolated Tern window (sandbox `TK_E2E_SANDBOX`, default
`/tmp/tk-tern-e2e`) with a snapshot copy of `plugin/`, then runs
`tests/e2e/scenarios/*.sh` against the kind cluster, asserting with
`tern ctl` (`plugins expect`, `click`, `key`, `tree`). Scenarios 01-17 are
read-only; 18-22 mutate only `tk-e2e-*` objects in `tern-test-mutate` (and
Jobs they create in `tern-test-batch`), 23 works in its own
`tern-test-gitops-ui` namespace and a throwaway git repository, and 30 edits
only the sandbox's config file; all clean up on exit. Scenarios that need
output a read-only cluster cannot produce switch the pane to the fake
`tests/bin/kubectl`. `--shots` regenerates `docs/screenshots/`
(`E2E_SHOTS="m3b m4"` limits it to some groups) and then runs
`make shots-optimize` (pngquant quality floor 95, then lossless oxipng;
idempotent, only `docs/screenshots/*.png`), `--perf`
prints timings for [performance.md](performance.md). It exits 0 with
"SKIPPED" when `tern` is not installed.

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
| `tests/fixtures/drift/` | `scripts/fixtures/capture-drift.sh` | recreates `tern-test-drift`, `tern-test-gitops` |
| `tests/fixtures/gitops/captured/` | `scripts/fixtures/capture-gitops.sh` | none (kustomize/helm render) |
| `tests/fixtures/synthetic/` | `scripts/fixtures/synth.sh` | none (deterministic seed) |
| `plugin/lib/kubectl/{flags,kinds_data}.luau` | `KUBECONFIG=.sandbox/kubeconfig python3 scripts/kubectl/gen_tables.py`, then StyLua | none |

`scripts/fixtures/capture.sh --world-only` builds the same world (plus
metrics-server and the quick-action toolbox) on a fresh cluster for the e2e
and integration suites without touching any fixture.

Details: `tests/fixtures/real/README.md`. `capture.sh` fails if kubeconfig
certificate, key or token material appears in a fixture; `capture-json.sh`
lists Secrets by name only.
