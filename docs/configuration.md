# Configuration

tern-kube reads one JSON file. Every key is optional; a missing key has its
default, and the defaults are the safe choice (secret values hidden, Explore
never polls, mutations go through preview and confirmation).

## Location

1. `$XDG_CONFIG_HOME/tern-kube/config.json` when `XDG_CONFIG_HOME` is set to
   an absolute path (relative values are ignored, as the XDG spec requires);
2. otherwise `$HOME/.config/tern-kube/config.json`.

The variables are read from the Tern daemon's environment, which is the
environment the Tern window was launched with, not your shell's.

On plugin load, when no file exists at that path, tern-kube creates it (and
its directory) with only a schema reference and the format version:

```json
{
  "$schema": "https://raw.githubusercontent.com/contrafy/tern-kube/master/schema/config.schema.json",
  "schema_version": 1
}
```

The stub sets no setting, so later default changes still reach you. An
existing file, or a symlink at the path (even a dangling one), is never
replaced. When the path is unknown (neither `XDG_CONFIG_HOME` nor `HOME`
set) or not writable, nothing is written and a line goes to Tern's log; the
defaults apply as without a file. A file you delete is created again on the
next plugin load; an empty `{}` keeps it from coming back.

### Editor support

[`schema/config.schema.json`](../schema/config.schema.json) is a JSON Schema
(draft 2020-12) of the file, generated from the loader's own key catalog
(`make schema`; `make check` fails when it is stale). Editors that read
`$schema` (VS Code, JetBrains IDEs, Zed, Neovim or Helix with the JSON
language server) then complete every key with its description and default
and flag what the loader reports: a wrong type, an out-of-range number, an
unknown key. `$schema` is the only key tern-kube ignores; replace `master`
in its URL with a release tag to pin the schema to that release. To check a
file from a shell:

```sh
uvx check-jsonschema --schemafile \
  https://raw.githubusercontent.com/contrafy/tern-kube/master/schema/config.schema.json \
  "${XDG_CONFIG_HOME:-$HOME/.config}/tern-kube/config.json"
```

### Settings block

**Tern Kube: Settings** in the palette opens a block that edits this file:
every key with its effective value, a description and a reset to the
default (`r`). Booleans and enums toggle with `enter`; numbers, strings and
lists open an input. Each change is validated before it is written, unknown
keys and `$schema` are kept, and the file is replaced atomically. The Status
page (`tab`) shows the file's diagnostics, the resolved `kubectl`, alias
claims in the installed manifest and the shell guard's spool.

