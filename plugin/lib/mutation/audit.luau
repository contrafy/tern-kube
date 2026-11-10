--!strict
-- One JSON line per decision for tern.plugin.data/audit.log. Built from an
-- explicit whitelist: command output, environment values and credentials
-- passed on the command line never reach the log (only the kubeconfig path).
local Fingerprint = require("./fingerprint")
local T = require("./types")

type Plan = T.Plan

export type Mode = "native" | "guard"
export type Decision = "approved" | "denied" | "cancelled" | "blocked" | "executed" | "failed"

export type Event = {
	mode: Mode,
	decision: Decision,
	tier: T.Tier?,
	fingerprint: string?,
	exitCode: number?,
	-- Unix seconds.
	previewedAt: number?,
	decidedAt: number,
	startedAt: number?,
	finishedAt: number?,
	-- `Kind ns/name` of the previewed objects.
	objects: { string }?,
	-- Digests of the fingerprinted input files (-f, --patch-file, edit files).
	files: { Fingerprint.FileDigest }?,
	-- helm rollback: the release's latest revision when it was previewed.
	fromRevision: number?,
}

export type FileEntry = { path: string, sha256: string }

export type Record = {
	v: number,
	op: string,
	family: string,
	mode: Mode,
	decision: Decision,
	context: string,
	context_source: string,
	namespace: string?,
	release: string?,
	revision: number?,
	from_revision: number?,
	kubeconfig: string?,
	cwd: string,
	argv: { string },
	tier: string?,
	fingerprint: string?,
	exit_code: number?,
	previewed_at: number?,
	decided_at: number,
	started_at: number?,
	finished_at: number?,
	objects: { string }?,
	objects_total: number?,
	files: { FileEntry }?,
}

local M = {}

M.MAX_OBJECTS = 50

-- Flags whose values are credentials.
local SECRET_FLAGS = { token = true, password = true }
M.REDACTED = "<redacted>"

-- Replaces credential values in `--token X`, `--token=X` (and --password);
-- arguments after `--` belong to the container command and are kept.
function M.redactArgv(argv: { string }): { string }
	local out: { string } = {}
	local hideNext = false
	local afterDash = false
	for _, a in argv do
		if hideNext then
			table.insert(out, M.REDACTED)
			hideNext = false
			continue
		end
		if not afterDash then
			if a == "--" then
				afterDash = true
			else
				local name, eq = string.match(a, "^%-%-([%w%-]+)(=?)")
				if name and SECRET_FLAGS[name] then
					if eq == "=" then
						table.insert(out, "--" .. name .. "=" .. M.REDACTED)
					else
						table.insert(out, a)
						hideNext = true
					end
					continue
				end
			end
		end
		table.insert(out, a)
	end
	return out
end

function M.record(plan: Plan, event: Event): Record
	local objects: { string }? = nil
	if event.objects then
		objects = table.move(event.objects, 1, math.min(#event.objects, M.MAX_OBJECTS), 1, {})
	end
	local files: { FileEntry }? = nil
	if event.files and #event.files > 0 then
		local list: { FileEntry } = {}
		for _, f in event.files do
			table.insert(list, { path = f.path, sha256 = f.sha256 })
		end
		files = list
	end
	return {
		v = 1,
		op = plan.operation,
		family = plan.family,
		mode = event.mode,
		decision = event.decision,
		context = plan.targetContext,
		context_source = plan.contextSource,
		namespace = plan.targetNamespace,
		release = if plan.helm then plan.helm.release else nil,
		revision = if plan.helm then plan.helm.revision else nil,
		from_revision = if plan.helm then event.fromRevision else nil,
		kubeconfig = plan.kubeconfig,
		cwd = plan.cwd,
		argv = M.redactArgv(plan.argv),
		tier = event.tier,
		fingerprint = event.fingerprint,
		exit_code = event.exitCode,
		previewed_at = event.previewedAt,
		decided_at = event.decidedAt,
		started_at = event.startedAt,
		finished_at = event.finishedAt,
		objects = objects,
		objects_total = if event.objects then #event.objects else nil,
		files = files,
	}
end

local ORDER = {
	"v",
	"decided_at",
	"decision",
	"mode",
	"op",
	"family",
	"context",
	"context_source",
	"namespace",
	"release",
	"revision",
	"from_revision",
	"kubeconfig",
	"cwd",
	"argv",
	"tier",
	"fingerprint",
	"exit_code",
	"previewed_at",
	"started_at",
	"finished_at",
	"objects",
	"objects_total",
	"files",
}

local function quote(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function value(v: any): string
	local t = type(v)
	if t == "string" then
		return quote(v)
	elseif t == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.17g", v)
	elseif t == "boolean" then
		return tostring(v)
	end
	local parts: { string } = {}
	for _, item in v do
		if type(item) == "table" then
			-- File entries: fixed key order.
			table.insert(parts, '{"path":' .. quote(item.path) .. ',"sha256":' .. quote(item.sha256) .. "}")
		else
			table.insert(parts, quote(item))
		end
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

-- Fixed key order, absent fields omitted, terminated by "\n".
function M.line(record: Record): string
	local r = record :: any
	local parts: { string } = {}
	for _, key in ORDER do
		local v = r[key]
		if v ~= nil then
			table.insert(parts, quote(key) .. ":" .. value(v))
		end
	end
	return "{" .. table.concat(parts, ",") .. "}\n"
end

-- What is known about a run before it starts (a guard approval).
export type Outcome = {
	mode: Mode,
	tier: T.Tier?,
	fingerprint: string?,
	previewedAt: number?,
	objects: { string }?,
	files: { Fingerprint.FileDigest }?,
	fromRevision: number?,
}

-- Fields of an outcome record that only the process running the command
-- knows, as they appear in the template; the guard replaces each with the
-- field and its value. A needle starts and ends with an unescaped `"`, which
-- quote() never emits inside a value, so each occurs exactly once.
M.OUTCOME_FIELDS = {
	{ key = "decided_at", needle = '"decided_at":@' },
	{ key = "decision", needle = '"decision":"@"' },
	{ key = "exit_code", needle = '"exit_code":@' },
	{ key = "started_at", needle = '"started_at":@' },
	{ key = "finished_at", needle = '"finished_at":@' },
}

-- One line, no newline: the executed/failed record of a run that starts after
-- the block closed, with the OUTCOME_FIELDS needles in place of their values.
function M.outcomeTemplate(plan: Plan, o: Outcome): string
	local line = M.line(M.record(plan, {
		mode = o.mode,
		decision = "executed",
		tier = o.tier,
		fingerprint = o.fingerprint,
		exitCode = 0,
		previewedAt = o.previewedAt,
		decidedAt = 0,
		startedAt = 0,
		finishedAt = 0,
		objects = o.objects,
		files = o.files,
		fromRevision = o.fromRevision,
	}))
	for _, f in M.OUTCOME_FIELDS do
		local filled = if f.key == "decision" then '"' .. f.key .. '":"executed"' else '"' .. f.key .. '":0'
		local i, j = string.find(line, filled, 1, true)
		if i and j then
			line = string.sub(line, 1, i - 1) .. f.needle .. string.sub(line, j + 1)
		end
	end
	return (string.gsub(line, "\n$", ""))
end

return M
