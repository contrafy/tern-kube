--!strict
-- Locates Kubernetes objects in `kubectl get -o yaml` output and in
-- multi-document manifests without a YAML parser. Only indentation is
-- trusted: a mapping key belongs to an object only when it sits at exactly
-- the object's indentation, which YAML guarantees for block scalars, nested
-- sequences and multi-line flow scalars (their content is always deeper).
-- Identity comes from the top-level `kind`, `apiVersion` and the
-- `metadata.name`/`metadata.namespace` children; nothing else is interpreted.
local Redact = require("../model/redact")
local Resource = require("../model/resource")
local Types = require("../model/types")

export type Doc = {
	startLine: number,
	endLine: number,
	-- Column offset of the object's top-level keys (2 for `- ` list items).
	indent: number,
	ref: Types.ResourceRef?,
	kind: string?,
	apiVersion: string?,
	name: string?,
	namespace: string?,
}

export type SplitResult = { docs: { Doc }, diagnostics: { Types.Diagnostic } }

type Entry = { key: string, line: number, colon: number, value: string }

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) :: string
end

local function lines(text: string): { string }
	local out = string.split(text, "\n")
	for i, line in out do
		if string.byte(line, -1) == 13 then
			out[i] = string.sub(line, 1, -2)
		end
	end
	return out
end

-- stderr interleaved into the capture; at column 0 these cannot be part of a
-- Kubernetes object (no object has such top-level keys).
local function strayLine(line: string): ("warning" | "error")?
	if string.sub(line, 1, 9) == "Warning: " then
		return "warning"
	end
	if string.sub(line, 1, 17) == "Error from server" or string.sub(line, 1, 7) == "error: " then
		return "error"
	end
	return nil
end

local function marker(line: string, chars: string): boolean
	if string.sub(line, 1, 3) ~= chars then
		return false
	end
	local rest = string.sub(line, 4, 4)
	return rest == "" or rest == " " or rest == "\t"
end

-- Returns the 0-based indentation of a line carrying content, or nil for
-- blank, comment and stray stderr lines.
local function contentIndent(line: string): number?
	local first = string.find(line, "[^ ]")
	if not first then
		return nil
	end
	local c = string.sub(line, first, first)
	if c == "#" or c == "\t" or c == "\r" then
		return nil
	end
	if first == 1 and strayLine(line) then
		return nil
	end
	return first - 1
end

local function unescapeDouble(body: string): string
	return (
		string.gsub(body, "\\(.)", function(c: string): string
			if c == "n" then
				return "\n"
			elseif c == "t" then
				return "\t"
			end
			return c
		end)
	)
end

-- Parses a quoted scalar starting at `pos`; returns the value and the
-- position after the closing quote, or nil when the quote is not closed on
-- this line (multi-line quoted scalars are not followed).
local function quoted(s: string, pos: number): (string?, number)
	local q = string.sub(s, pos, pos)
	local i = pos + 1
	if q == '"' then
		while i <= #s do
			local c = string.sub(s, i, i)
			if c == "\\" then
				i += 2
			elseif c == '"' then
				return unescapeDouble(string.sub(s, pos + 1, i - 1)), i + 1
			else
				i += 1
			end
		end
		return nil, i
	end
	while i <= #s do
		local close = string.find(s, "'", i, true)
		if not close then
			break
		end
		if string.sub(s, close + 1, close + 1) == "'" then
			i = close + 2
		else
			local body = string.gsub(string.sub(s, pos + 1, close - 1), "''", "'")
			return body, close + 1
		end
	end
	return nil, #s + 1
end

-- Scalar value of an identity field. Block scalars, flow collections and
-- aliases yield nil: identity fields are never written that way in practice.
local function scalar(raw: string): string?
	local s = trim(raw)
	s = string.gsub(s, "^&%S+%s*", "")
	s = string.gsub(s, "^!%S*%s+", "")
	local c = string.sub(s, 1, 1)
	if c == "" or c == "#" or c == "|" or c == ">" or c == "{" or c == "[" or c == "*" then
		return nil
	end
	if c == '"' or c == "'" then
		return (quoted(s, 1))
	end
	local plain = trim((string.gsub(s, "%s#.*$", "")))
	if plain == "" or plain == "~" or plain == "null" then
		return nil
	end
	return plain
