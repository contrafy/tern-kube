--!strict
-- Shared shapes of the Helm features: what the parsers produce from helm's
-- JSON, what Explore keeps per release, and the rollback options. Pure data.

export type Status =
	"deployed"
	| "failed"
	| "pending-install"
	| "pending-upgrade"
	| "pending-rollback"
	| "superseded"
	| "uninstalling"
	| "uninstalled"
	| "unknown"

export type ReleaseKey = { name: string, namespace: string }

-- One row of `helm list -o json`.
export type ReleaseRow = {
	name: string,
	namespace: string,
	revision: number,
	updated: string,
	updatedAt: number?,
	status: Status,
	chart: string,
	chartName: string,
	chartVersion: string?,
	appVersion: string,
}

-- One row of `helm history -o json`.
export type Revision = {
	revision: number,
	updated: string,
	updatedAt: number?,
	status: Status,
	chart: string,
	chartName: string,
	chartVersion: string?,
	appVersion: string,
	description: string,
}

export type Info = {
	status: Status,
	description: string,
	firstDeployed: string?,
	lastDeployed: string?,
	notes: string,
}

-- `helm status [--revision N] -o json`; `user` is the user-supplied values.
export type ReleaseStatus = {
	name: string,
	namespace: string,
	revision: number,
	info: Info,
	user: { [string]: any },
	manifest: string,
}

export type Dependency = { name: string, version: string, repository: string, alias: string }

export type Chart = {
	name: string,
	version: string,
	appVersion: string,
	type: string,
	description: string,
	home: string,
	sources: { string },
	dependencies: { Dependency },
}

export type Hook = {
	name: string,
	kind: string,
	path: string,
	weight: number,
	events: { string },
	deletePolicies: { string },
	phase: string,
	startedAt: string?,
	completedAt: string?,
	manifest: string,
}

-- Output of Query.EXTRAS_TEMPLATE: what the stored release holds beyond
-- `helm status` (chart metadata, stored chart defaults, hooks).
export type Extras = {
	name: string,
	namespace: string,
	revision: number,
	chart: Chart,
	defaults: { [string]: any },
	hooks: { Hook },
}

export type Owner = { release: string, namespace: string, via: "annotation" | "instance-label" }

export type OwnerInfo = {
	owner: Owner,
	status: "loading" | "ok" | "missing" | "error",
	revision: number?,
	release: ReleaseRow?,
	error: string?,
}

export type RollbackOptions = {
	wait: boolean,
	waitForJobs: boolean,
	cleanupOnFail: boolean,
	force: boolean,
	noHooks: boolean,
	timeoutS: number,
}

-- A chart directory found by the manifest index.
export type ChartDir = { path: string, name: string, version: string, appVersion: string?, valuesFiles: { string } }

export type LoadStatus = "idle" | "loading" | "ok" | "error"

export type Load<T> = { status: LoadStatus, gen: number, data: T?, error: string?, argv: { string }?, at: number? }

export type DefaultsChoice = { source: string, revision: number?, values: { [string]: any }?, note: string? }

-- Explore sub-state: explore/helm.luau owns the logic, helm/view.luau reads it.
export type ExploreState = {
	gen: number,
	-- key: scope id
	lists: { [string]: Load<{ ReleaseRow }> },
	-- key: ns/name
	histories: { [string]: Load<{ Revision }> },
	-- key: ns/name#rev (0 = latest)
	statuses: { [string]: Load<ReleaseStatus> },
	extras: { [string]: Load<Extras> },
	computed: { [string]: Load<{ [string]: any }> },
	-- helm-resources rows; the shape is owned by explore/helm.luau.
	resources: { [string]: Load<any> },
	-- key: ctx|ns/name
	owners: { [string]: OwnerInfo },
	-- history mark per release (ns/name)
	marks: { [string]: number },
	defaults: { [string]: Load<DefaultsChoice> },
	-- Revision diffs, key ns/name#A..B (data: helm/revdiff.luau Result).
	diffs: { [string]: Load<any> },
	-- Running defaults fallbacks per ns/name#rev (shape owned by explore/helm.luau).
	fallbacks: { [string]: any },
}

return nil
