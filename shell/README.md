# tern-kube shell guard (opt-in)

Makes mutating `kubectl` commands typed in a Tern pane wait for an approval
block that previews them (server dry-run, `kubectl diff` or before/after
object diffs, risk-tier confirmation). Only after you approve does the guard
run the exact command you typed. Guarded: `apply`, `delete`, `scale`,
`patch`, `label`, `annotate`, `cordon`, `uncordon`, `drain`,
`rollout restart|undo|pause|resume`, `set image|env|resources|selector|
serviceaccount|subject`, `replace`, `taint`, `run`, `expose`, `create`
(`create -f/-k` and every subcommand, e.g. `create configmap`, `create job`,
`create secret generic|tls|docker-registry`, `create service nodeport`; not
`create token`), and `edit` (approved after you save, see below). Everything
else runs immediately, unchanged (one `sh` start plus an argv scan, a few
milliseconds), and so do commands that cannot change the cluster:
`--dry-run=client|server`, `patch|label|annotate|set ... --local`,
`label|annotate|set env --list`.

Mutating commands the guard does not intercept (they run immediately):
`create token` (prints a credential; it has no dry run and nothing is
persisted), `autoscale`, `certificate approve|deny`, `auth reconcile`,
`apply set-last-applied|edit-last-applied`, a typed `kubectl debug` (the
Explore debug quick action is approved), and `cp`, `exec`, `attach`.

The guard is a POSIX sh core, `shell/tern-kube-guard`, plus one small
activation file per shell that defines a `kubectl` function calling it. It
fails closed: outside a Tern pane, without the tern-kube plugin, on timeout,
on any mismatch, nothing runs. The wire protocol is in
[PROTOCOL.md](PROTOCOL.md).

## Install

Clone the repository somewhere stable (the activation files find the core
next to themselves), then add one line to your shell's startup file and open
a new Tern pane (panes started before the plugin loaded lack
`TKUBE_SPOOL`).

zsh, `~/.zshrc`:

```sh
source /path/to/tern-kube/shell/tern-kube.zsh
```

bash, `~/.bashrc`:

```sh
source /path/to/tern-kube/shell/tern-kube.bash
```

fish, `~/.config/fish/config.fish`:

```fish
source /path/to/tern-kube/shell/tern-kube.fish
```

Put the line after anything that sets up `PATH` for `kubectl`, and after
other prompt hooks if their order matters to you (bash: the hook is appended
to `PROMPT_COMMAND`, never replacing it).

Tern panes run login shells. fish reads `config.fish` for login and
interactive shells alike, so the line above works with fish as the login
shell too.

### On a remote host

Panes on a host added with `tern remote setup` run that host's login shell,
so the guard must be installed there. Install the plugin on the remote host
from a pane there (same syntax in fish, bash and zsh):

```sh
"$TERN_EXE" plugin install github.com/contrafy/tern-kube
```

and source the snippet from the installed package, for example in fish:

```fish
source ~/.config/tern/plugins/tern-kube/shell/tern-kube.fish
```

`tern remote setup` installs `tern` under `~/.local/bin`, which login shells
often lack on `PATH`; the guard does not need it there (see `TERN_EXE`
below).

## Conflicts

If `kubectl` is already an alias or function in your shell (fish: also an
abbreviation), the activation file prints a message, returns 1 and defines
nothing: your definition keeps working, unguarded. To use the guard, remove
or rename your definition (for example to `k`) before the `source` line.
Aliases that expand to `kubectl` (`alias k=kubectl`, fish `alias k kubectl`)
reach the guard automatically.

A `kubectl` alias or function defined after the `source` line silently
replaces the guard; `tern-kube-guard-status` shows which `kubectl` is active.

## Status

```sh
tern-kube-guard-status
```

prints whether `kubectl` is the guard function, whether the pane env hook is
installed, the core's path, the `kubectl` and `tern` it will use (with the
source that chose `tern`: `TERN_BIN`, `TERN_EXE` or `PATH`), the approval
timeout, and what a guarded verb would do in this shell (ask for approval,
or be refused and why).

## kubectl edit

`kubectl edit` opens your editor first (`KUBE_EDITOR`, else `EDITOR`, else
`vi`, as kubectl picks it). When you save and quit with a change, the
approve block shows the diff and a server dry run of your edit; kubectl
applies it only if you approve. If you deny, the object is not changed and
your edited text is kept in `$TMPDIR/kubectl-edit-denied-XXXXXX` (the path
is printed). A timeout, Ctrl-C or any failed check also keeps that copy and
makes kubectl stop with "there was a problem with the editor". When kubectl
rejects an edit and reopens the editor, each changed save asks again.

