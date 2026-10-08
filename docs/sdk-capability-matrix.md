# Tern SDK capability matrix (M0 + M2 quick actions)

Verified against Tern 0.6.2 (4b3ed42) on macOS arm64, 2026-10-08. M0 rows ran in an
isolated sandbox (`scripts/dev-tern.sh`, sandbox `/tmp/tk-tern`) with the
plugin in `plugin/` linked and the fake kubectl in `tests/bin/`. Evidence
quotes are from `tern ctl --control /tmp/tk-tern/ctl.sock ...` replies, the
sandbox logs (`tern-daemon.log` = host half, `tern.log` = window half) or
`tern ctl shot` PNGs.

The M2 quick-action rows (prefixed "Quick:") ran in sandbox `/tmp/tk-tern-qa`
(`TK_TERN_SANDBOX=/tmp/tk-tern-qa scripts/dev-tern.sh start`; panes get a
neutral zsh with `ZDOTDIR=<sandbox>/zsh` and `KUBECONFIG=.sandbox/kubeconfig`)
against kind cluster `tern-kube-dev` (context `kind-tern-kube-dev`) with the
toolbox from `tests/integration/manifests/qa/toolbox.yaml` (Deployment +
Service `tk-qa-shell` in `tern-test-mutate`, containers `web` (busybox httpd
on 8080) and `ticker`). Probes ran first in a throwaway plugin copy whose
window handler split with diagnostic commands; rows marked "real" were
repeated with the shipped `plugin/window.luau` +
`plugin/lib/actions/quick.luau` (links built by `Quick.encode`, opened from
the Explore block with `cx:open`).

Status: **Verified** (observed in this build), **Workaround** (the direct
capability is missing; the named substitute was observed working),
**Unsupported** (observed absent or not working), **Proposed** (design built
on verified pieces, the composition itself not exercised),
**Unverified** (not exercised, with the reason).

