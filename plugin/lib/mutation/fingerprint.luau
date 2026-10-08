--!strict
-- Canonical description of everything that decides what a mutation does:
-- the exact argv, the resolved context, the kubeconfig, the explicit
-- namespace, the working directory and the content of every input file. The
-- host digests it with sha256 (an injected hasher); the shell guard builds
-- the same bytes, so a guard request and the block agree byte for byte.
--
-- Format "tern-kube/fp/v1", every line ending in "\n", lengths in bytes:
--   tern-kube/fp/v1
--   argv <n>            then n lines `<len>:<arg>`
--   context <len>:<ctx>
--   kubeconfig <len>:<raw KUBECONFIG env value>        or `kubeconfig -`
--                       (--kubeconfig in argv is covered by the argv lines)
--   namespace <len>:<-n value>                          or `namespace 0:`
--   cwd <len>:<physical cwd>
--   files <m>           then m lines `<len>:<abspath> <size> <sha256>`,
--                       sorted by path bytewise
-- Length prefixes make values with spaces or newlines unambiguous; file
-- paths with a newline are refused anyway (the shell side cannot list them).
local T = require("./types")

export type FileDigest = { path: string, size: number, sha256: string }

export type Input = {
	argv: { string },
	context: string,
	kubeconfig: string?,
	namespace: string?,
	cwd: string,
	files: { FileDigest },
}

local M = {}

M.VERSION = "tern-kube/fp/v1"

local function lp(s: string): string
	return #s .. ":" .. s
end

-- Bytewise order (LC_ALL=C sort), independent of any collation.
local function byteLess(a: string, b: string): boolean
	local n = math.min(#a, #b)
	for i = 1, n do
		local x, y = string.byte(a, i), string.byte(b, i)
		if x ~= y then
			return x < y
		end
	end
	return #a < #b
end

function M.canonical(input: Input): (string?, string?)
	if input.context == "" then
		return nil, "fingerprint needs a resolved context"
	end
	local files = table.clone(input.files)
	for _, f in files do
		if string.find(f.path, "\n", 1, true) then
			return nil, string.format("file path %q contains a newline", f.path)
		end
		if string.sub(f.path, 1, 1) ~= "/" then
			return nil, string.format("file path %q is not absolute", f.path)
		end
		if not string.match(f.sha256, "^%x+$") or #f.sha256 ~= 64 then
			return nil, string.format("%s: %q is not a sha256 hex digest", f.path, f.sha256)
		end
		if f.size < 0 or math.floor(f.size) ~= f.size then
			return nil, string.format("%s: invalid size %s", f.path, tostring(f.size))
		end
	end
	table.sort(files, function(a: FileDigest, b: FileDigest): boolean
		return byteLess(a.path, b.path)
	end)
	for i = 2, #files do
		if files[i].path == files[i - 1].path then
			return nil, string.format("file %s listed twice", files[i].path)
		end
	end

	local out: { string } = { M.VERSION, "argv " .. #input.argv }
	for _, a in input.argv do
		table.insert(out, lp(a))
	end
	table.insert(out, "context " .. lp(input.context))
	local kubeconfig = input.kubeconfig
	table.insert(out, if kubeconfig and kubeconfig ~= "" then "kubeconfig " .. lp(kubeconfig) else "kubeconfig -")
	table.insert(out, "namespace " .. lp(input.namespace or ""))
	table.insert(out, "cwd " .. lp(input.cwd))
	table.insert(out, "files " .. #files)
	for _, f in files do
		table.insert(out, string.format("%s %d %s", lp(f.path), f.size, string.lower(f.sha256)))
	end
	return table.concat(out, "\n") .. "\n", nil
end

-- hasher: sha256 hex of a string (the host runs shasum/sha256sum).
function M.compute(input: Input, hasher: (string) -> string): (string?, string?)
	local text, e = M.canonical(input)
	if text == nil then
		return nil, e
	end
	return string.lower(hasher(text)), nil
end

function M.fromPlan(plan: T.Plan, files: { FileDigest }): Input
	return {
		argv = table.clone(plan.argv),
		context = plan.targetContext,
		kubeconfig = plan.envKubeconfig,
		namespace = plan.explicitNamespace,
		cwd = plan.cwd,
		files = files,
	}
end

-- A missing digest never matches: an unverified state must not confirm.
function M.equal(a: string?, b: string?): boolean
	if a == nil or b == nil or a == "" or b == "" then
		return false
	end
	return string.lower(a) == string.lower(b)
end

return M
