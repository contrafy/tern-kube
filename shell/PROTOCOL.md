# tern-kube guard protocol (version 1)

Contract between the shell guard (`shell/tern-kube-guard`, POSIX sh) and the
tern-kube approve block (`tern-kube.approve`). The block never executes the
command; it only previews it and writes a decision. The guard executes
`command kubectl` with the exact argv, and only after verifying that
decision. Every failure is a refusal: nothing runs.

## Preconditions (guard side)

A guarded invocation (`apply`, `delete`, `scale`, `rollout restart`, with any
global flags before the verb) needs all of:

- `TERM_PROGRAM=tern` and a non-empty `TERN_PANE` (any process that can reach
  the Tern daemon could raise an approval otherwise);
- `TKUBE_SPOOL`: absolute path, injected into new panes by the plugin's
  `spawn` hook (`<plugin data>/spool`). Panes started before the plugin
  loaded lack it: "open a new Tern pane";
- no stdin input (`-f -`, `/dev/stdin`, any non-regular file), no remote
  `-f URL`, no newline in an input path, no `"` in an `-f` value;
- a resolvable context: `--context` (last occurrence wins), else
  `command kubectl [--kubeconfig K] config current-context` in the user's
  environment.

Not guarded (executed immediately with `exec kubectl "$@"`): every other verb,
and guarded verbs carrying `--dry-run=client|server` (already a no-op) when
no flag is unknown to the embedded table. An unknown flag before the verb
when `apply`, `delete`, `scale` or `rollout` appears anywhere in the argv is
refused (it may have swallowed the verb).

## Spool

`$TKUBE_SPOOL`, mode 0700, owned by the user (the guard creates it if
missing, refuses a symlink or foreign owner, and `chmod 700`s it). Paths the
guard hands to `tern open` are physical (`pwd -P`), matching Tern's
canonicalized paths (`/private/tmp/...` on macOS).

| File | Writer | Mode | Lifetime |
| --- | --- | --- | --- |
| `req-<nonce>.json` | guard (noclobber) | 0600 | removed by the guard when it finishes |
| `resp-<nonce>.env` | block (atomic tmp + rename) | 0600 best effort | removed by the guard |
| `cancel-<nonce>` | guard | 0600 | left for the block, which removes it |
| `work-<nonce>/` | guard (scratch) | 0700 | removed by the guard |
| `pane-<TERN_PANE>.env` | shell snippets | 0600 | see "Pane env record" |

The guard sweeps `req-*`, `resp-*` and `cancel-*` older than one day plus the
timeout.

`<nonce>` is 32 lowercase hex characters from 16 bytes of `/dev/urandom`.

## Request: `req-<nonce>.json`

One JSON object on one line, UTF-8. Strings escape `"`, `\` and control bytes
(`\b \t \n \f \r`, others `\u00XX`); every other byte passes through
unchanged (argv is passed through as typed, so non-UTF-8 bytes would be
passed through too).

```json
{"version":1,
 "nonce":"<32 hex>",
 "argv":["kubectl","apply","-f","my dir/a.yaml"],
 "program":"/opt/homebrew/bin/kubectl",
 "cwd":"/Users/me/src/app",
 "kubeconfig":"/Users/me/.kube/a:/Users/me/.kube/b",
 "context":"kind-dev",
 "context_source":"current-context",
 "namespace":null,
 "pane":"4294967309",
 "files":[{"path":"/Users/me/src/app/my dir/a.yaml","size":120,"sha256":"<64 hex>"}],
 "fingerprint":"<64 hex>",
 "created_at":1791476707,
 "timeout_s":600}
