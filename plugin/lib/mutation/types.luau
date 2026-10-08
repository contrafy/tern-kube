--!strict
-- Shared shapes of the mutation engine (plan -> preview steps -> risk ->
-- confirm). Pure data: the host runs the steps and feeds results back.
local Types = require("../model/types")

export type Family = "apply" | "delete" | "restart" | "scale" | "debug-pod" | "debug-node" | "cronjob-run"

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
}

export type StepKind = "dry-run" | "diff" | "targets"

export type Step = {
	id: string,
	kind: StepKind,
	label: string,
	argv: { string },
	-- Environment overrides for the preview process (never secrets).
	env: { [string]: string },
	timeoutMs: number,
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