end

-- Parses a mapping key at `col`. Sequence entries, complex keys and flow
-- collections are not keys of the mapping being scanned.
local function parseKey(line: string, col: number): (string?, number)
	local c = string.sub(line, col, col)
	local key: string?
	local pos: number
	if c == '"' or c == "'" then
		key, pos = quoted(line, col)
		if not key then
			return nil, 0
		end
		local spaces = string.match(line, "^ *", pos) :: string
		pos += #spaces
		if string.sub(line, pos, pos) ~= ":" then
			return nil, 0
		end
	else
		if c == "-" or c == "?" or c == "{" or c == "[" or c == "|" or c == ">" then
			local nextChar = string.sub(line, col + 1, col + 1)
			if c ~= "-" or nextChar == "" or nextChar == " " then
				return nil, 0
			end
		end
		local found = string.find(line, ":", col, true)
		while found do
			local after = string.sub(line, found + 1, found + 1)
			if after == "" or after == " " or after == "\t" then
				break
			end
			found = string.find(line, ":", found + 1, true)
		end
		if not found then
			return nil, 0
		end
		key = trim(string.sub(line, col, found - 1))
		pos = found
	end
	local after = string.sub(line, pos + 1, pos + 1)
	if after ~= "" and after ~= " " and after ~= "\t" then
		return nil, 0
	end
	return key, pos
end

-- `- key: v` scanned as if the dash were a space, so the first key of a
-- list item lines up with the following ones.
local function undash(line: string): string?
	local dash = string.find(line, "[^ ]")
	if dash and string.sub(line, dash, dash) == "-" then
		local after = string.sub(line, dash + 1, dash + 1)
		if after == " " or after == "" then
			return string.sub(line, 1, dash - 1) .. " " .. string.sub(line, dash + 1)
		end
	end
	return nil
end

local function scanEntries(
	source: { string },
	first: number,
	last: number,
	indent: number,
	override: string?
): { Entry }
	local entries: { Entry } = {}
	for i = first, last do
		local line = if i == first and override then override else source[i]
		if contentIndent(line) ~= indent then
			continue
		end
		local key, colon = parseKey(line, indent + 1)
		if key then
			table.insert(entries, { key = key, line = i, colon = colon, value = string.sub(line, colon + 1) })
		end
	end
	return entries
end

local function blockLast(entries: { Entry }, k: number, last: number): number
	local nextEntry = entries[k + 1]
	return if nextEntry then nextEntry.line - 1 else last
end

local function find(entries: { Entry }, key: string): number?
	for k, entry in entries do
		if entry.key == key then
			return k
		end
	end
	return nil
end

-- Child entries of a block-style mapping value, or nil when the value is
-- written inline.
local function children(source: { string }, entries: { Entry }, k: number, last: number): { Entry }?
	local entry = entries[k]
	local value = trim((string.gsub(entry.value, "^%s*#.*$", "")))
	if value ~= "" then
		return nil
	end
	local stop = blockLast(entries, k, last)
	for i = entry.line + 1, stop do
		local indent = contentIndent(source[i])
		if indent then
			return scanEntries(source, i, stop, indent)
		end
	end
	return {}
end

-- Best-effort single-line flow mapping (`{name: x, namespace: "y"}`); nested
-- collections are skipped. Returns nil when the mapping is not closed on the
-- line.
local function flowMapping(raw: string): { [string]: string }?
	local s = trim(raw)
	local out: { [string]: string } = {}
	local depth, i, pieceStart = 0, 1, 2
	local function piece(stop: number)
		local text = string.sub(s, pieceStart, stop)
		local key, colon = parseKey(text, (string.find(text, "[^ ]")) or 1)
		if key then
			local value = scalar(string.sub(text, colon + 1))
			if value then
				out[key] = value
			end
		end
	end
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == '"' or c == "'" then
			local value, after = quoted(s, i)
			if not value then
				return nil
			end
			i = after
			continue
		elseif c == "{" or c == "[" then
			depth += 1
		elseif c == "}" or c == "]" then
			depth -= 1
			if depth == 0 then
				piece(i - 1)
				return out
			end
		elseif c == "," and depth == 1 then
			piece(i - 1)
			pieceStart = i + 1
		end
		i += 1
	end
	return nil
end

