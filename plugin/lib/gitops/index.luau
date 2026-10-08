--!strict
-- Manifest index: which file and lines declare each object. Built from plain
-- YAML files (addFile) and from kustomize/helm renders (addRendered); the
-- host (gitops_host.luau) lists and reads files and runs the renderers.
-- Identity comes from parse/yaml.luau, so only kind, apiVersion and
-- metadata.name/namespace are ever interpreted.
local Kinds = require("../kubectl/kinds")
local Resource = require("../model/resource")
local Types = require("../model/types")
local Yaml = require("../parse/yaml")

type Ref = Types.ResourceRef

export type SourceType = "dir" | "file" | "kustomize" | "helm"

export type HelmSpec = { release: string, namespace: string?, values: { string } }

export type Source = {
	type: SourceType,
	root: string,
	path: string,
	helm: HelmSpec?,
	label: string,
}

export type ManifestDoc = {
	-- Resource key with the namespace resolved; nil while it is unknown.
	key: string?,
	ref: Ref?,
	file: string,
	startLine: number,
	endLine: number,
	source: Source,
	-- The object is namespaced (or of an unknown kind) and nothing says
	-- where: kubectl would use -n or the context default.
	namespaceInferred: boolean,
	-- From a kustomize/helm render: file and lines are the best-guess
	-- origin, `text` is the rendered document.
	rendered: boolean,
	text: string?,
	-- Directory of the kustomization listing this file as a resource or patch.
	kustomization: string?,
	-- A kustomize patch: a partial object, never the manifest of anything.
	patch: boolean,
	-- metadata.namespace as written in the document.
	declaredNamespace: string?,
}

export type Kustomization = {
	dir: string,
	file: string,
	namespace: string?,
	namePrefix: string?,
	nameSuffix: string?,
	-- Absolute files or directories (other kustomizations); remote refs dropped.
	resources: { string },
	patches: { string },
}

export type Diagnostic = {
	file: string?,
	line: number?,
	severity: "error" | "warning" | "info",
	text: string,
}

export type Limits = { maxFiles: number, maxBytes: number, maxFileBytes: number }

export type Index = {
	root: string,
	sources: { Source },
	docs: { ManifestDoc },
	byKey: { [string]: { ManifestDoc } },
	kustomizations: { [string]: Kustomization },
	diagnostics: { Diagnostic },
	truncated: boolean,
	scannedFiles: number,
	bytes: number,
	limits: Limits,
}

export type Plan = {
	read: { string },
	kustomizations: { string },
	charts: { string },
	skipped: { { path: string, reason: string } },
	truncated: boolean,
	limits: Limits,
}

export type Layout = {
	style: "per-kind-dirs" | "per-namespace-kind-dirs" | "file-per-resource" | "multi-doc" | "unknown",
	-- File name pattern without extension; tokens <kind> (lowercased Kind),
	-- <name>, <namespace>.
	naming: string,
	ext: ".yaml" | ".yml",
	kustomization: boolean,
	-- Kind directory naming for the *-kind-dirs styles: "<kind>" or "<plural>".
	kindDir: string?,
	confidence: number,
	samples: number,
}

export type GitFileStatus = {
	code: string,
	state: "modified" | "staged" | "added" | "deleted" | "renamed" | "untracked" | "conflicted",
}

local M = {}

M.CONFIDENT = 0.8

local DEFAULT_LIMITS: Limits = table.freeze({
	maxFiles = 2000,
	maxBytes = 32 * 1024 * 1024,
	maxFileBytes = 1024 * 1024,
})

local KUSTOMIZATION_FILES = { ["kustomization.yaml"] = true, ["kustomization.yml"] = true, ["Kustomization"] = true }

-- Paths -------------------------------------------------------------------

local function normalize(path: string): string
	local absolute = string.sub(path, 1, 1) == "/"
	local parts: { string } = {}
	for _, part in string.split(path, "/") do
		if part == "" or part == "." then
			continue
		elseif part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= ".." or not absolute then
			table.insert(parts, part)
		end
	end
	local joined = table.concat(parts, "/")
	return if absolute then "/" .. joined else joined
end

local function dirname(path: string): string
	local dir = string.match(path, "^(.*)/[^/]*$")
	if dir == nil then
		return ""
	end
	return if dir == "" then "/" else dir
