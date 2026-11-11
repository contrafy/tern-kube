--!strict
-- Shared shapes of the mutation engine (plan -> preview steps -> risk ->
-- confirm). Pure data: the host runs the steps and feeds results back.
local HelmTypes = require("../helm/types")
local Types = require("../model/types")

export type Family =
	"apply"
	| "delete"
	| "restart"
	| "scale"
	| "debug-pod"
	| "debug-node"
	| "cronjob-run"
	| "undo"
	| "pause"
	| "resume"
	| "patch"
	| "label"
	| "annotate"
	| "cordon"
	| "uncordon"
	| "drain"
	| "edit"
	| "helm-rollback"
	| "set-image"
	| "set-env"
	| "set-resources"
	| "set-selector"
	| "set-serviceaccount"
	| "set-subject"
	| "replace"
	| "taint"
	| "create"
	| "run"
	| "expose"

-- Same vocabulary as Explore's target provenance.
export type ContextSource = "flag" | "chosen" | "inferred"

export type Code =
	"not-mutation"
	| "dry-run"
	| "stdin"
	| "remote-input"
	| "unknown-flag"
	| "ambiguous"
	| "raw"
	| "interactive"
	| "unsupported"
	| "invalid"
	| "missing-target"
	| "no-context"

-- `error` rejects the command (fail closed); `info` with code "not-mutation"
-- or "dry-run" means the command needs no approval and runs unchanged.
export type Diagnostic = { severity: "error" | "warning" | "info", code: Code, text: string }

export type Env = {
	-- Resolved context name; ignored when the argv carries --context.
	context: string?,
	contextSource: ContextSource?,
	-- Kubeconfig path the command will use (--kubeconfig wins over this).
	kubeconfig: string?,
	-- kubectl's own fallback ($HOME/.kube/config) when neither --kubeconfig nor
	-- KUBECONFIG is set: pinned in steps and exec, never fingerprinted.
	defaultKubeconfig: string?,
	-- Program the steps and native exec run; argv[1] (as typed) is kept in
	-- `argv` and the fingerprint.
	program: string?,
	-- Default namespace of the resolved context, when known.
	namespace: string?,
	cwd: string,
	timeoutMs: number?,
	-- Guard edit approvals: kubectl's temp file and the copy of its first round.
	edit: EditInput?,
	-- Resolved helm program: an argv starting with it is a helm command.
	helm: string?,
	-- HELM_DRIVER for every helm call (helm.driver).
	helmDriver: string?,
}

-- A `kubectl edit` round: the file the editor saved and kubectl's original
-- serialization of the objects (both absolute, both fingerprinted).
export type EditInput = { file: string, original: string }

-- label/annotate positional edits: `key=value` sets, `key-` removes.
export type LabelEdit = { key: string, value: string?, remove: boolean }

-- A `kubectl taint` spec: `key[=value]:Effect` adds, `key[:Effect]-` removes.
export type TaintSpec = { key: string, value: string?, effect: string?, remove: boolean }

export type DrainOpts = {
	ignoreDaemonsets: boolean,
	deleteEmptyDir: boolean,
	force: boolean,
	disableEviction: boolean,
	gracePeriod: number?,
	timeout: string?,
	podSelector: string?,
}

-- targets   `get -o json` of the objects (before state)
-- dry-run   human dry-run text (parse/mutation)
-- diff      `kubectl diff` (apply)
-- after     server dry run with `-o json` (after state, concatenated objects)
-- evict     drain server dry run with a bounded --timeout (PodDisruptionBudget probe)
-- history   `rollout history` text (revision list)
-- revision  `rollout history --revision=N -o json` (target template)
-- convert   `patch --local -f FILE -o json` (edit: a manifest file to JSON, offline)
-- helm-status   `helm status [--revision N] -o json` (release manifest and values)
-- helm-extras   `helm get all --template` (stored chart metadata and hooks)
-- helm-history  `helm history --max N -o json` (latest revision and status)
-- nodes     `get nodes -o json` (cordon/drain: is another node schedulable?)
-- pdbs      `get poddisruptionbudgets -o json` (scale to 0: does a budget protect the pods?)
-- selection `get -o jsonpath` of a target set at confirm (selection.luau)
-- convert   also: replace --force, the file's objects as JSON (offline)
-- probe     replace --force: the same replace without --force (server dry run)
-- pods      taint: `get pods -A --field-selector spec.nodeName=N` (evictions)
export type StepKind =
	"dry-run"
	| "diff"
	| "targets"
	| "after"
	| "evict"
	| "history"
	| "revision"
	| "convert"
	| "helm-status"
	| "helm-extras"
	| "helm-history"
	| "nodes"
	| "pdbs"
	| "selection"
	| "probe"
	| "pods"