To edit by hand, open the stub (or `o` in the Settings block) and let the
editor complete keys, or start from the complete example:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/tern-kube"
cp examples/config.json "${XDG_CONFIG_HOME:-$HOME/.config}/tern-kube/config.json"
```

## When the file is read

- Once when the plugin loads (Tern start, `tern plugin reload`).
- Again whenever a tern-kube block (such as Explore) opens, so opening a new
  Explore block picks up edits.
- Never while a command lens renders: the lens callbacks (`open`, `line`,
  `finish`, `view`, `event`) must not do I/O, so the `kubectl` lens uses the
  config cached by the last read. To apply an edit to lenses, open any
  tern-kube block or run `tern plugin reload`.

The file must be a regular file of at most 262144 bytes. A symlinked file
(stow, chezmoi, home-manager) is supported: Tern's capped read refuses
symlinks, so tern-kube resolves the link with `realpath` in the background
and reads the target with the same cap. Until that finishes (milliseconds
after plugin load) the defaults apply. A link to anything other than a
regular file is rejected.

## Errors and diagnostics

A bad config never stops tern-kube. Each problem produces a diagnostic, and
the rest of the file still applies:

| Problem | Result | Level |
| --- | --- | --- |
| File missing, empty or only whitespace | all defaults (a missing file gets the stub at plugin load) | none |
| Invalid JSON | all defaults; message gives the byte offset, line and column | error |
| Top level is not a JSON object | all defaults | error |
| Value has the wrong type or is out of range | that key keeps its default; message names the key path, the expected value and the default used | error |
| Section (e.g. `explore`) is not an object | that section keeps its defaults | error |
| Invalid entry in `aliases.additional` | that entry is dropped, the others kept | error |
| Unknown key, at any level | ignored | warning |
| `$schema` is not a string | ignored | warning |
| `schema_version` newer than this tern-kube | known keys apply, unknown keys are ignored | warning |
| `explore.auto_refresh` set to `true` | kept `false` | warning |
| Invalid entry in `gitops.helm` or `gitops.unmanaged_kinds` | that entry is dropped, the others kept | error |

Example messages:

```text
general.max_rendered_rows: expected an integer between 1 and 10000, got string "lots"; using the default 500.
quick_actions.placement: expected one of "right", "down", "tab", got string "left"; using the default "right".
genral: unknown key; it is ignored. Check the spelling against docs/configuration.md.
config.json is not valid JSON at byte 29 (line 1, column 29): trailing comma at line 1 column 29. Using the defaults for every setting until the file is fixed.
```

Diagnostics are written to Tern's log (target `tern::plugin`; errors and
warnings at `warn`, notes at `info`) each time they change.

`null` for any key means "use the default" (Tern's JSON decoder drops null
members).

## Keys

Paths are relative to the top-level object. "Integer" means a JSON number
without a fractional part, within the stated range.

### Top level

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `$schema` | string | none (the stub sets it) | JSON Schema for editor completion and validation ([Editor support](#editor-support)). tern-kube ignores it and keeps it when Settings writes the file. |
| `schema_version` | integer >= 1 | `1` | Version of this file's format. tern-kube understands version 1. A newer value is accepted with a warning: keys this version knows apply, the rest are ignored. |
| `kubectl` | string: program name or absolute path (`~/` allowed) | `"kubectl"` | The kubectl binary Explore, quick actions and mutations run. A name is looked up as described in [Programs and `PATH`](#programs-and-path); an absolute path is used as is. Relative paths with a `/` are rejected because the daemon's working directory is not yours. |
| `kubeconfig` | string: absolute path (`~/` allowed), or `null` | `null` | Kubeconfig passed as `--kubeconfig` when an Explore link does not name one. |
| `gitops` | object | see [`gitops`](#gitops) | Manifest index, drift, export and the git flow in Explore ([gitops.md](gitops.md)). |

### Programs and `PATH`

Tern runs plugin commands with the Tern daemon's `PATH`. Started from the
Dock, Finder or Spotlight, that is launchd's `/usr/bin:/bin:/usr/sbin:/sbin`,
which holds neither Homebrew's nor Docker Desktop's `kubectl`. tern-kube
therefore finds `kubectl`, `helm` and `gh` itself.

The kubectl program, first match wins: the Tern kv key `kubectl` (set by
tests and the settings flow), then `kubectl` from this file when it is
anything other than the bare default `"kubectl"`, then the daemon
environment variable `TKUBE_KUBECTL`, then the name `kubectl`. `gh` comes
from `gitops.gh`, `helm` is always the name `helm`. An absolute path is run
as is. A name (the default, or a value such as `"kubecolor"`) is searched,
first hit wins, in:

1. your login shell's `PATH` (when `general.shell_env` is `true`);
2. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/bin`,
   `~/.rd/bin` (Rancher Desktop), `~/.docker/bin`,
   `~/.local/share/mise/shims`, `~/.asdf/shims`, `~/.nix-profile/bin`,
   `/run/current-system/sw/bin`, `/nix/var/nix/profiles/default/bin`,
   `/snap/bin`, `/usr/local/sbin`;
3. Tern's own `PATH`.

Every command tern-kube runs gets that combined `PATH` (shell entries,
then the directories above that exist, then Tern's, without duplicates), so
kubectl's exec credential plugins (`aws`, `gke-gcloud-auth-plugin`,
`kubelogin`) are found too. When Tern's environment has no `KUBECONFIG`,
commands get the shell's.

The login shell is read once per Tern daemon, in the background from plugin
load: `$SHELL -l -i` (zsh, bash, sh, fish with its own syntax; other shells
are skipped) runs with a 5 second timeout, and all its output except one
marker line is discarded. Explore waits for it before its first command.
If it fails or times out, the directories above still apply and Tern's log
gets a line; Settings > Status shows the result and how long it took. Set
`general.shell_env` to `false` to never start your shell, for example when
its startup files are slow or print prompts.

Effective kubeconfig for Explore, first match wins: the `kubeconfig` of the
lensed command (its `--kubeconfig` flag), then `kubeconfig` from this file,
then the daemon's `KUBECONFIG`, then the login shell's `KUBECONFIG`, then
`$HOME/.kube/config`. Explore always pins `--context` (and `--kubeconfig`
when known) on every command it runs.

