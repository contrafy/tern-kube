# Upstream opportunities (Tern SDK)

SDK gaps observed while building tern-kube against Tern 0.6.2 (4b3ed42),
each checked again against Tern 0.9.8 (pinned types `78ba204` and the 0.9
docs, 2026-11-02): all ten are still open. Items 11-13 come from the logs
lens and events timeline (0.3.0, Tern 0.9.8), item 14 from the Explore block
(0.4.0, Tern 0.9.8), items 15-17 from remote hosts (0.5.0, Tern 0.9.8 window,
0.9.10 host). Tern 0.9.14 (types `a933069`, 2026-11-10) resolves item 8 in
the types; items 18-19 are new on 0.9.14.
Evidence is in `docs/sdk-capability-matrix.md`; each item lists the impact,
the current workaround and a minimal reproduction. Anything not directly
observed is marked `[not observed]`.

## 1. Pre-exec veto hook

- Impact: a plugin cannot stop a command (e.g. a mutating `kubectl`) before it runs.
- Workaround: the mutation guard is a shell wrapper using `tern open --wait`.
- Tern 0.9.8: still open, checked against 0.9.8. The hook list is unchanged,
  `command_started` is a notification, and `tern.override` covers only
  built-in command ids.
- Reproduction:

  ```luau
  tern.on("command_started", function(ev) return false end)
  ```

  Run `kubectl get pods`: the hook logs the line and the command still runs
  (`command_finished status=0`).

## 2. Lens keyboard and text input

- Impact: lens views are pointer-only; no filter/search or key navigation in a lens.
- Workaround: keys, filter and search live in the Explore block.
- Tern 0.9.8: still open, checked against 0.9.8. `LensDef` is unchanged;
  the new `features` (native editing) exists only on `BlockDef`.
- Reproduction: render an `input` node in a lens view, click it (the lens gets
  `{"ev":"focus",...}`), then `tern ctl key j` / `type abc`: reply
  `focused: textarea.tv-input` and the text goes to the shell prompt.

## 3. Lens pane width / CSS container queries

- Impact: lens tables cannot adapt to the pane width; a narrow split of a wide window keeps all columns.
- Workaround: `@media (max-width: ...)` tiers in `plugin/tern-kube.css`, which compare to the window width.
- Tern 0.9.8: still open, checked against 0.9.8. `@container` is still
  rejected, `@media` still compares to the window, and a lens `view` still
  gets no cols.
- Tern 0.9.14: still open, checked live: `@container` is a parse error
  ("unsupported at-rule"). A narrow split therefore cannot stand in for a
  narrow window in e2e, and `ctl resize`/`ctl size` resize the real window,
  which a tiling window manager (OmniWM) keeps in its tile; e2e 13 falls back
  to checking the narrow column tier classes.
- Reproduction: add `@container (max-width: 500px) { .x { display: none } }` to a
  manifest `styles` sheet (rejected); log the arguments of a lens `view`
  callback (no cols; only blocks get `cx.cols`).

## 4. `tern open --wait` exit status

- Impact: the caller cannot read a block's decision from the exit status.
- Workaround: the decision travels in a response file; the approve block always exits 0.
- Tern 0.9.8: still open, checked against 0.9.8 types and docs, which still
  describe `--wait` as waiting only; the exit status is undocumented
  `[not observed on 0.9.8]`.
- Reproduction: a route opens a block whose action calls `cx:exit(3)`;
  `tern open --wait <file>; echo RC=$?` prints `RC=0`, and the "Shell exited
  with 3" sheet keeps `--wait` blocked until closed by hand.

## 5. `tern.process.run`: no kill handle, no streaming

- Impact: Explore cannot cancel a fetch or show progressive output (watch, logs).
- Workaround: `timeout_ms`, plus ignoring late callbacks via a generation/stopped flag.
- Tern 0.9.8: still open, checked against 0.9.8. `tern.process.run` still
  returns no handle; `Awaitable` has no cancel.
- Reproduction:

  ```luau
  tern.process.run({ "sleep", "5" }, { timeout_ms = 500 }, function(r) print(r.status, r.timed_out) end)
  ```

  Prints `-1 true`; the call returns no handle and the callback fires once with the full output.

## 6. No YAML codec

- Impact: `-o yaml` output and YAML manifests cannot be parsed natively.
- Workaround: request `-o json`, or parse YAML in Luau.
- Tern 0.9.8: still open, checked against 0.9.8: only `tern.json` and
  `tern.base64` codecs.
- Reproduction: `print(type(tern.yaml))` -> `nil`.

## 7. Unclaimed custom-scheme links fall through to the OS

