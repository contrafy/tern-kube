# GitOps

Kube Lens compares the manifests in your repository with what is running
in the cluster. Inside Tern this is part of Explore; outside Tern (CI,
cron, a plain terminal) the standalone `kube-lens-drift` CLI produces the
same per-resource report.

## In Tern

### Manifest index

The first GitOps view opened in an Explore block indexes the git
repository containing the directory the command ran in (`git ls-files`,
tracked and untracked, `.gitignore` respected), or that directory when it
is not a repository. It reads plain YAML (single and multi-document),
renders Kustomize directories with `kubectl kustomize`, and renders the Helm
releases listed in [`gitops.helm`](configuration.md#gitops) with
`helm template`. Scanning is bounded (`gitops.max_files`, `max_bytes`,
`max_file_bytes`), runs in small steps with progress, and only reruns when
you press `r`.

Objects are matched by group, kind, namespace and name. A document without
a namespace matches the command's namespace; Kustomize `namespace:` and
Helm release namespaces are applied first.

When an object carries Argo CD or Flux tracking metadata, its detail view
shows the owning application with its sync and health status, and links
to the source path when the application's repository URL matches one of
your local remotes. Kube Lens never writes Argo CD or Flux objects.

### Open manifest and diff vs manifest

From an Explore object, or with the **Manifest** / **Diff vs manifest**
chips in the lens inspector:

| Key | |
| --- | --- |
| `m` | open the manifest in a Tern file block at its line |
| `=` | diff the live object against its manifest |
| `]` `[` | next or previous manifest, when several declare the object |
| `a` | apply the manifest through the approve block |

The diff writes the matched document to a private temporary file (0600),
runs `kubectl diff -f` pinned to the block's context and removes the file.
Secret values are redacted as in the approve block.

### Drift report

`ctrl+g` picks a source (a directory, a Kustomization, a configured Helm
release, or an Argo CD / Flux application checked out locally) and compares
it with the cluster: **changed** objects with their diff, objects **missing
in cluster**, and **unmanaged** objects (live in the source's namespaces,
of kinds the source uses, declared nowhere). Owned objects, defaults and
controller bookkeeping are not reported as unmanaged.

`f` cycles the filter, `enter` opens an entry, `a` applies one manifest and
`A` the whole source (both through the approve block), `E` exports the
selected live object and `X` everything shown.

### Export

`E` turns live objects into manifests: status, server-set metadata and
defaults are dropped (`uid`, `resourceVersion`, `managedFields`,
`clusterIP`, …) and Secret values become `REPLACE_ME` placeholders. Files
follow the target directory's existing layout when it has a clear one,
else `<namespace>/<kind>/<name>.yaml` plus a `kustomization.yaml`. The
preview lists every file as new, modified or unchanged with its diff;
`t` changes the directory, `w` then `y` writes. Existing files are never
overwritten without that preview.

### Git branches and pull requests

After a write, `b` prepares a branch and commit for the exported files. Each
command is shown before it runs, and `enter` runs them in order, stopping at
the first failure. Push (`p`) and `gh pr create` (`P`) are off until you
turn them on; nothing is ever force-pushed. If changes unrelated to the
export are staged, the flow refuses unless `o` commits only the exported
files.

## kube-lens-drift CLI

`bin/kube-lens-drift` is a single POSIX `sh` script with no Tern
dependency. It needs `awk`, `sed`, `sort`, `mktemp`, `kubectl` and, for
Helm charts, `helm`. Copy it anywhere on your `PATH`, or vendor it into a
repository for CI.

```sh
kube-lens-drift (-f PATH [-R] | -k DIR | --helm CHART --release R [-f VALUES]...)
                [--context C] [--kubeconfig K] [-n NS]
                [--format text|markdown|json] [--max-diff-lines N] [--max-bytes N]
                [--unmanaged KINDS|auto]
```

| Source | Runs |
| --- | --- |
| `-f PATH` (repeatable), `-R` | `kubectl diff -f PATH... [-R]` |
| `-k DIR` | `kubectl diff -k DIR` |
| `--helm CHART --release R` | `helm template R CHART [--namespace NS] [-f VALUES]...`, then `kubectl diff -f` on the rendered output |

With `--helm`, `-f` and `--values` name values files, as in Helm.
`--context`, `--kubeconfig` and `-n` are passed to every kubectl call. The
`KUBECTL` and `HELM` environment variables select the binaries.

`kubectl diff` sends each manifest to the API server as a server-side dry
run, so admission webhooks and defaulting apply and nothing is written.
`KUBECTL_EXTERNAL_DIFF` is ignored: the CLI always parses kubectl's
built-in `diff -u -N` output. kubectl masks Secret `data` in the diff, but
the `kubectl.kubernetes.io/last-applied-configuration` annotation still
holds the applied values in clear; the CLI replaces that line in Secret
diffs (in every format) before printing.

### Report

Each object in the diff is one resource with a change and line counts:

| Change | Meaning |
| --- | --- |
| `create` | declared in the manifests, missing from the cluster |
| `modify` | in both, applying the manifest would change the live object |
| `delete` | removed by the apply (only with kubectl's pruning) |
| `unknown` | kubectl could not show a text diff (binary content) |

The split into resources follows `plugin/lib/mutation/diffseg.luau`, so
the CLI and the Tern views always agree: `tests/shell/drift/run.sh` checks
both on the same golden `kubectl diff` captures.

- `--format text` (default): a table, a summary line, then each diff.
- `--format markdown`: a heading, a summary table and one collapsible
  `<details>` block per resource. Names, context and namespace are
  entity-escaped and each diff sits in a code fence longer than any
  backtick run inside it, so the output is safe to post as a pull request
  comment.
- `--format json`: for scripts. Top level `version`, `source`, `context`,
  `namespace`, `drift`, `summary` (counts), `resources` (`key`, `group`,
  `version`, `kind`, `namespace`, `name`, `action`, `added`, `removed`,
  `binary`, `lineCount`, `truncated`, `lines`: the segment verbatim,
  header lines included), `unmanaged` (`null` unless requested) and
  `notes` (lines kubectl printed outside any resource).

`--max-diff-lines N` keeps the first N lines of each resource's diff and
says how many were cut. `--max-bytes N` (text and Markdown) drops whole
diffs, and in Markdown then table rows, to stay under N bytes; the summary
line is always kept. GitHub rejects comments over 65536 characters.

### Unmanaged objects

`--unmanaged KINDS` lists live objects that no manifest declares, for the
comma-separated kubectl resource names in KINDS (`auto`: the kinds that
appear in the source), in the namespaces the source covers. The source's
objects are resolved with `kubectl apply --dry-run=client`. Objects that
are expected to be absent from Git are skipped: anything with
`ownerReferences`, the `default` ServiceAccount, `kube-root-ca.crt`,
service-account token and Helm release Secrets, events, endpoints,
endpoint slices, leases, `default` and `kube-*` namespaces and built-in
`system:` / bootstrap RBAC objects.

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | no drift |
| 1 | drift: at least one resource differs, or an unmanaged object was found |
| 2 | error: bad arguments, kubectl or helm failed (their message is on stderr) |

## CI

`examples/ci/github-actions-drift.yml` runs the CLI on pull requests, on
a weekday schedule and on demand:

- every run writes the report to the job summary;
- pull requests get one sticky comment, found by its
  `<!-- kube-lens-drift -->` marker and edited on every push;
- scheduled and manual runs fail when the cluster has drifted, pull
  request runs only when the CLI errors;
- the kubeconfig comes from the secret `KUBE_LENS_DRIFT_KUBECONFIG`, is
  written to a 0600 file under `$RUNNER_TEMP`, never printed, and deleted
  at the end; fork pull requests receive no secrets and skip the check.

Set `DRIFT_SOURCES` (one CLI source per line, for example
`-k deploy/overlays/production` or `-R -f k8s -n web`) and copy
`bin/kube-lens-drift` to `.github/kube-lens-drift`. The workflow pins
`kubectl` by version and SHA-256 and `actions/checkout` by commit.

A pull request run diffs the pull request's merge commit, so the comment
shows both what merging would change and any drift already in the
cluster. The runner must reach the API server; for private clusters use a
self-hosted runner.

### Minimal RBAC

`kubectl diff` needs, for each resource type in the manifests:

| Verb | Why |
| --- | --- |
| `get` | read the live object |
| `patch` | server-side dry run of the change to an existing object |
| `create` | server-side dry run of an object missing from the cluster (without it the first such object fails the run with Forbidden) |
| `list` | only for `--unmanaged` |

`update`, `delete`, `watch`, `escalate` and `bind` are not needed. Diffing
Secrets needs `get` on secrets, which also lets the token read every
Secret in the namespace; diffing Roles and RoleBindings needs `escalate`
and `bind` (or holding every permission they grant), because the API
server checks privilege escalation on dry runs too.

RBAC cannot tell a dry run from a real write, so `create` and `patch`
alone would let the token change the cluster.
`examples/ci/rbac-drift-readonly.yaml` adds a ValidatingAdmissionPolicy
(Kubernetes 1.30+) that rejects every request from the CI ServiceAccount
that is not a dry run. It contains a ServiceAccount, a ClusterRole with
`get`, `list`, `create`, `patch` on common workload kinds, one RoleBinding
per target namespace, and the policy with its binding. Edit the
ServiceAccount namespace (`kube-lens-drift`), the target namespaces
(`my-app`) and the resource list before applying it.

`tests/integration/drift-rbac/run.sh` applies the example unchanged
except for names on the kind development cluster and checks that a token
for it reports modify, create and unmanaged drift; that `apply`,
server-side apply, `create`, `patch`, `annotate`, `scale`,
`rollout restart`, `delete` and `replace` are all rejected and the live
objects are unchanged; and that removing `get`, `patch`, `create` or
`list` breaks exactly the cases listed above, and that diffing a Role
without `escalate` fails. Run it with
`sh tests/integration/drift-rbac/run.sh` against `scripts/cluster.sh create`.

### Kubeconfig for the secret

With an admin context for the target cluster:

```sh
kubectl apply -f rbac-drift-readonly.yaml
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ca=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
token=$(kubectl -n kube-lens-drift create token kube-lens-drift --duration=720h)
umask 077
cat >drift.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: target
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: kube-lens-drift
    user:
      token: $token
contexts:
  - name: drift
    context: {cluster: target, user: kube-lens-drift}
current-context: drift
EOF
gh secret set KUBE_LENS_DRIFT_KUBECONFIG <drift.kubeconfig
rm drift.kubeconfig
```

The API server may cap `--duration`; rotate the secret before the token
expires. Prefer an environment secret with required reviewers if people
who can push branches should not be able to run workflows with it.
