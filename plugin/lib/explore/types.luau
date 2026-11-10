--!strict
-- Types shared by the Explore core (state.luau), its GitOps and Helm routes
-- (gitops.luau, helm.luau) and the host glue. Pure: no `tern` global.

local Textfield = require("../textfield")
local Types = require("../model/types")

type Ref = Types.ResourceRef

export type RouteKind =
	"list"
	| "detail"
	| "relations"
	| "describe"
	| "logs"
	| "events"
	| "contexts"
	| "namespaces"
	| "kinds"
	| "manifest"
	| "diff"
	| "drift"
	| "export"
	| "git"
	| "helm-releases"
	| "helm-release"
	| "helm-history"
	| "helm-values"
	| "helm-manifest"
	| "helm-notes"
	| "helm-hooks"
	| "helm-resources"
	| "helm-diff"
	| "compare"
	| "matrix"

export type Route = {
	kind: RouteKind,
	-- list: resource token (`pods`, `deployments.apps`).
	resource: string?,
	-- list: explicit namespace; nil follows the target's namespace scope.
	-- logs (selector-only): the pods' namespace. events (namespace scope):
	-- nil follows the target, `*` = all namespaces.
	namespace: string?,
	-- detail/relations/describe/logs/manifest/diff; events: the scoped
	-- object (nil = namespace scope).
	ref: Ref?,
	-- logs: nil = every container (--all-containers).
	container: string?,
	previous: boolean?,
	-- logs without a ref: the `-l` selector.
	selector: string?,
	-- logs: --since and --tail from a lens link (tail nil = explore.logs_tail).
	since: string?,
	tail: number?,
	-- logs: lowest level shown (x); nil = every level.
	floor: ("warn" | "error")?,
	-- logs: long messages wrap (w).
	wrap: boolean?,
	-- logs: the selected record's inspector is open (enter).
	inspect: boolean?,
	-- events: Warning events only (x).
	warnings: boolean?,
	-- events: also objects the scoped one owns; nil = on for workload kinds.
	related: boolean?,
	-- Filter text a link asked for; moved into the route's filter once the
	-- target (part of the filter's key) is resolved.
	q: string?,
	-- diff: which matched manifest (1 = best match).
	doc: number?,
	-- drift: the chosen source id; nil shows the source chooser.
	source: string?,
	-- drift: the drilled-into report entry.
	item: string?,
	-- helm-*: the release (its namespace is `namespace`); helm-releases
	-- scopes like a list.
	release: string?,
	-- helm-*: the revision shown (nil = latest); helm-diff: the older one.
	revision: number?,
	-- helm-diff: the newer revision.
	against: number?,
	-- helm-values: changed | user | computed | defaults | diff (nil = changed).
	mode: string?,
	-- compare/matrix: the other side(s); nil shows the picker, `=<ctx>` one
	-- context, `*` every context of the kubeconfig, `@` compare.contexts.
	across: string?,
	-- compare/matrix: the selected other context ([ and ]); matrix drill-in
	-- (drift): the context whose load the item is read from.
	context: string?,
	-- compare (list): the list filter it was opened under; `keys` are the
	-- rows that filter showed (other sides also keep same-named objects).
	match: string?,
	keys: { string }?,
	-- compare: restored after a plugin reload and not fetched again (r does).
	reloaded: boolean?,
}

export type Item = { key: string, ref: Ref?, value: string? }

export type Decode = (string) -> any

export type ProcessResult = { status: number, stdout: string, stderr: string, timed_out: boolean }

export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

export type ScanOpts = {
	maxFiles: number?,
	maxBytes: number?,
	maxFileBytes: number?,
	renderKustomize: boolean?,
	helm: { { chart: string, release: string, namespace: string?, values: { string } } }?,
}

export type Progress = { phase: "root" | "list" | "read" | "render", done: number, total: number }

export type FileWrite = { path: string, text: string }

-- What the host executes. `run` spawns argv (env/cwd/stdin optional) and
-- answers with a `result`; `scan` indexes manifests (gitops_host.scan) and
-- answers with `progress` messages and one `result` carrying `index`;
-- `read` answers with the file text as stdout; `readtree` answers with
-- `files` (YAML and kustomization files under `path`); `write` writes
-- `files` through tern.fs and answers with a `result`; `openfile` opens
-- `path` at `line` in a Tern file block; `restart` re-runs init with the
-- current config and program; `focus` gives field `id` the caret, `blur`
-- takes it from every field.
export type Effect = {
	t: "run"
		| "copy"
		| "toast"
		| "open"
		| "exit"
		| "save"
		| "focus"
		| "blur"
		| "render"
		| "scan"
		| "read"
		| "readtree"
		| "write"
		| "openfile"
		| "restart",
	tag: string?,
	argv: { string }?,
	env: { [string]: string }?,
	cwd: string?,
	stdin: string?,
	timeout_ms: number?,
	gen: number?,
	text: string?,
	sub: string?,
	level: ("success" | "info" | "error")?,
	url: string?,
	id: string?,
	path: string?,
	line: number?,
	scan: ScanOpts?,
	files: { FileWrite }?,
}

export type Msg = {
	t: "key" | "action" | "result" | "tick" | "resize" | "progress" | "edit" | "undo",
	key: Key?,
	act: string?,
	value: string?,
	tag: string?,
	gen: number?,
	result: ProcessResult?,
	-- Set by the host when tern.process.run raised (kubectl not found).
	spawnError: string?,
	-- os.time() when the result arrived / of the tick.
	at: number?,
	now: number?,
	-- tick: seconds east of UTC, once the host read the zone (`date +%z`).
	utcOffset: number?,
	-- resize: the block's height in lines.
	rows: number?,
	-- key: the host's millisecond clock (tern.now); nil in tests that do not
	-- care about timing.
	clock: number?,
	-- scan: progress, then the finished index (gitops/index.luau Index).
	progress: Progress?,
	index: any?,
	-- readtree: absolute path -> text.
	files: { [string]: string }?,
	-- edit/undo: the field (`main.<key>`) and Tern's native edit.
	id: string?,
	edit: Textfield.Edit?,
}

return {}
