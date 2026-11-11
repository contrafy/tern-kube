--!strict
-- One JSON line per decision for tern.plugin.data/audit.log. Built from an
-- explicit whitelist: command output, environment values and credentials
-- passed on the command line never reach the log (only the kubeconfig path).
local Argv = require("../kubectl/argv")
local Fingerprint = require("./fingerprint")
local Redact = require("../model/redact")
local T = require("./types")

type Plan = T.Plan

-- quick: a mutating quick action (approved in the block, run in a split).
export type Mode = "native" | "guard" | "quick"
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
	-- Quick actions: the window's run id (32 hex) shared with the outcome record.
	run: string?,
}

export type FileEntry = { path: string, sha256: string }

export type Record = {
	v: number,
	op: string,
	family: string,
	mode: Mode,
	run: string?,
	decision: Decision,
	context: string,
	context_source: string,
	namespace: string?,
	release: string?,
	revision: number?,
	from_revision: number?,
	kubeconfig: string?,
	-- Absent in quick outcome records: the split's directory says nothing.
	cwd: string?,
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
local SECRET_FLAGS = { token = true, password = true, ["docker-password"] = true }
M.REDACTED = "<redacted>"

-- `KEY=VALUE` with the value masked when masking applies to it.
local function maskPair(pair: string, all: boolean): string
	local key = string.match(pair, "^([^=]+)=")
	if key and (all or Redact.sensitiveKey(key)) then
		return key .. "=" .. M.REDACTED
	end
	return pair
end

-- What else the command carries in clear: `create secret ...` literals
-- (every --from-literal value) and `set env`/`run` variables under a
-- sensitive name (`DB_PASSWORD=...`, also as --env values).
local function literalScope(argv: { string }): (boolean, boolean)
	if #argv < 2 then
		return false, false
	end
	local inv = Argv.parse(argv[1], table.move(argv, 2, #argv, 1, {}))
	local secret = inv.verb == "create" and string.sub(inv.subverb or "", 1, 6) == "secret"
	local env = (inv.verb == "set" and inv.subverb == "env") or inv.verb == "run"
	return secret, env
end

-- Replaces credential values in `--token X`, `--token=X` (also --password,
-- --docker-password), secret literals and sensitive environment values;
-- arguments after `--` belong to the container command and are kept.
function M.redactArgv(argv: { string }): { string }
	local secret, env = literalScope(argv)
	local out: { string } = {}
	local hide: string? = nil
	local afterDash = false
	for _, a in argv do
		if hide == "all" then
			table.insert(out, M.REDACTED)
			hide = nil
			continue
		elseif hide == "literal" then
			table.insert(out, maskPair(a, true))
			hide = nil
			continue
		end
		hide = nil
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
						hide = "all"
					end
					continue
				elseif name == "from-literal" and secret then
					if eq == "=" then
						table.insert(out, "--from-literal=" .. maskPair(string.sub(a, #"--from-literal=" + 1), true))
					else
						table.insert(out, a)
						hide = "literal"
					end
					continue
				elseif env and name == "env" and eq == "=" then
					table.insert(out, "--env=" .. maskPair(string.sub(a, #"--env=" + 1), false))
					continue
				elseif env and string.match(a, "^%-e=?.") then
					local prefix = if string.sub(a, 3, 3) == "=" then "-e=" else "-e"
					table.insert(out, prefix .. maskPair(string.sub(a, #prefix + 1), false))
					continue
				elseif env and string.sub(a, 1, 1) ~= "-" then
					table.insert(out, maskPair(a, false))
					continue
				end
			end
		end
		table.insert(out, a)
	end
	return out
end

local function runId(run: string?): string?
	return if type(run) == "string" and #run == 32 and string.find(run, "^[0-9a-f]+$") then run else nil
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
		run = runId(event.run),
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
	"run",
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

-- A filled record line with the OUTCOME_FIELDS needles in place of their
-- zero values, newline dropped.
local function fillNeedles(line: string): string
	for _, f in M.OUTCOME_FIELDS do
		local filled = if f.key == "decision" then '"' .. f.key .. '":"executed"' else '"' .. f.key .. '":0'
		local i, j = string.find(line, filled, 1, true)
		if i and j then
			line = string.sub(line, 1, i - 1) .. f.needle .. string.sub(line, j + 1)
		end
	end
	return (string.gsub(line, "\n$", ""))
end

-- One line, no newline: the executed/failed record of a run that starts after
-- the block closed, with the OUTCOME_FIELDS needles in place of their values.
function M.outcomeTemplate(plan: Plan, o: Outcome): string
	return fillNeedles(M.line(M.record(plan, {
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
	})))
end

-- What the window knows about a confirmed quick action: the validated fields
-- the split's argv is built from.
export type QuickRun = {
	op: string,
	family: string,
	-- nil: the argv has no --context (kubectl's current context).
	context: string?,
	namespace: string?,
	kubeconfig: string?,
	argv: { string },
	run: string?,
	objects: { string }?,
}

-- The outcome record template of a quick action's split, as outcomeTemplate:
-- one line, the OUTCOME_FIELDS needles in place of their values. A confirmed
-- link pins --context ("flag"). Tier and fingerprint are in the approved
-- record with the same run id.
function M.quickTemplate(q: QuickRun): string
	local record: Record = {
		v = 1,
		op = q.op,
		family = q.family,
		mode = "quick",
		run = runId(q.run),
		decision = "executed",
		context = q.context or "",
		context_source = if q.context then "flag" else "inferred",
		namespace = q.namespace,
		kubeconfig = q.kubeconfig,
		argv = M.redactArgv(q.argv),
		exit_code = 0,
		decided_at = 0,
		started_at = 0,
		finished_at = 0,
		objects = q.objects,
		objects_total = if q.objects then #q.objects else nil,
	}
	return fillNeedles(M.line(record))
end

return M
