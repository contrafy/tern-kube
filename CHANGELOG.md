# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0: minor
versions may break).

## [Unreleased]

## [0.5.0] - 2026-11-02

### Added

- Remote hosts (`tern remote setup`): lenses, Explore, approvals, Settings and the shell guard work in panes on the remote host, against its `kubectl`, kubeconfig and config file; quick actions from a remote pane open their split on that host with a bare `kubectl` and the remote `quick_actions.placement` and `logs_tail`; port-forward prints the ssh tunnel to run locally. Verified on Debian 13 with fish, bash and zsh login shells. See [docs/remote-hosts.md](docs/remote-hosts.md).
- fish as login shell, locally and on remote hosts: `PATH` probe through `fish -l -c`, quick-action lines quoted so fish parses them (contexts and kubeconfig paths with quotes included).
- The shell guard and `tern-kube-aliases` find Tern through `TERN_EXE` (set by Tern in every pane) when `TERN_BIN` is unset and `tern` is not on `PATH`; `tern-kube-guard status` names the source.
- `make test-shell-login`: login-shell suite for sh, dash, bash, zsh and fish; CI job `linux-shells` runs the shell suites in a Debian 13 container as a fish login user.
- `scripts/remote-host.sh` (disposable Debian 13 remote host) and `scripts/e2e.sh --remote` with end-to-end scenarios 60-69; `scripts/dev-tern.sh start --shell zsh|fish|bash`.

### Changed

- Quick-action confirmation grants are minted by the window half (random token from `/dev/urandom`, passed to the approve block, valid 600 s, single use) so approvals work when the approve block runs on another host. The approve block refuses a quick action opened without a token: install the same tern-kube version on the window machine and every remote host.
- Explore `e` (edit) splits on a remote host run that host's guard core, named by `TKUBE_GUARD_CORE` in its panes.

### Known limitations

- Quick actions from remote panes use the remote login shell's `KUBECONFIG`: there is no per-pane record on remote panes.
- The Linux desktop window is the same window half but was not verified locally.

## [0.4.0] - 2026-11-02

### Added

- Explore Helm views: `H` (or the kinds picker row `helm releases`, or **Tern Kube: Helm releases** in the palette) lists releases in the Explore namespace scope with status badges (failed, pending, stuck), chart, version and app version; on a Helm-managed object `H` opens its release. A release shows its header, a values summary (overridden, same as default, unknown keys), notes and hooks; `h` history (latest and running revision marked), `v` values in five modes (changed, user-supplied, computed, chart defaults, defaults → computed), `M` manifest, `N` notes, `K` hooks with their last run, `R` resources with live presence. Every helm call pins the context and `HELM_DRIVER`.
- Revision diffs: `=` diffs a revision against the latest (or one marked with `space`): chart and app version change, user values that changed, hooks added or removed, and per-object diffs.
- Helm rollback through the approve block (`ctrl+r` on a release or a history row): the recorded change between the two revisions, the live `kubectl diff` against the target manifest, a dry run, options (wait, cleanup on fail, force), and the typed release name. Pending releases, forced rollbacks and deletions carry their reason; the rollback is refused when the release moved since the preview. Audit records carry the release and both revisions.
- Secret masking for Helm values, notes, manifests, hooks and diffs: key names, value shapes (PEM, JWT, bearer tokens, URL passwords) and echoes of masked values in other text; `security.show_secret_values` turns it off.
- Chart auto-detect for drift: a chart directory in the repository whose name and version match a deployed release becomes a drift source, rendered with the release's deployed values (written 0600, removed after the render) or a values file next to the chart. **Copy as gitops.helm entry** copies the config for it.
- Objects managed by Helm name their release (revision, status, chart) in Explore detail and relations, with a chip to the release; the lens shows a **Helm release ns/X** chip on `describe`, `get -o yaml`, `get -o json` and tables with `--show-labels`.
- Settings section `helm`: program, storage driver, list and history limits, auto-detect, chart sources, rollback defaults.

### Changed

- End-to-end scenarios 50-55 cover the Helm views, revision diffs, rollback, relations and chart auto-detect against kind; `tests/integration/helm/template-compat.sh` (run in CI) checks the release extras template against the pinned helm, and the mutation integration suite gains Helm rollback scenarios.
- The test sandbox points `HELM_CONFIG_HOME`, `HELM_CACHE_HOME` and `HELM_DATA_HOME` at the sandbox.

### Fixed

- Drift of a Helm source diffs the render in the release namespace: objects without `metadata.namespace` were compared in kubectl's default namespace and reported missing.
- Drift of a Helm source ignores objects of other Helm releases and Helm hook objects in the same namespace instead of listing them as unmanaged.
- **Apply source** (`A`) and **Apply** (`a`) on a Helm drift source apply the render with `-n <release namespace>`: objects without `metadata.namespace` would have been applied to kubectl's default namespace. Documents of different releases, or renders mixed with plain manifests, are refused.

## [0.3.0] - 2026-11-02

### Added

