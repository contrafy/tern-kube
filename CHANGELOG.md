# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0: minor
versions may break).

## [Unreleased]

### Added

- GitOps in Explore: manifest index for YAML, Kustomize and Helm sources;
  open a resource's manifest at its line; diff vs manifest; drift reports
  (changed, missing, unmanaged) per directory, Kustomization, Helm release
  or locally checked out Argo CD / Flux app; export of live objects as
  clean manifests following the target layout, with an optional branch
  and commit (push and pull request opt-in, never forced).
- Argo CD and Flux awareness: owning application, sync and health status.
- `bin/kube-lens-drift`: Tern-free drift report (text, Markdown, JSON) and
  an example GitHub Actions workflow with dry-run-only RBAC.
- Settings block (**Kube Lens: Settings**): every config key with
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
- Opt-in alias claims for bash and fish (`scripts/kube-lens-aliases`).
- Versioned JSON config (`$XDG_CONFIG_HOME/kube-lens/config.json`) with
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

[Unreleased]: https://github.com/contrafy/tern-kube-lens/commits/master
