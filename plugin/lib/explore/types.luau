--!strict
-- Types shared by the Explore core (state.luau), its GitOps routes
-- (gitops.luau) and the host glue. Pure: no `tern` global.

local Types = require("../model/types")

type Ref = Types.ResourceRef

export type RouteKind =
	"list"
	| "detail"
	| "relations"
	| "describe"
	| "logs"
	| "contexts"
	| "namespaces"
	| "kinds"
	| "manifest"
	| "diff"
	| "drift"
	| "export"
	| "git"

export type Route = {
	kind: RouteKind,
	-- list: resource token (`pods`, `deployments.apps`).
	resource: string?,
	-- list: explicit namespace; nil follows the target's namespace scope.
	namespace: string?,
	-- detail/relations/describe/logs/manifest/diff.
	ref: Ref?,
	-- logs.
	container: string?,
	previous: boolean?,
	-- diff: which matched manifest (1 = best match).
	doc: number?,
	-- drift: the chosen source id; nil shows the source chooser.
	source: string?,
	-- drift: the drilled-into report entry.
	item: string?,
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
-- current config and program.
export type Effect = {
	t: "run"
		| "copy"
		| "toast"
		| "open"
		| "exit"
		| "save"
		| "focus"
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
	t: "key" | "action" | "result" | "tick" | "resize" | "progress",
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
	-- resize: the block's height in lines.
	rows: number?,
	-- scan: progress, then the finished index (gitops/index.luau Index).
	progress: Progress?,
	index: any?,
	-- readtree: absolute path -> text.
	files: { [string]: string }?,
}

return {}
