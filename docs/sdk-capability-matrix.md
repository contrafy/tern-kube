# Tern SDK capability matrix (M0)

Verified against Tern 0.6.2 (4b3ed42) on macOS arm64, 2026-10-08, in an
isolated sandbox (`scripts/dev-tern.sh`, sandbox `/tmp/kl-tern`) with the
plugin in `plugin/` linked and the fake kubectl in `tests/bin/`. Evidence
quotes are from `tern ctl --control /tmp/kl-tern/ctl.sock ...` replies, the
sandbox logs (`tern-daemon.log` = host half, `tern.log` = window half) or
`tern ctl shot` PNGs.

Status: **Verified** (observed in this build), **Workaround** (the direct
capability is missing; the named substitute was observed working),
**Unsupported** (observed absent or not working), **Proposed** (design built
on verified pieces, the composition itself not exercised),
**Unverified** (not exercised, with the reason).

| Capability | Status | Evidence (Tern 0.6.2) | Notes / fallback |
| --- | --- | --- | --- |
| Built-in kubectl lens | Verified | With no plugin linked, `kubectl get pods` rendered a native table; lens role discovered via `dump ".sf-block[data-role^='...']"` is `lens.k8s.get`. Built-ins also claim `kubectl logs ...` (`lens.docker.logs`) and `kubectl get pods -o json` (`lens.k8s.describe`). Screenshot `screenshots/m0-builtin-k8s-get.png`. | Tern already ships a status-colored `kubectl get` table. kube-lens must add value beyond it (sort, inline inspector, Explore, guard). |
| Plugin claim beats built-in | Verified | Same commands after linking: role `lens.plugin.kube-lens.get`; `lens.open` logged in `tern-daemon.log`. | A plugin claim also suppresses the built-in when our `view` returns nil (raw shown, not the built-in). We therefore render `-o json` ourselves with `tern.parse.json_tree`. |
| Claim globs (`kubectl get`, `kubectl get *`, `kubecolor get`, `kubecolor get *`) | Verified | `lens.open` logged for `kubectl get pods`, `kubecolor get pods` (fake kubecolor), absolute path `/…/tests/bin/kubectl get pods` (`program=kubectl`), `command kubectl get pods`, `KUBE_LENS_FAKE_ROWS=100 kubectl get pods`, `kubectl get pods 2>/dev/null`. Not claimed: `kubectl get pods > file`, `kubectl get pods \| cat`. | Matches docs: wrappers, `VAR=` prefixes, program dirs and stderr redirects are skipped; pipelines and stdout redirects are never lensed. |
| Global flags before the verb | Verified | `kubectl * get *` claimed `kubectl --context x -n y get pods` but also `kubectl describe pod get x` (false positive). Replaced by `kubectl -* get` / `kubectl -* get *`: claims `kubectl --context x -n y get pods` and `kubectl -n y get pods`; does not claim `kubectl logs get-thing` or `kubectl describe pod get x`; still claims `kubectl -n y logs pod get x`. | Globs cannot negate. The lens re-derives the verb from argv (`plugin/lib/kubectl/argv.luau`, M1) and `view` returns nil (raw) for verbs it does not render. Residual cost: such a false claim hides the built-in logs lens for that one command. |
| Aliases (`k get pods`) | Verified | With the user's zsh alias `k=kubectl`, `k get pods` was claimed: `lens.open kubectl get pods typed=k get pods`. | zsh reports the expanded line. bash/fish behavior not exercised (no fish installed); docs say globs see the typed line there. Default manifest claims no `k` forms (decision). |
| Lens lines / finish | Verified | 6-row fixture: `lens.finish status=0 lines=7`. stderr-only `kubectl get pods missing`: `status=1 lines=1` (stderr is in-stream). Empty output `kubectl get secrets`: `status=0 lines=0`, view nil, nothing drawn. | `finish` status is a number. Ctrl-C of a watch: `status=130`, and the last line is `^C` (the parser drops it). |
| Lens view / native table | Verified | `plugins expect '"CrashLoopBackOff"'` -> `{"ok":true}`; `tree` shows `.sf-block-body > ... .kl-grid` with one `.kl-h` per column and `.kl-r` rows. Screenshot `screenshots/m0-lens-table.png`. | |
| Raw toggle | Verified | `click ".tv-block:last-child .sf-block-opt:nth-child(2)"` -> segment shows `Raw` on and the original text; clicking `Native` restored the plugin view with its last state (no event, no rehydration). | Built-in per block; no API to drive or read it. |
| Lens click actions (sort) | Verified | `click ".kl-grid th:nth-child(3)"` -> `lens.event {"act":"v","ev":"action","id":"b.n17","sf":"lens10","value":"mode:el;sort:STATUS"}` then re-`view`; row order changed (`tree ".kl-grid tbody tr"`). | Event ids (`b.n17`) are not stable across views; payload must live in the action name (`v=sort:STATUS;open:db-0`). |
| Clickable rows: `table` node with per-row `actions` | Unsupported | Rows with `actions` rendered, clicking a row cell fired only the table node's action: `{"act":"table-click","ev":"action","id":"b.n12"}` with no row info. | Docs agree: table rows are data, not nodes. |
| Clickable rows: `list`/`item` | Verified (rejected for tables) | Item `actions` fired `{"act":"v",...,"value":"...open:cache-6b7c8d9e0-abcde"}`; a non-item node inserted after the item rendered as an inline inspector. Screenshot `screenshots/m0-rejected-list-rows.png`. | No column alignment (detail is one joined string). Good for the Explore block, not for tables. |
| Clickable rows: `el` HTML table | Workaround (partial) | `tr` with `actions` is clickable (`.sf-act`), `th` sort works. `attrs={colspan=5}` (number or string) is ignored: inspector `td` rect `[26,214,523.28,124]` equals the first column's width. | Inline inspector cannot span the row. |
| Clickable rows: `el` div CSS grid (chosen) | Verified | `div.kl-grid.kl-cols-N` (`display:grid`), rows `div.kl-r{display:contents}` carrying `actions`, cells `div.kl-c`, inspector `div.kl-insp{grid-column:1/-1}`. Clicking a cell (`click 100 203`) fired the row action; inspector rect `[26,214,1238,124]` = full width. Screenshot `screenshots/m0-lens-inspector.png`. | Clicks on a `display:contents` row's cells reach the row's action. Column template classes are defined in `plugin/kube-lens.css` for 1..12 columns. |
| `tern ctl` selectors for clicks | Verified | CSS selectors work: `click ".kl-grid .kl-h:nth-child(3)"`, `click "[data-surface='plugin.kube-lens.approve'] .kl-btn:nth-child(1)"`; coordinates: `click 100 203`; modifiers after the selector. `tree SEL` returns `{"nodes":[{tag,class,text,rect}]}`; attributes such as `data-role` are not printed but match in selectors. | `hover X Y` is not accepted (`bad selector`). Hidden tabs' DOM also matches selectors; scope with `.tv-block:last-child`. |
| Keys in a lens | Unsupported | `key j`, `type abc` after clicking the lens: reply `focused: textarea.tv-input` (the terminal); no lens event. | Keyboard navigation needs a block. |
| Text input in a lens | Unsupported | An `input` node renders in a lens; clicking it sends `{"ev":"focus","id":"b.n13","sf":"lens12"}` to `event`, but typed text goes to the shell prompt. | Filter/search live in the Explore block. |
| Rehydration after reload | Verified | After `dev-tern.sh reload`, a header click on an old lens block logged `lens.open kubectl get pods` -> `lens.view lines=7` (lines replayed) -> view shows `6 rows · sorted by NAME`; an earlier run logged `lens.open` -> `lens.finish` -> `lens.event` -> `lens.view` with the state from the action value. | `open/line/finish` must stay side-effect free. Running blocks (Explore) are not re-initialized by a reload; their timers and pending callbacks are dropped. |
| Plugin auto-reload on save | Verified | Saving a broken `host.luau` logged `plugin failed to load ... host.luau:225: Expected identifier`; saving fixes reloaded without `tern plugin reload`. Manifest `styles` CSS changes applied on reload. | At window start the log says `cannot watch the tree root=<cfg>/plugins` when the folder does not exist yet; after `link` created it, auto-reload worked. |
| Lens -> block | Verified | Inspector `Explore` badge -> `cx:open("kube-lens://explore?kind=pods&name=db-0")` -> `tern.log`: `route.link kube-lens://explore?... pane=4294967297` -> `explore.init ["kube-lens://explore?kind=pods&name=db-0"] pane=4294967299`; block opened as a split beside the lens pane. Screenshot `screenshots/m0-explore-block.png`. | |
| Unclaimed custom-scheme `cx:open` | Verified (hazard) | `route.link` returning nil for `kube-lens://...` -> `tern.log`: `the host failed a shell call call="open_url" error=no application could open kube-lens://explore?kind=pods&name=db-0`, and macOS showed a system dialog "There is no application set to open the URL ..." on the user's screen. | Any lens `cx:open` of `kube-lens://` must be claimed by the window half or the user sees an OS dialog. See design consequences. |
| Palette command -> block | Verified | `plugins run plugin.kube-lens.explore` -> `cx:new_block("kube-lens.explore", {"palette"}, "beside")` opened the block. | |
| Block keys | Verified | `key j`, `key j`, `key down`, `key k` -> `explore.key {"name":"j","text":"j",...}`, `{"name":"down"}`; `.sf-item.sel` moved. `escape` -> `cx:exit(0)` closed the pane. | Return `false` for unused keys. |
| Block input + focus | Verified | `/` -> `cx:frame({{"focus","main.query"}})`; `tree` shows `.sf-input.focused` text `/db`; typed `d`,`b` arrive as keys and the program owns the text. | Input id is `main.<key>` for a direct child of the `main` root `col`. |
| Process run (host) | Verified | Explore block ran `{kubectl, get, pods, -o, json}` via `tern.process.run(argv, {timeout_ms, cwd}, cb)`: `status=0 stdout_bytes=3928 took_ms=35`; `cx:render()` in the callback redrew (`6 pods`). | No streaming, no kill handle. |
| Process timeout | Verified | `{"sleep","5"}` with `timeout_ms=500` -> `status=-1 timed_out=true`. | Only `timeout_ms` stops a process; "cancel" = ignore the late callback (generation/stopped flag). |
| Daemon env / PATH | Verified | Daemon `tern.getenv`: `PATH=/opt/homebrew/bin:...:/usr/local/bin:...` (window launch env), `KUBECONFIG=nil`, `SHELL=/bin/zsh`, `TERN_PLUGIN_DATA=nil` (only set for children). Bare `kubectl` resolved to the host's real `/usr/local/bin/kubectl`. `{"$SHELL","-lc","command -v kubectl"}` -> `/usr/local/bin/kubectl`. | The daemon PATH is not the shell PATH and KUBECONFIG/context can differ from the user's shell. Explore resolves the binary via kv `kubectl`, then `KUBE_LENS_KUBECTL`, then `kubectl`; the user's effective kubeconfig/context must be passed explicitly (M1+). |
| Liveness | Verified | Timer polling `tern.pane.list()` logged `explore pane gone 4294967319` ~2 s after `close`. | No block-closed callback. |
| fs / spool | Verified | Approve block wrote `<data>/spool/resp-<nonce>.json` = `{"at":...,"decision":"approve","nonce":"..."}` with `tern.fs.write`; host created `<data>/spool` with `tern.fs.mkdir`. `tern.plugin.data` = `/tmp/kl-tern/cfg/plugin-data/kube-lens`. | Paths arrive canonicalized (`/private/tmp/...`) from `tern open`. |
| kv | Verified | An externally written `<data>/kv.json` `{"kubectl": "<repo>/tests/bin/kubectl"}` was read by `tern.kv.get("kubectl")` in the host. | Plain JSON file; usable by tests and a settings flow. |
| JSON | Verified | `tern.json.decode` of fixture `-o json`; `tern.json.encode` used for logs and responses (keys sorted). `tern.parse.json_tree` exists and returns a `tree` node. | |
| YAML | Unsupported | `type(tern.yaml)` -> `nil` at runtime. | Use `-o json`, or parse YAML in Luau. |
| `tern.parse.columns` | Verified | Returns `{"head":["NAME","READY","STATUS"],"rows":[["a","1/1","Running"],...]}`. | Host-only; `plugin/lib/parse/table.luau` (M1) is a pure span-based equivalent that keeps cells like `2 (5h ago)` whole. |
| Timers | Verified | `tern.timer(2000, tick)` re-armed for liveness polling. | One slow timer callback disables timers for the VM (docs). |
| Pre-exec veto | Unsupported | `tern.on("command_started", fn)` returning `false` logged `{"cwd":...,"line":"kubectl get pods","pane":...}` and the command still ran (`command_finished status=0 took_ms=22`). | Mutation guard must be a shell wrapper (decision). |
| Guard transport: `tern open --wait` | Verified | In a pane: `tern open --wait <spool>/req-<nonce>.json` -> window `route.open <path> origin=cli how=beside` -> `{block="kube-lens.approve", args={path}}`; Approve/Deny buttons fire `{"act":"decide","value":"approve","id":"main.buttons.approve"}`; response file written; `cx:exit(0)` closed the pane; shell printed `RC=0 WAITED=17s` (blocks until the block exits, no timeout). Screenshot `screenshots/m0-approve-block.png`. | Decision travels only in the response file: `tern open` returned `RC=0` for a block that called `cx:exit(3)`, and a non-zero exit left a "Shell exited with 3" sheet that kept `--wait` blocked until closed by hand (37 s). Approve therefore always exits 0. |
| Guard: path the route does not claim | Verified | `tern open --wait /tmp/kl-spike/other.json` -> `route.open ... origin=cli` returned nil -> built-in file block opened; `--wait` blocked until it was closed; `RC=0 WAITED=8s`. | If the plugin is not loaded, the wrapper's request file opens in an editor block and `--wait` still returns 0: the wrapper must verify `resp-<nonce>.json` and fail closed when it is missing. |
| Guard: `tern open` from outside a Tern pane | Verified (with sandbox env) | From a non-Tern process with only `TERN_CONFIG_DIR`/`TERN_DAEMON_SOCKET` set (no `TERN_PANE`, no `TERM_PROGRAM`): the route ran (`origin=cli`), the approve block opened beside the window's focused pane, approval returned `rc=0` after 8.5 s. | Any process that can reach the daemon can raise an approval in the window, possibly unnoticed. The wrapper must require `TERM_PROGRAM=tern` and `TERN_PANE` and refuse otherwise. |
| Guard: no Tern / no window | Unverified | Not run: `tern open --help` says "With no Tern running it starts one", which could launch or target the user's real Tern. | Wrapper refuses outside a Tern pane before calling `tern open`; a missing response file is a refusal. |
| Pane env | Verified | Pane env: `TERM_PROGRAM=tern`, `TERM_PROGRAM_VERSION=0.6.2`, `TERN_PANE=4294967309`, `TERN_PANE_SOCKET=<daemon sock>`, `TERN_LENSES=1`, `TERN_WINDOW_KEY=` (empty), `TERN_WINDOW_SOCKET=` (empty), plus the window's launch env (`TERN_CONFIG_DIR`, `TERN_DAEMON_SOCKET`). | `TERN_LENSES=1` tells a wrapper that lenses are on. |
| Spawn env injection | Verified | `tern.on("spawn", ...)` setting `spec.env.KUBE_LENS_SPOOL`; a new tab's shell printed `SPOOL=/tmp/kl-tern/cfg/plugin-data/kube-lens/spool`. Shells started before the plugin loaded do not have it. | `TERN_BLOB_DIR` in the spawn env points at `~/Library/Caches/Tern/blobs` even in the sandbox. |
| Node shapes / pure builders | Verified | `tern.json.encode` of builders: `text` = `{"k":"text","p":{"spans":[{"s":"muted","t":"a"},{"t":"b"}]}}`; `badge` = `{"k":"badge","p":{"text":"x","tone":"error"}}`; `col`/`row` add `p.gap="sm"`; `kv` = `{"k":"kv","p":{"items":[{"k":[spans],"v":[spans]}]}}`; `table` fills col defaults and row ids `r0..`; `list` = `{"k":"list","c":[{"k":"item","p":{label/detail/value as spans}}]}`; `el` = `{"k":"el","p":{"tag":"td","text":"t","class":"c"},"c":[...]}`; `overflow(3)` = muted text `… 3 more (Raw shows everything)`. `encode(ui.node("item",{label="x"})) == encode({k="item",p={label="x"}})` -> `true`. Plain `{k,p,c}` tables built in Luau rendered identically in the lens (grid mode). | `plugin/lib/ui.luau` builds these without the `tern` global. |
| Performance | Verified | See "Performance" below. | |
| Screenshots of the real window | Verified | `tern ctl --control <ctl> shot NAME` -> `{"png":"target/shots/tern/live/NAME.png","size":[2560,1600]}` relative to the window's cwd; PNGs show the plugin view. | |
| Headless `tern shot` | Verified (no user plugins) | `tern shot headless.txt --out ...` with `TERN_CONFIG_DIR` = sandbox (kube-lens linked) ran a real shell and rendered the built-in `kubectl get` table, not the plugin view. | CI cannot screenshot the plugin headlessly; use the real-window `--control` path. |
| Scripted testing | Verified | `ready`, `run`, `expect` (grid text only), `plugins expect` (surfaces incl. lens views), `plugins run plugin.kube-lens.explore`, `click`, `key`, `type`, `tab new`, `focus left`, `close`, `scroll`, `state`, `tree`, `dump`, `shot`, `quit`. | `ctl` joins words: quote scenario strings (`run '"cmd"'`). `expect` does not see lens views; use `plugins expect`. |
| Settings (`command_lenses`) | Verified (default) | No `settings.json` in the sandbox; lenses fired and panes report `TERN_LENSES=1`. | Not toggled. Plugin settings: none in the manifest; kv/config file. |
| Sandbox lifecycle | Verified | `dev-tern.sh start` (named service), `link` (`kube-lens 0.0.1 Kube Lens — 2 blocks, 1 lenses, window ready`), `reload`, `list`, `ctl`, `stop` (`ctl quit`; the daemon stopped with the window, no processes left), `env`, refusal of sandboxes outside `/tmp` (exit 2). `clean` = `stop` + `rm -rf <sandbox>` (not run, sandbox kept). | `(cmd &)` from a one-shot shell dies; run `start` under a persistent service or terminal. |

