# Security model

What Kube Lens protects against, what it does not, and why. Reporting a
vulnerability: [SECURITY.md](../SECURITY.md).

## Trust boundary: the local user

Kube Lens runs as the user, inside the user's Tern, with the user's
`kubectl` credentials. Anything running as the same user is trusted: it can
already run `kubectl` directly. Concretely:

- The spool directory (`<plugin data>/spool`, exported to panes as
  `KUBE_LENS_SPOOL`) is mode 0700; request and response files are 0600. A
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
- Quick-action confirmation grants live in Tern's plugin kv store
  (`plugin/lib/mutation/link.luau`): single use, 60 s expiry, exact link
  match. A same-user process able to write that store is inside the boundary.

## The guard is advisory, not admission control

The shell guard (`shell/kube-lens-guard`) only sees commands typed through
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

- guard outside a Tern pane, without `KUBE_LENS_SPOOL`, plugin not loaded
  (the request opens in an editor and no response appears), timeout
  (`KUBE_LENS_GUARD_TIMEOUT`, default 600 s), Ctrl-C, any response check
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
- `kube-lens://` links never carry a command line: the window and the block
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

## Secrets

- Native views mask Secret `data`/`stringData` and the Secret's
  `last-applied-configuration` annotation unless
  `security.show_secret_values` is `true` (default `false`);
  `security.sensitive_output_strict_mode` adds a name heuristic
  (`plugin/lib/model/redact.luau`, `docs/configuration.md`). Masking is best
  effort.
- `kubectl diff` masks Secret data but not the last-applied annotation; the
  approve block (`Diffseg.redactSecrets`, `plugin/lib/mutation/diffseg.luau`)
  and `bin/kube-lens-drift` replace those lines.
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
namespaces (`plugin/lib/mutation/risk.luau`). Without a valid grant the link
opens the approve block instead of running.

## No credentials stored

Kube Lens stores no credentials. It records context names, the kubeconfig
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
`fingerprint`, `exit_code`, `previewed_at`, `started_at`, `finished_at`.
Values of `--token` and `--password` in argv are replaced by `<redacted>`.
Command output, environment values and file contents are never logged. The
log is local, unsigned and user-writable: a record of what Kube Lens did,
not tamper evidence. Commands that bypass Kube Lens are not in it.