- Impact: an unclaimed `tern-kube://` link (or a `route.link` handler that raises) shows the macOS "There is no application set to open the URL" dialog.
- Workaround: the window half claims every `tern-kube://` URL, wraps handlers in pcall and always returns `{handled = true}`.
- Tern 0.9.8: still open, checked against 0.9.8 types and docs: nothing
  documents a fix for the fallthrough `[not observed on 0.9.8]`; the
  workaround stays.
- Reproduction:

  ```luau
  tern.route.link(function(link) error("boom") end)
  -- in a lens action: cx:open("tern-kube://explore?kind=pods")
  ```

  Log: `plugin handler failed hook="route.link"`, then `open_url ... no
  application could open tern-kube://...`. Returning nil gives the same dialog.

## 8. Table rows cannot carry actions

- Impact: native `table` nodes cannot have clickable rows.
- Workaround: `el` div CSS grid with `display:contents` rows carrying `actions`.
- Tern 0.9.8: still open, checked against 0.9.8: the data guide still says
  table rows have no events or per-row actions.
- Tern 0.9.14: resolved in the types and docs: `TableRow {id, cells, menu,
  disabled}`, `TableOpts.selectable`, `select`/`activate` events with `item`
  and `ButtonCell` actions. Not verified live and not adopted yet; the `el`
  grid stays.
- Reproduction: render a `table` node whose rows have `actions`; clicking a
  cell fires `{"act":"table-click","ev":"action","id":"b.n12"}` with no row info.

## 9. `tern.fs.read` with a cap rejects symlinks

- Impact: config files managed by dotfile managers (symlinked) cannot be read.
- Workaround: `plugin/config_host.luau` resolves the path with `realpath` via `tern.process.run` and reads the target.
- Tern 0.9.8: still open, checked against 0.9.8: `tern.fs.read` with
  `max_bytes` still requires a regular non-symlink file.
- Reproduction: `ln -s real.toml config.toml`, then `tern.fs.read` of
  `config.toml` with a size cap fails with an error containing `non-symlink`.

## 10. `Launch.command` runs a non-interactive login shell

- Impact: environment exported only in `.zshrc`/`.bashrc` (e.g. `KUBECONFIG`) is missing in quick-action splits.
- Workaround: actions pin `--kubeconfig`/`--context` when known, else print the effective context first; opt-in KUBECONFIG capture planned for M3 `[not observed]`.
- Tern 0.9.8: still open, checked against 0.9.8: the layout guide still runs
  `Launch.command` through the login shell, and `Launch` has no env option.
- Reproduction: put `export FOO=1` in `.zshrc` only, then from `route.link`:

  ```luau
  cx.layout:split(link.pane, "right", { command = "echo $- FOO=$FOO; sleep 5" })
  ```

  `ps` shows `/bin/zsh -l -c ...`; it prints `569Xl FOO=` (login, not interactive).
  The exact `echo` probe is `[not observed]`; the observed probe printed `$-` and env markers.

## 11. Deliver plugin lens lines on newline (U1)

- Impact: a plugin lens's live view trails a slow stream. `line` fires only
  when a row scrolls off an 8-row scratch screen: `kubectl logs -f` at 1
  line/s reached the plugin about 6 lines (4.45 s) late, and lines 3 s apart
  arrived only at `finish`. Tern's built-in `lens.docker.logs` shows the same
  stream with no lag, so a plugin cannot match a built-in while following.
- Workaround: a running `logs -f` (and `get events -w`, `events -w`) shows
  raw by default (`general.streaming_view = "raw"`) and turns native when it
  stops; `native` shows the live view with a "trails the stream" note.
- Ask: call `line` when a newline arrives (or after a short flush interval),
  not when the scratch screen scrolls.
- Reproduction: a lens claiming `kubectl logs *` that logs `tern.now()` in
  `open` and `line`; run `kubectl logs -f --tail=3` on a container printing a
  line per second: the first `line` comes about 4.5 s after `open`.

## 12. Re-render or message a lens from the window half (U2)

- Impact: no in-place search in a lens. A lens cannot take text input
  (item 2) and the window half can prompt (`cx:prompt` resolved the typed
  text, matrix F8), but nothing lets a window callback update a lens's view
  state or ask it to re-render.
- Workaround: **Search…** opens Explore logs on the same source with the
  filter focused.
- Ask: a window call delivering an event to a lens's `event` handler,
  followed by `view`.
- Reproduction: lens chip -> `cx:open("tk-probe://prompt")` -> window
  `route.link` -> `cx:prompt(...)` returns the text; no API takes it back to
  the lens.

## 13. Scroll a lens node into view (U3)

- Impact: "jump to first error" cannot move the pane to the row, and a
  pointer click cannot scroll the terminal pane.
- Workaround: **First error** and **Show in context** render a small context
  view (20 records either side of the target, the record open) so the target
  is on screen wherever the pane is scrolled.
- Ask: a node prop or lens-side call that scrolls a keyed node into view
  after `view`.
