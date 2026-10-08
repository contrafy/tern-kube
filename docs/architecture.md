# Architecture

Kube Lens is one Tern plugin package (`plugin/`) plus tools that live outside
it: the opt-in shell guard (`shell/`), the standalone drift CLI
(`bin/kube-lens-drift`) and the alias claim generator
(`scripts/kube-lens-aliases`). SDK facts this design relies on are recorded
with evidence in [sdk-capability-matrix.md](sdk-capability-matrix.md).

## Rule: pure core, thin host glue

- `plugin/lib/**` is pure Luau. It never references the `tern` global;
  whatever it needs (JSON decoder, hasher, clock values, config) is passed in.
  It runs under the standalone `luau` binary, so every decision is unit
  tested in `tests/unit/` without Tern.
- Only `plugin/host.luau`, `plugin/window.luau` and the adapters
  `plugin/config_host.luau`, `plugin/explore_host.luau`,
  `plugin/mutate_host.luau` and `plugin/gitops_host.luau` call `tern.*`.
  They execute effects and feed results back; they decide nothing.
- Views are plain `{k, p, c}` tables (`plugin/lib/ui.luau`), about 50x
  cheaper than the `tern.ui` builders for large grids.

## Module map

```
plugin/
  plugin.toml          manifest: lens "kubectl" (claim globs), blocks
                       "explore", "approve" and "settings", styles
  host.luau            daemon half: lens "kubectl", spawn hook
                       (KUBE_LENS_SPOOL), registers the blocks below
  window.luau          window half: route.link (every kube-lens:// URL),
                       route.open (guard requests), palette commands
  config_host.luau     reads/caches $XDG_CONFIG_HOME/kube-lens/config.json
  explore_host.luau    block "explore": runs lib/explore/state effects
  mutate_host.luau     block "approve": runs lib/mutation/session effects,
                       audit log, quick-action grants
  gitops_host.luau     manifest scan, kustomize/helm render, git status
  settings_host.luau   block "settings": runs lib/settings/state effects
  lib/
    kubectl/           argv parser (cobra/pflag rules), generated flag and
                       kind tables, copyable commands and Explore links
    parse/             table, describe, json, yaml, mutation-result output
    model/             shared types, typed cell values, resource keys,
                       redaction policy
    lens/              capture (run -> immutable model), query (filter,
                       sort), viewstate (state encoded in action values),
                       view (dispatch)
    render/            grid, table/describe/yaml/objtree/mutation views,
                       header, summary
    explore/           state (Elm-style core), gitops (manifest, diff,
                       drift, export and git routes), render, query (pinned
                       argv), relations, label selectors
    actions/quick.luau shell, logs, port-forward, debug, CronJob run-now
                       links and the commands they launch
    mutation/          plan, steps, diffseg, risk, confirm, fingerprint,
                       audit, link (mutate links + grants), session (approve
                       block core), render
    gitops/            index, controllers, clean, emit, export, drift, view
    settings/          settings block core and view
    config.luau        config schema, validation, defaults
shell/                 kube-lens-guard (POSIX sh core) + zsh/bash/fish
                       activation files; protocol in shell/PROTOCOL.md
bin/kube-lens-drift    POSIX sh drift report for CI (no Tern)
```

## Data flow

```
 Tern pane: kubectl get pods
      |  claim glob in plugin.toml
      v
 host.luau lens "kubectl"
   open/line/finish: record argv, lines, exit status only
   view:  lib/lens/capture -> lib/parse/* -> lib/lens/view -> lib/render/*
   event: "v=<state>" re-render | copy | explore | act
      |  cx:open("kube-lens://...")
      v
 window.luau route.link  (claims every kube-lens:// URL, pcall-wrapped)
   act/<shell|logs|port-forward>  -> lib/actions/quick -> layout:split,
                                     new pane runs a visible kubectl line
   act/<debug-*|cronjob-run>      -> needs a confirm grant, else approve block
   mutate?...                     -> block "approve"  (mutate_host)
   anything else                  -> block "explore"  (explore_host)

 Explore block (lib/explore/state)
   key/click -> update(state, msg) -> (state, effects)
   effects: run pinned kubectl, copy, toast, open link, focus
   results come back as messages; render is a pure function of state

 Guarded typed mutation (opt-in)
   kubectl apply -f x.yaml   (shell function from shell/kube-lens.<sh>)
      -> shell/kube-lens-guard writes <spool>/req-<nonce>.json
      -> tern open --wait <req>  -> window route.open -> block "approve"
      -> preview, confirm, block writes resp-<nonce>.env, exits 0
      -> guard verifies nonce, context, fingerprint -> exec kubectl "$@"
```

