--!strict

export type OutputFormat =
	"table"
	| "wide"
	| "json"
	| "yaml"
	| "name"
	| "custom-columns"
	| "custom-columns-file"
	| "jsonpath"
	| "go-template"
	| "template"
	| "other"

export type ResourceArg = {
	kind: string,
	group: string?,
	name: string?,
}

export type Invocation = {
	program: string,
	verb: string?,
	subverb: string?,
	resources: { ResourceArg },
	names: { string },
	namespace: string?,
	allNamespaces: boolean,
	context: string?,
	kubeconfig: string?,
	cluster: string?,
	user: string?,
	output: OutputFormat,
	outputSpec: string?,
	watch: boolean,
	noHeaders: boolean,
	showLabels: boolean,
	showKind: boolean,
	selector: string?,
	fieldSelector: string?,
	sortBy: string?,
	labelColumns: { string },
	filenames: { string },
	recursive: boolean,
	kustomize: string?,
	dryRun: string?,
	flags: { [string]: { string } },
	positionals: { string },
	afterDash: { string },
	unknownFlags: { string },
	ambiguities: { string },
}

export type Column = {
	name: string,
	start: number,
	stop: number?,
}

export type TableRow = {
	cells: { string },
	line: number,
}

export type RawLine = {
	line: number,
	text: string,
}

export type ParsedTable = {
	columns: { Column },
	rows: { TableRow },
	headerLine: number?,
	unparsed: { RawLine },
}

export type Diagnostic = {
	line: number?,
	severity: "error" | "warning" | "info",
	text: string,
}

export type DescribeField = {
	key: string,
	value: string,
	values: { string },
	line: number,
	children: { DescribeField },
	table: ParsedTable?,
}

export type DescribeEvent = {
	type: string,
	reason: string,
	age: string,
	from: string,
	message: string,
	line: number,
}

export type DescribeObject = {
	name: string,
	namespace: string?,
	kind: string?,
	line: number,
	fields: { DescribeField },
	events: { DescribeEvent }?,
}

export type DescribeParse = {
	objects: { DescribeObject },
	diagnostics: { Diagnostic },
}

export type MutationResult = {
	kind: string,
	group: string?,
	name: string,
	namespace: string?,
	action: string,
	dryRun: ("server" | "client")?,
	line: number,
}

export type MutationParse = {
	results: { MutationResult },
	diagnostics: { Diagnostic },
}

export type ResourceRef = {
	clusterContext: string?,
	namespace: string?,
	group: string?,
	version: string?,
	kind: string,
	name: string,
	uid: string?,
	source: "snapshot" | "live",
}

export type ColumnType =
	"text"
	| "duration"
	| "ratio"
	| "count"
	| "quantity"
	| "percent"
	| "number"
	| "status"
	| "timestamp"

export type ResourceRow = {
	key: string,
	ref: ResourceRef?,
	cells: { string },
	rawLines: { number },
	warnings: { string },
}

export type SnapshotTable = {
	kind: string?,
	group: string?,
	headers: { string },
	types: { ColumnType },
	rows: { ResourceRow },
}

export type Confidence = "high" | "partial" | "unsupported"

export type Snapshot = {
	invocation: Invocation,
	exitCode: number?,
	tables: { SnapshotTable },
	diagnostics: { Diagnostic },
	truncated: boolean,
	confidence: Confidence,
	reason: string?,
}

return nil