## Captures in detail

- `kubectl get pods -w` (fake prints 4 lines, sleeps): while running, the block
  shows the raw lines live; the lens received no rows until Ctrl-C
  (`key ctrl+c`), then `finish status=130 lines=5` with a trailing `^C` line.
  A watch view only becomes native when the watch ends.
- Lines arrive in batches: a 1000-row output produced a single `view` call,
  at finish.
- Empty stdout and stderr-only output: `view` returns nil and the block shows
  the raw text (nothing, or the error line).

## Performance (in-plugin `os.clock`, Apple M5)

| Fixture | parse | sort | view total | Notes |
| --- | --- | --- | --- | --- |
| 6 rows | 0.06 ms | 0 | 0.25 ms (plain tables) / 1.9-3.3 ms (builders) | |
| 100 rows | 0.45 ms | 0 | 17.2 ms | `tern.ui.el`/`text` builders |
| 1000 rows | 3.7-6.2 ms | 4.9-5.5 ms | 156-174 ms | builders |
| 1000 rows | 4.5-5.7 ms | 5.5 ms | 45-54 ms | plain `{k,p,c}` tables |

- `line` callbacks for 1000 lines: 0.08 ms total.
- Micro-benchmark, 5000 `el`+`text` nodes: builders 59.6 ms, plain tables
  1.25 ms (about 50x).