end

local function basename(path: string): string
	return string.match(path, "([^/]*)$") :: string
end

local function join(dir: string, rel: string): string
	if string.sub(rel, 1, 1) == "/" then
		return normalize(rel)
	end
	return normalize(if dir == "" then rel else dir .. "/" .. rel)
end

-- `path` relative to `dir`, or nil when it is not inside it.
local function under(dir: string, path: string): string?
	local base = if string.sub(dir, -1) == "/" then dir else dir .. "/"
	if string.sub(path, 1, #base) == base then
		return string.sub(path, #base + 1)
	end
	return nil
end

local function relative(root: string, path: string): string
	if path == root then
		return "."
	end
	return under(root, path) or path
end

local function lowerExt(path: string): string?
	local ext = string.match(string.lower(path), "(%.[^./]+)$")
	return if ext == ".yaml" or ext == ".yml" then ext else nil
end

M.normalize = normalize
M.relative = relative

-- Plan --------------------------------------------------------------------

local function hidden(path: string): boolean
	for _, part in string.split(path, "/") do
		if string.sub(part, 1, 1) == "." and part ~= "." and part ~= ".." then
			return true
		end
	end
	return false
end

-- Decides which of `files` (repo-relative or absolute) to read: YAML files
-- and kustomization files, kustomizations first so their namespace and
-- resource lists are known early. Helm chart directories are left to
-- `helm template`: their templates are not YAML.
export type PlanOpts = { maxFiles: number?, maxBytes: number?, maxFileBytes: number? }

function M.plan(files: { string }, opts: PlanOpts?): Plan
	local o: PlanOpts = opts or {}
	local limits: Limits = {
		maxFiles = o.maxFiles or DEFAULT_LIMITS.maxFiles,
		maxBytes = o.maxBytes or DEFAULT_LIMITS.maxBytes,
		maxFileBytes = o.maxFileBytes or DEFAULT_LIMITS.maxFileBytes,
	}
	local paths: { string } = {}
	local charts: { string } = {}
	for _, raw in files do
		local path = normalize(raw)
		local name = basename(path)
		if name == "Chart.yaml" then
			table.insert(charts, dirname(path))
		end
		if lowerExt(path) or KUSTOMIZATION_FILES[name] then
			table.insert(paths, path)
		end
	end
	table.sort(charts)
	table.sort(paths)
	local read: { string } = {}
	local kustomizations: { string } = {}
	local skipped: { { path: string, reason: string } } = {}
	local plain: { string } = {}
	for _, path in paths do
		local inChart = false
		for _, chart in charts do
			if chart == "" or under(chart, path) then
				inChart = true
				break
			end
		end
		if inChart then
			table.insert(skipped, { path = path, reason = "helm chart" })
		elseif hidden(path) then
			table.insert(skipped, { path = path, reason = "hidden" })
		elseif KUSTOMIZATION_FILES[basename(path)] then
			table.insert(kustomizations, dirname(path))
			table.insert(read, path)
		else
			table.insert(plain, path)
		end
	end
	local truncated = false
	for _, path in plain do
		if #read >= limits.maxFiles then
			truncated = true
			table.insert(skipped, { path = path, reason = "limit" })
		else
			table.insert(read, path)
		end
	end
	return {
		read = read,
		kustomizations = kustomizations,
		charts = charts,
		skipped = skipped,
		truncated = truncated,
		limits = limits,
	}
end

-- Index -------------------------------------------------------------------

function M.new(root: string, limits: Limits?): Index
	return {
		root = normalize(root),
		sources = {},
		docs = {},
		byKey = {},
		kustomizations = {},
		diagnostics = {},
		truncated = false,
		scannedFiles = 0,
		bytes = 0,
		limits = limits or DEFAULT_LIMITS,
	}
end

local function sourceLabel(index: Index, kind: SourceType, path: string, helm: HelmSpec?): string
	local label = relative(index.root, path)
	if kind == "helm" and helm then
		label ..= " (release " .. helm.release .. ")"
	end
	return label
end

-- The interned source for (type, path): one entry per directory, overlay,
-- chart or helm release.
function M.source(index: Index, kind: SourceType, path: string, helm: HelmSpec?): Source
	local p = normalize(path)
	for _, s in index.sources do
		if s.type == kind and s.path == p and (s.helm and s.helm.release) == (helm and helm.release) then
			if helm then
				s.helm = helm
			end
			return s
		end
	end
	local source: Source =
		{ type = kind, root = index.root, path = p, helm = helm, label = sourceLabel(index, kind, p, helm) }
	table.insert(index.sources, source)
	table.sort(index.sources, function(a: Source, b: Source): boolean
		if a.label ~= b.label then
			return a.label < b.label
		end
		return a.type < b.type
	end)
	return source
end

local function link(index: Index, doc: ManifestDoc)
	local key = doc.key
	if key and not doc.patch then
		local list = index.byKey[key]
		if list == nil then
			list = {}
			index.byKey[key] = list
		end
		table.insert(list, doc)
	end
end

local function unlink(index: Index, doc: ManifestDoc)
	local key = doc.key
	local list = if key then index.byKey[key] else nil
	if key and list then
		local at = table.find(list, doc)
		if at then
			table.remove(list, at)
		end
		if #list == 0 then
			index.byKey[key] = nil
		end
	end
end

local function removeDocs(index: Index, keep: (ManifestDoc) -> boolean)
	local kept: { ManifestDoc } = {}
	for _, doc in index.docs do
		if keep(doc) then
			table.insert(kept, doc)
		else
			unlink(index, doc)
		end
	end
	index.docs = kept
end

-- Unknown kinds count as namespaced: a custom resource without a namespace
-- is still matched by name, never keyed as cluster-scoped by mistake.
local function namespaced(ref: Ref): boolean
	return Kinds.normalize(if ref.group then ref.kind .. "." .. ref.group else ref.kind).namespaced ~= false
end

local function resolve(doc: ManifestDoc, explicit: string?, fallback: string?)
	local ref = doc.ref
	if ref == nil then
		doc.key = nil
		doc.namespaceInferred = false
		return
	end
	local scoped = namespaced(ref)
	local ns = if scoped then explicit or fallback else nil
	local resolved: Ref = table.clone(ref)
	resolved.namespace = ns
	doc.ref = resolved
	doc.namespaceInferred = scoped and ns == nil
	doc.key = if doc.namespaceInferred then nil else Resource.key(resolved)
end

-- Kustomization parsing ------------------------------------------------------

local function scalar(raw: string): string?
	local s = string.match(raw, "^%s*(.-)%s*$") :: string
	local q = string.sub(s, 1, 1)
	if q == '"' or q == "'" then
		local close = string.find(s, q, 2, true)
		return if close then string.sub(s, 2, close - 1) else nil
	end
	s = string.match((string.gsub(s, "%s#.*$", "")), "^(.-)%s*$") :: string
	if s == "" or s == "~" or s == "null" or string.sub(s, 1, 1) == "#" then
		return nil
	end
	return s
end

local function flowList(raw: string): { string }?
	local body = string.match(raw, "^%s*%[(.*)%]%s*$") or string.match(raw, "^%s*%[(.*)%]%s+#")
	if body == nil then
		return nil
	end
	local out: { string } = {}
	for _, item in string.split(body, ",") do
		local v = scalar(item)
		if v then
			table.insert(out, v)
		end
	end
	return out
end

local REMOTE_PREFIXES = { "git@", "git::", "github.com/", "gitlab.com/", "bitbucket.org/" }

local function remote(entry: string): boolean
	if string.find(entry, "://", 1, true) then
		return true
	end
	for _, prefix in REMOTE_PREFIXES do
		if string.sub(entry, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- A list item that is a plain path, not a mapping or a block scalar.
local function pathItem(item: string): string?
	local c = string.sub(item, 1, 1)
	if c == "|" or c == ">" or c == "{" or c == "[" or string.find(item, ":%s") or string.match(item, ":$") then
		return nil
	end
	return scalar(item)
end

-- Line-based: top-level scalars and the items of top-level lists. Patch
-- entries are `path:` keys of `patches` items or plain paths (legacy keys);
-- inline patch bodies are deeper than the item keys and ignored.
local function parseKustomization(file: string, text: string): Kustomization
	local dir = dirname(file)
	local k: Kustomization = { dir = dir, file = file, resources = {}, patches = {} }
	local section: { string }? = nil
	local listIndent: number? = nil
	local function add(list: { string }, entry: string?)
		if entry and not remote(entry) then
			table.insert(list, join(dir, entry))
		end
	end
	for _, line in Yaml.lines(text) do
		local top, rest = string.match(line, "^([%w_]+):(.*)$")
		if top then
			section, listIndent = nil, nil
			if top == "namespace" or top == "namePrefix" or top == "nameSuffix" then
				(k :: any)[top] = scalar(rest :: string)
			elseif top == "resources" or top == "bases" or top == "components" then
				section = k.resources
			elseif top == "patches" or top == "patchesStrategicMerge" or top == "patchesJson6902" then
				section = k.patches
			end
			local inline = if section then flowList(rest :: string) else nil
			if section and inline then
				for _, entry in inline do
					add(section, entry)
				end
				section = nil
			end
			continue
		end
		local list = section
		if list == nil or string.match(line, "^%s*#") or string.match(line, "^%s*$") then
			continue
		end
		local spaces, item = string.match(line, "^(%s*)%-%s+(.*)$")
		if spaces and (listIndent == nil or #spaces == listIndent) then
			listIndent = #spaces
			local pathValue = string.match(item :: string, "^path:%s+(.*)$")
			if list == k.patches and pathValue then
				add(list, scalar(pathValue))
			else
				add(list, pathItem(item :: string))
			end
		elseif list == k.patches and listIndent then
			local keySpaces, pathValue = string.match(line, "^(%s*)path:%s+(.*)$")
			if keySpaces and #keySpaces == listIndent + 2 then
				add(list, scalar(pathValue :: string))
			end
		elseif listIndent == nil and string.match(line, "^%S") then
			section = nil
		end
	end
	return k
end

-- Kustomization membership -----------------------------------------------

local function membership(index: Index, file: string): (Kustomization?, boolean)
	local found: Kustomization? = nil
	local patch = false
	for _, k in index.kustomizations do
		local isResource = table.find(k.resources, file) ~= nil
		local isPatch = table.find(k.patches, file) ~= nil
		if (isResource or isPatch) and (found == nil or k.dir < (found :: Kustomization).dir) then
			found = k
			patch = isPatch and not isResource
		end
	end
	return found, patch
end

local function place(index: Index, doc: ManifestDoc)
	if doc.rendered then
		return
	end
	unlink(index, doc)
	local k, patch = membership(index, doc.file)
	doc.kustomization = if k then k.dir else nil
	doc.patch = patch
	resolve(doc, doc.declaredNamespace, if k then k.namespace else nil)
	link(index, doc)
end

-- Adding files ---------------------------------------------------------------

local function sliceText(source: { string }, first: number, last: number): string
	return table.concat(source, "\n", first, last) .. "\n"
end

local function hasKind(docs: { Yaml.Doc }): boolean
	for _, d in docs do
		if d.kind then
			return true
		end
	end
	return false
end

local function addDiagnostics(index: Index, file: string, diagnostics: { Types.Diagnostic })
	for _, d in diagnostics do
		table.insert(index.diagnostics, { file = file, line = d.line, severity = d.severity, text = d.text })
	end
end

-- Indexes one file. Returns false (and marks the index truncated) when the
-- file would exceed the byte budget; the host then stops reading. Re-adding
-- a file replaces what it declared.
function M.addFile(index: Index, path: string, text: string): boolean
	local file = normalize(path)
	if #text > index.limits.maxFileBytes or index.bytes + #text > index.limits.maxBytes then
		index.truncated = true
		return false
	end
	index.scannedFiles += 1
	index.bytes += #text
	removeDocs(index, function(d: ManifestDoc): boolean
		return d.rendered or d.file ~= file
	end)
	local kept: { Diagnostic } = {}
	for _, d in index.diagnostics do
		if d.file ~= file then
			table.insert(kept, d)
		end
	end
	index.diagnostics = kept

	if KUSTOMIZATION_FILES[basename(file)] then
		local k = parseKustomization(file, text)
		index.kustomizations[k.dir] = k
		for _, doc in index.docs do
			place(index, doc)
		end
		return true
	end

	local lines = Yaml.lines(text)
	local split = Yaml.splitLines(lines)
	if not hasKind(split.docs) then
		return true
	end
	addDiagnostics(index, file, split.diagnostics)
	local source = M.source(index, "dir", dirname(file), nil)
	for _, d in split.docs do
		if d.ref == nil or string.sub(d.apiVersion or "", 1, 23) == "kustomize.config.k8s.io" then
			continue
		end
		local doc: ManifestDoc = {
			key = nil,
			ref = d.ref,
			file = file,
			startLine = d.startLine,
			endLine = d.endLine,
			source = source,
			namespaceInferred = false,
			rendered = false,
			text = nil,
			kustomization = nil,
			patch = false,
			declaredNamespace = d.namespace,
		}
		table.insert(index.docs, doc)
		place(index, doc)
	end
	return true
end

-- Rendered output ------------------------------------------------------------

type Origin = { file: string, startLine: number, endLine: number }

-- Kustomizations reachable from `dir` through directory resources, with
-- the name prefix/suffix kustomize applies to their resources.
local function reachable(index: Index, dir: string): { [string]: { prefix: string, suffix: string } }
	local out: { [string]: { prefix: string, suffix: string } } = {}
	local function visit(d: string, prefix: string, suffix: string)
		local k = index.kustomizations[d]
		if k == nil or out[d] then
			return
		end
		local p, s = prefix .. (k.namePrefix or ""), (k.nameSuffix or "") .. suffix
		out[d] = { prefix = p, suffix = s }
		for _, r in k.resources do
			visit(r, p, s)
		end
	end
	visit(dir, "", "")
	return out
end

local function kustomizeOrigin(index: Index, source: Source, ref: Ref): Origin
	local scopes = reachable(index, source.path)
	local exact: ManifestDoc? = nil
	local best: ManifestDoc? = nil
	for _, doc in index.docs do
		local r = doc.ref
		local scope = if doc.kustomization then scopes[doc.kustomization] else nil
		if doc.rendered or doc.patch or r == nil or scope == nil or r.kind ~= ref.kind or r.group ~= ref.group then
			continue
		end
		if scope.prefix .. r.name .. scope.suffix == ref.name then
			if best == nil or doc.file < (best :: ManifestDoc).file then
				best = doc
			end
		elseif r.name == ref.name and (exact == nil or doc.file < (exact :: ManifestDoc).file) then
			exact = doc
		end
	end
	local found = best or exact
	if found then
		return { file = found.file, startLine = found.startLine, endLine = found.endLine }
	end
	local k = index.kustomizations[source.path]
	return { file = if k then k.file else source.path .. "/kustomization.yaml", startLine = 1, endLine = 1 }
end

-- `# Source: <chart>/templates/x.yaml` precedes each document in
-- `helm template` output; the first segment is the chart name.
local function helmOrigin(source: Source, lines: { string }, startLine: number): Origin
	for i = startLine - 1, 1, -1 do
		local line = lines[i]
		local path = string.match(line, "^# Source: [^/]+/(.+)$")
		if path then
			return { file = join(source.path, (string.gsub(path, "%s+$", ""))), startLine = 1, endLine = 1 }
		end
		if string.sub(line, 1, 3) == "---" then
			break
		end
	end
	return { file = join(source.path, "Chart.yaml"), startLine = 1, endLine = 1 }
end

-- Indexes a kustomize/helm render of `source`, replacing its previous render.
function M.addRendered(index: Index, source: Source, text: string)
	removeDocs(index, function(d: ManifestDoc): boolean
		return not (d.rendered and d.source == source)
	end)
	local lines = Yaml.lines(text)
	local split = Yaml.splitLines(lines)
	addDiagnostics(index, source.path, split.diagnostics)
	local fallback = if source.type == "helm" and source.helm then source.helm.namespace else nil
	for _, d in split.docs do
		local ref = d.ref
		if ref == nil then
			continue
		end
		local origin = if source.type == "helm"
			then helmOrigin(source, lines, d.startLine)
			else kustomizeOrigin(index, source, ref)
		local doc: ManifestDoc = {
			key = nil,
			ref = ref,
			file = origin.file,
			startLine = origin.startLine,
			endLine = origin.endLine,
			source = source,
			namespaceInferred = false,
			rendered = true,
			text = sliceText(lines, d.startLine, d.endLine),
			kustomization = if source.type == "kustomize" then source.path else nil,
			patch = false,
			declaredNamespace = d.namespace,
		}
		resolve(doc, d.namespace, fallback)
		table.insert(index.docs, doc)
		link(index, doc)
	end
end

-- Keys declared by more than one hand-written document (renders repeat
-- their inputs by design and are not counted).
function M.duplicates(index: Index): { string }
	local out: { string } = {}
	for key, docs in index.byKey do
		local n = 0
		for _, d in docs do
			if not d.rendered then
				n += 1
			end
		end
		if n > 1 then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

-- Matching -------------------------------------------------------------------

local function docOrder(a: ManifestDoc, b: ManifestDoc): boolean
	if a.rendered ~= b.rendered then
		return a.rendered
	end
	if a.file ~= b.file then
		return a.file < b.file
	end
	return a.startLine < b.startLine
end

-- Documents declaring `ref`, best first: exact namespace, then documents
-- without a namespace when the object lives in the default namespace (or is
-- cluster-scoped). Within a tier renders come first: they are what is
-- applied.
function M.match(index: Index, ref: Ref, opts: { defaultNamespace: string? }?): { ManifestDoc }
	local exact = table.clone(index.byKey[Resource.key(ref)] or {})
	table.sort(exact, docOrder)
	local default = (opts and opts.defaultNamespace) or "default"
	local inferred: { ManifestDoc } = {}
	if ref.namespace == nil or ref.namespace == default then
		for _, doc in index.docs do
			local r = doc.ref
			if
				doc.namespaceInferred
				and not doc.patch
				and r
				and r.kind == ref.kind
				and r.name == ref.name
				and (r.group or "") == (ref.group or "")
			then
				table.insert(inferred, doc)
			end
		end
	end
	table.sort(inferred, docOrder)
	table.move(inferred, 1, #inferred, #exact + 1, exact)
	return exact
end

-- Layout ---------------------------------------------------------------------

local NAMINGS = {
	"<name>",
	"<kind>",
	"<kind>-<name>",
	"<name>-<kind>",
	"<kind>_<name>",
	"<name>_<kind>",
	"<kind>.<name>",
	"<name>.<kind>",
	"<namespace>-<name>",
	"<namespace>-<kind>-<name>",
}

local function plural(kind: string): string
	local info = Kinds.normalize(kind)
	return if info.known then info.plural else string.lower(kind) .. "s"
end

local function fill(pattern: string, ref: Ref): string?
	if string.find(pattern, "<namespace>", 1, true) and ref.namespace == nil then
		return nil
	end
	local out = string.gsub(pattern, "<(%a+)>", function(token: string): string
		if token == "kind" then
			return string.lower(ref.kind)
		elseif token == "name" then
			return ref.name
		end
		return ref.namespace or ""
	end)
	return out
end

local function kindDirOf(segment: string, ref: Ref): string?
	if segment == string.lower(ref.kind) then
		return "<kind>"
	elseif segment == plural(ref.kind) then
		return "<plural>"
	end
	return nil
end

local function argmax(votes: { [string]: number }, order: { string }): (string?, number)
	local best: string?, n = nil, 0
	for _, k in order do
		local v = votes[k] or 0
		if v > n then
			best, n = k, v
		end
	end
	return best, n
end

local STYLES = { "per-kind-dirs", "per-namespace-kind-dirs", "file-per-resource", "multi-doc", "other" }

-- The file convention of `dir`, from the hand-written documents under it:
-- each file votes for one style; less than CONFIDENT agreement (or no
-- files) is "unknown".
function M.layout(index: Index, dir: string): Layout
	local base = normalize(dir)
	local files: { [string]: { ManifestDoc } } = {}
	local order: { string } = {}
	for _, doc in index.docs do
		if doc.rendered or doc.patch or doc.ref == nil or under(base, doc.file) == nil then
			continue
		end
		local list = files[doc.file]
		if list == nil then
			list = {}
			files[doc.file] = list
			table.insert(order, doc.file)
		end
		table.insert(list, doc)
	end
	local styles: { [string]: number } = {}
	local namings: { [string]: number } = {}
	local kindDirs: { [string]: number } = {}
	local exts: { [string]: number } = {}
	for _, file in order do
		local docs = files[file]
		local rel = under(base, file) :: string
		local segments = string.split(rel, "/")
		local name = segments[#segments]
		local ext = lowerExt(name) or ".yaml"
		exts[ext] = (exts[ext] or 0) + 1
		local stem = string.sub(name, 1, #name - #ext)
		local style = "other"
		local ref = docs[1].ref :: Ref
		if #docs > 1 then
			style = "multi-doc"
		elseif #segments == 1 then
			style = "file-per-resource"
		elseif #segments == 2 then
			local kd = kindDirOf(segments[1], ref)
			if kd then
				style = "per-kind-dirs"
				kindDirs[kd] = (kindDirs[kd] or 0) + 1
			end
		elseif #segments == 3 then
			local kd = kindDirOf(segments[2], ref)
			if kd and (ref.namespace == nil or ref.namespace == segments[1]) then
				style = "per-namespace-kind-dirs"
				kindDirs[kd] = (kindDirs[kd] or 0) + 1
			end
		end
		styles[style] = (styles[style] or 0) + 1
		if #docs == 1 then
			for _, pattern in NAMINGS do
				if fill(pattern, ref) == stem then
					namings[pattern] = (namings[pattern] or 0) + 1
				end
			end
		end
	end
	local kustomization = false
	for kdir in index.kustomizations do
		if kdir == base or under(base, kdir) then
			kustomization = true
			break
		end
	end
	local samples = #order
	local style, votes = argmax(styles, STYLES)
	local confidence = if samples > 0 then votes / samples else 0
	local chosen = if style and style ~= "other" and confidence >= M.CONFIDENT then style else "unknown"
	local naming = argmax(namings, NAMINGS) or "<name>"
	local kindDir = if chosen == "per-kind-dirs" or chosen == "per-namespace-kind-dirs"
		then argmax(kindDirs, { "<kind>", "<plural>" })
		else nil
	local ext: ".yaml" | ".yml" = if (exts[".yml"] or 0) > (exts[".yaml"] or 0) then ".yml" else ".yaml"
	return {
		style = chosen :: any,
		naming = naming,
		ext = ext,
		kustomization = kustomization,
		kindDir = kindDir,
		confidence = confidence,
		samples = samples,
	}
end

-- Git output -----------------------------------------------------------------

-- `git ls-files -z` output (repo-relative) as absolute paths under `root`.
function M.parseFileList(root: string, stdout: string): { string }
	local out: { string } = {}
	for _, rel in string.split(stdout, "\0") do
		if rel ~= "" then
			table.insert(out, join(root, rel))
		end
	end
	return out
end

local CONFLICTS = { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }

local function stateOf(code: string): GitFileStatus
	local x, y = string.sub(code, 1, 1), string.sub(code, 2, 2)
	local state: "modified" | "staged" | "added" | "deleted" | "renamed" | "untracked" | "conflicted"
	if code == "??" then
		state = "untracked"
	elseif CONFLICTS[code] then
		state = "conflicted"
	elseif x == "D" or y == "D" then
		state = "deleted"
	elseif x == "R" or x == "C" then
		state = "renamed"
	elseif x == "A" then
		state = "added"
	elseif y ~= " " then
		state = "modified"
	else
		state = "staged"
	end
	return { code = code, state = state }
end

-- `git status --porcelain=v1 -z` output keyed by absolute path; the source
-- path of a rename or copy is consumed, not reported.
function M.parseGitStatus(root: string, stdout: string): { [string]: GitFileStatus }
	local out: { [string]: GitFileStatus } = {}
	local entries = string.split(stdout, "\0")
	local i = 1
	while i <= #entries do
		local entry = entries[i]
		i += 1
		if #entry < 4 then
			continue
		end
		local code = string.sub(entry, 1, 2)
		out[join(root, string.sub(entry, 4))] = stateOf(code)
		local x = string.sub(code, 1, 1)
		if x == "R" or x == "C" then
			i += 1
		end
	end
	return out
end

return M