| Capability | Status | Evidence (Tern 0.6.2) | Notes / fallback |
| --- | --- | --- | --- |
| Built-in kubectl lens | Verified | With no plugin linked, `kubectl get pods` rendered a native table; lens role discovered via `dump ".sf-block[data-role^='...']"` is `lens.k8s.get`. Built-ins also claim `kubectl logs ...` (`lens.docker.logs`) and `kubectl get pods -o json` (`lens.k8s.describe`). Screenshot `screenshots/m0-builtin-k8s-get.png`. | Tern already ships a status-colored `kubectl get` table. tern-kube must add value beyond it (sort, inline inspector, Explore, guard). |
| Plugin claim beats built-in | Verified | Same commands after linking: role `lens.plugin.tern-kube.get`; `lens.open` logged in `tern-daemon.log`. | A plugin claim also suppresses the built-in when our `view` returns nil (raw shown, not the built-in). We therefore render `-o json` ourselves with `tern.parse.json_tree`. |
| Claim globs (`kubectl get`, `kubectl get *`, `kubecolor get`, `kubecolor get *`) | Verified | `lens.open` logged for `kubectl get pods`, `kubecolor get pods` (fake kubecolor), absolute path `/…/tests/bin/kubectl get pods` (`program=kubectl`), `command kubectl get pods`, `TKUBE_FAKE_ROWS=100 kubectl get pods`, `kubectl get pods 2>/dev/null`. Not claimed: `kubectl get pods > file`, `kubectl get pods \| cat`. | Matches docs: wrappers, `VAR=` prefixes, program dirs and stderr redirects are skipped; pipelines and stdout redirects are never lensed. |
| Global flags before the verb | Verified | `kubectl * get *` claimed `kubectl --context x -n y get pods` but also `kubectl describe pod get x` (false positive). Replaced by `kubectl -* get` / `kubectl -* get *`: claims `kubectl --context x -n y get pods` and `kubectl -n y get pods`; does not claim `kubectl logs get-thing` or `kubectl describe pod get x`; still claims `kubectl -n y logs pod get x`. | Globs cannot negate. The lens re-derives the verb from argv (`plugin/lib/kubectl/argv.luau`, M1) and `view` returns nil (raw) for verbs it does not render. Residual cost: such a false claim hides the built-in logs lens for that one command. |
| Aliases (`k get pods`) | Verified | With the user's zsh alias `k=kubectl`, `k get pods` was claimed: `lens.open kubectl get pods typed=k get pods`. | zsh reports the expanded line. bash/fish behavior not exercised (no fish installed); docs say globs see the typed line there. Default manifest claims no `k` forms (decision). |
| Lens lines / finish | Verified | 6-row fixture: `lens.finish status=0 lines=7`. stderr-only `kubectl get pods missing`: `status=1 lines=1` (stderr is in-stream). Empty output `kubectl get secrets`: `status=0 lines=0`, view nil, nothing drawn. | `finish` status is a number. Ctrl-C of a watch: `status=130`, and the last line is `^C` (the parser drops it). |
| Lens view / native table | Verified | `plugins expect '"CrashLoopBackOff"'` -> `{"ok":true}`; `tree` shows `.sf-block-body > ... .tk-grid` with one `.tk-h` per column and `.tk-r` rows. Screenshot `screenshots/m0-lens-table.png`. | |
| Raw toggle | Verified | `click ".tv-block:last-child .sf-block-opt:nth-child(2)"` -> segment shows `Raw` on and the original text; clicking `Native` restored the plugin view with its last state (no event, no rehydration). | Built-in per block; no API to drive or read it. |
| Lens click actions (sort) | Verified | `click ".tk-grid th:nth-child(3)"` -> `lens.event {"act":"v","ev":"action","id":"b.n17","sf":"lens10","value":"mode:el;sort:STATUS"}` then re-`view`; row order changed (`tree ".tk-grid tbody tr"`). | Event ids (`b.n17`) are not stable across views; payload must live in the action name (`v=sort:STATUS;open:db-0`). |
| Clickable rows: `table` node with per-row `actions` | Unsupported | Rows with `actions` rendered, clicking a row cell fired only the table node's action: `{"act":"table-click","ev":"action","id":"b.n12"}` with no row info. | Docs agree: table rows are data, not nodes. |
| Clickable rows: `list`/`item` | Verified (rejected for tables) | Item `actions` fired `{"act":"v",...,"value":"...open:cache-6b7c8d9e0-abcde"}`; a non-item node inserted after the item rendered as an inline inspector. Screenshot `screenshots/m0-rejected-list-rows.png`. | No column alignment (detail is one joined string). Good for the Explore block, not for tables. |
| Clickable rows: `el` HTML table | Workaround (partial) | `tr` with `actions` is clickable (`.sf-act`), `th` sort works. `attrs={colspan=5}` (number or string) is ignored: inspector `td` rect `[26,214,523.28,124]` equals the first column's width. | Inline inspector cannot span the row. |
| Clickable rows: `el` div CSS grid (chosen) | Verified | `div.tk-grid.tk-cols-N` (`display:grid`), rows `div.tk-r{display:contents}` carrying `actions`, cells `div.tk-c`, inspector `div.tk-insp{grid-column:1/-1}`. Clicking a cell (`click 100 203`) fired the row action; inspector rect `[26,214,1238,124]` = full width. Screenshot `screenshots/m0-lens-inspector.png`. | Clicks on a `display:contents` row's cells reach the row's action. Column template classes are defined in `plugin/tern-kube.css` for 1..12 columns. |
| `tern ctl` selectors for clicks | Verified | CSS selectors work: `click ".tk-grid .tk-h:nth-child(3)"`, `click "[data-surface='plugin.tern-kube.approve'] .tk-btn:nth-child(1)"`; coordinates: `click 100 203`; modifiers after the selector. `tree SEL` returns `{"nodes":[{tag,class,text,rect}]}`; attributes such as `data-role` are not printed but match in selectors. | `hover X Y` is not accepted (`bad selector`). Hidden tabs' DOM also matches selectors; scope with `.tv-block:last-child`. |
| Keys in a lens | Unsupported | `key j`, `type abc` after clicking the lens: reply `focused: textarea.tv-input` (the terminal); no lens event. | Keyboard navigation needs a block. |
| Text input in a lens | Unsupported | An `input` node renders in a lens; clicking it sends `{"ev":"focus","id":"b.n13","sf":"lens12"}` to `event`, but typed text goes to the shell prompt. | Filter/search live in the Explore block. |
| Rehydration after reload | Verified | After `dev-tern.sh reload`, a header click on an old lens block logged `lens.open kubectl get pods` -> `lens.view lines=7` (lines replayed) -> view shows `6 rows · sorted by NAME`; an earlier run logged `lens.open` -> `lens.finish` -> `lens.event` -> `lens.view` with the state from the action value. | `open/line/finish` must stay side-effect free. Running blocks (Explore) are not re-initialized by a reload; their timers and pending callbacks are dropped. |
| Plugin auto-reload on save | Verified | Saving a broken `host.luau` logged `plugin failed to load ... host.luau:225: Expected identifier`; saving fixes reloaded without `tern plugin reload`. Manifest `styles` CSS changes applied on reload. | At window start the log says `cannot watch the tree root=<cfg>/plugins` when the folder does not exist yet; after `link` created it, auto-reload worked. |
| Lens -> block | Verified | Inspector `Explore` badge -> `cx:open("tern-kube://explore?kind=pods&name=db-0")` -> `tern.log`: `route.link tern-kube://explore?... pane=4294967297` -> `explore.init ["tern-kube://explore?kind=pods&name=db-0"] pane=4294967299`; block opened as a split beside the lens pane. Screenshot `screenshots/m0-explore-block.png`. | |
| Lens action value with `=` and `&` (quick-action chips, M2) | Verified | Inspector chip `actions = { click = "act=tern-kube://act/shell?kind=Pod&name=tk-qa-shell-...&namespace=tern-test-mutate" }`: the lens `event` got `act="act"` and the whole URL as `value` (split at the first `=`); `cx:open(value)` -> `tern.log` `route.link tern-kube://act/shell?kind=Pod&name=tk-qa-shell-5f6b8bff9b-djlsb&namespace=tern-test-mutate` -> `quick action shell ... pane=7`; the split's interactive shell echoed typed input (e2e `16-quick-actions`). | The host decodes the value with `Quick.decode` before `cx:open` and drops anything else, so no unvalidated URL reaches the window. |
| Unclaimed custom-scheme `cx:open` | Verified (hazard) | `route.link` returning nil for `tern-kube://...` -> `tern.log`: `the host failed a shell call call="open_url" error=no application could open tern-kube://explore?kind=pods&name=db-0`, and macOS showed a system dialog "There is no application set to open the URL ..." on the user's screen. | Any lens `cx:open` of `tern-kube://` must be claimed by the window half or the user sees an OS dialog. See design consequences. |
| Palette command -> block | Verified | `plugins run plugin.tern-kube.explore` -> `cx:new_block("tern-kube.explore", {"palette"}, "beside")` opened the block. | |
| Block keys | Verified | `key j`, `key j`, `key down`, `key k` -> `explore.key {"name":"j","text":"j",...}`, `{"name":"down"}`; `.sf-item.sel` moved. `escape` -> `cx:exit(0)` closed the pane. | Return `false` for unused keys. |
| Block input + focus | Verified | `/` -> `cx:frame({{"focus","main.query"}})`; `tree` shows `.sf-input.focused` text `/db`; typed `d`,`b` arrive as keys and the program owns the text. | Input id is `main.<key>` for a direct child of the `main` root `col`. |
| Process run (host) | Verified | Explore block ran `{kubectl, get, pods, -o, json}` via `tern.process.run(argv, {timeout_ms, cwd}, cb)`: `status=0 stdout_bytes=3928 took_ms=35`; `cx:render()` in the callback redrew (`6 pods`). | No streaming, no kill handle. |
| Process timeout | Verified | `{"sleep","5"}` with `timeout_ms=500` -> `status=-1 timed_out=true`. | Only `timeout_ms` stops a process; "cancel" = ignore the late callback (generation/stopped flag). |
| Daemon env / PATH | Verified | Daemon `tern.getenv`: `PATH=/opt/homebrew/bin:...:/usr/local/bin:...` (window launch env), `KUBECONFIG=nil`, `SHELL=/bin/zsh`, `TERN_PLUGIN_DATA=nil` (only set for children). Bare `kubectl` resolved to the host's real `/usr/local/bin/kubectl`. `{"$SHELL","-lc","command -v kubectl"}` -> `/usr/local/bin/kubectl`. | The daemon PATH is not the shell PATH and KUBECONFIG/context can differ from the user's shell. Explore resolves the binary via kv `kubectl`, then `TKUBE_KUBECTL`, then `kubectl`; the user's effective kubeconfig/context must be passed explicitly (M1+). |
| Liveness | Verified | Timer polling `tern.pane.list()` logged `explore pane gone 4294967319` ~2 s after `close`. | No block-closed callback. |
| fs / spool | Verified | Approve block wrote `<data>/spool/resp-<nonce>.json` = `{"at":...,"decision":"approve","nonce":"..."}` with `tern.fs.write`; host created `<data>/spool` with `tern.fs.mkdir`. `tern.plugin.data` = `/tmp/tk-tern/cfg/plugin-data/tern-kube`. | Paths arrive canonicalized (`/private/tmp/...`) from `tern open`. |
| kv | Verified | An externally written `<data>/kv.json` `{"kubectl": "<repo>/tests/bin/kubectl"}` was read by `tern.kv.get("kubectl")` in the host. | Plain JSON file; usable by tests and a settings flow. |
| JSON | Verified | `tern.json.decode` of fixture `-o json`; `tern.json.encode` used for logs and responses (keys sorted). `tern.parse.json_tree` exists and returns a `tree` node. | |
| YAML | Unsupported | `type(tern.yaml)` -> `nil` at runtime. | Use `-o json`, or parse YAML in Luau. |
| `tern.parse.columns` | Verified | Returns `{"head":["NAME","READY","STATUS"],"rows":[["a","1/1","Running"],...]}`. | Host-only; `plugin/lib/parse/table.luau` (M1) is a pure span-based equivalent that keeps cells like `2 (5h ago)` whole. |
| Timers | Verified | `tern.timer(2000, tick)` re-armed for liveness polling. | One slow timer callback disables timers for the VM (docs). |
| Pre-exec veto | Unsupported | `tern.on("command_started", fn)` returning `false` logged `{"cwd":...,"line":"kubectl get pods","pane":...}` and the command still ran (`command_finished status=0 took_ms=22`). | Mutation guard must be a shell wrapper (decision). |
| Guard transport: `tern open --wait` | Verified | In a pane: `tern open --wait <spool>/req-<nonce>.json` -> window `route.open <path> origin=cli how=beside` -> `{block="tern-kube.approve", args={path}}`; Approve/Deny buttons fire `{"act":"decide","value":"approve","id":"main.buttons.approve"}`; response file written; `cx:exit(0)` closed the pane; shell printed `RC=0 WAITED=17s` (blocks until the block exits, no timeout). Screenshot `screenshots/m0-approve-block.png`. | Decision travels only in the response file: `tern open` returned `RC=0` for a block that called `cx:exit(3)`, and a non-zero exit left a "Shell exited with 3" sheet that kept `--wait` blocked until closed by hand (37 s). Approve therefore always exits 0. |
| Guard: path the route does not claim | Verified | `tern open --wait /tmp/tk-spike/other.json` -> `route.open ... origin=cli` returned nil -> built-in file block opened; `--wait` blocked until it was closed; `RC=0 WAITED=8s`. | If the plugin is not loaded, the wrapper's request file opens in an editor block and `--wait` still returns 0: the wrapper must verify `resp-<nonce>.json` and fail closed when it is missing. |
| Guard: `tern open` from outside a Tern pane | Verified (with sandbox env) | From a non-Tern process with only `TERN_CONFIG_DIR`/`TERN_DAEMON_SOCKET` set (no `TERN_PANE`, no `TERM_PROGRAM`): the route ran (`origin=cli`), the approve block opened beside the window's focused pane, approval returned `rc=0` after 8.5 s. | Any process that can reach the daemon can raise an approval in the window, possibly unnoticed. The wrapper must require `TERM_PROGRAM=tern` and `TERN_PANE` and refuse otherwise. |
| Guard: no Tern / no window | Unverified | Not run: `tern open --help` says "With no Tern running it starts one", which could launch or target the user's real Tern. | Wrapper refuses outside a Tern pane before calling `tern open`; a missing response file is a refusal. |
| Pane env | Verified | Pane env: `TERM_PROGRAM=tern`, `TERM_PROGRAM_VERSION=0.6.2`, `TERN_PANE=4294967309`, `TERN_PANE_SOCKET=<daemon sock>`, `TERN_LENSES=1`, `TERN_WINDOW_KEY=` (empty), `TERN_WINDOW_SOCKET=` (empty), plus the window's launch env (`TERN_CONFIG_DIR`, `TERN_DAEMON_SOCKET`). | `TERN_LENSES=1` tells a wrapper that lenses are on. |
| Spawn env injection | Verified | `tern.on("spawn", ...)` setting `spec.env.TKUBE_SPOOL`; a new tab's shell printed `SPOOL=/tmp/tk-tern/cfg/plugin-data/tern-kube/spool`. Shells started before the plugin loaded do not have it. | `TERN_BLOB_DIR` in the spawn env points at `~/Library/Caches/Tern/blobs` even in the sandbox. |
| Node shapes / pure builders | Verified | `tern.json.encode` of builders: `text` = `{"k":"text","p":{"spans":[{"s":"muted","t":"a"},{"t":"b"}]}}`; `badge` = `{"k":"badge","p":{"text":"x","tone":"error"}}`; `col`/`row` add `p.gap="sm"`; `kv` = `{"k":"kv","p":{"items":[{"k":[spans],"v":[spans]}]}}`; `table` fills col defaults and row ids `r0..`; `list` = `{"k":"list","c":[{"k":"item","p":{label/detail/value as spans}}]}`; `el` = `{"k":"el","p":{"tag":"td","text":"t","class":"c"},"c":[...]}`; `overflow(3)` = muted text `… 3 more (Raw shows everything)`. `encode(ui.node("item",{label="x"})) == encode({k="item",p={label="x"}})` -> `true`. Plain `{k,p,c}` tables built in Luau rendered identically in the lens (grid mode). | `plugin/lib/ui.luau` builds these without the `tern` global. |
| Quick: `route.link` split (1) | Verified | `route.link` calls `cx.layout:split(link.pane, dir, {command = ...})` and returns `{handled = true}`; handler time around the split (os.clock): 0.044-0.078 ms, first call 1.58 ms, within the 50 ms budget. `split` returns the new pane id and focuses it. Real: `tern-kube quick action shell ... pane=33`. | |
| Quick: `split` on an unknown pane (1a) | Verified | `split(999999, "right", ...)` -> nil, no error. | The window copies the command and toasts (fallback). |
| Quick: `split` with an invalid direction (1b) | Verified (raises) | `unknown direction 'sideways' (right, down, left or up)`. | |
| Quick: `route.link` handler that raises (1c) | Verified (hazard) | Log: `plugin handler failed hook="route.link"` followed by `open_url ... no application could open tern-kube://...`. | The URL falls through to the OS; the window wraps quick actions in pcall and always returns `{handled = true}`. |
| Quick: `cx.layout:new_tab({command = ...})` (1d) | Verified | Placement `tab` opened a new tab titled by the action (real, config-driven). | |
| Quick: placement `down` (1e) | Verified | Real, config `quick_actions.placement = "down"`: the Explore pane and the new pane share a Column split. | Config is re-read per link (`config_host.load()`); changing the file needs no reload. |
| Quick: shell running `Launch.command` (2) | Verified | `ps`: `/bin/zsh -l -c printf ...`, parent `tern daemon --socket /tmp/tk-tern-qa/d.sock`. `$-` = `569Xl` (login, not interactive). | `$SHELL -l -c <command>`. |
| Quick: split environment (2a) | Verified | `KUBECONFIG` = sandbox kubeconfig (set in the sandbox `.zshenv`); `TKUBE_KUBECTL` (set only in the sandbox `.zshrc`) empty; a marker exported in the window's own environment (`TKQA_MARK`) empty. `PATH` = path_helper login PATH (`/usr/local/bin:...:/opt/homebrew/bin:/Applications/Tern.app/Contents/MacOS`); `TERN_PANE` = new pane id; cwd = the originating pane's directory. | Daemon environment + login rc files, NOT the interactive rc. A `KUBECONFIG` exported only in `.zshrc`/`.bashrc` does not reach the split. |
| Quick: user shell independence (2b) | Verified (zsh, bash) | The same line under `/bin/zsh -c` and `/bin/bash -c` with a fake kubectl printing argv: identical argv, including a context `it's $(id) \`x\`; y` and kubeconfig `/tmp/a b/c'd` (no expansion). | Every line is `sh -c '<script>'`. fish not installed; the outer line is a single word with POSIX `'\''` escapes, which fish also parses (not executed). |
| Quick: command exits 0 (3) | Verified | Env probe (exit 0) and `exit` from the pod shell: pane removed within ~2 s. | Pane closes by itself. |
| Quick: command exits non-zero (3a) | Verified | `exit 3`: sheet "Shell exited with 3" with Restart / Close (Cmd+W) and an inbox notification; `tern ls` shows `exited: 3`. Ctrl+C on `logs -f` left `exited: 1`. A port-forward whose local port is taken exits 1 with kubectl's `address already in use` visible; Restart re-runs the same line. | Pane stays with an exit sheet. |
| Quick: pane title (3b) | Verified | `tern ls` title: `tern-kube shell tern-test-mutate/tk-qa-shell-...:web @ kind-tern-kube-dev`. | OSC 0 from the script sets it; the tab chip shows the first word of the command (`sh`/`printf`), not the OSC title. |
| Quick: `link.pane` from a lens (4) | Verified | Lens on pane 5, row inspector "Explore live" -> `link.pane=5`. | `EffectCx:open` from a lens event: the pane holding the lensed command. |
| Quick: `link.pane` from a block (4a) | Verified | Explore block `cx.pane=13` -> `link.pane=13` (also for every real quick action). | `BlockCx:open`: the block's pane. |
| Quick: `kubectl exec -it` in the split (5) | Verified | Real: `kubectl exec -it --kubeconfig <sandbox> --context kind-tern-kube-dev -n tern-test-mutate <pod> -c web -- sh -c 'command -v bash ... \|\| exec sh'`; typed `echo ok-from-split; hostname` -> `ok-from-split`, `tk-qa-shell-5f6b8bff9b-djlsb`; `exit` closed the pane. | Shell on the Deployment through the resolved pod prints kubectl's `Defaulted container "web" out of: web, ticker`. |
| Quick: `kubectl logs -f` in a split (6) | Verified | Real, unpinned context: first line `tern-kube: context kind-tern-kube-dev`, then `[pod/<pod>/ticker] ticker: tick N` / `[pod/<pod>/web] ...` streaming (`-l app=tk-qa-shell --prefix --all-containers --max-log-requests=10`). | Pod logs without a container use `--all-containers --prefix`. |
| Quick: `kubectl port-forward` in a split (6a) | Verified | Real `svc/tk-qa-shell` port 80 -> `Forwarding from 127.0.0.1:8080 -> 8080`; `curl http://127.0.0.1:8080/index.html` -> `tk-qa-ok` (also from another Tern pane). Deployment without a known port: the script resolved the first declared port (8080) at run time. After closing the panes, curl failed to connect and no `port-forward` process remained. | Closing the pane stops it. |
| Quick: mutating actions in M2 (6b) | Verified (refused) | Real: debug-pod link -> toast "Tern Kube: Debug needs confirmation (coming in M3)", no pane. | |
| Quick: invalid links (6c) | Verified (refused, claimed) | `name=x%3Breboot` -> toast "invalid quick action: name must be a DNS-1123 subdomain"; `act/rm` -> "unknown action \"rm\"". No OS fallthrough in the log. | |
| Quick: remote (ssh) hosts, fish login shell | Unverified | Not exercised: the split would run on the pane's host while the window reads its own config file; fish not installed. | |
| Performance | Verified | See "Performance" below. | |
| Screenshots of the real window | Verified | `tern ctl --control <ctl> shot NAME` -> `{"png":"target/shots/tern/live/NAME.png","size":[2560,1600]}` relative to the window's cwd; PNGs show the plugin view. | |
| Headless `tern shot` | Verified (no user plugins) | `tern shot headless.txt --out ...` with `TERN_CONFIG_DIR` = sandbox (tern-kube linked) ran a real shell and rendered the built-in `kubectl get` table, not the plugin view. | CI cannot screenshot the plugin headlessly; use the real-window `--control` path. |
| Scripted testing | Verified | `ready`, `run`, `expect` (grid text only), `plugins expect` (surfaces incl. lens views), `plugins run plugin.tern-kube.explore`, `click`, `key`, `type`, `tab new`, `focus left`, `close`, `scroll`, `state`, `tree`, `dump`, `shot`, `quit`. | `ctl` joins words: quote scenario strings (`run '"cmd"'`). `expect` does not see lens views; use `plugins expect`. |
| Settings (`command_lenses`) | Verified (default) | No `settings.json` in the sandbox; lenses fired and panes report `TERN_LENSES=1`. | Not toggled. Plugin settings: none in the manifest; kv/config file. |
| Sandbox lifecycle | Verified | `dev-tern.sh start` (named service), `link` (`tern-kube 0.0.1 Tern Kube — 2 blocks, 1 lenses, window ready`), `reload`, `list`, `ctl`, `stop` (`ctl quit`; the daemon stopped with the window, no processes left), `env`, refusal of sandboxes outside `/tmp` (exit 2). `clean` = `stop` + `rm -rf <sandbox>` (not run, sandbox kept). | `(cmd &)` from a one-shot shell dies; run `start` under a persistent service or terminal. |

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
5. **`tern-kube://` links must always be claimed.** An unclaimed `cx:open`
   of the private scheme falls through to macOS LaunchServices and shows a
   system error dialog. The window half registers `tern.route.link` at load
   and claims every `tern-kube://` URL; it must never return nil for the
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
   binary from config (kv `kubectl`, `TKUBE_KUBECTL`) and must pass the
   lensed command's context/namespace/kubeconfig explicitly.
