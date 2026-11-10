# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): from 1.0.0, config
keys, link formats and the guard protocol change incompatibly only in a major
release (0.x minor versions could break them).

## [Unreleased]

## [1.1.0] - 2026-11-10

### Added

- Explore lists (resources, pickers, relations, Helm and GitOps lists) are Tern native tables: they fill the pane and scroll with a sticky header, sort by header click (counts descending first), keep the unique end of long names, show AGE, hide NAMESPACE for a single namespace, and carry ready / not ready / restart tiles. Logs, events and the compare matrix keep their own layout.
- Explore refreshes after a change it started (scale, pause, cordon, rollback, apply); approval results offer the next step (Uncordon, Resume, Follow logs).
- Lens: a **Filter in Explore** chip opens Explore on the same query with the filter focused, honouring `-l`; the `+N` facet overflow expands; output too large for the native view says why and shows the first lines.
- Risk: cordon or drain of the last schedulable node, drain with nowhere to reschedule and scale to 0 under a PodDisruptionBudget need the typed confirmation; run-now names the Job it creates.
- Quick-action splits echo the kubectl command and the context they pinned; the edit split shows its outcome and the path of a denied copy until Enter.

### Changed

- Approval blocks open over the pane that asked (it comes back when they close), one per pane; approve and Settings use Tern's sans font and native buttons.
- Lens: names and log sources are cut in the middle; facet chips wrap in narrow panes; opening a row no longer shifts the columns; the selected row stays readable in both themes; Problems counts only restarts in the last hour; `describe` shows the real container state (CrashLoopBackOff, Terminated with exit code); the header echoes `-l`, `-c` and `--previous`; cluster-scoped kinds show no namespace; a single object with `-o json`/`-o yaml` opens as a tree; events sort newest first; repeated klog errors fold into one; an unknown context gets an error card.
- Explore: times are local; help scrolls and lists the current view's keys first; hints follow the focused kind; relations nest pods under their ReplicaSet and show the Services that select them; a new block starts in the last scope used; palette commands reuse the open Explore; chips that can only refuse are hidden; `allow_live_queries: false` hides the live controls.
- GitOps and Helm: reports go stale after an apply or export and rerun on return, and `r` rescans changed manifests; `ctrl+g` on a release opens its own drift with deployed values; `=` on a Helm-managed object diffs against its chart; Helm reports export only unmanaged objects; Helm masks no longer show byte counts; `ctrl+d` on drift rows is offered only for unmanaged objects.
- Create diffs omit server-set `creationTimestamp` and `uid`; `tern-kube-drift` 0.3.0 (same JSON layout).
- Debug uses `--profile=general` (and `--target` when the container is known); the guard's waiting line names the verb and target and `tern-kube-guard-status` prints the context and namespace; Settings shows `explore.auto_refresh` read-only.

## [1.0.1] - 2026-11-10

### Fixed

- **Shell guard: an approval can no longer run in a namespace you did not preview.** A `kubectl --context X ...` without `-n` used whatever namespace the context pointed at when it finally ran, so a `kubens` while the approval waited ran it elsewhere. The approve block re-reads the context's namespace and user at confirm and the guard re-checks them right before kubectl runs; any change refuses.
- **GitOps: exported Secret placeholders are never applied silently.** Drift shows `placeholder` instead of a masked change, apply leaves such Secrets out, `tern-kube-drift` flags them.
- **Helm 4** (Homebrew ships 4.2): the Helm releases view, release lookups and chart auto-detect failed on `helm list -a`. Every Helm call now works with Helm 3 and 4; CI checks both.
- Helm hooks no longer show as drift (CI drift jobs failed forever on charts with upgrade hooks) and are not applied as plain objects; objects of a Helm release never count as unmanaged.
- A Secret that does not exist yet diffs as create, not modify (kubectl prints it as `-null`).
- Apply bundles, which can hold Secret values, are deleted when the approve block closes instead of after 24 hours.
- Guarded commands record their outcome (executed or failed, exit code) in the audit log; a refused guard request asks to run the command again instead of looping on `r`; Ctrl-C shows "Not executed"; a denied `kubectl edit` exits 1; `ctrl+t` confirms the target while typing; restart warns about a paused Deployment; apply previews account for every object.
- Drift: a context without the namespace reports its objects as missing instead of an error; error reasons skip klog noise; an object declared twice is marked ambiguous.
- Tern 0.9.14: PageUp/PageDown work again (the key names changed); the palette no longer lists the Explore and Settings blocks twice.
- Explore: `esc` at the top asks for a second press and backspace never closes it; `m` opens the manifest without taking focus; pickers start with an empty filter; choosing the current context keeps the namespace; list compare uses the filtered rows; `o` reads previous logs per container; Manifest and Diff views survive a plugin reload; mutation keys are hidden when mutations are off; a kubeconfig whose context reads both fail no longer crashes the view.
- Follow-logs and port-forward splits end cleanly on Ctrl-C (no failure dialog); port-forward uses the suggested local port only when it is free.

