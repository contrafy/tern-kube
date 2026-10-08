# Releasing

## Versioning

- [SemVer](https://semver.org). Before 1.0.0 a minor bump (`0.y.0`) may
  break config keys, link formats or the guard protocol; patch releases
  (`0.y.z`) only fix.
- The plugin version is `version` in `plugin/plugin.toml` (Tern shows it in
  `tern plugin list`). Tags are `v<version>`.
- `bin/kube-lens-drift` carries its own `VERSION` (it is also installed
  standalone); bump it when the CLI's behavior or output changes.
- The guard protocol has its own version (`shell/PROTOCOL.md`, request
  field `version`); bump it on any incompatible change to the request,
  response or fingerprint bytes, together with
  `plugin/lib/mutation/fingerprint.luau`.

## Steps

Nothing is pushed, tagged or published without the maintainer's approval.

1. `master` is green in CI (`.github/workflows/ci.yml`), and `make e2e` is
   green locally on macOS arm64 (CI cannot run Tern).
2. On a release branch:
   - set `version` in `plugin/plugin.toml`;
   - bump `VERSION` in `bin/kube-lens-drift` if it changed;
   - in `CHANGELOG.md` rename `## [Unreleased]` to
     `## [X.Y.Z] - YYYY-MM-DD`, add a new empty `## [Unreleased]`, update the
     compare links at the bottom;
   - check `README.md` (status, minimum Tern version, install lines).
   Open a PR titled `chore(release): vX.Y.Z` and merge it.
3. Run the smoke test below on the merged commit, on both platforms.
4. Tag and publish:

   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   awk '/^## \[X.Y.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md >/tmp/notes.md
   gh release create vX.Y.Z --title "vX.Y.Z" --notes-file /tmp/notes.md
   ```

`tern plugin install github.com/contrafy/tern-kube-lens/plugin` clones the
default branch, so a release is what `master` holds at the tag. To install
an exact tag, clone it and install the directory:

```sh
git clone --branch vX.Y.Z https://github.com/contrafy/tern-kube-lens
tern plugin install tern-kube-lens/plugin --force
```

## Manual smoke test

Run on macOS arm64 and Linux x86_64 (Linux: only if a Tern build for it is
available; otherwise record it as not run). The tester is not the author and
uses only `README.md`, `shell/README.md` and `docs/`; every point where they
needed help is a documentation bug to file before the release. Use a
disposable kind cluster (`scripts/cluster.sh create`) and a Tern profile
that holds nothing of value (a fresh OS user, or `TERN_CONFIG_DIR` and
`TERN_DAEMON_SOCKET` pointing at a scratch directory).

Install

- [ ] `tern plugin install github.com/contrafy/tern-kube-lens/plugin`
- [ ] `tern plugin list`: `kube-lens` at the release version, loaded, no
      problems.

Lens

- [ ] `kubectl get pods -A`: native table; column sort; row inspector;
      Raw toggle shows kubectl's text.
- [ ] `kubectl describe pod <pod>`, `kubectl get deploy -o yaml`,
      `kubectl get pods -o json`: cards, document list, object tree.
- [ ] `kubectl get secret <name> -o yaml`: values masked in the native view.
- [ ] `kubectl get pods -w`: raw while running, native after Ctrl-C.
- [ ] `tern plugin reload`, then click an older lens: it rehydrates with
      its sort and filters.

Explore and quick actions

- [ ] Palette "Kube Lens: Explore" opens the block; `j`/`k`, `/`, `enter`,
      `esc`, `?` work.
- [ ] Shell (`s`), logs (`l`), port-forward (`shift+f`) open a split whose
      title names the pod and context; exiting closes the pane.

Mutations (in a `tern-test-*` namespace)

- [ ] Delete, restart and scale from Explore open the approve block with
      dry-run, diff and risk tier; Cancel changes nothing; confirming
      executes; a line is appended to `audit.log` in the plugin data
      directory.
- [ ] Debug and CronJob run-now ask for confirmation before the split opens.

Shell guard (zsh, bash and fish)

- [ ] Add the `source .../shell/kube-lens.<shell>` line, open a new pane,
      `kube-lens-guard-status` reports the guard active.
- [ ] `kubectl apply -f <file>`: approve block opens; Deny runs nothing;
      Approve runs the exact command.
- [ ] `kubectl get pods` is unaffected; `command kubectl ...` bypasses.
- [ ] `kube-lens-guard-uninstall` and removing the `source` line restore
      plain `kubectl`.

Drift CLI

- [ ] `bin/kube-lens-drift -f <dir>` against the cluster: exit 0 with no
      drift, 1 after changing a manifest, 2 on a bad path.

Uninstall

- [ ] `tern plugin remove kube-lens`; `tern plugin list` no longer shows
      it; `kubectl get pods` shows Tern's built-in view again.
- [ ] Optional cleanup documented and complete: config
      (`~/.config/kube-lens/`), plugin data (spool, audit log).