8. **Watch commands are raw until they end.** `-w` output stays raw while
   running; the native view appears after Ctrl-C (status 130, trailing `^C`).
9. **Testing uses the real window.** Headless `tern shot` loads no user
   plugins; `tern --control` + `tern ctl` (`plugins expect`, `click`,
   `shot`) drives the plugin, with the fake kubectl first on PATH.
10. **Quick actions are one POSIX `sh -c '<script>'` line.** `Launch.command`
    runs `$SHELL -l -c <line>` (login, non-interactive: only login rc files
    are read), so the line is a single word with POSIX quoting and the
    script runs in `sh`, independent of the user's zsh/bash/fish.
11. **Exit status drives the pane.** Exit 0 closes the pane; non-zero
    leaves an exit sheet with Restart (re-runs the same line). Ctrl+C on
    `logs -f` exits 1 and leaves the sheet; a port-forward stops when its
    pane closes.
12. **Splits open beside the origin.** `link.pane` is the lensed command's
    pane for lens-opened links and the block's pane for block-opened links,
    so `split(link.pane, ...)` places the action next to where it was
    clicked. An unknown pane makes `split` return nil: copy the command and
    toast.
13. **`route.link` must pcall and always return `{handled = true}`** (row
    1c): a raising handler falls through to the OS "no application" dialog
    just like an unclaimed link.
14. **Pin the cluster, do not trust the split's env.** A `KUBECONFIG`
    exported only in the interactive rc (`.zshrc`/`.bashrc`) does not reach
    the split. Actions pin `--kubeconfig`/`--context` when known, otherwise
    print the effective context first (`tern-kube: context ...`). An opt-in
    KUBECONFIG capture is planned for M3 with the shell activation snippet.
15. **Responsive layout uses window-width media queries.** `@container`
    queries are rejected in plugin style sheets and a lens cannot know its
    pane width (lens view callbacks get no cols; only blocks get `cx.cols`).
    `plugin/tern-kube.css` hides column priority tiers (`tk-p3`, then `p2`,
    then `p1`) with `@media (max-width: 1000px | 760px | 520px)`, which
    compare to the window: a narrow split of a wide window only shrinks long
    cells.
