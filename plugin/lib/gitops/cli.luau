--!strict
-- The bin/tern-kube-drift command that reproduces a drift report (or a
-- matrix) outside Tern. It must compare what Explore compared: the same
-- files (`-R` only when git proves the directory holds exactly them), the
-- same namespace for namespace-less documents, the same contexts in column
-- order and the same unmanaged kinds. Paths are absolute, so pasting the
-- line changes no shell state. Pure: the caller gathers the inputs.
local Command = require("../kubectl/command")
local Types = require("../model/types")

local M = {}

M.PROGRAM = "tern-kube-drift"
-- A git listing longer than this is treated as unknown (explicit files).
M.LIST_MAX = 5000

export type Helm = { chart: string, release: string, namespace: string?, values: { string } }

export type Source = {
	type: string,
	path: string,
	-- Dir sources: the compared files (absolute), Explore's diff input.
	files: { string }?,
	-- Dir sources: M.recursive held.
	recursive: boolean?,
	helm: Helm?,
}

export type Input = {
	source: Source,
	-- One context, or a matrix's columns in order (base first).
	contexts: { string },
	kubeconfig: string?,
	namespace: string?,
	-- Explicit `get` resource types; nil or empty: no --unmanaged.
	unmanaged: { string }?,
	-- helm.program; a HELM= prefix unless it is plain `helm`.
	helmProgram: string?,
}

-- The fields of a manifest document namespaceArg reads.
export type NamespaceDoc = { ref: Types.ResourceRef?, namespaceInferred: boolean }

local function push(argv: { string }, ...: string)
	for _, a in { ... } do
		table.insert(argv, a)
	end
end

function M.argv(input: Input): { string }
	local argv = { M.PROGRAM }
	local src = input.source
	local helm = src.helm
	if src.type == "helm" and helm then
		push(argv, "--helm", helm.chart, "--release", helm.release)
		for _, v in helm.values do
			push(argv, "--values", v)
		end
	elseif src.type == "kustomize" then
		push(argv, "-k", src.path)
	elseif src.type == "dir" and src.recursive then
		push(argv, "-R", "-f", src.path)
	elseif src.type == "dir" then
		for _, f in (src.files or {}) :: { string } do
			push(argv, "-f", f)
		end
	else
		push(argv, "-f", src.path)
	end
	for _, c in input.contexts do
		push(argv, "--context", c)
	end
	if input.kubeconfig then
		push(argv, "--kubeconfig", input.kubeconfig :: string)
	end
	if input.namespace then
		push(argv, "-n", input.namespace :: string)
	end
	local kinds = input.unmanaged
	if kinds and #kinds > 0 then
		push(argv, "--unmanaged", table.concat(kinds, ","))
	end
	return argv
end

function M.format(input: Input): string
	local line = Command.format(M.argv(input))
	local program = input.helmProgram
	if input.source.type == "helm" and program and program ~= "helm" then
		return "HELM=" .. Command.quote(program) .. " " .. line
	end
	return line
end

local EXTENSIONS: { [string]: boolean } = { json = true, yaml = true, yml = true }

-- kubectl -R reads files with exactly these extensions (case-sensitive).
local function readByKubectl(path: string): boolean
	local ext = string.match(path, "%.([^./]+)$")
	return ext ~= nil and EXTENSIONS[ext] == true
end

local function under(path: string, dir: string): boolean
	local d = string.gsub(dir, "/+$", "")
	return string.sub(path, 1, #d + 1) == d .. "/"
end

-- `git -C root ls-files -c -o -z -- <dir>` output as absolute paths; nil
-- when it holds more than LIST_MAX paths.
function M.listed(root: string, stdout: string): { string }?
	local out: { string } = {}
	local base = string.gsub(root, "/+$", "")
	for _, rel in string.split(stdout, "\0") do
		if rel ~= "" then
			if #out >= M.LIST_MAX then
				return nil
			end
			table.insert(out, base .. "/" .. rel)
		end
	end
	return out
end

-- Whether `-R -f dir` reads exactly the compared files: every file kubectl
-- would read under dir (tracked, untracked and ignored, per `listed`) is
-- compared, and every compared file is among them.
function M.recursive(dir: string, compared: { string }, listed: { string }?): boolean
	if listed == nil or #compared == 0 then
		return false
	end
	local want: { [string]: boolean } = {}
	for _, f in compared do
		if not under(f, dir) then
			return false
		end
		want[f] = true
	end
	local seen = 0
	for _, f in listed do
		if under(f, dir) and readByKubectl(f) then
			if not want[f] then
				return false
			end
			want[f] = nil
			seen += 1
		end
	end
	return next(want) == nil and seen > 0
end

-- The -n kubectl needs for `docs` so namespace-less documents land in the
-- target namespace (where the report resolves them). kubectl refuses -n
-- next to a document of another namespace: then no -n, and a note.
-- docs: any array of NamespaceDoc-shaped tables (Luau arrays are invariant).
function M.namespaceArg(docs: { any }, target: string?): (string?, string?)
	if target == nil then
		return nil, nil
	end
	local inferred = 0
	local other = false
	for _, doc in docs do
		local d: NamespaceDoc = doc
		local ref = d.ref
		if d.namespaceInferred then
			inferred += 1
		elseif ref and ref.namespace and ref.namespace ~= target then
			other = true
		end
	end
	if inferred == 0 then
		return nil, nil
	elseif other then
		return nil,
			string.format(
				"%d %s without a namespace %s compared in the kubeconfig's namespace: "
					.. "kubectl cannot combine -n with documents of other namespaces",
				inferred,
				if inferred == 1 then "document" else "documents",
				if inferred == 1 then "is" else "are"
			)
	end
	return target, nil
end

return M
