--!strict
-- Shared shapes of the logs lens: parsed records, kubectl notices and the
-- options a store parses with.

export type Level = "fatal" | "error" | "warn" | "info" | "debug" | "trace" | "none"
export type Format = "json" | "klog" | "logfmt" | "plain"
export type Source = { pod: string?, container: string? }
export type Field = { key: string, value: string }
export type Record = {
	-- Arrival ordinal, 1-based, stable when the same lines are replayed.
	index: number,
	-- Index into Store.sources; 0 = unattributed.
	source: number,
	-- Kubelet time (--timestamps).
	ts: string?,
	-- Time from the payload.
	appTime: string?,
	level: Level,
	format: Format,
	message: string,
	fields: { Field }?,
	-- klog file:line.
	location: string?,
	-- The delivered line, for Copy line.
	raw: string,
	-- Continuation lines (stack frames), at most Parse.MAX_EXTRA.
	extra: { string }?,
	-- Continuation lines past the cap, counted only.
	more: number?,
}
export type NoticeKind = "found-pods" | "defaulted-container" | "error" | "warning" | "interrupted" | "dropped"
export type Notice = {
	kind: NoticeKind,
	text: string,
	pod: string?,
	containers: { string }?,
	-- The defaulted container of a "defaulted-container" notice.
	container: string?,
}
export type Options = {
	prefix: boolean,
	timestamps: boolean,
	follow: boolean,
	decode: (string) -> any,
	-- What the invocation tells about the source of unprefixed lines.
	pod: string?,
	container: string?,
	multiPod: boolean?,
	allContainers: boolean?,
}
export type Limits = { maxLines: number, maxBytes: number }

return nil