- Native `kubectl logs` lens (also `kubecolor`, after global flags): records with level, source, time and message, parsed from JSON, klog, logfmt and plain lines, with `--prefix` and `--timestamps` honoured and stack traces folded into one record. Level and source chips with counts, **First error** with a small context view and Prev/Next error, Wrap, By time (merges per-pod blocks when `--timestamps` was given), a row inspector with Copy line, Copy message and Copy JSON, and pages with the newest first. `Found N pods` and `Defaulted container` lines are notices, not rows.
- Logs lens actions: **Follow in split** (raw, live), **Open in Explore**, **Search…**, and **Run in split** variants (other container, `--previous`, `--all-containers --prefix`, `--timestamps --prefix`) typed into a new interactive split so the lens renders them there. A variant whose values would need shell quoting is copied instead, with a toast. The typed line lands in that shell's history.
- `kubectl events` and `kubectl get events` render as native tables: each row stands for its involved object (inspector chips, Explore live, **Events for**), LAST SEEN sorts by age and shows `×N over D`, TYPE and REASON are facets, Warning rows are marked.
- Explore events timeline: `v` opens the namespace's events, `V` the focused object's (workloads include the objects they own), grouped by recency with toned reasons; `x` Warnings only, `]` `[` next/previous Warning, `/` filter, `enter` opens the object. Palette command **Tern Kube: Events**.
- Settings `general.streaming_view` (`raw` or `native`: what `logs -f` and event watches show while they run) and `explore.logs_tail`.

### Changed

- Explore `L` shows parsed records (level badges, sources, inspector) with `]` `[` errors, `x` level floor, `a` container, `o` previous instance, `w` wrap and `/` search; the tail is `explore.logs_tail` (default 500) instead of a fixed 500.
- Follow in split works from a label selector (`logs -f -l ... --prefix`).
- `kubectl logs -f`, `get events -w` and `kubectl events -w` show raw while they run and turn native after Ctrl-C or when they end.
- End-to-end scenarios 40-49 and integration checks `tests/integration/logs/check.sh` and `tests/integration/events/check.sh` (run in CI) cover logs and events against kind.

## [0.2.0] - 2026-11-02

### Added

- Guarded `rollout undo`, `rollout pause`, `rollout resume`, `patch`, `label`, `annotate`, `cordon`, `uncordon` and `drain`: Explore keys (`U` `p` `P` `X` `t` `T` `C` `u` `D`), lens inspector chips and the shell guard, each with a before/after object diff from a server dry run (or the target revision for `rollout undo`) and risk tiers.
- `drain` previews the pods it would evict, the DaemonSet, unmanaged and emptyDir pods, and pods a PodDisruptionBudget blocks right now.
- `kubectl edit` as preview then apply: after you save, the approve block shows the diff and a server dry run; deny restores the object and keeps your edit in a file. Explore `e` and the lens Edit chip open it in a split.
- Audit records list the previewed objects and the digests of input files.

### Changed

- The lens shows native results for `label`, `annotate`, `patch`, `cordon`, `uncordon` and `rollout undo|pause|resume`.
- End-to-end scenarios 24-29 cover the new verbs in a sandbox window against kind; the snapshot under test includes `shell/` (native edit runs `shell/tern-kube-guard`) and a scripted `KUBE_EDITOR`.

### Fixed

- A failed preview step shows kubectl's error, not a warning printed before it: kubectl 1.37 warns about `last-applied-configuration` before `rollout undo` errors such as "no rollout history", and the approve block and the shell refusal showed only the warning.
- The mutation integration suite installs the Widget CRD it patches, so it passes on a freshly created cluster.

## [0.1.3] - 2026-11-02

### Added

- Native text editing in block fields (Tern 0.9 `features = { "edit", "undo" }`): the Explore filter, the GitOps directory, branch and message fields, Settings values and the approve block's replicas, path and typed-confirmation fields take a click to place the caret, shift-arrow and drag selection, paste over a selection or at the caret, and cmd+Z/ctrl+Z undo. Focus returns to the list when editing ends. A typed delete still needs the exact token: Enter with any other text never confirms.

### Changed

- Tern 0.9 or later is required; tern-kube is tested on Tern 0.9.8. Nothing documents how older Tern treats the new `features` key, and 0.9.8 is the only version we can test.
- The plugin types are pinned to tern-sdk `78ba204` (the types Tern 0.9.8 ships); luau-lsp reads them without the earlier `userdata` patch.
- The test sandbox bounds every `tern ctl` call (`TK_CTL_TIMEOUT`, default 60 s), waits for the window and its daemon to exit on `stop` (TERM, then KILL), and starts with Tern's omp management off, so tests never download or link omp.

### Fixed

- Completed and Succeeded pods no longer show READY `0/1` in the warning tone; the cell is muted, matching the Problems filter.
- Explore sizes its list window to the rows that fit (the block chrome takes 24 lines on Tern 0.9.8, not 18), so `G` and `j` keep the selected row visible.
- The Dock/Finder `PATH` end-to-end check (scenario 31) passes on Tern 0.9, whose daemon outlives its window: a restart now waits for the old daemon to exit and requires a new one.

