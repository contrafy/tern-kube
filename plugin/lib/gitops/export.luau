--!strict
-- Plans an export of live objects into a manifest directory without touching
-- the filesystem: the host writes `files` and `kustomizationEdits` only after
-- the user confirmed the previewed statuses and diffs. Every decision is
-- deterministic (sorted inputs, fixed collision order) so the same cluster
-- state always produces the same tree, and nothing existing is replaced
-- silently: objects already present in a file are updated in place (other
-- documents and comments survive), and existing Secret manifests are never
-- overwritten with placeholders.
local Clean = require("./clean")
local Emit = require("./emit")
local Kinds = require("../kubectl/kinds")
local Resource = require("../model/resource")
local Types = require("../model/types")
local Yaml = require("../parse/yaml")

type Object = { [string]: any }
type Ref = Types.ResourceRef

export type Style = "per-kind-dirs" | "per-namespace-kind-dirs" | "file-per-resource" | "multi-doc" | "unknown"

-- Same shape as gitops/index.layout(); extra fields are ignored.
export type Layout = {
	style: Style,
	naming: string,
	ext: string,
	kustomization: boolean,
	kindDir: string?,
}

export type Target = {
	dir: string,
	layout: Layout?,
	-- File name for the multi-doc style (default `resources<ext>`).
	file: string?,
}

export type Status = "new" | "modified" | "unchanged"

export type FileChange = {
	path: string,
	text: string,
	status: Status,
	-- Unified diff against the existing text (all additions for new files).
	diff: string?,
	keys: { string },
}

export type Note = {
	severity: "info" | "warning",
	code: string,
	text: string,
	key: string?,
	path: string?,
}

export type Plan = {
	files: { FileChange },
	kustomizationEdits: { FileChange },
	notes: { Note },
}

export type Options = {
	isList: ((t: { [any]: any }) -> boolean)?,
	null: any?,
	clean: Clean.Options?,
}

local DEFAULT_LAYOUT: Layout = {
	style = "per-namespace-kind-dirs",
	naming = "<name>",
	ext = ".yaml",
	kustomization = true,
	kindDir = "<kind>",
}

local CLUSTER_DIR = "_cluster"
local KUSTOMIZATION_NAMES = { "kustomization.yaml", "kustomization.yml", "Kustomization" }

local APPLY_RANK: { [string]: number } = {
	Namespace = 1,
	CustomResourceDefinition = 2,
	ServiceAccount = 3,
	Role = 4,
	ClusterRole = 4,
	RoleBinding = 5,
	ClusterRoleBinding = 5,
	ConfigMap = 6,
	Secret = 6,
	Service = 7,
	Deployment = 8,
	StatefulSet = 8,
	DaemonSet = 8,
	ReplicaSet = 8,
	ReplicationController = 8,
	Job = 8,
	CronJob = 8,
	Pod = 8,
}

type Entry = {
	ref: Ref,
	key: string,
	object: Object,
	path: string,
	-- Existing document to replace in place.
	doc: Yaml.Doc?,
}

local function note(
	notes: { Note },
	severity: "info" | "warning",
	code: string,
	text: string,
	key: string?,
	path: string?
)
	table.insert(notes, { severity = severity, code = code, text = text, key = key, path = path })
end

local function join(dir: string, name: string): string
	return (string.gsub(dir, "/+$", "")) .. "/" .. name
end

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or ""
end

local function basename(path: string): string
	return string.match(path, "([^/]*)$") :: string
end

local function sanitize(s: string): string
	return (string.gsub(s, "[^%w%._%-]", "-"))
end

-- Key with the namespace blanked: matches docs whose namespace is inferred.
local function looseKey(ref: Ref): string
	return table.concat({ ref.group or "", ref.kind, "", ref.name }, "/")
end

local function applyLess(a: Entry, b: Entry): boolean
	local ra, rb = APPLY_RANK[a.ref.kind] or 9, APPLY_RANK[b.ref.kind] or 9
	if ra ~= rb then
		return ra < rb
	end
	if a.ref.kind ~= b.ref.kind then
		return a.ref.kind < b.ref.kind
	end
	return a.key < b.key
end