- Reproduction `[not observed]`: no node prop or call in the 0.9.8 types
  scrolls a pane; a lens re-render keeps the pane's scroll position.

## 14. Pane sizes do not reach the daemon while the window is in the background

- Impact: a block opened while its window is in the background (behind other
  apps' windows, never activated) reads Tern's spawn size 80x24 in `cx.cols`
  and `cx.rows`, and its `resize` hook is not called, until the window is
  activated; window resizes, splits, zoom and closed panes in the meantime
  change only the window's layout. Terminal PTYs keep stale sizes the same way.
  A plugin cannot tell this from a real 80x24 pane: Explore sized its lists to
  3 rows in a 45-row pane, and e2e runs in a background window failed (matrix
  "Block size"). Why activation flushes the sizes (a frame drawn, or the
  activation event itself) is `[not observed]`.
- Workaround: tern-kube reads exactly 80x24 as "not sent yet" and sizes lists
  for a pane of Tern's default 1280x800 window (`plugin/lib/blocksize.luau`);
  the real size replaces it once Tern sends it.
- Ask: send pane sizes to the daemon on every layout change (including
  `tern ctl resize`), in the background or not, or create a block with its
  pane's size (`cx.rows` nil while unknown).
- Reproduction: a sandbox window behind another app's window;
  `tern ctl split right`, then type `stty size` in the new pane: `24 80`
  while `tern ctl state` gives the pane 78x45. In a block, log `cx.rows` in
  `view`: 24 until the window's process is asked to come to the front
  (System Events `set frontmost`), then `resize` fires with the pane's size.

## 15. Pane environment for remote panes

- Impact: a quick action from a remote pane cannot pin the pane's
  `KUBECONFIG`: the per-pane record lives in the remote spool, the window
  cannot read it, and `LinkRequest` carries no pane environment.
- Workaround: the remote split uses the remote login shell's `KUBECONFIG`
  and prints `tern-kube: <host>: kubeconfig from the login environment`
  ([remote-hosts.md](remote-hosts.md#limitations)).
- Ask: the originating pane's environment (or selected variables) on
  `LinkRequest`, or an env option on `Launch`.
- Reproduction `[not observed]`: `export KUBECONFIG=/tmp/other` in a remote
  pane, click Shell on a lens row; the split uses the login environment.

## 16. `route.link` cannot await

- Impact: the window cannot run a process (here: 32 bytes of
  `/dev/urandom` for a grant token and a run id) before deciding what a link does.
- Workaround: return `{handled = true}` at once and open the approve block
  from the `tern.process.run` callback with `cx:new_block`, which lands on
  the window's current host rather than the link's pane host.
- Ask: an async `route.link`, or `new_block` on a given pane's host.
- Reproduction: `route.link` is synchronous in the 0.9.8 types; a
  `tern.process.run` result arrives in a later callback.

## 17. `tern.fs.read` of character devices

- Impact: no in-VM randomness for capability tokens in the window half.
- Workaround: `od -An -tx1 -N32 /dev/urandom` through `tern.process.run`
  (`plugin/lib/env/entropy.luau`), failing closed without a clean read.
- Ask: allow capped reads of `/dev/urandom`, or a `tern.random.bytes(n)`.
- Reproduction: a capped `tern.fs.read` of `/dev/urandom` in the window half
  is refused (device file).

## 18. The plugin watcher reloads on any file below a linked directory

- Impact: a linked checkout reloads the plugin on every `git` command
  (`.git/index` changes), on edits to docs or tests, and on files tools write
  under `.sandbox`. Each reload re-creates open blocks, which re-run their
  queries and lose state that cannot be restored (an Explore compare route,
  an approve preview re-runs).
- Workaround: `scripts/dev-tern.sh link` links a snapshot copy without
  `.git`, `.sandbox` and `.tools` ([testing](testing.md#manual-sandbox)).
- Ask: ignore `.git/` (and ideally everything outside `plugin.toml` and the
  entry, style and `require` paths) when watching a linked package.
- Reproduction: link a git checkout, open a block, `touch <link>/.git/index`:
  the daemon log shows `settings loaded` and the block's `init` again within
  about 1 s.

## 19. A user interrupt counts as a failed split command

- Impact: Ctrl-C is how a user stops `kubectl logs -f` or a port-forward in
  a split; kubectl exits 1, and Tern shows the "Shell exited with 1" sheet, a
  red tab and a notification, so every normal stop looks like an error.
- Workaround: follow-logs and port-forward splits exit 0 on Ctrl-C.
- Ask: treat an exit after a user-sent SIGINT (or exit 130) as not a failure,
  or let `Launch` opt out of the failure sheet.
- Reproduction: `cx.layout:split(pane, "right", { command = "kubectl logs -f
  POD" })`, then Ctrl-C in the split: the sheet and the notification appear.