## [0.1.2] - 2026-10-09

### Fixed

- `kubectl`, `helm`, `gh` and kubectl's exec credential plugins are found when Tern is launched from the Dock or Finder (launchd's minimal `PATH`): tern-kube reads `PATH` and `KUBECONFIG` from your login shell once per daemon, then searches common install directories (Homebrew, Docker Desktop, Rancher Desktop, mise, asdf, Nix). `general.shell_env: false` skips the shell.
- Explore shows a missing `kubectl` once, as a card with Open Settings and Retry, instead of a Lua traceback.

### Added

- The first plugin load creates `~/.config/tern-kube/config.json` with only `$schema` and `schema_version` when it is missing; an existing file is never overwritten.
- JSON Schema of the config file (`schema/config.schema.json`), so editors complete and check every key with its description and default.

## [0.1.1] - 2026-10-09

### Fixed

- Install from the repository root: `tern plugin install github.com/contrafy/tern-kube`.

### Changed

- Screenshots are optimized PNGs, so an install copies about 6 MB instead of 13 MB.

## [0.1.0] - 2026-10-08

First public beta.

### Added

- GitOps in Explore: manifest index for YAML, Kustomize and Helm sources;
  open a resource's manifest at its line; diff vs manifest; drift reports
  (changed, missing, unmanaged) per directory, Kustomization, Helm release
  or locally checked out Argo CD / Flux app; export of live objects as
  clean manifests following the target layout, with an optional branch
  and commit (push and pull request opt-in, never forced).
- Argo CD and Flux awareness: owning application, sync and health status.
- `bin/tern-kube-drift`: Tern-free drift report (text, Markdown, JSON) and
  an example GitHub Actions workflow with dry-run-only RBAC.
- Settings block (**Tern Kube: Settings**): every config key with
  validation, reset to default and status of config, kubectl, alias
  claims and the shell guard.
- Lens for `kubectl` and `kubecolor` `get`, `describe`, `top`, `apply`,
  `delete`, `rollout restart` and `scale`, also after global flags, taking
  over from Tern's built-in `kubectl get` lens. Pipelines and redirected
  output are never lensed.
- Native tables parsed by header spans, with typed sorting (ages,
  quantities, ratios, restarts), filter chips by status, namespace and
  kind, a Problems filter (completed pods excluded), an inline row
  inspector, Inspect view and copyable `describe`, `logs` and `get -o yaml`
  commands pinned to the snapshot's context and namespace.
- `describe` as cards with an events timeline, `-o yaml` as a document list,
  `-o json` as an object tree, mutation output as a result summary.
- View state carried in every action, so lenses keep sort, filters and the
  open inspector after a plugin reload.
- Raw fallback for output the lens cannot render faithfully: watches,
  `-o jsonpath`, empty output, captures over 20000 lines or 16 MiB.
- Narrow-window layout: low-priority columns hide by window width.
- Opt-in alias claims for bash and fish (`scripts/tern-kube-aliases`).
- Versioned JSON config (`$XDG_CONFIG_HOME/tern-kube/config.json`) with
  validated defaults and diagnostics.
- Secret values masked in native views by default
  (`security.show_secret_values`), optional strict masking of
  sensitive-looking values (`security.sensitive_output_strict_mode`).
- Explore block: live view with a pinned target, relations, k9s-style keys
  and a viewport for large lists; opened from the lens or the palette.
- Quick actions in a new split or tab: pod shell, follow logs,
  port-forward; debug containers and CronJob run-now behind confirmation.
- Mutation engine: plan from argv (fails closed on stdin, unknown flags,
  `--raw`, interactive prompts), server dry run and `kubectl diff` previews
  split per resource, advisory risk tiers (simple, typed, blocked),
  fingerprint of argv, target and input files, and a JSON-lines audit log.
- Approve block for mutations from Explore, the lens and the shell guard,
  with per-resource diffs, typed confirmation for risky operations and
  re-verification of target and inputs before execution.
- Opt-in shell guard for zsh, bash and fish: `apply`, `delete`, `scale` and
  `rollout restart` typed in a Tern pane wait for approval in Tern and run
  only on a matching approval; fails closed outside Tern or on timeout.
- Repo-local pinned dev tools, standalone Luau test runner, kind cluster
  script, real kubectl fixtures, Tern sandbox script and e2e suite.
- CI on macOS arm64 and Linux x86_64 with kind integration tests on Linux.
- Docs: SDK capability matrix, configuration, performance, architecture,
  security model, testing, releasing.

[Unreleased]: https://github.com/contrafy/tern-kube/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/contrafy/tern-kube/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/contrafy/tern-kube/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/contrafy/tern-kube/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/contrafy/tern-kube/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/contrafy/tern-kube/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/contrafy/tern-kube/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/contrafy/tern-kube/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/contrafy/tern-kube/releases/tag/v0.1.0