### Changed

- Tested on Tern 0.9.14; plugin types pinned to tern-sdk `a933069`.
- The guard protocol (still version 1) gains `context_namespace`, `context_user` and `audit` in approve responses; the guard refuses without them, so the shell snippet and the plugin must come from the same release.
- `scripts/dev-tern.sh link` links a snapshot without `.git`: Tern 0.9.14 reloads a linked plugin on any file change below it.

## [1.0.0] - 2026-11-03

Every feature on the v1.0 list is done; no code changes since 0.6.0.

### Changed

- Stable release: config keys, `tern-kube://` link formats and the guard protocol (version 1) now follow SemVer, so an incompatible change needs a major version.

### Since the first public beta (0.1.0)

- 0.1.3: Tern 0.9 support with native text editing in block fields.
- 0.2.0: guarded `rollout undo`/`pause`/`resume`, `patch`, `label`, `annotate`, `cordon`, `uncordon`, `drain` (eviction and PodDisruptionBudget preview) and `edit` as preview then apply.
- 0.3.0: native `kubectl logs` lens, `kubectl events` tables, Explore logs records and events timeline.
- 0.4.0: Helm releases in Explore (history, values against chart defaults, revision diffs with masked secrets), guarded `helm rollback`, chart auto-detect in GitOps.
- 0.5.0: remote SSH hosts, Linux hosts (Debian 13) and fish as login shell; approval grants minted by the window.
- 0.6.0: compare objects and lists across contexts; one GitOps source against several clusters; `tern-kube-drift --context` repeatable.

## [0.6.0] - 2026-11-02

### Added