- A 1000-row el grid mounts about 13.9k elements (not virtualized); the view
  caps rows at 500 with an overflow line.

## Design consequences

1. **Tables are `el` CSS grids built from plain tables.** The `table` kind
   has no row actions and `el` tables ignore `colspan`; a `display:grid` of
   `el` divs with `display:contents` rows gives aligned columns, clickable
   rows and a full-width inline inspector. Render modules in `plugin/lib`
   build `{k,p,c}` tables directly (pure Luau, testable, about 50x cheaper
   than builder calls).
2. **Every lens action carries the full view state** (`v=sort:STATUS;desc:1;open:db-0`),
   because a reload drops lens state and rehydration replays only the
   captured output.
3. **Lens views are pointer-only.** Keys, filter and search live in the
   Explore block (verified keys, `input` focus, list selection).
4. **Claims are broad, views are strict.** Globs over-claim (`kubectl -* get *`)
   and a claim suppresses the built-in lens even when `view` returns nil, so
   `view` re-checks the verb and output format and handles `-o json` itself.
5. **`kube-lens://` links must always be claimed.** An unclaimed `cx:open`
   of the private scheme falls through to macOS LaunchServices and shows a
   system error dialog. The window half registers `tern.route.link` at load
   and claims every `kube-lens://` URL; it must never return nil for the
   scheme (unknown paths still open the Explore block, which shows the URL).
   Residual risk: a host half loaded without a working window half (e.g.
   window-half load error). Proposed for M1: the window half writes a load
   marker that the lens checks before emitting the link, or the lens opens
   a path under `tern.plugin.data` instead of a URL so the fallback is a
   Tern file block, not an OS dialog (neither verified yet).
6. **Guard transport = spool file + `tern open --wait` + approve block,
   decision in the response file.** `tern open` exit status is meaningless
   for the decision; the block always exits 0; the wrapper verifies
   `resp-<nonce>.json` (nonce match) and fails closed when it is missing.
   The wrapper refuses outside a Tern pane (`TERM_PROGRAM=tern` and
   `TERN_PANE` set) because any process reaching the daemon can raise an
   approval. `--wait` has no timeout; the wrapper should impose one.
7. **Explore must not trust the daemon environment.** The daemon PATH found
   the host's real kubectl and has no `KUBECONFIG`; Explore resolves the
   binary from config (kv `kubectl`, `KUBE_LENS_KUBECTL`) and must pass the
   lensed command's context/namespace/kubeconfig explicitly.
8. **Watch commands are raw until they end.** `-w` output stays raw while
   running; the native view appears after Ctrl-C (status 130, trailing `^C`).
9. **Testing uses the real window.** Headless `tern shot` loads no user
   plugins; `tern --control` + `tern ctl` (`plugins expect`, `click`,
   `shot`) drives the plugin, with the fake kubectl first on PATH.
