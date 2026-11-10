# Architecture

Tern Kube is one Tern plugin package (the repository root: `plugin.toml`
loading `plugin/`) plus tools that live outside
it: the opt-in shell guard (`shell/`), the standalone drift CLI
(`bin/tern-kube-drift`) and the alias claim generator
(`scripts/tern-kube-aliases`). SDK facts this design relies on are recorded
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
plugin.toml            manifest at the repository root (the package root):
                       lens "kubectl" (claim globs), blocks "explore",
                       "approve" and "settings", styles; entries under plugin/
plugin/
  host.luau            daemon half: lens "kubectl" (logs branch and table/
                       describe branch), spawn hook (TKUBE_SPOOL), registers
                       the blocks below
  window.luau          window half: route.link (every tern-kube:// URL),
                       route.open (guard requests), palette commands
  config_host.luau     reads/caches $XDG_CONFIG_HOME/tern-kube/config.json
  explore_host.luau    block "explore": runs lib/explore/state effects
  mutate_host.luau     block "approve": runs lib/mutation/session effects,
                       audit log, quick-action grants
  gitops_host.luau     manifest scan, kustomize/helm render (Chart.yaml
                       reads for auto-detect), git status
  settings_host.luau   block "settings": runs lib/settings/state effects
  lib/
    kubectl/           argv parser (cobra/pflag rules), generated flag and
                       kind tables, copyable commands and Explore links
    parse/             table, describe, json, yaml, mutation-result output
    model/             shared types, typed cell values, resource keys,
                       redaction policy (+ maskTree/maskEchoes for Helm
                       values), linediff (LCS unified diff)
    lens/              capture (run -> immutable model), query (filter,
                       sort), viewstate (state encoded in action values),
                       view (dispatch)
    render/            grid, table/describe/yaml/objtree/mutation views,
                       header, summary, helm_chip (lens "Helm release" chip),
                       segcard (diff segment card shared by GitOps, Helm
                       and compare views)
    logs/              parse (JSON, klog, logfmt, plain; prefix, kubelet
                       time, continuations), store (incremental ring of
                       records), query (filters, pages, context, next
                       error), viewstate (`lv=` action values), render
    events/            model (EventList and table rows -> events), timeline
                       (sort, filter, time groups, ownerReferences closure)
    explore/           state (Elm-style core), gitops (manifest, diff,
                       drift, export, git and drift matrix routes), helm
                       (Helm routes: loads, keys, rollback links), compare
                       (compare routes: per-side loads, queue, keys),
                       render, query (pinned argv), relations, label
                       selectors
    compare/           contexts (kubeconfig contexts, picker choices,
                       short labels), normalize (strip what differs between
                       clusters), model (pairing, paths, object diff, list
                       matrix, filters, max_parallel queue), view (picker,
                       fan-out, matrix, pairwise diff)
    helm/              types, query (pinned helm argv, extras template),
                       parse (list/history/status/values/extras), owner
                       (object -> release), values (defaults vs user vs
                       computed), revdiff (two revision manifests ->
                       diff segments), detect (chart dir <-> release), view
    actions/quick.luau shell, logs, port-forward, debug, CronJob run-now
                       links, the commands they launch and typed logs lines
    mutation/          plan, helm_plan (`helm rollback` argv), steps,
                       diffseg, objdiff (before/after diffs), drain,
                       rollout, edit, risk, confirm, fingerprint, audit, link
                       (mutate links + grants), session (approve block
                       core), render
    gitops/            index, controllers, clean, emit, export, drift,
                       matrix (drift reports of several contexts -> one
                       matrix), view
    settings/          settings block core and view
    config.luau        config schema, validation, defaults
shell/                 tern-kube-guard (POSIX sh core) + zsh/bash/fish
                       activation files; protocol in shell/PROTOCOL.md
bin/tern-kube-drift    POSIX sh drift report for CI (no Tern)
```

## Data flow

```
 Tern pane: kubectl get pods
      |  claim glob in plugin.toml
      v
 host.luau lens "kubectl"
   open/line/finish: record argv, lines, exit status only
                     (logs: Store.push per line, pure state)
   view:  logs   -> lib/logs/{query,render}
          other  -> lib/lens/capture -> lib/parse/* -> lib/lens/view
                    -> lib/render/*  (events tables: lib/events/model rows)
   event: "v=<state>" | "lv=<state>" re-render | copy | explore | act
      |  cx:open("tern-kube://...")
      v
 window.luau route.link  (claims every tern-kube:// URL, pcall-wrapped)
   act/<shell|logs-follow|port-forward> -> lib/actions/quick -> layout:split,
                                     new pane runs a visible kubectl line
   act/logs (Run in split)        -> lib/actions/quick typedLine ->
                                     split(pane, dir, {}) + cx:run(line):
                                     an interactive shell, so the lens
                                     claims the typed line in the new pane
   act/<debug-*|cronjob-run>      -> with a valid confirm grant: split;
                                     else mint a grant, approve block
   mutate?...                     -> block "approve"  (mutate_host)
   anything else                  -> block "explore"  (explore_host)

 Explore block (lib/explore/state)
   key/click -> update(state, msg) -> (state, effects)
   effects: run pinned kubectl, copy, toast, open link, focus
   results come back as messages; render is a pure function of state

 Guarded typed mutation (opt-in)
   kubectl apply -f x.yaml   (shell function from shell/tern-kube.<sh>)
      -> shell/tern-kube-guard writes <spool>/req-<nonce>.json
      -> tern open --wait <req>  -> window route.open -> block "approve"
      -> preview, confirm, block writes resp-<nonce>.env, exits 0
      -> guard verifies nonce, context, fingerprint -> exec kubectl "$@"
```

### Where each half runs

The host half runs on the machine of the pane (local, or a host added with
`tern remote setup`): lenses, Explore, approve and Settings blocks, their
kubectl calls, config file and audit log. The window half always runs on
the desktop: `route.link` finds the clicked pane's host in
`ManagedHost.panes` and splits there, while blocks it opens with
`cx:new_block` land on the window's current host. Details and limits:
[remote-hosts.md](remote-hosts.md).

### Quick-action grants

The window, not the approve block, mints the grant: on a mutating quick
action without a valid `confirm`, it reads 16 bytes of `/dev/urandom`
through a short process (`env/entropy.luau`; `tern.fs.read` refuses device
files and `route.link` cannot await, so the block opens from the process
callback), stores the token with the exact link in the window kv
(`Link.mintGrant`, 600 s) and opens the approve block with `{url, token}`.
On confirm the block, possibly on another host with its own kv, emits one
`open` of the link with `confirm=<token>`; the window consumes the token once
(`Link.consumeGrant`): every minted field must come back unchanged and only
resolved fields (`context`, `kubeconfig`, `image`, `suffix`) may be added.
No randomness, no grant, no block: fail closed.

### Lens

- Claims are broad, views strict: globs such as `kubectl -* get *`
  over-claim, so `view` re-derives the verb from argv
  (`plugin/lib/kubectl/argv.luau`) and returns nil (raw output) for anything
  it cannot render faithfully: watches other than event listings,
  `-o jsonpath`, empty output, tables over `general.max_rows` lines or
  `general.max_capture_bytes`.
- Mutation verbs (`apply`, `delete`, `scale`, `patch`, `label`, `annotate`,
  `cordon`, `uncordon`, `rollout restart|undo|pause|resume`) render as a
  result summary (`plugin/lib/render/mutation_view.luau`); by the time a lens
  sees them the change has happened.
- `logs` keeps its own state (`plugin/lib/logs/store.luau`): records are
  parsed per `line` callback, so `view` is O(page) while a stream runs. A log
  is append-only, so past `general.max_rows` it keeps the newest records and
  says how many are only in Raw, instead of falling back to raw. A running
  `logs -f` (and `get events -w`, `events -w`) shows raw unless
  `general.streaming_view` is `native`: Tern hands lines to a plugin lens
  late (see the capability matrix), and raw is live. A pointer cannot scroll
  the pane, so **First error** and **Show in context** render a small
  context view (20 records either side) instead of jumping.
- Event listings (`kubectl events`, `get events`) go through the table
  pipeline; each row's ref is the involved object, so the inspector chips
  act on it.

### Rehydration

After a plugin reload Tern rebuilds a lens from the captured output only: it
replays `open`, `line` and `finish`, then calls `view`. Therefore:

- `open`, `line` and `finish` are side-effect free (`plugin/host.luau`);
- every clickable carries the whole view state in its action value
  (`v=sort:STATUS;desc:1;f:STATUS~Running;open:<key>`,
  `plugin/lib/lens/viewstate.luau`; logs `lv=lvl:error;src:1;open:42`,
  `plugin/lib/logs/viewstate.luau`, record indices are arrival ordinals so
  a replay rebuilds the same store), so a click on a rehydrated lens
  restores sort, filters and the open inspector;
- parsers use no clock: ages are shown as kubectl printed them.

A reload also re-creates running blocks (Explore, approve): Tern calls `init`
again with their saved state, timers and pending callbacks are dropped, and
the new block re-runs its queries (Explore its route, approve its preview).
Tern 0.9.14 reloads a linked plugin on any file change below the linked
directory, `.git` included, so development links a snapshot
([testing](testing.md#manual-sandbox)).

### Effects and cancellation

Explore and the approve block are Elm-style cores: `init`/`update` return
the next state and a list of effects (`run`, `read`, `write`, `remove`,
`audit`, `open`, `focus`, ...). The host executes them and delivers
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
pipeline: native (`tern-kube://mutate?...` from Explore keys, lens chips,
palette), quick (mutating quick actions) and guard (spool request).

1. resolve the context, `config view --minify` (context exists, server URL
   recorded);
2. `plan.luau`: family, target, exact argv; unsupported input fails closed;
3. digest input files (`-f`, `--patch-file`, edit files), compute the
   fingerprint (`fingerprint.luau`);
4. stage-1 preview steps in parallel (`steps.luau`), then stage-2 steps that
   need stage-1 output (`Steps.followUp`: undo target revisions, edit dry
   runs; at most 20 objects);
5. risk tier `simple` / `typed` / `blocked` (`risk.luau`; manifest scans
   are advisory);
6. confirm (`confirm.luau`): re-read digests, fingerprint, server, inferred
   context and, for `rollout undo`, the revision list; any change refuses;
7. native: run the pinned argv; quick: open the action link with
   `confirm=<window-minted token>` (see Quick-action grants); guard: write
   `resp-<nonce>.env`, exit 0;
8. append one JSON line to `<plugin data>/audit.log` (`audit.luau`: argv,
   previewed objects, input file digests), then the outcome (executed or
   failed, exit code, start and finish times) for native runs and, appended
   by the guard after kubectl exits, for guarded shell commands; mutating
   quick actions record only the approval (see
   [security model](security-model.md)).

Families and their preview steps:

| Family | Stage 1 | Stage 2 | Before/after |
| --- | --- | --- | --- |
| apply | server dry run, `kubectl diff` | | `kubectl diff` per resource (`diffseg.luau`) |
| delete, scale | targets, server dry run | | |
| restart | targets | | |
| patch, label, annotate | targets, server dry run `-o json` | | live vs dry run |
| rollout undo | targets, `rollout history`, server dry run | `rollout history --revision=R -o json` per object | live vs live with the revision's template |
| rollout pause/resume | targets | | live vs `spec.paused` set/removed |
| cordon, uncordon | targets (nodes), server dry run | | live vs `spec.unschedulable` set/removed |
| drain | targets, client dry run, server eviction probe (bounded `--timeout`) | | node cordoned; evictions card (`drain.luau`) |
| edit (guard edit hook) | `patch --local -o json` of both files, targets | merge patch dry run per changed object (`edit.luau`) | live vs dry run |
| helm-rollback | `helm status` of the latest and the target revision, `history --max 1`, the target's extras (soft), `helm rollback --dry-run` | `kubectl diff -f -` of the target manifest (stdin, soft) | the two revision manifests (`helm/revdiff.luau`) |

Families without `kubectl diff` render before/after object diffs through
`objdiff.luau`: both sides are cleaned (generation, resourceVersion,
managedFields; Secret values redacted), emitted as YAML and line-diffed into
the same unified text `kubectl diff` prints, so the diff cards, counts and
focus cycling are shared with apply.

Input ops (scale, apply, label, annotate, patch, drain) open at a prompt
(`Link.prompt`); typed text is validated into link fields by
`Link.withInput`, and `i` after a preview returns to the prompt. A native
drain must carry a `--timeout` below `mutations.execute_timeout_ms`: the
block cannot stop kubectl once it runs.

A helm rollback is always typed (token: the release name) and always
carries `--timeout`, checked against `mutations.execute_timeout_ms` for the
same reason. Confirm re-runs `helm history --max 1` (`Steps.verifySteps`)
and refuses when the latest revision or its status moved since the preview.

### Helm

```
 Explore H / kinds picker / palette / lens chip
   -> helm-releases (helm list -a, -A or -n by the namespace scope)
   -> helm-release: status, history, extras (get all --template), computed
      values (get values --all) -> header, values summary, notes, hooks
      -> h history -> = revision diff (two statuses + extras -> revdiff)
      -> v values (defaults from the earliest trustworthy revision, a
         chart dir in the repository, or helm.chart_sources)
      -> M manifest, N notes, K hooks, R resources (+ live kubectl get)
      -> ctrl+r tern-kube://mutate?op=rollback -> approve block
 Explore detail of an object: Owner.fromObject -> one helm status per
   release and context -> "Managed by Helm release" line and chip
 ctrl+g: chart dirs with Chart.yaml x helm list -> Detect.candidates ->
   helm template (deployed values via a 0600 temp file, or a values file)
   -> Index.addRendered -> kubectl diff -n <release namespace> -> drift
```

`plugin/lib/explore/helm.luau` keeps every load (lists, statuses, extras,
computed values, defaults, diffs, resources) keyed by context, namespace,
release and revision, each with its generation; `enter` only starts what a
route still lacks and `r` forgets the release. Rendering
(`plugin/lib/helm/view.luau`) masks values through `model/redact.luau`
before any text reaches a node, so copies and toasts see masked text too.
helm runs with `HELM_DRIVER` from `helm.driver` and the pinned
`--kube-context`/`--kubeconfig` (a kubeconfig path list goes into the
environment instead).

### Compare across contexts

```
 Explore x (object or list) / lens chip explore-route=compare
   -> picker: kubectl [--kubeconfig K] config view -o json -> Contexts.choices
   -> per side (base first): kubectl --context C get <plural.version.group>
      --field-selector metadata.name=N -o json  (object)
      or get <resource> (-n NS | -A) -o json   (list)
      at most compare.max_parallel in flight (Model.queue)
   -> every side answered: Normalize -> Model.objectDiff / listMatrix
      -> pair (base vs one context), fan-out (one row per context) or
         matrix (rows = objects, columns = contexts)
 GitOps x (drift report or item)
   -> same picker -> one drift report per context (startDrift, target
      pinned to C, namespace explicit) -> GitopsMatrix.fromReports
```

`plugin/lib/explore/compare.luau` is a sub-core like the Helm one: one load
per target, subject and choice, a generation per side (tag
`compare|side|<i>|<load>`; a stale result is dropped), and `r` refetches
every side. Only when every side has settled does it build the matrix. At
that point it computes the pairwise diffs that involve a Secret (masked by
`Objdiff` with the redaction policy) and drops the raw Secrets. Other
objects are kept per column so `enter` on a row diffs without a new query.
`compare/normalize.luau` runs `gitops/clean.luau` with
`secretValues = "keep"` and `skipDefaults = false`, so equal Secrets compare
equal and nothing is skipped. `Objdiff` labels the two sides with their
contexts instead of live/merged.

Drift loads in `explore/gitops.luau` are keyed `kubeconfig@context|source`.
A matrix column is the ordinary drift load of that context, so the drift
item view opened from a cell reads the same load. Compare and matrix routes
are not saved across reloads, and both are read-only: the Explore core
refuses quick actions, mutations and export there, and GitOps refuses apply,
export and delete on any context but the block's own.

### GitOps

`plugin/lib/gitops/` maps live objects to manifest files (plain YAML,
Kustomize, Helm renders), reads Argo CD/Flux tracking metadata (never writes
controller objects), cleans and emits objects as YAML for export, and sorts
drift into changed/missing/unmanaged. `bin/tern-kube-drift` applies the same
diff segmentation as `diffseg.luau` outside Tern. See [gitops.md](gitops.md).