export type Step = {
	id: string,
	kind: StepKind,
	label: string,
	argv: { string },
	-- Environment overrides for the preview process (never secrets).
	env: { [string]: string },
	timeoutMs: number,
	-- Stage-2 steps: identity key (Objdiff.identity) of their object.
	object: string?,
	-- A failure is a preview finding (edit rejected by the server), not a
	-- failed preview.
	soft: boolean?,
	-- Bytes for the process's stdin (the rollback's target manifest for
	-- `kubectl diff -f -`); never written to disk.
	stdin: string?,
}

-- What the `nodes` and `pdbs` steps read. A list is nil when its step is
-- not part of the plan or could not be read; `*Unknown` then says why the
-- read failed, so risk states the unknown instead of assuming nothing.
export type ClusterFacts = {
	nodes: { any }?,
	nodesUnknown: string?,
	pdbs: { any }?,
	pdbsUnknown: string?,
}

-- `helm rollback RELEASE REVISION`: what the plan targets and how it runs.
export type HelmRollback = {
	release: string,
	namespace: string,
	revision: number,
	options: HelmTypes.RollbackOptions,
	driver: string,
	-- Program for the live `kubectl diff` of the target manifest.
	kubectl: string,
}

export type KindRef = { kind: string, group: string?, namespaced: boolean? }

export type Plan = {
	family: Family,
	operation: string,
	program: string,
	-- The exact command as typed, program first.
	argv: { string },
	-- What the native path executes: argv with --kubeconfig/--context (and the
	-- resolved namespace when safe) pinned after the program.
	execArgv: { string },
	targetContext: string,
	contextSource: ContextSource,
	kubeconfig: string?,
	-- Kubeconfig from the environment (raw KUBECONFIG, or the host's resolved
	-- path), as fingerprinted; --kubeconfig in argv is covered by argv itself.
	envKubeconfig: string?,
	-- Namespace given on the command line (-n), as fingerprinted.
	explicitNamespace: string?,
	targetNamespace: string?,
	allNamespaces: boolean,
	cwd: string,
	filenames: { string },
	recursive: boolean,
	kustomize: string?,
	kinds: { KindRef },
	resources: { Types.ResourceRef },
	selector: string?,
	fieldSelector: string?,
	all: boolean,
	replicas: number?,
	-- --patch-file values as typed (relative to cwd).
	patchFiles: { string },
	-- label/annotate positional edits; {} for other families.
	edits: { LabelEdit },
	-- label/annotate --overwrite.
	overwrite: boolean,
	-- patch --type (nil: strategic).
	patchType: string?,
	-- rollout undo --to-revision (nil or 0: previous).
	toRevision: number?,
	drain: DrainOpts?,
	-- replace --force (delete, then create).
	force: boolean,
	-- taint specs; {} for other families.
	taints: { TaintSpec },
	-- set/create subcommand as resolved (`image`, `secret generic`).
	subverb: string?,
	-- Guard edit approvals only.
	edit: EditInput?,
	helm: HelmRollback?,
	steps: { Step },
	invocation: Types.Invocation,
	validation: { Diagnostic },
}

export type Severity = "high" | "medium" | "low" | "info"
export type Tier = "simple" | "typed" | "blocked"

export type Reason = {
	id: string,
	severity: Severity,
	text: string,
	-- Lowest tier this reason demands.
	tier: Tier,
	-- Heuristic findings are advisory; argv/preview facts are not.
	advisory: boolean,
	-- A blocking reason the user may override when config allows it.
	overridable: boolean,
}

export type Assessment = {
	tier: Tier,
	reasons: { Reason },
	-- Exact text the typed tier asks for.
	token: string,
}

export type Manifest = { path: string, text: string }

return nil
