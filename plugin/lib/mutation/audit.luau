--!strict
-- One JSON line per decision for tern.plugin.data/audit.log. Built from an
-- explicit whitelist: command output, environment values and credentials
-- passed on the command line never reach the log (only the kubeconfig path).
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
}

export type Record = {
	v: number,
	op: string,
	family: string,
	mode: Mode,
	decision: Decision,
	context: string,
	context_source: string,
	namespace: string?,
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
}

local M = {}

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
	return {
		v = 1,
		op = plan.operation,
		family = plan.family,
		mode = event.mode,
		decision = event.decision,
		context = plan.targetContext,
		context_source = plan.contextSource,
		namespace = plan.targetNamespace,
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
	"kubeconfig",
	"cwd",
	"argv",
	"tier",
	"fingerprint",
	"exit_code",
	"previewed_at",
	"started_at",
	"finished_at",
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
		table.insert(parts, quote(item))
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

return M
