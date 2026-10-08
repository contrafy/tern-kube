# tern-kube-lens

**Kube Lens** reads `kubectl` output in [Tern](https://stencil.so/tern) as
native views: sortable, filterable tables you can click into, with the
original output one click away (**Raw**).

![Pods with the inline inspector open](docs/screenshots/m1-inspector-dark-wide.png)

> Public beta, in active development. See [Status](#status).

- **Click a column** to sort. Ages, quantities, ratios and restarts sort by
  value, not text.
- **Click a row** for an inline inspector; **Inspect** shows every field,
  the source line and, with `-o json`, the object tree.
- **Filter chips** by status, namespace and kind, plus **Problems**
  (failing, not ready, restarting).
- **Copy** the name, a qualified id, or a ready `describe`, `logs` or
  `get -o yaml` command for the same context and namespace.
- `describe` renders as cards with an events timeline, `-o yaml` as a
  document list, and `apply` / `delete` / `scale` / `rollout restart` as a
  result summary (a result, never a preview).
- Secret values are masked in the native view.
- Output it cannot render faithfully (`-w`, `-o jsonpath`, very large
  output) stays raw.

It claims `kubectl` and `kubecolor` running `get`, `describe`, `top`,
`apply`, `delete`, `rollout restart` and `scale`, also after global flags
(`kubectl --context prod -n web get pods`), and takes over from Tern's
built-in `kubectl get` lens. Pipelines and redirected output are never
lensed.

| `get all` | `describe` |
| --- | --- |
| ![get all](docs/screenshots/m1-get-all-dark-wide.png) | ![describe](docs/screenshots/m1-describe-light-wide.png) |

## Explore

**Explore live** on a row, or **Kube Lens: Explore** in the palette, opens a
live block beside the pane. It pins the context it queries, shows where that
context came from, and only refreshes when you ask.

![Relations of a Deployment](docs/screenshots/m2-relations-dark-wide.png)

| Keys | |
| --- | --- |
| `j` `k` `gg` `G` `enter` `esc` | move, open, back |
| `/` | filter |
| `d` `y` `L` `R` | describe, object, last logs, relations |
| `s` `l` `shift+f` | shell, follow logs, port-forward in a split |
| `c` `n` `:` | context, namespace, kind |
| `ctrl+d` `ctrl+r` `shift+s` | delete, rollout restart, scale |
| `r` `Y` `?` | refresh, copy the command, help |

Shell, logs and port-forward are also chips in the lens inspector (two
clicks from any row). They open beside the pane by default; see
[configuration](docs/configuration.md).

## Changes

Delete, restart, scale, debug, CronJob run-now (Explore keys or inspector
chips) and **Kube Lens: Apply file or directory** open an approval block
first: server dry run, `kubectl diff` per resource, then a confirmation
scaled to the risk. Deletes and other broad changes need the target typed.
Nothing runs if the preview fails or the inputs or target change before
you confirm.

![Approving an apply with per-resource diffs](docs/screenshots/m3-diff-expanded-dark-wide.png)

Typed commands can get the same preview with the opt-in shell guard for
zsh, bash and fish: `kubectl apply`, `delete`, `scale` and
`rollout restart` wait for your approval in Tern; everything else runs
untouched. It is a seatbelt, not a policy: `command kubectl` and scripts
bypass it. Setup: [shell/README.md](shell/README.md).

## GitOps

Explore knows the git repository you ran the command in: `m` opens an
object's manifest at its line, `=` diffs it against the live object,
`ctrl+g` reports drift for a directory, Kustomization, Helm release or a
locally checked out Argo CD / Flux app (changed, missing, unmanaged), and
`E` exports live objects as clean manifests, optionally onto a new branch
and commit. Push and pull requests are off unless you turn them on.

![Drift report](docs/screenshots/m3b-drift-dark-wide.png)

Outside Tern, [`bin/kube-lens-drift`](bin/kube-lens-drift) produces the same
report for CI ([example workflow](examples/ci/github-actions-drift.yml)).
Details: [docs/gitops.md](docs/gitops.md).

## Install

```sh
git clone https://github.com/contrafy/tern-kube-lens
tern plugin link tern-kube-lens/plugin
```

Requires Tern 0.6.2 or later with shell integration and native command
output on (`command_lenses`, the default), and `kubectl` on your `PATH`.

zsh expands aliases before Tern sees the command, so `alias k=kubectl`
works as is. In bash and fish, opt in per alias:

```sh
tern-kube-lens/scripts/kube-lens-aliases add k
```

To remove: `tern plugin unlink kube-lens`.

## Status

- [x] Generic lens: tables, describe, top, YAML/JSON, mutation results
- [x] Explore: live view with relations, keyboard navigation, and one-key
      shell, logs and port-forward in a split
- [x] Mutations with server dry-run, per-resource diff and risk-tiered
      confirmation; opt-in zsh/bash/fish guard for typed commands
- [x] GitOps: open and diff a resource's manifest, drift reports
      (YAML, Kustomize, Helm, Argo CD/Flux aware), export, CI drift check
- [x] Settings file ([configuration](docs/configuration.md))
- [ ] Settings UI, CI, releases

## Development

```sh
make bootstrap   # pinned tools into .tools/
make check       # format, lint, typecheck, unit tests, benchmark
make e2e         # drives an isolated Tern window; needs Docker
```

`make e2e` runs against a disposable [kind](https://kind.sigs.k8s.io)
cluster (`scripts/cluster.sh create`) and refuses any other context.

More: [SDK capability matrix](docs/sdk-capability-matrix.md),
[performance](docs/performance.md).

## License

[MIT](LICENSE)
