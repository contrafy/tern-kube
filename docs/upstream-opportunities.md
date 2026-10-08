# Upstream opportunities (Tern SDK)

SDK gaps observed while building kube-lens against Tern 0.6.2 (4b3ed42).
Evidence is in `docs/sdk-capability-matrix.md`; each item lists the impact,
the current workaround and a minimal reproduction. Anything not directly
observed is marked `[not observed]`.

## 1. Pre-exec veto hook

- Impact: a plugin cannot stop a command (e.g. a mutating `kubectl`) before it runs.
- Workaround: the mutation guard is a shell wrapper using `tern open --wait`.
- Reproduction:

  ```luau
  tern.on("command_started", function(ev) return false end)
  ```

  Run `kubectl get pods`: the hook logs the line and the command still runs
  (`command_finished status=0`).

## 2. Lens keyboard and text input

- Impact: lens views are pointer-only; no filter/search or key navigation in a lens.
- Workaround: keys, filter and search live in the Explore block.
- Reproduction: render an `input` node in a lens view, click it (the lens gets
  `{"ev":"focus",...}`), then `tern ctl key j` / `type abc`: reply
  `focused: textarea.tv-input` and the text goes to the shell prompt.

## 3. Lens pane width / CSS container queries

- Impact: lens tables cannot adapt to the pane width; a narrow split of a wide window keeps all columns.
- Workaround: `@media (max-width: ...)` tiers in `plugin/kube-lens.css`, which compare to the window width.
- Reproduction: add `@container (max-width: 500px) { .x { display: none } }` to a
  manifest `styles` sheet (rejected); log the arguments of a lens `view`
  callback (no cols; only blocks get `cx.cols`).

## 4. `tern open --wait` exit status

- Impact: the caller cannot read a block's decision from the exit status.
- Workaround: the decision travels in a response file; the approve block always exits 0.
- Reproduction: a route opens a block whose action calls `cx:exit(3)`;
  `tern open --wait <file>; echo RC=$?` prints `RC=0`, and the "Shell exited
  with 3" sheet keeps `--wait` blocked until closed by hand.

## 5. `tern.process.run`: no kill handle, no streaming

- Impact: Explore cannot cancel a fetch or show progressive output (watch, logs).
- Workaround: `timeout_ms`, plus ignoring late callbacks via a generation/stopped flag.
- Reproduction:

  ```luau
  tern.process.run({ "sleep", "5" }, { timeout_ms = 500 }, function(r) print(r.status, r.timed_out) end)
  ```

  Prints `-1 true`; the call returns no handle and the callback fires once with the full output.

## 6. No YAML codec

- Impact: `-o yaml` output and YAML manifests cannot be parsed natively.
- Workaround: request `-o json`, or parse YAML in Luau.
- Reproduction: `print(type(tern.yaml))` -> `nil`.

## 7. Unclaimed custom-scheme links fall through to the OS

- Impact: an unclaimed `kube-lens://` link (or a `route.link` handler that raises) shows the macOS "There is no application set to open the URL" dialog.
- Workaround: the window half claims every `kube-lens://` URL, wraps handlers in pcall and always returns `{handled = true}`.
- Reproduction:

  ```luau
  tern.route.link(function(link) error("boom") end)
  -- in a lens action: cx:open("kube-lens://explore?kind=pods")
  ```

  Log: `plugin handler failed hook="route.link"`, then `open_url ... no
  application could open kube-lens://...`. Returning nil gives the same dialog.

## 8. Table rows cannot carry actions

- Impact: native `table` nodes cannot have clickable rows.
- Workaround: `el` div CSS grid with `display:contents` rows carrying `actions`.
- Reproduction: render a `table` node whose rows have `actions`; clicking a
  cell fires `{"act":"table-click","ev":"action","id":"b.n12"}` with no row info.

## 9. `tern.fs.read` with a cap rejects symlinks

- Impact: config files managed by dotfile managers (symlinked) cannot be read.
- Workaround: `plugin/config_host.luau` resolves the path with `realpath` via `tern.process.run` and reads the target.
- Reproduction: `ln -s real.toml config.toml`, then `tern.fs.read` of
  `config.toml` with a size cap fails with an error containing `non-symlink`.

## 10. `Launch.command` runs a non-interactive login shell

- Impact: environment exported only in `.zshrc`/`.bashrc` (e.g. `KUBECONFIG`) is missing in quick-action splits.
- Workaround: actions pin `--kubeconfig`/`--context` when known, else print the effective context first; opt-in KUBECONFIG capture planned for M3 `[not observed]`.
- Reproduction: put `export FOO=1` in `.zshrc` only, then from `route.link`:

  ```luau
  cx.layout:split(link.pane, "right", { command = "echo $- FOO=$FOO; sleep 5" })
  ```

  `ps` shows `/bin/zsh -l -c ...`; it prints `569Xl FOO=` (login, not interactive).
  The exact `echo` probe is `[not observed]`; the observed probe printed `$-` and env markers.
