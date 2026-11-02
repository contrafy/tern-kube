# Security model

What Tern Kube protects against, what it does not, and why. Reporting a
vulnerability: [SECURITY.md](../SECURITY.md).

## Trust boundary: the local user

Tern Kube runs as the user, inside the user's Tern, with the user's
`kubectl` credentials. Anything running as the same user is trusted: it can
already run `kubectl` directly. Concretely:

- The spool directory (`<plugin data>/spool`, exported to panes as
  `TKUBE_SPOOL`) is mode 0700; request and response files are 0600. A
  same-user process can still read requests, write responses or delete them.
  The guard therefore checks ownership, regular-file type, nonce, timestamps,
  context and fingerprint (`shell/PROTOCOL.md`, "Response"), which detects
  stale or mismatched files, not a hostile process running as the user.
- Approvals happen in the Tern window. Any process that can reach the Tern
  daemon socket can open an approve block (verified, see
  `docs/sdk-capability-matrix.md`, "Guard: `tern open` from outside a Tern
  pane"); the guard refuses unless it runs in a Tern pane
  (`TERM_PROGRAM=tern`, `TERN_PANE`) so it never raises approvals for
  background processes, and the block refuses requests whose pane is gone or
  whose `created_at + timeout_s` has passed
  (`plugin/lib/mutation/session.luau`).
- Quick-action confirmation grants live in the window machine's plugin kv
  store (`plugin/lib/mutation/link.luau`). The window mints a random
  32-hex-digit token before opening the approve block and passes it as the
  block's second argument; the block, which may run on a remote host with
  its own kv, only hands the token back in the confirmed link. The window
  consumes it once, within 600 s of minting, and only if every field of the
  link it minted for comes back unchanged; the block may add only what it
  resolved and showed (`context`, `kubeconfig`, `image`, `suffix`). A
  same-user process able to write the window's kv store is inside the
  boundary. Tokens are never written to a host's kv, audit log or spool.
- On a remote host the host half runs with that host user's credentials and
  kubeconfig; installing tern-kube there trusts it like any program the
  user runs there. Both machines must run the same tern-kube version: an
  approve block opened without a token (older window half) refuses before
  previewing anything.

## The guard is advisory, not admission control

The shell guard (`shell/tern-kube-guard`) only sees commands typed through
the `kubectl` shell function. It does not see scripts, `command kubectl`,
absolute paths, `kubecolor`, other tools, CI, or other machines. It is a
seatbelt against mistakes at the prompt. Enforce policy on the cluster
(RBAC, admission controllers). The risk heuristics in
`plugin/lib/mutation/risk.luau` are labeled advisory and never claim policy
conformance.

`command kubectl` bypasses the guard by design; refusal messages say so and
warn that a bypassed command gets no preview, diff, confirmation or audit
entry (`shell/README.md`).

## Fail closed

Every uncertain case refuses; nothing runs:

- guard outside a Tern pane, without `TKUBE_SPOOL`, plugin not loaded
  (the request opens in an editor and no response appears), timeout
  (`TKUBE_GUARD_TIMEOUT`, default 600 s), Ctrl-C, any response check
  failing (`shell/PROTOCOL.md`);
- inputs that cannot be fingerprinted: stdin (`-f -`, `/dev/stdin`), URLs,
  paths with newlines; unknown or ambiguous flags around a mutating verb;
  `--raw`; interactive deletes (`plugin/lib/mutation/plan.luau`);
- a failed server dry run or diff blocks confirmation unless
  `mutations.allow_failed_preview_override` is `true` (default `false`);
  some blocked reasons cannot be overridden at all
  (`plugin/lib/mutation/confirm.luau`);
- an inferred target context must be confirmed while
  `mutations.require_target_confirmation` is `true` (default);
- at confirm time the block re-reads file digests, fingerprint, the
  context's API server and (when inferred) the current context; any change
  refuses (`session.luau`);
- `tern-kube://` links never carry a command line: the window and the block
  rebuild argv from validated fields (`plugin/lib/actions/quick.luau`,
  `plugin/lib/mutation/link.luau`), so a crafted link can at most request a
  preview or a read-only split. Invalid links are refused with a toast.
- an invalid config value falls back to its safe default with a diagnostic
  (`plugin/lib/config.luau`).

## Fingerprint and TOCTOU

The fingerprint (`plugin/lib/mutation/fingerprint.luau`, same bytes in the
guard) covers argv, context, raw `KUBECONFIG`, explicit namespace, cwd and
the size and sha256 of every input file. Limits:

- it is checked just before kubectl starts; a file changed between that
  check and kubectl reading it is not detected;
- files a kustomization reaches outside its directory (`../base`) are not
  fingerprinted;
- the server state is not fingerprinted: a dry run previews the cluster as
  it was; objects changed by others in between are applied over;
- a spawned native mutation cannot be cancelled (`tern.process.run` has no
  kill handle).

## Guarded verbs and `kubectl edit`

The approve block and the shell guard cover `apply`, `delete`, `scale`,
`patch`, `label`, `annotate`, `cordon`, `uncordon`, `drain`,
`rollout restart|undo|pause|resume` and `edit`. Commands that cannot change
the cluster (`--dry-run=client|server`, `--local`, `--list`) run without
approval, but only when every flag is known to the guard's table for that
verb (`shell/PROTOCOL.md`, "Preconditions"). A `--patch-file` is an input
file like `-f`: hashed into the fingerprint, re-hashed before kubectl runs.

- Server state is not fingerprinted (see above): the pods a `drain`
  evicts, the PodDisruptionBudgets that block it, and the objects a
  `label`/`annotate` selector matches are what the preview saw, not what
  kubectl finds later.
- `rollout undo` without `--to-revision` targets "the previous revision",
  which moves with every rollout. At confirm the block re-reads the
  revision list and refuses when any object's newest revision changed
  since the preview.
- `kubectl edit` is approved after you save (`shell/PROTOCOL.md`, "Edit
  approvals"): the guard points `KUBE_EDITOR` at a hook in a private 0700
  directory under `TMPDIR`, which runs your editor, then asks for approval.
  Between the approval and kubectl reading the file, kubectl's temp file
  (0600, in `TMPDIR`) is the only copy of what will be applied; a same-user
  process that rewrites it in that instant is inside the trust boundary
  above, as with any `-f` file. The fingerprint covers the edited file and
  kubectl's original serialization, both re-hashed just before the hook
  lets kubectl continue. An unapproved edit never reaches the cluster: an
  EXIT trap writes back the bytes kubectl produced, so kubectl sees no
  change (deny) or an editor failure (any refusal).
- Denied and refused edits are kept in `TMPDIR/kubectl-edit-denied-*`
  (mode 0600) so no work is lost. Such a copy can contain Secret data in
  clear (base64 `data` or `stringData`), as can kubectl's own copies of
  failed edits; neither is removed automatically.
- The preview of an edit is a server dry run of the JSON merge patch from
  the original to the edited object. When the live object changed since
  kubectl fetched it, the block says so; kubectl itself sends a strategic
  merge patch computed against its first fetch.

## Helm rollback

`helm rollback` goes through the approve block only from Tern Kube links
(Explore); there is no shell guard for `helm` typed in a pane.

- Every helm call pins `--kube-context` (and `--kubeconfig` when it names
  one file; a path list travels in `KUBECONFIG`) and sets `HELM_DRIVER`
  from `helm.driver`: the Tern daemon has no shell environment, and a
  driver that does not match the release storage lists nothing.
- The grammar is strict (`plugin/lib/mutation/helm_plan.luau`): an explicit
  revision, a `--timeout`, and only flags whose effect the preview models
  (`--wait`, `--wait-for-jobs`, `--cleanup-on-fail`, `--force`,
  `--no-hooks`, `--history-max`, connection flags); anything else is
  refused. `--timeout` is always pinned because it also bounds hooks, and
  it must leave 30 s within `mutations.execute_timeout_ms`, since the block
  cannot stop helm once it runs.
- `helm rollback --dry-run` validates nothing on the server; the block uses
  it only to prove the target revision exists. The preview is the change
  between the two stored revision manifests plus `kubectl diff -f -` of the
  target manifest against the live objects (approximate: helm merges three
  ways). The target manifest reaches kubectl on stdin, never a file.
- Confirmation is always typed (the release name). A release stuck in
  `pending-*` is a typed finding, not a block: rollback is helm's recovery
  path, but it races a helm process that may still run.
- At confirm the block re-reads `helm history --max 1` and refuses when the
  newest revision or its status changed since the preview (an upgrade,
  rollback or uninstall in between).
- Helm values are masked in the approve block by key name and value shape
  (`plugin/lib/model/redact.luau`); every masked string from the deployed
  and target user values and the stored chart defaults is also replaced
  where it is echoed into other objects (a ConfigMap DSN) in both diffs,
  because kubectl masks only Secret objects. `security.show_secret_values`
  turns this off.

## Secrets

- Native views mask Secret `data`/`stringData` and the Secret's
  `last-applied-configuration` annotation unless
  `security.show_secret_values` is `true` (default `false`);
  `security.sensitive_output_strict_mode` adds a name heuristic
  (`plugin/lib/model/redact.luau`, `docs/configuration.md`). Masking is best
  effort.
- `kubectl diff` masks Secret data but not the last-applied annotation; the
  approve block (`Diffseg.redactSecrets`, `plugin/lib/mutation/diffseg.luau`)
  and `bin/tern-kube-drift` replace those lines.
- Raw output is kubectl's own and is never masked. Tern keeps it (the Raw
  toggle, lens rehydration after reload) under Tern's own retention; Kube
  Lens cannot redact or purge it. Run `kubectl get secret -o yaml` only where
  you would print it anyway.
- GitOps export writes placeholders instead of Secret values
  (`plugin/lib/gitops/clean.luau`).
- Test fixtures never contain Secret data: capture scripts list Secrets with
  `-o name` only (`scripts/fixtures/capture-json.sh`).

## Quick actions: exec never prompts

By explicit user decision, the read-style quick actions (shell, follow logs,
port-forward) open a new split immediately, without a confirmation step.
Mitigations: the command is visible in the new pane; the pane title names
action, namespace, pod/container and context; the context is always pinned
with `--context` (and `--kubeconfig` when known), so a later
`kubectl config use-context` cannot redirect it. A pod shell can still
mutate the workload from inside; that is the user's action.

Mutating quick actions (`kubectl debug` on a pod or node, CronJob
run-now) need a confirmation grant from the approve block; `debug node` is
in the typed tier because it creates a privileged pod in the node's host
namespaces (`plugin/lib/mutation/risk.luau`). A link without `confirm`
opens the approve block; one whose grant is unknown, expired, used or
minted for different fields runs nothing ("Tern Kube: not confirmed").

## No credentials stored

Tern Kube stores no credentials. It records context names, the kubeconfig
path (from `KUBECONFIG` or `--kubeconfig`) and, with the opt-in shell
snippets, each pane's `KUBECONFIG` value in `<spool>/pane-<pane>.env`
(nothing else from the environment). Commands run with the user's own
kubeconfig.

## Audit log

`<plugin data>/audit.log`, one JSON line per decision, appended with umask
077 (`plugin/mutate_host.luau`). Fields (`plugin/lib/mutation/audit.luau`):
`v`, `decided_at`, `decision` (approved, denied, cancelled, blocked,
executed, failed), `mode` (native, guard), `op`, `family`, `context`,
`context_source`, `namespace`, `kubeconfig` (path), `cwd`, `argv`, `tier`,
`fingerprint`, `exit_code`, `previewed_at`, `started_at`, `finished_at`,
`objects` (up to 50 previewed `Kind namespace/name`), `objects_total` and
`files` (path and sha256 of each fingerprinted input file); helm rollbacks
add `release`, `revision` (the target) and `from_revision` (the newest
revision when previewed).
Values of `--token` and `--password` in argv are replaced by `<redacted>`;
inline `-p` patch text stays in argv, since it is the command.
Command output, environment values and file contents are never logged. The
log is local, unsigned and user-writable: a record of what Tern Kube did,
not tamper evidence. Commands that bypass Tern Kube are not in it.