### Lens

- Claims are broad, views strict: globs such as `kubectl -* get *`
  over-claim, so `view` re-derives the verb from argv
  (`plugin/lib/kubectl/argv.luau`) and returns nil (raw output) for anything
  it cannot render faithfully: watches, `-o jsonpath`, empty output, output
  over `general.max_rows` lines or `general.max_capture_bytes`.
- Mutation verbs (`apply`, `delete`, `rollout restart`, `scale`) render as a
  result summary (`plugin/lib/render/mutation_view.luau`); by the time a lens
  sees them the change has happened.

### Rehydration

After a plugin reload Tern rebuilds a lens from the captured output only: it
replays `open`, `line` and `finish`, then calls `view`. Therefore:

- `open`, `line` and `finish` are side-effect free (`plugin/host.luau`);
- every clickable carries the whole view state in its action value
  (`v=sort:STATUS;desc:1;f:STATUS~Running;open:<key>`,
  `plugin/lib/lens/viewstate.luau`), so a click on a rehydrated lens restores
  sort, filters and the open inspector;
- parsers use no clock: ages are shown as kubectl printed them.

Running blocks (Explore, approve) are not re-initialized by a reload; their
timers and pending callbacks are dropped.

### Effects and cancellation

Explore and the approve block are Elm-style cores: `init`/`update` return
the next state and a list of effects (`run`, `read`, `write`, `remove`,
`audit`, `grant`, `open`, `focus`, ...). The host executes them and delivers
results as messages on a later tick, never re-entering `update`.
`tern.process.run` has no kill handle: every load carries a generation and a
late result for an older generation is dropped. A spawned native mutation
cannot be cancelled; the block says so while it runs.

### Target pinning

Once a context is resolved, every cluster query pins `--context` (and
`--kubeconfig` when known): `plugin/lib/explore/query.luau`,
`plugin/lib/mutation/steps.luau`, `plugin/lib/actions/quick.luau`. The daemon
environment is not the shell's (different `PATH`, no `KUBECONFIG`), so the
target always comes from the lensed command, the pane's recorded
`KUBECONFIG` (`<spool>/pane-<pane>.env`, written by the shell snippets) or
an explicit choice in Explore.

### Mutation pipeline

`plugin/lib/mutation/session.luau` serves three entry points with one
pipeline: native (`kube-lens://mutate?...` from Explore keys, lens chips,
palette), quick (mutating quick actions) and guard (spool request).

1. resolve the context, `config view --minify` (context exists, server URL
   recorded);
2. `plan.luau`: family, target, exact argv; unsupported input fails closed;
3. digest input files, compute the fingerprint (`fingerprint.luau`);
4. preview steps in parallel (`steps.luau`): server dry run, `kubectl diff`
   split per resource (`diffseg.luau`), target listing;
5. risk tier `simple` / `typed` / `blocked` (`risk.luau`; manifest scans
   are advisory);
6. confirm (`confirm.luau`): re-read digests, fingerprint, server and
   inferred context; any change refuses;
7. native: run the pinned argv; quick: grant a single-use token and open
   the action link; guard: write `resp-<nonce>.env`, exit 0;
8. append one JSON line to `<plugin data>/audit.log` (`audit.luau`).

### GitOps

`plugin/lib/gitops/` maps live objects to manifest files (plain YAML,
Kustomize, Helm renders), reads Argo CD/Flux tracking metadata (never writes
controller objects), cleans and emits objects as YAML for export, and sorts
drift into changed/missing/unmanaged. `bin/kube-lens-drift` applies the same
diff segmentation as `diffseg.luau` outside Tern. See [gitops.md](gitops.md).