### `general`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `native_default` | boolean | `true` | `false`: the lens returns no native view, every lensed command shows Tern's raw output; equivalent to disabling the lens. Plugins cannot drive the Raw toggle, so there is no per-block native switch. |
| `max_rows` | integer 1-100000 | `20000` | Output lines a lens records for its native view from one command; past this many lines the block falls back to Tern's raw output. |
| `max_rendered_rows` | integer 1-10000 | `500` | Rows drawn at once. Lens tables page by this many rows (page chips switch pages); Explore lists draw the page that holds the selection and count the rest in an overflow note. |
| `max_capture_bytes` | integer 65536-268435456 | `16777216` | Output bytes a lens captures from one command; beyond it the block falls back to Tern's raw output. |
| `shell_env` | boolean | `true` | Read `PATH` and `KUBECONFIG` from your login shell once per Tern daemon, so `kubectl`, `helm`, `gh` and kubectl's exec credential plugins (`aws`, `gke-gcloud-auth-plugin`, `kubelogin`) are found when Tern starts from the Dock or Finder with the system's minimal `PATH`. See [Programs and `PATH`](#programs-and-path). `false` skips the shell; the well-known install directories are still searched. |

### `aliases`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `additional` | list of command names (letters, digits, `_`, `.`, `-`; at most 64 characters) | `[]` | Informational: the alias names you intend tern-kube to claim. It claims nothing by itself. Lens claims for aliases are written into the plugin manifest by `scripts/tern-kube-aliases add NAME`, which first verifies that your shell resolves NAME to kubectl or kubecolor. |

### `explore`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `allow_live_queries` | boolean | `true` | `false` disables the Explore block's cluster reads: it opens but runs no `kubectl` command. |
| `auto_refresh` | boolean | `false` | Only `false` is supported. Explore never polls the cluster; refresh with `r` or the Refresh chip. `true` is kept `false` with a warning. |
| `query_timeout_ms` | integer 500-600000 | `10000` | Each Explore `kubectl` call is killed after this many milliseconds and shown as an error. |
| `relationship_max_nodes` | integer 1-5000 | `250` | Maximum objects in a relations graph; larger graphs are truncated with a note. |

### `mutations`

Read by the approve block (native mutations from Explore, lens chips and the
palette, mutating quick actions, and shell-guard requests).

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | `false` hides every mutating action (Explore `ctrl+d`/`ctrl+r`/`shift+s`, the lens Delete/Restart/Scale chips, debug containers, CronJob run-now) and makes the approve block refuse: native requests cannot be confirmed and shell-guard requests are denied with the reason, so the guarded command exits 1 without running. |
| `interactive_guard` | boolean | `false` | Marks the opt-in shell guard as wanted; the guard functions themselves are installed separately. |
| `require_target_confirmation` | boolean | `true` | Mutations need the target context confirmed (named by `--context` or chosen and confirmed in Explore), never inferred from the current context alone. |
| `allow_failed_preview_override` | boolean | `false` | `true` allows confirming a mutation whose server dry-run or diff failed. |
| `preview_timeout_ms` | integer 1000-600000 | `30000` | Each preview step (`current-context`, `config view`, server dry-run, `kubectl diff`, target reads, file digests) is killed after this many milliseconds and shown as failed. |
| `execute_timeout_ms` | integer 1000-3600000 | `300000` | A confirmed native mutation is killed after this many milliseconds. A mutation cannot be cancelled once it started; the result shows that it timed out and the cluster state must be checked with Requery. |

### `security`

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `show_secret_values` | boolean | `false` | `false` masks the values of Secret `data`/`stringData` and the Secret's `kubectl.kubernetes.io/last-applied-configuration` annotation (which embeds them) in the native views: lens JSON and YAML views, the lens object tree and the Explore object view. A banner notes that the raw output contains Secret data. `true` shows the values, with a warning banner that the output contains Secret values. Set `true` only on a machine and screen you trust. Tern's raw output is kubectl's own and is never masked. |
| `sensitive_output_strict_mode` | boolean | `false` | `true` additionally masks values that look sensitive outside Secret data. Heuristic, advisory only: a value is masked when its key or env var name contains, case-insensitively, one of `password`, `passwd`, `secret`, `token`, `apikey`, `api_key`, `private_key` or `credentials` (plurals included) as a whole name segment; names are split at `_`, `-`, `.` and camelCase, so `DB_PASSWORD`, `apiKey` and `GITHUB_TOKEN` match while `tokenizer_mode` does not. Names ending in `name` or `ref` (`secretName`, `tokenSecretRef`) are references and stay visible. Applies to the native views of the lens and Explore: describe (fields such as pod `Environment` entries and ConfigMap `Data` keys), YAML (`key: value` lines and env `name`/`value` pairs) and JSON/object trees (mapping keys and `{name, value}` env entries); when anything in an object is masked, its last-applied annotation is masked too. It cannot recognise every secret: values under innocuous names or embedded in larger strings stay visible, and raw output is never masked. |

### `quick_actions`

Quick actions open a new split (or tab) running a visible `kubectl` command:
shell, follow logs, port-forward, and the mutating debug and CronJob
actions. They never type into existing panes.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `placement` | `"right"`, `"down"` or `"tab"` | `"right"` | Where the action's terminal opens: a split to the right of or below the originating pane, or a new tab. |
| `shell_command` | non-empty list of up to 32 non-empty strings | `["sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash \|\| exec sh"]` | Program and arguments run inside the container by the Shell action (`kubectl exec -it ... -- <shell_command>`). The default starts bash when the image has it, else sh. |
| `logs_tail` | integer 1-100000 | `200` | Lines of history the Logs action shows before following (`kubectl logs -f --tail=<n>`). |
| `debug_image` | container image reference without spaces | `"busybox:1.36"` | Image for the debug actions (`kubectl debug ... --image=<image>`). These mutate the cluster and go through the confirmation tier. |

### `gitops`

Read by Explore's GitOps views ([gitops.md](gitops.md)). The manifest index
is built only when one of them needs it, from the repository that contains
Explore's working directory.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `helm` | list of `{"chart", "release", "namespace"?, "values"?}` | `[]` | Helm releases rendered with `helm template <release> <chart> [-n namespace] [-f values]...` for diff and drift (only when `helm` is found, see [Programs and `PATH`](#programs-and-path)). `chart` and `values` are absolute, `~/`, or relative to the repository root; `release` and `namespace` are lowercase DNS labels. Charts are never exported. |
| `unmanaged_kinds` | non-empty list of kinds (`"Deployment"`, `"widgets.example.com"`), or omitted | omitted | Kinds the drift report lists to find unmanaged objects. Omitted: the namespaced kinds the source declares. |
| `max_files` | integer 1-20000 | `2000` | Manifest files indexed per scan (`git ls-files` order; kustomizations first). |
| `max_bytes` | integer 1048576-268435456 | `33554432` | Total bytes read per scan. |
| `max_file_bytes` | integer 4096-16777216 | `1048576` | Larger files are skipped. |
| `render_kustomize` | boolean | `true` | Render top-level kustomizations with `kubectl kustomize` while indexing, so overlays map to live names. |
| `gh` | string: program name or absolute path | `"gh"` | GitHub CLI for the optional `gh pr create` step; offered only when `gh auth status` succeeds. A name is looked up like `kubectl`. |

## Complete example

This is `examples/config.json`: every key at its default. Delete the keys
you do not change; missing keys keep their defaults.

```json
{
  "$schema": "https://raw.githubusercontent.com/contrafy/tern-kube/master/schema/config.schema.json",
  "schema_version": 1,
  "general": {
    "native_default": true,
    "max_rows": 20000,
    "max_rendered_rows": 500,
    "max_capture_bytes": 16777216,
    "shell_env": true
  },
  "aliases": {
    "additional": []
  },
  "explore": {
    "allow_live_queries": true,
    "auto_refresh": false,
    "query_timeout_ms": 10000,
    "relationship_max_nodes": 250
  },
  "mutations": {
    "enabled": true,
    "interactive_guard": false,
    "require_target_confirmation": true,
    "allow_failed_preview_override": false,
    "preview_timeout_ms": 30000,
    "execute_timeout_ms": 300000
  },
  "security": {
    "show_secret_values": false,
    "sensitive_output_strict_mode": false
  },
  "quick_actions": {
    "placement": "right",
    "shell_command": ["sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"],
    "logs_tail": 200,
    "debug_image": "busybox:1.36"
  },
  "kubectl": "kubectl",
  "kubeconfig": null,
  "gitops": {
    "helm": [],
    "max_files": 2000,
    "max_bytes": 33554432,
    "max_file_bytes": 1048576,
    "render_kustomize": true,
    "gh": "gh"
  }
}
```

A typical small file:

```json
{
  "$schema": "https://raw.githubusercontent.com/contrafy/tern-kube/master/schema/config.schema.json",
  "schema_version": 1,
  "kubectl": "/opt/homebrew/bin/kubectl",
  "quick_actions": { "placement": "down", "logs_tail": 500 },
  "explore": { "query_timeout_ms": 20000 }
}
```
