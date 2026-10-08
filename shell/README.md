# kube-lens shell guard (opt-in)

Makes mutating `kubectl` commands typed in a Tern pane wait for an approval
block that previews them (server dry-run, `kubectl diff`, per-resource diffs,
risk-tier confirmation). Only after you approve does the guard run the exact
command you typed. Guarded: `apply`, `delete`, `scale`, `rollout restart`.
Everything else runs immediately, unchanged (one `sh` start plus an argv scan,
a few milliseconds).

The guard is a POSIX sh core, `shell/kube-lens-guard`, plus one small
activation file per shell that defines a `kubectl` function calling it. It
fails closed: outside a Tern pane, without the kube-lens plugin, on timeout,
on any mismatch, nothing runs. The wire protocol is in
[PROTOCOL.md](PROTOCOL.md).

## Install

Clone the repository somewhere stable (the activation files find the core
next to themselves), then add one line to your shell's startup file and open
a new Tern pane (panes started before the plugin loaded lack
`KUBE_LENS_SPOOL`).

zsh, `~/.zshrc`:

```sh
source /path/to/tern-kube-lens/shell/kube-lens.zsh
```

bash, `~/.bashrc`:

```sh
source /path/to/tern-kube-lens/shell/kube-lens.bash
```

fish, `~/.config/fish/config.fish`:

```fish
source /path/to/tern-kube-lens/shell/kube-lens.fish
```

Put the line after anything that sets up `PATH` for `kubectl`, and after
other prompt hooks if their order matters to you (bash: the hook is appended
to `PROMPT_COMMAND`, never replacing it).

## Conflicts

If `kubectl` is already an alias or function in your shell (fish: also an
abbreviation), the activation file prints a message, returns 1 and defines
nothing: your definition keeps working, unguarded. To use the guard, remove
or rename your definition (for example to `k`) before the `source` line.
Aliases that expand to `kubectl` (`alias k=kubectl`, fish `alias k kubectl`)
reach the guard automatically.

A `kubectl` alias or function defined after the `source` line silently
replaces the guard; `kube-lens-guard-status` shows which `kubectl` is active.

## Status

```sh
kube-lens-guard-status
```

prints whether `kubectl` is the guard function, whether the pane env hook is
installed, the core's path, the `kubectl` and `tern` it will use, the
approval timeout, and what a guarded verb would do in this shell (ask for
approval, or be refused and why).

## Settings

- `KUBE_LENS_GUARD_TIMEOUT`: seconds to wait for a decision (default 600).
  On timeout the request is withdrawn and nothing runs.
- `TERN_BIN`: the `tern` executable to call (default `tern` on `PATH`).

## Bypass

```sh
command kubectl delete pod web-0
```

runs kubectl directly, skipping the guard in every shell. Warning: a bypassed
command gets no preview, no diff, no target confirmation and no audit entry;
it mutates the cluster immediately. Refusal messages repeat this hint.

## Uninstall

1. In each open shell: `kube-lens-guard-uninstall` (removes the `kubectl`
   function, the prompt hook and the helper functions; bash restores
   `PROMPT_COMMAND` without the hook).
2. Delete the `source .../kube-lens.<shell>` line from your startup file.
3. Optional: remove leftover `pane-*.env` files from the plugin's spool
   directory (`$KUBE_LENS_SPOOL`).

## Pane env record

On each prompt in a Tern pane, the activation files record the pane's
effective `KUBECONFIG` in `$KUBE_LENS_SPOOL/pane-$TERN_PANE.env` (one line,
`kubeconfig=<value>`, mode 0600), so quick actions launched from that pane
pin the same kubeconfig. The file is rewritten only when the value changes;
no other environment variable is recorded. See PROTOCOL.md.

## Limitations

- Only commands typed through the `kubectl` function are guarded. Scripts,
  `command kubectl`, absolute paths (`/usr/local/bin/kubectl`), other tools
  calling kubectl, `kubecolor`, `xargs kubectl`, `env kubectl` and kubectl
  plugins are not.
- kubectl's own aliases (kuberc `aliases`) that map another word to a
  mutating verb are not recognised.
- Global flags before the verb must be ones kubectl defines globally
  (`--context`, `-n`, `--kubeconfig`, ...). An unknown flag before the verb
  when a mutating verb appears in the command is refused; put command flags
  after the verb.
- Inputs that cannot be fingerprinted are refused: stdin (`-f -`,
  `/dev/stdin`), URLs, paths containing a newline, `-f` values containing `"`.
  Save the manifests to a file first.
- Files a kustomization pulls from outside its directory are not covered by
  the fingerprint.
- The fingerprint is checked just before kubectl starts; a file changed in
  the instant between the check and kubectl reading it is not detected.
- `--dry-run=client|server` runs without approval (it does not mutate).
- bash and fish report the alias name (`k apply ...`) to Tern while zsh
  reports the expanded line; this affects lens claims, not the guard (see
  `scripts/kube-lens-aliases`).

## Tests

`make test-shell-guard` runs `tests/shell/guard/run.sh` in zsh, bash and fish
(and the core under dash when installed) with a fake `tern` and a fake
`kubectl`; no Tern or cluster is needed. It also checks that the embedded
flag table matches `plugin/lib/kubectl/flags.luau` (regenerate with
`make guard-flags`).