local function normalizeLayout(layout: Layout?): Layout
	if not layout then
		return DEFAULT_LAYOUT
	end
	if layout.style == "unknown" then
		return {
			style = DEFAULT_LAYOUT.style,
			naming = DEFAULT_LAYOUT.naming,
			ext = layout.ext or DEFAULT_LAYOUT.ext,
			kustomization = layout.kustomization,
			kindDir = DEFAULT_LAYOUT.kindDir,
		}
	end
	return layout
end

local function plural(ref: Ref): string
	local token = string.lower(ref.kind) .. (if ref.group then "." .. ref.group else "")
	local info = Kinds.normalize(token)
	if info.known then
		return info.plural
	end
	local lower = string.lower(ref.kind)
	if string.find(lower, "[^aeiou]y$") then
		return string.sub(lower, 1, -2) .. "ies"
	elseif string.find(lower, "[sx]$") or string.find(lower, "[cs]h$") then
		return lower .. "es"
	end
	return lower .. "s"
end

local function namespaceDir(ref: Ref): string
	if ref.kind == "Namespace" and ref.group == nil then
		return sanitize(ref.name)
	end
	return if ref.namespace then sanitize(ref.namespace) else CLUSTER_DIR
end

local function fileName(layout: Layout, ref: Ref): string
	local tokens: { [string]: string } = {
		["<kind>"] = sanitize(string.lower(ref.kind)),
		["<name>"] = sanitize(ref.name),
		["<namespace>"] = namespaceDir(ref),
	}
	local name = string.gsub(layout.naming, "<%a+>", function(token: string): string
		return tokens[token] or token
	end)
	return name .. layout.ext
end

local function layoutPath(target: Target, layout: Layout, ref: Ref): string
	if layout.style == "multi-doc" then
		return join(target.dir, target.file or ("resources" .. layout.ext))
	end
	local file = fileName(layout, ref)
	if layout.style == "file-per-resource" then
		return join(target.dir, file)
	end
	local kindDir = if layout.kindDir == "<plural>" then plural(ref) else sanitize(string.lower(ref.kind))
	if layout.style == "per-kind-dirs" then
		return join(join(target.dir, kindDir), file)
	end
	return join(join(join(target.dir, namespaceDir(ref)), kindDir), file)
end

-- Alternatives tried in order when a path is taken by another object.
local function alternative(path: string, ref: Ref, attempt: number): string
	local stem, ext = string.match(path, "^(.*)(%.[^./]+)$")
	local base, suffix = stem or path, ext or ""
	if attempt == 1 then
		return base .. "-" .. sanitize(string.lower(ref.kind)) .. suffix
	elseif attempt == 2 then
		return base .. "-" .. sanitize(string.lower(ref.kind)) .. "-" .. namespaceDir(ref) .. suffix
	end
	return base .. "-" .. attempt - 1 .. suffix
end

local function isKustomization(path: string): boolean
	return table.find(KUSTOMIZATION_NAMES, basename(path)) ~= nil
end

type Located = { path: string, doc: Yaml.Doc }
type Existing = {
	exact: { [string]: Located },
	loose: { [string]: Located },
}

local function indexExisting(existing: { [string]: string }): Existing
	local paths: { string } = {}
	for path in existing do
		if string.find(path, "%.ya?ml$") and not isKustomization(path) then
			table.insert(paths, path)
		end
	end
	table.sort(paths)
	local out: Existing = { exact = {}, loose = {} }
	for _, path in paths do
		for _, doc in Yaml.split(existing[path]).docs do
			local ref = doc.ref
			-- Objects nested in a `kind: List` cannot be replaced by a top-level document.
			if ref and doc.indent == 0 then
				local located = { path = path, doc = doc }
				if ref.namespace then
					local k = Resource.key(ref)
					out.exact[k] = out.exact[k] or located
				else
					local k = looseKey(ref)
					out.loose[k] = out.loose[k] or located
				end
			end
		end
	end
	return out
end

-- Line-level LCS diff; context of 3 lines per hunk.
local MAX_DIFF_CELLS = 4000000