`TMPDIR` (default `/tmp`) must be an absolute path without spaces: the
guard puts kubectl's editor hook there, and kubectl splits the editor
command on spaces. The guard checks this, and everything else it needs,
before your editor opens.

## Settings

- `TKUBE_GUARD_TIMEOUT`: seconds to wait for a decision (default 600).
  On timeout the request is withdrawn and nothing runs.
- `TERN_BIN`: the `tern` executable to call. Default: `$TERN_EXE`, which Tern
  sets in every pane (local or remote) to the binary serving that pane; else
  `tern` on `PATH`. `scripts/tern-kube-aliases` picks `tern` the same way.

## Bypass

```sh
command kubectl delete pod web-0
```

runs kubectl directly, skipping the guard in every shell. Warning: a bypassed
command gets no preview, no diff, no target confirmation and no audit entry;
it mutates the cluster immediately. Refusal messages repeat this hint.

## Uninstall

1. In each open shell: `tern-kube-guard-uninstall` (removes the `kubectl`
   function, the prompt hook and the helper functions; bash restores
   `PROMPT_COMMAND` without the hook).
2. Delete the `source .../tern-kube.<shell>` line from your startup file.
3. Optional: remove leftover `pane-*.env` files from the plugin's spool
   directory (`$TKUBE_SPOOL`).

## Pane env record

On each prompt in a Tern pane, the activation files record the pane's
effective `KUBECONFIG` in `$TKUBE_SPOOL/pane-$TERN_PANE.env` (one line,
`kubeconfig=<value>`, mode 0600), so quick actions launched from that pane
pin the same kubeconfig. The file is rewritten only when the value changes;
no other environment variable is recorded. Only a single absolute path is
pinned: with `KUBECONFIG` unset, relative, or a colon-separated list, the
new split's kubectl resolves its kubeconfig from Tern's own environment, as
without the snippet. Mutating quick actions (Debug, Run now) show the pinned
kubeconfig in the approve block before they run. See PROTOCOL.md "Pane env
record".

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
  `--patch-file -`, `--from-file -`, `--from-env-file -`, `--cert -`,
  `--key -`, `set env -e -` or a `-` argument, `/dev/stdin`), URLs, paths
  containing a newline, `-f`, `--from-file` and `--from-env-file` values
  containing `"`. Save the data to a file first. `kubectl run -f/-k` (the
  `--rm` delete inputs) is refused.
- Files a `create configmap|secret` reads (`--from-file`, `--from-env-file`,
  `--cert`, `--key`) are fingerprinted like `-f` files; a `--from-file`
  directory covers the regular files directly inside it.
- The waiting line never shows `--from-literal`, `--docker-password` or
  other flag values; `set env KEY=VALUE` arguments whose key looks like a
  credential (password, secret, token, key, ...) show as `KEY=<redacted>`.
- Files a kustomization pulls from outside its directory are not covered by
  the fingerprint.
- The fingerprint is checked just before kubectl starts (for `edit`: just
  before kubectl reads your saved file); a file changed in the instant
  between the check and kubectl reading it is not detected.
- The cluster state is not fingerprinted: objects a selector matches, the
  pods a `drain` evicts and the revision a `rollout undo` returns to can
  change between the preview and the run.
- `--dry-run=client|server`, `--local` and `--list` run without approval
  (they do not mutate).
- A denied or refused `edit` leaves your text in
  `$TMPDIR/kubectl-edit-denied-*`, which can hold Secret data (kubectl's own
  failure copies can too); delete it when done.
- bash and fish report the alias name (`k apply ...`) to Tern while zsh
  reports the expanded line; this affects lens claims, not the guard (see
  `scripts/tern-kube-aliases`).

## Tests

`make test-shell-guard` runs `tests/shell/guard/run.sh` in zsh, bash and fish
(and the core under dash when installed) with a fake `tern` and a fake
`kubectl`; no Tern or cluster is needed. It also checks that the embedded
flag table matches `plugin/lib/kubectl/flags.luau` (regenerate with
`make guard-flags`).

`make test-shell-login` runs `tests/shell/login/run.sh`: for each installed
shell of sh, dash, bash, zsh and fish, a temp `HOME` whose rc files add
`PATH` and `KUBECONFIG` the usual way, then the plugin's own PATH probe, a
quick-action split line (context and kubeconfig with quotes, `$(...)` and
backticks; exact argv through a fake `kubectl`) and, for fish, the guard
snippet sourced from `config.fish`. Missing shells are reported as skipped.
