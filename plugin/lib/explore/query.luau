--!strict
-- kubectl argv for every Explore read. Each cluster query pins --context (and
-- --kubeconfig when known): Explore never relies on the kubeconfig's
-- current-context after resolution, so `kubectl config use-context` in the
-- user's shell cannot redirect it. Only the kubeconfig queries used to
-- resolve the target run without a context.

local Command = require("../kubectl/command")
local Kinds = require("../kubectl/kinds")
local Relations = require("./relations")
local Types = require("../model/types")

type Ref = Types.ResourceRef

export type ContextSource = "flag" | "chosen" | "inferred" | "unresolved"

export type Target = {
	kubeconfig: string?,
	context: string?,
	contextSource: ContextSource,
	namespace: string?,
	allNamespaces: boolean,
	confirmed: boolean,
	-- os.time() when the context was inferred from current-context.
	inferredAt: number?,
}

export type Scope = { namespace: string?, all: boolean }

export type RelQuery = Relations.RelQuery

local M = {}

M.LOG_TAIL = 500

local function kubeconfigArgs(program: string, kubeconfig: string?): { string }
	local argv = { program }
	if kubeconfig and kubeconfig ~= "" then
		table.insert(argv, "--kubeconfig")
		table.insert(argv, kubeconfig)
	end
	return argv
end

function M.base(program: string, target: Target): { string }
	local argv = kubeconfigArgs(program, target.kubeconfig)
	if target.context and target.context ~= "" then
		table.insert(argv, "--context")
		table.insert(argv, target.context)
	end
	return argv
end

local function append(argv: { string }, ...: string): { string }
	for _, a in { ... } do
		table.insert(argv, a)
	end
	return argv
end

local function namespaceOf(argv: { string }, ref: Ref): { string }
	if ref.namespace and ref.namespace ~= "" then
		append(argv, "-n", ref.namespace)
	end
	return argv
end

function M.list(program: string, target: Target, resource: string, scope: Scope): { string }
	local argv = append(M.base(program, target), "get", resource)
	if scope.all then
		table.insert(argv, "-A")
	elseif scope.namespace and scope.namespace ~= "" then
		append(argv, "-n", scope.namespace)
	end
	return append(argv, "-o", "json")
end

function M.get(program: string, target: Target, ref: Ref): { string }
	local argv = append(M.base(program, target), "get", Command.resourceType(ref), ref.name)
	return append(namespaceOf(argv, ref), "-o", "json")
end

function M.describe(program: string, target: Target, ref: Ref): { string }
	return namespaceOf(append(M.base(program, target), "describe", Command.resourceType(ref), ref.name), ref)
end

local function isPod(ref: Ref): boolean
	return ref.kind == "Pod" and (ref.group == nil or ref.group == "")
end

function M.logs(
	program: string,
	target: Target,
	ref: Ref,
	container: string?,
	previous: boolean,
	tail: number?
): { string }
	local subject = if isPod(ref) then ref.name else Command.resourceType(ref) .. "/" .. ref.name
	local argv = namespaceOf(append(M.base(program, target), "logs", subject), ref)
	if container and container ~= "" then
		append(argv, "-c", container)
	end
	if previous then
		table.insert(argv, "--previous")
	end
	table.insert(argv, "--tail=" .. string.format("%d", tail or M.LOG_TAIL))
	return argv
end

function M.contexts(program: string, kubeconfig: string?): { string }
	return append(kubeconfigArgs(program, kubeconfig), "config", "get-contexts", "-o", "name")
end

function M.currentContext(program: string, kubeconfig: string?): { string }
	return append(kubeconfigArgs(program, kubeconfig), "config", "current-context")
end

function M.namespaces(program: string, target: Target): { string }
	return append(M.base(program, target), "get", "namespaces", "-o", "name")
end

function M.apiResources(program: string, target: Target): { string }
	return append(M.base(program, target), "api-resources", "--verbs=list", "-o", "name")
end

-- Secrets are only ever listed by name: their data never reaches Explore.
function M.relation(program: string, target: Target, q: RelQuery): { string }
	local info = Kinds.normalize(q.kind)
	local argv = append(M.base(program, target), "get", q.kind)
	-- A dangling reference is an answer ("missing"), not a failure.
	if q.name and q.name ~= "" then
		append(argv, q.name, "--ignore-not-found")
	end
	-- Relations gives cluster-scoped kinds no namespace: never -A.
	if q.namespace and q.namespace ~= "" then
		append(argv, "-n", q.namespace)
	end
	if q.selector and q.selector ~= "" then
		append(argv, "-l", q.selector)
	end
	if q.fieldSelector and q.fieldSelector ~= "" then
		append(argv, "--field-selector", q.fieldSelector)
	end
	local nameOnly = q.nameOnly == true or (info.known and info.kind == "Secret")
	return append(argv, "-o", if nameOnly then "name" else "json")
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- A LabelSelector (or a plain equality map such as Service spec.selector) as
-- a `-l` argument; nil when it selects nothing.
function M.selectorString(selector: any): string?
	if type(selector) ~= "table" then
		return nil
	end
	local parts: { string } = {}
	local labels = selector.matchLabels
	local exprs = selector.matchExpressions
	if labels == nil and exprs == nil then
		labels = selector
	end
	if type(labels) == "table" then
		for _, k in sortedKeys(labels) do
			if type(labels[k]) == "string" then
				table.insert(parts, k .. "=" .. labels[k])
			end
		end
	end
	if type(exprs) == "table" then
		for _, e in exprs do
			if type(e) ~= "table" or type(e.key) ~= "string" then
				continue
			end
			local values = if type(e.values) == "table" then table.concat(e.values, ",") else ""
			if e.operator == "In" then
				table.insert(parts, e.key .. " in (" .. values .. ")")
			elseif e.operator == "NotIn" then
				table.insert(parts, e.key .. " notin (" .. values .. ")")
			elseif e.operator == "Exists" then
				table.insert(parts, e.key)
			elseif e.operator == "DoesNotExist" then
				table.insert(parts, "!" .. e.key)
			end
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ",")
end

return M