local function isListKind(kind: string?): boolean
	return kind ~= nil and (kind == "List" or (#kind > 4 and string.sub(kind, -4) == "List"))
end

type State = { source: { string }, docs: { Doc }, diagnostics: { Types.Diagnostic } }

local function warn(state: State, line: number, text: string)
	table.insert(state.diagnostics, { line = line, severity = "warning", text = text })
end

local function addDoc(state: State, start: number, stop: number, indent: number, entries: { Entry })
	local function field(key: string): string?
		local k = find(entries, key)
		return if k then scalar(entries[k].value) else nil
	end
	local kind, apiVersion = field("kind"), field("apiVersion")
	local name: string?, namespace: string?
	local m = find(entries, "metadata")
	if m then
		local fields = children(state.source, entries, m, stop)
		if fields then
			local n, ns = find(fields, "name"), find(fields, "namespace")
			name = if n then scalar(fields[n].value) else nil
			namespace = if ns then scalar(fields[ns].value) else nil
		else
			local flow = flowMapping(entries[m].value)
			if flow then
				name, namespace = flow.name, flow.namespace
			else
				warn(state, entries[m].line, "metadata written as a multi-line flow mapping is not supported")
			end
		end
	end
	if not kind then
		warn(state, start, string.format("document at line %d has no kind", start))
	end
	local ref = if kind
		then Resource.fromObject(
			{ kind = kind, apiVersion = apiVersion, metadata = { name = name, namespace = namespace } },
			"snapshot"
		)
		else nil
	table.insert(state.docs, {
		startLine = start,
		endLine = stop,
		indent = indent,
		ref = ref,
		kind = kind,
		apiVersion = apiVersion,
		name = name,
		namespace = namespace,
	})
end

local function lastContent(source: { string }, first: number, last: number): number
	for i = last, first, -1 do
		if contentIndent(source[i]) then
			return i
		end
	end
	return first
end

local function addItems(state: State, entries: { Entry }, k: number, last: number)
	local source = state.source
	local items = entries[k]
	local inline = trim((string.gsub(items.value, "%s#.*$", "")))
	if inline == "[]" then
		return
	elseif inline ~= "" then
		warn(state, items.line, "List items written in flow style are not supported")
		return
	end
	local stop = blockLast(entries, k, last)
	local seqIndent: number? = nil
	local starts: { number } = {}
	for i = items.line + 1, stop do
		local line = source[i]
		local indent = contentIndent(line)
		if not indent then
			continue
		end
		seqIndent = seqIndent or indent
		if indent == seqIndent and undash(line) then
			table.insert(starts, i)
		elseif indent <= (seqIndent :: number) then
			warn(state, i, "unexpected content in List items")
			stop = i - 1
			break
		end
	end
	for j, start in starts do
		local itemLast = lastContent(source, start, if starts[j + 1] then starts[j + 1] - 1 else stop)
		local override = undash(source[start]) :: string
		local base = contentIndent(override)
		if not base then
			for i = start + 1, itemLast do
				base = contentIndent(source[i])
				if base then
					break
				end
			end
		end
		addDoc(state, start, itemLast, base or 0, scanEntries(source, start, itemLast, base or 0, override))
	end
end

local function addRegion(state: State, first: number, last: number)
	local source = state.source
	local start: number? = nil
	for i = first, last do
		if contentIndent(source[i]) then
			start = i
			break
		end
	end
	if not start then
		return
	end
	local stop = lastContent(source, start, last)
	local indent = contentIndent(source[start]) :: number
	local entries = scanEntries(source, start, stop, indent)
	local k = find(entries, "kind")
	local items = find(entries, "items")
	if k and items and isListKind(scalar(entries[k].value)) then
		addItems(state, entries, items, stop)
	else
		addDoc(state, start, stop, indent, entries)
	end
end

local function splitLines(source: { string }): SplitResult
	local state: State = { source = source, docs = {}, diagnostics = {} }
	local regionStart = 1
	for i, line in source do
		if marker(line, "---") or marker(line, "...") then
			addRegion(state, regionStart, i - 1)
			regionStart = i + 1
			local rest = trim(string.sub(line, 4))
			if rest ~= "" and string.sub(rest, 1, 1) ~= "#" then
				warn(state, i, "content on a document marker line is not supported")
			end
		else
			local severity = strayLine(line)
			if severity then
				local diagnostic: Types.Diagnostic =
					{ line = i, severity = if severity == "warning" then "warning" else "error", text = line }
				table.insert(state.diagnostics, diagnostic)
			end
		end
	end
	addRegion(state, regionStart, #source)
	table.sort(state.diagnostics, function(a: Types.Diagnostic, b: Types.Diagnostic): boolean
		return (a.line or 0) < (b.line or 0)
	end)
	return { docs = state.docs, diagnostics = state.diagnostics }
end

local function split(text: string): SplitResult
	return splitLines(lines(text))
end

local LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration"

local function blockText(source: { string }, first: number, last: number): string
	local parts = {}
	local indent: number? = nil
	for i = first, last do
		local line = source[i]
		local lineIndent = string.find(line, "[^ ]")
		if lineIndent then
			indent = indent or lineIndent
			table.insert(parts, string.sub(line, indent :: number))
		else
			table.insert(parts, "")
		end
	end
	while #parts > 0 and parts[#parts] == "" do
		table.remove(parts)
	end
	return table.concat(parts, "\n")
end

local function maskEntry(out: { string }, source: { string }, entry: Entry, last: number, suffix: string)
	local raw = trim(entry.value)
	local value: string
	if string.match(raw, "^[|>][%d+-]*%s*$") or string.match(raw, "^[|>][%d+-]*%s+#") then
		value = blockText(source, entry.line + 1, last)
	else
		value = scalar(raw) or raw
		for i = entry.line + 1, last do
			if contentIndent(source[i]) then
				value ..= " " .. trim(source[i])
			end
		end
	end
	out[entry.line] = string.sub(source[entry.line], 1, entry.colon)
		.. string.format(" '<redacted: %d bytes%s>'", #value, suffix)
	for i = entry.line + 1, last do
		out[i] = ""
	end
end

local function maskValues(
	out: { string },
	source: { string },
	entries: { Entry },
	k: number,
	last: number,
	suffix: string
)
	local stop = blockLast(entries, k, last)
	local values = children(source, entries, k, last)
	if values then
		for j, entry in values do
			maskEntry(out, source, entry, blockLast(values, j, stop), suffix)
		end
		return
	end
	local inline = scalar(entries[k].value)
	local raw = trim((string.gsub(entries[k].value, "%s#.*$", "")))
	if raw ~= "{}" and (inline ~= nil or string.sub(raw, 1, 1) == "{") then
		maskEntry(out, source, entries[k], stop, "")
	end
end

local function maskSecretValues(out: { string }, source: { string }, doc: Doc, entries: { Entry })
	for k, entry in entries do
		if entry.key == "data" then
			maskValues(out, source, entries, k, doc.endLine, " base64")
		elseif entry.key == "stringData" then
			maskValues(out, source, entries, k, doc.endLine, "")
		end
	end
end

-- The annotation embeds the applied manifest verbatim, so it leaks whatever
-- was masked elsewhere in the document.
local function maskLastApplied(out: { string }, source: { string }, doc: Doc, entries: { Entry })
	local m = find(entries, "metadata")
	if m == nil then
		return
	end
	local stop = blockLast(entries, m, doc.endLine)
	local metadata = children(source, entries, m, doc.endLine)
	local a = if metadata then find(metadata, "annotations") else nil
	local annotations = if metadata and a then children(source, metadata, a, stop) else nil
	local applied = if annotations then find(annotations, LAST_APPLIED) else nil
	if metadata and a and annotations and applied then
		local annotationsLast = blockLast(metadata, a, stop)
		maskEntry(out, source, annotations[applied], blockLast(annotations, applied, annotationsLast), "")
	end
end

-- Mapping key on a line, reading `- key:` as if the dash were a space so
-- the first key of a sequence item lines up with its siblings.
local function lineEntry(source: { string }, i: number): (Entry?, number)
	local text = undash(source[i]) or source[i]
	local indent = contentIndent(text)
	if indent == nil then
		return nil, 0
	end
	local key, colon = parseKey(text, indent + 1)
	if key == nil then
		return nil, 0
	end
	return { key = key, line = i, colon = colon, value = string.sub(text, colon + 1) }, indent
end

-- Last line belonging to the value of a key at `indent`.
local function valueLast(source: { string }, line: number, indent: number, last: number): number
	local stop = line
	for j = line + 1, last do
		local ci = contentIndent(source[j])
		if ci then
			if ci <= indent then
				break
			end
			stop = j
		end
	end
	return stop
end

-- Scalars and block scalars; nested mappings, sequences and flow
-- collections are left to their own keys.
local function scalarValue(entry: Entry): boolean
	local raw = trim((string.gsub(entry.value, "^%s*#.*$", "")))
	local c = string.sub(raw, 1, 1)
	return raw ~= "" and c ~= "{" and c ~= "[" and c ~= "&" and c ~= "*"
end

-- Sibling `value:` of a `name:` key at `indent` within the same mapping
-- (for env, the same sequence item: the next item's dash sits shallower).
local function siblingValue(source: { string }, nameLine: number, indent: number, first: number, last: number): Entry?
	local start = first
	if undash(source[nameLine]) then
		start = nameLine
	else
		for j = nameLine - 1, first, -1 do
			local ci = contentIndent(source[j])
			if ci and ci < indent then
				local _, keyIndent = lineEntry(source, j)
				start = if undash(source[j]) and keyIndent == indent then j else j + 1
				break
			end
		end
	end
	for j = start, last do
		local ci = contentIndent(source[j])
		if j > start and ci and ci < indent then
			break
		end
		local entry, keyIndent = lineEntry(source, j)
		if entry and keyIndent == indent and entry.key == "value" then
			return entry
		end
	end
	return nil
end

local function skipRanges(doc: Doc, entries: { Entry }): { [number]: boolean }
	local skip: { [number]: boolean } = {}
	if doc.kind ~= "Secret" then
		return skip
	end
	for k, entry in entries do
		if entry.key == "data" or entry.key == "stringData" then
			for i = entry.line, blockLast(entries, k, doc.endLine) do
				skip[i] = true
			end
		end
	end
	return skip
end

-- Strict mode, line by line: values under sensitive keys and the `value:` of
-- `- name: X` items (container env) with a sensitive X. Returns whether
-- anything was masked.
local function maskStrict(out: { string }, source: { string }, doc: Doc, entries: { Entry }): boolean
	local skip = skipRanges(doc, entries)
	local found = false
	local function mask(entry: Entry, indent: number)
		if out[entry.line] == source[entry.line] and scalarValue(entry) then
			maskEntry(out, source, entry, valueLast(source, entry.line, indent, doc.endLine), "")
			found = true
		end
	end
	for i = doc.startLine, doc.endLine do
		if skip[i] or out[i] ~= source[i] then
			continue
		end
		local entry, indent = lineEntry(source, i)
		if entry == nil then
			continue
		end
		if Redact.sensitiveKey(entry.key) then
			mask(entry, indent)
		elseif entry.key == "name" then
			local name = scalar(entry.value)
			if name and Redact.sensitiveKey(name) then
				local value = siblingValue(source, i, indent, doc.startLine, doc.endLine)
				if value then
					mask(value, indent)
				end
			end
		end
	end
	return found
end

-- For native display only: masks what `policy` hides (Secret `data` /
-- `stringData` values and the Secret's last-applied annotation unless
-- showSecrets; strict-mode matches plus that document's annotation). The line
-- count is preserved (masked continuation lines become empty) so line
-- numbers in docs and diagnostics still refer to the original output; the
-- input is not modified.
local function redact(source: { string }, docs: { Doc }, policy: Redact.Policy?): { string }
	local p = policy or Redact.DEFAULT
	local out = table.clone(source)
	for _, doc in docs do
		local secret = doc.kind == "Secret"
		if not p.strict and (p.showSecrets or not secret) then
			continue
		end
		local entries = scanEntries(source, doc.startLine, doc.endLine, doc.indent, undash(source[doc.startLine]))
		local annotate = false
		if secret and not p.showSecrets then
			maskSecretValues(out, source, doc, entries)
			annotate = true
		end
		if p.strict and maskStrict(out, source, doc, entries) then
			annotate = true
		end
		if annotate then
			maskLastApplied(out, source, doc, entries)
		end
	end
	return out
end

return {
	split = split,
	splitLines = splitLines,
	lines = lines,
	redact = redact,
}
