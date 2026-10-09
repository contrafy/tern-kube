# Contributing

## Setup

Supported dev hosts: macOS arm64 and Linux x86_64.

```sh
make bootstrap   # pinned luau, luau-lsp, StyLua, selene, kind, helm, oxipng, pngquant into .tools/
make check       # format, lint, typecheck, unit tests, benchmark
```

Tools are repo-local (`.tools/`, gitignored, checksums pinned in
`scripts/bootstrap.sh`); nothing is installed globally. The shell suites
also need zsh, bash and fish. Integration tests need Docker; e2e needs Tern
and `jq`. See [docs/testing.md](docs/testing.md) and
[docs/architecture.md](docs/architecture.md).

## Conventions

- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `test:`, `build:`,
  `chore:`, `refactor:`), imperative, small and atomic. One branch per
  change, PR against `master`.
- **TDD**: write the failing test first; tests state why the behavior
  matters. Bugs get a regression test.
- **Pure core**: code under `plugin/lib/` never references the `tern`
  global; inject what it needs. Only `plugin/host.luau`,
  `plugin/window.luau` and the `plugin/*_host.luau` adapters call `tern.*`.
- `--!strict` in every Luau file; no `any` unless an SDK type forces it.
  Small pure functions, immutable data where practical.
- Comments only where the code cannot say it (SDK constraints, safety
  reasons). No emojis in code, docs or commit messages.
- The package is the repository root: `plugin.toml` there, and everything
  it loads under `plugin/`, which holds only what ships (`.luau`, `.css`);
  tests, fixtures, scripts and docs live outside it. CI rejects anything
  else under `plugin/` and any entry, style or `require` that leaves it.
- Generated files are regenerated, never hand-edited
  (`plugin/lib/kubectl/flags.luau`, `kinds_data.luau`, the guard's flag
  table via `make guard-flags`, fixtures).
- Keep `README.md` and `docs/` true to the code in the same PR; add a line
  under `## [Unreleased]` in `CHANGELOG.md` for user-visible changes.

## Testing safely

- Only the disposable kind cluster (`scripts/cluster.sh create`); the real
  `kubectl` only with `KUBECONFIG=.sandbox/kubeconfig`. Mutations only in
  `tern-test-*` namespaces.
- Tern only through `scripts/dev-tern.sh` with a sandbox under `/tmp`
  (`TK_TERN_SANDBOX=/tmp/tk-tern-<name>`). Never run `tern` subcommands
  against your own Tern config or daemon, and never edit your shell rc files
  or kube contexts for tests.

## Pull request checklist

- [ ] Commits follow Conventional Commits.
- [ ] Failing test added first; `make check` passes.
- [ ] Shell changes: `make test-shell-aliases test-shell-guard
      test-shell-drift` pass (zsh, bash, fish).
- [ ] Cluster-facing changes: the relevant `tests/integration/` script passes
      against kind.
- [ ] UI changes: `make e2e` passes locally; screenshots updated if the view
      changed.
- [ ] No `tern` reference added under `plugin/lib/`; nothing but shippable
      files under `plugin/`.
- [ ] Docs, README and CHANGELOG updated.
- [ ] No secrets, kubeconfigs or real cluster output in the diff.
