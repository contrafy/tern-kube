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
- [ ] Explore: live view with relations, keyboard navigation, and one-key
      shell, logs and port-forward in a split
- [ ] Mutations with server dry-run, per-resource diff and risk-tiered
      confirmation; opt-in zsh/bash/fish guard for typed commands
- [ ] GitOps: open and diff a resource's manifest, drift reports
      (YAML, Kustomize, Helm, Argo CD/Flux aware), export, CI drift check
- [ ] Settings, CI, releases

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