- Explore compare across contexts: `x` on an object (or the **Compare across contexts** chip in Explore and the lens inspector) compares it with other contexts of the same kubeconfig; on a list, `x` (or **Compare list**) compares the whole list. A picker offers each other context with its API server, **All contexts (N)** and, with `compare.contexts`, a **Configured** preset; contexts on the base's API server are marked, configured names missing from the kubeconfig are listed as such, and choices above `compare.max_contexts` are disabled with the reason. Every side is one pinned `kubectl --context C get ... -o json` (the version is pinned for objects, so both sides read the same apiVersion), the base included, so both sides are snapshots of the same moment.
- Pairwise object diff: both sides' context, API server and fetch time, a status line (`same`, `differs (+a -r)`, `missing in <ctx>`), the differing paths (`spec.replicas 2 -> 3`) and the diff card. All contexts: one row per context (same, changed, missing, error, with the first paths) and `enter` opens its diff. A list: one row per object and one column per context (`present`, `same`, `changed`, `missing`, `extra`, `error`), per-column counts, short context labels with a legend, `f` all / differs / missing or extra, `[` `]` select the other context, and `enter` opens the object diff from the lists already fetched (no new query). `r` refetches every side, `Y` copies every pinned command.
- Both sides are normalized before comparing: status, server-set metadata, ownerReferences, last-applied and rollout annotations, Service cluster IPs, Pod `nodeName` and the injected token volume, PVC `volumeName`. Secret values take part in the comparison but show as `<redacted>` / `<redacted, changed>` unless `security.show_secret_values` is on (then as kubectl prints `data`, base64).
- GitOps across clusters: `x` on a drift report or drift item compares the source against other contexts (one, all, or the configured preset). The matrix has one row per resource and one column per context (server and fetch time, a summary such as `2 changed, 1 missing, 1 unmanaged`); cells `in sync`, `changed +a -r`, `missing`, `unmanaged`, `-`, `error`; `f` all / drifted anywhere / differs between contexts; `enter` opens that context's drift item. Every context gets the same explicit namespace. See [docs/gitops.md](docs/gitops.md#across-clusters).
- `tern-kube-drift` 0.2.0: `--context` is repeatable and `--all-contexts` takes every context of the kubeconfig; two or more contexts give one combined report (text and Markdown matrix, JSON `version: 2`). A failing context is reported as an error column while the others still run; exit 2 if any context failed (report still printed), else 1 if any drifted. With one context the output is byte-identical to 0.1.0 (JSON `version: 1`). The CI example takes several `--context` per `DRIFT_SOURCES` line.
- Settings section `compare` (shared by Explore and GitOps): `contexts`, `max_contexts` (8), `max_parallel` (4 queries or contexts in flight), `max_objects` (500 per side in a list compare).
- `scripts/cluster.sh create-peer|delete-peer|mc-kubeconfig-path`: a second kind cluster `tern-kube-dev2` and the merged `.sandbox/kubeconfig-mc`; `tests/integration/compare/run.sh` (`make test-integration-compare`, in CI) drives compare and the CLI against both clusters with real kubectl and proves nothing was written; end-to-end scenarios 70-79 with `E2E_MC=1`; `make bench` times a 500-object list compare.

### Changed

- `x` is an Explore key on every route (compare); in the logs and events views it keeps its meaning (level floor, Warnings only).
- The drift item view names its context; a drift item of another context hints that `c` switches.

### Fixed

- Drift reports are kept per kubeconfig and context: after `c`, the report of the previous context is no longer shown as the new context's.

### Security

- Compare and matrix views are read-only: quick actions, mutations, export, apply and delete are refused there (`Compare views are read-only`, `Switch to <ctx> (c) to change it`); the approve block stays single-target.
- Raw Secret objects of a compare are held only until every side has answered; the diffs are then computed with values masked and the raw Secrets dropped.

### Known limitations

- Only contexts of the block's kubeconfig, and the same namespace on every side.
- Drift and matrix runs do not check `explore.allow_live_queries` (drift reports never did); Explore compare does.
- `/` does not filter the drift matrix picker.

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
- End-to-end runs restart `tk-logmix` when its pods are older than 4 hours (the logs lens keeps the newest 20 000 lines, so scenario 40 lost the container's first lines), build the Helm world afresh in every run instead of reusing one another run left or is still deleting, and wait until kubectl can read crashy's previous instance before scenario 49 asks for it.

### Fixed

- Drift of a Helm source diffs the render in the release namespace: objects without `metadata.namespace` were compared in kubectl's default namespace and reported missing.
- Drift of a Helm source ignores objects of other Helm releases and Helm hook objects in the same namespace instead of listing them as unmanaged.
- **Apply source** (`A`) and **Apply** (`a`) on a Helm drift source apply the render with `-n <release namespace>`: objects without `metadata.namespace` would have been applied to kubectl's default namespace. Documents of different releases, or renders mixed with plain manifests, are refused.
- Explore and Settings lists keep a full window of rows when the block opens while the Tern window is in the background (behind other windows): Tern reports such a block as 80x24 until the window is activated, and Explore cut its lists to 3 rows.

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

[Unreleased]: https://github.com/contrafy/tern-kube/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/contrafy/tern-kube/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/contrafy/tern-kube/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/contrafy/tern-kube/compare/v0.6.0...v1.0.0
[0.6.0]: https://github.com/contrafy/tern-kube/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/contrafy/tern-kube/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/contrafy/tern-kube/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/contrafy/tern-kube/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/contrafy/tern-kube/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/contrafy/tern-kube/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/contrafy/tern-kube/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/contrafy/tern-kube/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/contrafy/tern-kube/releases/tag/v0.1.0
