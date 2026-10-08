# Real kubectl fixtures

Captured from the disposable kind cluster `tern-kube-dev` by
`sh scripts/fixtures/capture.sh`. Never hand-edit these files: change the world in
`tests/integration/manifests/` or the capture list in the script and re-run it.

## Regenerating

```sh
sh scripts/cluster.sh create          # kind cluster + .sandbox/kubeconfig (idempotent)
sh scripts/fixtures/capture.sh        # delete + rebuild every tern-test-* namespace, capture
sh scripts/fixtures/capture.sh --reuse  # keep the existing world, recapture only
sh scripts/fixtures/capture.sh --world-only  # build the world for live tests and e2e, capture nothing
```

The script only talks to the cluster through `.sandbox/kubeconfig` (verified by
`scripts/cluster.sh kubeconfig-path`), runs kubectl with `KUBERC=off`, `TMPDIR=/tmp`
and no `KUBECTL_EXTERNAL_DIFF`, waits for steady state (jobs complete/failed,
ImagePullBackOff reached, metrics-server serving pod and node metrics, and the
`crashloop` pod freshly in a CrashLoopBackOff back-off before every capture group that
shows it, so it never appears as a momentary Running/Error), wipes this directory except this README and
`json-world/`, captures in
a fixed order, and fails if any capture exits with an unexpected status or if
certificate/key/token material from the kubeconfig shows up in a fixture.

Ages, UIDs, IPs, resourceVersions, pod name hashes, restart counts and event
timing differ between runs; everything else is reproducible.

## JSON world

`json-world/` holds `kubectl get <kind> -n <ns> -o json` per kind for every fixture
namespace plus `get nodes -o json`, captured read-only from the existing world by
`sh scripts/fixtures/capture-json.sh` (nothing in the cluster is changed; argv in
`json-world/MANIFEST.tsv`). The Explore relation specs resolve their queries against
it. Secrets are listed with `-o name` only, and `kube-root-ca.crt` (the cluster CA
certificate) is excluded from the ConfigMap JSON and listed by name only.

## Mutation previews

`mutate-preview/` holds `kubectl diff` and `--dry-run=server` output against the
existing world, captured by `sh scripts/fixtures/capture-mutate-preview.sh` (the
script refuses any argv that is neither `diff` nor `--dry-run=server` and any
namespace outside `tern-test-*`, so nothing in the cluster changes; argv in
`mutate-preview/MANIFEST.tsv`, context always pinned). Inputs live in
`tests/integration/manifests/preview/` and are never applied: a create + modify +
unchanged mix, CRD objects (including a dotted name and a prune deletion), and
cluster-scoped creates (empty namespace in the diff file name). `capture.sh` keeps
this directory; re-run the preview script after rebuilding the world.

## Layout

`<scenario>/<key>.txt` stdout, `<key>.stderr` stderr (only when non-empty),
`<key>.exit` exit status (only when non-zero). `.txt` is omitted when stdout is empty
and stderr is not; both-empty output (for example `kubectl diff` with no changes)
yields an empty `.txt`.

`<key>` is the scheme of `tests/bin/kubectl`: argv with connection flags
(`--context`, `--kubeconfig`, `-n/--namespace`, `--cluster`, `--user`) removed,
joined by `_`, `/` mapped to `+`. Since `-n` is not part of the key, each namespace
gets its own scenario directory. Use a scenario with the fake:

```sh
TKUBE_FAKE_FIXTURES=tests/fixtures/real/ns-apps tests/bin/kubectl get pods -n tern-test-apps
```

`MANIFEST.tsv` lists every fixture: `scenario`, `key`, the exact `argv` (including
`-n`/`-A`/`--context`), `exit`, `kubectl_version`, `server_version`. Commands run
with working directory `tests/integration/manifests`, so `-f` paths in argv and in
error messages are relative to it.

| Scenario | Namespace / scope | Contents |
| --- | --- | --- |
| `cluster` | cluster-scoped | version, api-resources, nodes, namespaces, CRDs, describe node, top nodes |
| `ns-apps` | `tern-test-apps` | healthy Deployment `web` (2 replicas), `broken-image` (ImagePullBackOff), `crashloop`, `pending` (unschedulable), StatefulSet `db`, DaemonSet `node-agent`, ClusterIP/NodePort/headless/LoadBalancer(pending)/ExternalName services, Ingress with 2 hosts + TLS, ConfigMap, fake Secret; every output format, selectors, sort-by, names, multi-kind, events, describe, top |
| `ns-batch` | `tern-test-batch` | completed Job, failed Job, active and suspended CronJobs |
| `ns-crd` | `tern-test-crd` | `widgets.lens.example.com` with string/integer/date columns plus priority-1 Owner/Enabled (`-o wide`), 3 Widgets incl. a very long description |
| `ns-edge` | `tern-test-edge` | odd label keys/values (dots, slashes, empty, 63-char), Unicode annotations and ConfigMap data, a 71-char pod name with 2 containers |
| `ns-empty` | `tern-test-empty` | "No resources found" on stderr with exit 0 |
| `all-namespaces` | `-A` | every family across namespaces, including kube-system |
| `errors` | mixed | unknown kind, NotFound, partial NotFound, Forbidden (`--as`), unreachable server, invalid manifest (strict decoding), YAML syntax error, missing file, delete/scale/restart of missing objects |
| `errors-context` | `--context does-not-exist` | missing kubeconfig context |
| `mutate-create` | `tern-test-mutate` | `diff` of new objects (exit 1), server dry-run, multi-doc apply `created` |
| `mutate-unchanged` | `tern-test-mutate` | re-apply `unchanged`, `diff` with no changes (exit 0) |
| `mutate-configured` | `tern-test-mutate` | `diff` (exit 1), client and server dry-run, apply mixing `configured` and `unchanged` |
| `mutate-ops` | `tern-test-mutate` | scale, rollout restart, rollout status, delete pod |
| `mutate-delete` | `tern-test-mutate` | `delete -f` of a multi-doc file |

The only secret captured in YAML is `tern-test-apps/app-secret`, whose values are the
obviously fake `tern-kube-test-not-a-secret` / `tern-kube-test-user` (base64 in `data`,
plain text in the `last-applied-configuration` annotation, which is the realistic
leak case the lens must handle).

Captured with the client in `MANIFEST.tsv` against kind's `kindest/node:v1.37.0`.
Table output for `get` is printed server-side; `describe`, `diff`, and mutation
messages are client-side and may change with the kubectl version. `kubectl diff`
shells out to the host `diff`; the macOS and GNU `diff -u` headers differ slightly.

Quirks worth testing against, all real kubectl behavior: `top` rows end in trailing
spaces (client-side printer) while `get` tables do not; columns are separated by at
least 3 spaces (tabwriter padding 3, min width 6); `get endpoints` writes a deprecation
`Warning:` to stderr next to a normal table; `version` warns about client/server skew
on stderr; "No resources found" goes to stderr with exit 0; `get pods a b` with one
missing name prints the found row on stdout and the NotFound on stderr, exit 1.