local function lines(text: string): { string }
	local out = string.split(text, "\n")
	if out[#out] == "" then
		table.remove(out)
	end
	return out
end

type Op = { tag: " " | "-" | "+", text: string, a: number, b: number }

local function editScript(a: { string }, b: { string }): { Op }
	local n, m = #a, #b
	local ops: { Op } = {}
	if n * m > MAX_DIFF_CELLS then
		for i, s in a do
			table.insert(ops, { tag = "-", text = s, a = i, b = 0 })
		end
		for j, s in b do
			table.insert(ops, { tag = "+", text = s, a = n, b = j })
		end
		return ops
	end
	-- L(i, j) = LCS length of a[i..] and b[j..], for i in 1..n+1, j in 1..m+1.
	local w = m + 2
	local lcs = table.create((n + 2) * w, 0)
	local function at(i: number, j: number): number
		return i * w + j
	end
	for i = n, 1, -1 do
		for j = m, 1, -1 do
			lcs[at(i, j)] = if a[i] == b[j]
				then lcs[at(i + 1, j + 1)] + 1
				else math.max(lcs[at(i + 1, j)], lcs[at(i, j + 1)])
		end
	end
	local i, j = 1, 1
	while i <= n and j <= m do
		if a[i] == b[j] then
			table.insert(ops, { tag = " ", text = a[i], a = i, b = j })
			i += 1
			j += 1
		elseif lcs[at(i + 1, j)] >= lcs[at(i, j + 1)] then
			table.insert(ops, { tag = "-", text = a[i], a = i, b = j - 1 })
			i += 1
		else
			table.insert(ops, { tag = "+", text = b[j], a = i - 1, b = j })
			j += 1
		end
	end
	for k = i, n do
		table.insert(ops, { tag = "-", text = a[k], a = k, b = m })
	end
	for k = j, m do
		table.insert(ops, { tag = "+", text = b[k], a = n, b = k })
	end
	return ops
end

local function unified(old: string?, new: string, path: string): string?
	if old == new then
		return nil
	end
	local a, b = lines(old or ""), lines(new)
	local ops = editScript(a, b)
	local out = { "--- " .. (if old then path else "/dev/null"), "+++ " .. path }
	local k = 1
	while k <= #ops do
		if ops[k].tag == " " then
			k += 1
			continue
		end
		local first = math.max(1, k - 3)
		local last = k
		local probe = k
		while probe <= #ops do
			if ops[probe].tag ~= " " then
				last = probe
				probe += 1
			elseif probe - last > 6 then
				break
			else
				probe += 1
			end
		end
		last = math.min(#ops, last + 3)
		local aStart, bStart, aCount, bCount = 0, 0, 0, 0
		local body = {}
		for x = first, last do
			local op = ops[x]
			if op.tag ~= "+" then
				aCount += 1
				if aStart == 0 then
					aStart = op.a
				end
			end
			if op.tag ~= "-" then
				bCount += 1
				if bStart == 0 then
					bStart = op.b
				end
			end
			table.insert(body, op.tag .. op.text)
		end
		if aCount == 0 then
			aStart = ops[first].a
		end
		if bCount == 0 then
			bStart = ops[first].b
		end
		table.insert(out, string.format("@@ -%d,%d +%d,%d @@", aStart, aCount, bStart, bCount))
		table.move(body, 1, #body, #out + 1, out)
		k = last + 1
	end
	return table.concat(out, "\n") .. "\n"
end

local function change(path: string, old: string?, text: string, keys: { string }): FileChange
	local status: Status = if old == nil then "new" elseif old == text then "unchanged" else "modified"
	return { path = path, text = text, status = status, diff = unified(old, text, path), keys = keys }
end

-- kustomization.yaml `resources:` editing, line-based so comments, ordering
-- and every other field survive untouched.
local function unquote(s: string): string
	local v = string.match(s, "^%s*(.-)%s*$") :: string
	v = string.match(v, "^'(.*)'$") or string.match(v, '^"(.*)"$') or v
	v = string.gsub(v, "^%./", "")
	return (string.gsub(v, "/+$", ""))
end

local function addResources(text: string?, entries: { string }): string
	if text == nil or not string.find(text, "%S") then
		local out = { "apiVersion: kustomize.config.k8s.io/v1beta1", "kind: Kustomization", "resources:" }
		for _, e in entries do
			table.insert(out, "  - " .. Emit.quote(e))
		end
		return table.concat(out, "\n") .. "\n"
	end
	local src = lines(text :: string)
	local header: number? = nil
	for i, line in src do
		if string.find(line, "^resources%s*:") then
			header = i
			break
		end
	end
	local function missing(listed: { [string]: true }): { string }
		local out = {}
		for _, e in entries do
			if not listed[e] then
				table.insert(out, e)
			end
		end
		return out
	end
	if header == nil then
		local out = table.clone(src)
		table.insert(out, "resources:")
		for _, e in entries do
			table.insert(out, "  - " .. Emit.quote(e))
		end
		return table.concat(out, "\n") .. "\n"
	end
	local h = header :: number
	local flow = string.match(src[h], "^resources%s*:%s*%[(.*)%]%s*$")
	if flow then
		local listed: { [string]: true } = {}
		local items: { string } = {}
		for _, item in string.split(flow, ",") do
			if string.find(item, "%S") then
				table.insert(items, (string.match(item, "^%s*(.-)%s*$")) :: string)
				listed[unquote(item)] = true
			end
		end
		local add = missing(listed)
		if #add == 0 then
			return text :: string
		end
		local out = table.clone(src)
		local block = { "resources:" }
		for _, item in items do
			table.insert(block, "  - " .. item)
		end
		for _, e in add do
			table.insert(block, "  - " .. Emit.quote(e))
		end
		out[h] = table.concat(block, "\n")
		return table.concat(out, "\n") .. "\n"
	end
	local listed: { [string]: true } = {}
	local last = h
	local prefix = "  - "
	local i = h + 1
	while i <= #src do
		local line = src[i]
		local indent, item = string.match(line, "^(%s*%-%s+)(.*)$")
		-- Blank, comment and continuation lines stay inside the sequence.
		local inside = indent ~= nil or string.find(line, "^%s*$") ~= nil or string.find(line, "^%s+%S") ~= nil
		if not inside then
			break
		end
		if indent then
			listed[unquote((string.gsub(item :: string, "%s+#.*$", "")))] = true
			prefix = indent :: string
			last = i
		end
		i += 1
	end
	local add = missing(listed)
	if #add == 0 then
		return text :: string
	end
	local out: { string } = {}
	table.move(src, 1, last, 1, out)
	for _, e in add do
		table.insert(out, prefix .. Emit.quote(e))
	end
	table.move(src, last + 1, #src, #out + 1, out)
	return table.concat(out, "\n") .. "\n"
end

local function kustomizationPath(dir: string, ext: string, existing: { [string]: string }): string
	for _, name in KUSTOMIZATION_NAMES do
		local p = join(dir, name)
		if existing[p] ~= nil then
			return p
		end
	end
	return join(dir, "kustomization" .. ext)
end

local function kustomizationEdits(
	target: Target,
	layout: Layout,
	newFiles: { string },
	existing: { [string]: string }
): { FileChange }
	local root = (string.gsub(target.dir, "/+$", ""))
	local byDir: { [string]: { [string]: true } } = {}
	for _, path in newFiles do
		local child = path
		local dir = dirname(child)
		while #dir >= #root and string.sub(child, 1, #root + 1) == root .. "/" do
			byDir[dir] = byDir[dir] or {}
			byDir[dir][basename(child)] = true
			if dir == root then
				break
			end
			child = dir
			dir = dirname(dir)
		end
	end
	local dirs: { string } = {}
	for dir in byDir do
		table.insert(dirs, dir)
	end
	table.sort(dirs)
	local out: { FileChange } = {}
	for _, dir in dirs do
		local entries: { string } = {}
		for name in byDir[dir] do
			table.insert(entries, name)
		end
		table.sort(entries)
		local path = kustomizationPath(dir, layout.ext, existing)
		local old = existing[path]
		local edit = change(path, old, addResources(old, entries), {})
		if edit.status ~= "unchanged" then
			table.insert(out, edit)
		end
	end
	return out
end

local function emitDoc(entry: Entry, opts: Options): string
	local isSecret = entry.ref.kind == "Secret" and entry.ref.group == nil
	return Emit.yaml(entry.object, {
		isList = opts.isList,
		null = opts.null,
		comments = if isSecret then { Clean.SECRET_COMMENT } else nil,
	})
end

local function renderFile(entries: { Entry }, old: string?, opts: Options): string
	table.sort(entries, applyLess)
	if old == nil then
		local docs = {}
		for _, e in entries do
			table.insert(docs, emitDoc(e, opts))
		end
		return table.concat(docs, "---\n")
	end
	local src = lines(old)
	local replacements: { { first: number, last: number, text: string } } = {}
	local appended: { string } = {}
	for _, e in entries do
		local doc = e.doc
		if doc then
			table.insert(replacements, { first = doc.startLine, last = doc.endLine, text = emitDoc(e, opts) })
		else
			table.insert(appended, emitDoc(e, opts))
		end
	end
	table.sort(replacements, function(a, b)
		return a.first > b.first
	end)
	for _, r in replacements do
		local body = lines(r.text)
		local out: { string } = {}
		table.move(src, 1, r.first - 1, 1, out)
		table.move(body, 1, #body, #out + 1, out)
		table.move(src, r.last + 1, #src, #out + 1, out)
		src = out
	end
	local text = if #src > 0 then table.concat(src, "\n") .. "\n" else ""
	for _, doc in appended do
		text ..= (if string.find(text, "%S") then "---\n" else "") .. doc
	end
	return text
end

local function plan(objects: { Object }, target: Target, existing: { [string]: string }, opts: Options?): Plan
	local options: Options = opts or {}
	local layout = normalizeLayout(target.layout)
	local notes: { Note } = {}
	local index = indexExisting(existing)

	local entries: { Entry } = {}
	local seen: { [string]: true } = {}
	for _, raw in objects do
		local ref = Resource.fromObject(raw, "live")
		if not ref then
			note(notes, "warning", "invalid", "skipped an object without kind or metadata.name")
			continue
		end
		local key = Resource.key(ref)
		if seen[key] then
			note(notes, "info", "duplicate", "exported once despite appearing twice in the input", key)
			continue
		end
		seen[key] = true
		local cleaned, cleanNotes = Clean.clean(raw, options.clean)
		for _, n in cleanNotes do
			note(notes, n.severity, n.code, n.text, key)
		end
		if cleaned then
			table.insert(entries, { ref = ref, key = key, object = cleaned, path = "" })
		end
	end
	table.sort(entries, function(a, b)
		return a.key < b.key
	end)

	local taken: { [string]: string } = {}
	local pending: { Entry } = {}
	for _, e in entries do
		local located = index.exact[e.key] or index.loose[looseKey(e.ref)]
		if located then
			e.path, e.doc = located.path, located.doc
			taken[e.path] = taken[e.path] or e.key
			if e.ref.kind == "Secret" and e.ref.group == nil then
				note(
					notes,
					"warning",
					"secret-kept",
					"kept the existing Secret manifest; values are never exported",
					e.key,
					e.path
				)
				e.path = ""
			else
				note(notes, "info", "existing", "updates the existing manifest in place", e.key, e.path)
			end
		else
			table.insert(pending, e)
		end
	end

	local multi = layout.style == "multi-doc"
	for _, e in pending do
		local base = layoutPath(target, layout, e.ref)
		local path = base
		local attempt = 0
		local function conflict(p: string): boolean
			if multi then
				return false
			end
			if taken[p] ~= nil and taken[p] ~= e.key then
				return true
			end
			return existing[p] ~= nil and string.find(existing[p], "%S") ~= nil
		end
		while conflict(path) do
			attempt += 1
			path = alternative(base, e.ref, attempt)
		end
		if path ~= base then
			note(notes, "warning", "collision", "path taken by another object; using " .. path, e.key, base)
		end
		taken[path] = e.key
		e.path = path
	end

	local byPath: { [string]: { Entry } } = {}
	for _, e in entries do
		if e.path ~= "" then
			byPath[e.path] = byPath[e.path] or {}
			table.insert(byPath[e.path], e)
		end
	end
	local paths: { string } = {}
	for path in byPath do
		table.insert(paths, path)
	end
	table.sort(paths)

	local files: { FileChange } = {}
	local newFiles: { string } = {}
	for _, path in paths do
		local group = byPath[path]
		local keys: { string } = {}
		local old = existing[path]
		local text = renderFile(group, old, options)
		for _, e in group do
			table.insert(keys, e.key)
		end
		local fc = change(path, old, text, keys)
		table.insert(files, fc)
		if fc.status == "new" then
			table.insert(newFiles, path)
		end
	end

	local edits = if layout.kustomization then kustomizationEdits(target, layout, newFiles, existing) else {}
	return { files = files, kustomizationEdits = edits, notes = notes }
end

return {
	plan = plan,
	addResources = addResources,
	unified = unified,
	DEFAULT_LAYOUT = DEFAULT_LAYOUT,
}