```

- `argv`: the exact argv; the first element is always `kubectl` (the guard
  function's name, which aliases such as `k` resolve to); the rest is what runs.
- `program`: absolute path of the `kubectl` that `command kubectl` resolves to.
- `cwd`: physical working directory.
- `kubeconfig`: raw `$KUBECONFIG` (not split), `null` when unset or empty. A
  `--kubeconfig` flag is not copied here; it is in `argv`.
- `context` / `context_source`: `"flag"` (from `--context`) or
  `"current-context"` (resolved by the guard).
- `namespace`: the explicit `-n/--namespace` value (last wins), `null` when
  absent. Never resolved from the kubeconfig.
- `pane`: `$TERN_PANE`. The block must refuse requests whose pane is not alive.
- `files`: every input file, enumerated by the guard only (see below), sorted
  bytewise by path, de-duplicated.
- `created_at`: unix seconds; `timeout_s`: the guard's wait limit. The block
  must refuse requests older than `created_at + timeout_s`.

### Input files

From each `-f/--filename` value (split on commas, as kubectl's string-slice
flag does) and the `-k/--kustomize` value; relative paths are joined to `cwd`:

- regular file: itself (no extension filter);
- `-f DIR`: files directly in DIR named `*.json`, `*.yaml`, `*.yml`; with
  `-R/--recursive`, the same at any depth (symlinked subdirectories are not
  followed, as in kubectl);
- `-k DIR`: every non-directory entry under DIR, at any depth;
- listed path = `<value without trailing slashes>/<relative path>`.

The block hashes exactly the listed paths (fresh `size` and `sha256`) to
compute its fingerprint, so the two sides never need to agree on a directory
walk. The guard re-enumerates and re-hashes after approval, so a file added,
removed or edited in between changes the fingerprint and is refused.
Limitation: files a kustomization reaches outside its directory (`../base`)
are not fingerprinted.

## Fingerprint

`fingerprint` = lowercase hex sha256 of this byte string (also implemented by
`plugin/lib/mutation/fingerprint.luau`; both must change together). Lengths
are decimal byte counts; every line ends with `\n`:

```
tern-kube/fp/v1
argv <n>
<len>:<arg>                           (n lines, one per argv element, in order)
context <len>:<context>
kubeconfig <len>:<raw $KUBECONFIG>    or: kubeconfig -
namespace <len>:<explicit -n value>   or: namespace 0:
cwd <len>:<physical cwd>
files <m>
<len>:<abs path> <size> <sha256>      (m lines, sorted bytewise by path)
```

Length prefixes make values containing spaces or newlines unambiguous.

## Waiting

The guard runs `${TERN_BIN:-tern} open --wait <req path>` (stdin
`/dev/null`) in the background under a watchdog of
`$TKUBE_GUARD_TIMEOUT` seconds (default 600):

- timeout: the guard kills `tern open`, writes `cancel-<nonce>`, refuses;
- SIGINT/SIGTERM/SIGHUP (Ctrl-C): the guard writes `cancel-<nonce>`
  (`cancelled_at=<unix>`), kills `tern open`, removes the request, exits 130,
  never executes;
- `tern open` exits non-zero: `cancel-<nonce>`, refusal;
- `tern open` exits 0: its status says nothing about the decision (an
  unclaimed request opens in an editor block and still returns 0); the
  response file decides.

A block that sees `cancel-<nonce>` should close without writing a response.

## Response: `resp-<nonce>.env`

Line-based `key=value` (value = everything after the first `=`), written
atomically:

```
nonce=<nonce of the request>
decision=approve|deny
fingerprint=<64 hex the block computed and previewed>
context=<context the block previewed>
approved_at=<unix seconds>
reason=<one printable line; optional, deny only>
```

`reason` is set when the block denies on its own (for example
`mutations.enabled` is false); the guard prints it with the denial, stripped
of non-printable characters. Unknown keys are ignored.

The guard refuses, executing nothing, unless all hold:

1. the file exists, is a regular file (not a symlink) owned by the user;
2. no key above appears twice;
3. `nonce` equals the request nonce;
4. `decision=approve` (`deny`: "denied in Tern" plus the `reason` if any,
   exit 1);
5. `approved_at` is an integer with `created_at <= approved_at <=
   created_at + timeout_s`, and now `<= created_at + timeout_s`;
6. a fresh context resolution equals both the request `context` and the
   response `context` (context drift);
7. a fresh fingerprint (argv, context, `$KUBECONFIG`, namespace, cwd,
   re-enumerated and re-hashed files) equals both the request and the
   response `fingerprint`.

Then the guard removes its request, response and scratch files, restores the
user's umask and runs `exec kubectl "$@"`: the exact argv, the user's
terminal and environment, kubectl's exit status. Exit statuses of the guard
itself: 1 refusal or denial, 130 cancelled, 2 usage.

## Pane env record

The opt-in snippets (zsh `precmd`, bash `PROMPT_COMMAND`, fish `fish_prompt`)
record each pane's effective `KUBECONFIG` so quick actions launched from that
pane can pin it. On each prompt, when `TERN_PANE` and `TKUBE_SPOOL` are set
and the spool exists, and only when `(spool, pane, $KUBECONFIG)` changed since
the shell's last successful write (cached in a shell variable; no subprocess
otherwise), the snippet writes `$TKUBE_SPOOL/pane-$TERN_PANE.env`:

```
kubeconfig=<value of $KUBECONFIG, empty when unset>
```

exactly one line, nothing else from the environment; mode 0600; written to
`pane-<pane>.env.tmp.<pid>` then renamed. A `KUBECONFIG` containing a newline
is not recorded. Readers must ignore `*.tmp.*` files. If the file is deleted,
it is rewritten at the next change of `KUBECONFIG`, not before.

The plugin reads the record of the pane a quick action was launched from
(`link.pane`, at most 8 KiB) only when the action carries no kubeconfig of
its own and no confirm token (a confirmed action reuses the kubeconfig the
approve block previewed). It pins `--kubeconfig <value>` only for a single
absolute path; an empty value, a relative path, a colon-separated list,
control characters or any other line make it ignore the record (the split's
kubectl then resolves its kubeconfig from Tern's environment, as in a pane
without the snippet).
