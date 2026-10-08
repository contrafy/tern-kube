--!strict
-- `-o yaml` output and multi-document manifests as a list of the objects they
-- hold. Only the opened document's lines become a code node, so a 1000-item
-- List costs one grid page plus one document, never the whole text.

local Capture = require("../lens/capture")
local Grid = require("./grid")
local Query = require("../lens/query")
local Redact = require("../model/redact")
local Types = require("../model/types")
local Viewstate = require("../lens/viewstate")
local Yaml = require("../parse/yaml")
local ui = require("../ui")

type Capture = Capture.Capture
type Diagnostic = Types.Diagnostic
type Doc = Yaml.Doc
type Node = ui.Node
type SnapshotTable = Types.SnapshotTable
type ViewState = Viewstate.ViewState

local M = {}

M.PAGE_SIZE = 500
M.SENSITIVE = "Secret values are masked in this view; Raw shows kubectl's original output"

local HEADERS = { "KIND", "NAME", "NAMESPACE", "LINES" }
local TYPES: { Types.ColumnType } = { "text", "text", "text", "number" }

function M.docKey(index: number): string
	return "doc:" .. index
end

local function docIndex(key: string?): number?
	return if key then tonumber(string.match(key, "^doc:(%d+)$")) else nil
end

-- The document's own text: list items lose their "- " so every document
-- reads as a standalone object.
function M.docText(lines: { string }, doc: Doc): string
	local out: { string } = table.create(doc.endLine - doc.startLine + 1)
	local indent = doc.indent
	for i = doc.startLine, doc.endLine do
		local line = lines[i] or ""
		if indent > 0 then
			local lead = #(string.match(line, "^[ %-]*") :: string)
			line = string.sub(line, math.min(indent, lead) + 1)
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n")
end

local function codeNode(lines: { string }, doc: Doc, key: string): Node
	return ui.code(M.docText(lines, doc), "yaml", doc.startLine, { key = key .. "/code" })
end

local function title(doc: Doc): { ui.SpanLike }
	local head: { ui.SpanLike } = {
		ui.span(doc.kind or "<no kind>", "muted"),
		" ",
		ui.span(doc.name or "<no name>", "strong"),
	}
	if doc.namespace then
		table.insert(head, ui.span("  ns " .. doc.namespace, "muted"))
	end
	return head
end

local function diagnosticNodes(diagnostics: { Diagnostic }): { Node }
	local out: { Node } = {}
	for i, d in diagnostics do
		if d.severity == "error" then
			table.insert(
				out,
				ui.card({ ui.span("kubectl error", "error strong") }, { ui.text({ d.text }) }, {
					key = "diag" .. i,
					tone = "error",
					role = "kube-lens.error",
				})
			)
		else
			table.insert(
				out,
				ui.text(
					{ ui.span(d.text, if d.severity == "warning" then "warning" else "muted") },
					{ key = "diag" .. i }
				)
			)
		end
	end
	return out
end

local function docsTable(docs: { Doc }): SnapshotTable
	local rows: { Types.ResourceRow } = table.create(#docs)
	for i, doc in docs do
		rows[i] = {
			key = M.docKey(i),
			ref = doc.ref,
			cells = { doc.kind or "", doc.name or "", doc.namespace or "", tostring(doc.endLine - doc.startLine + 1) },
			rawLines = {},
			warnings = {},
		}
	end
	return { kind = nil, group = nil, headers = HEADERS, types = TYPES, rows = rows }
end

local function pager(vs: ViewState, vsm: typeof(Viewstate), page: number, pages: number, matched: number): Node
	local chips: { Node } = {}
	for p = 0, pages - 1 do
		local from = p * M.PAGE_SIZE + 1
		local to = math.min(matched, (p + 1) * M.PAGE_SIZE)
		table.insert(
			chips,
			ui.badge(string.format("%d-%d", from, to), if p == page then "accent" else "muted", {
				key = "page" .. p,
				actions = { click = vsm.action(vsm.paged(vs, p)) },
			})
		)
	end
	return ui.row(chips, { role = "kube-lens.pager", wrap = true })
end

local function docsGrid(docs: { Doc }, lines: { string }, vs: ViewState, vsm: typeof(Viewstate)): { Node }
	local shown = Query.apply(docsTable(docs), vs)
	local matched = #shown.rows
	local pages = math.max(1, math.ceil(matched / M.PAGE_SIZE))
	local page = math.clamp(vs.page, 0, pages - 1)
	local first = page * M.PAGE_SIZE + 1
	local last = math.min(matched, first + M.PAGE_SIZE - 1)
	local rows: { Grid.GridRow } = table.create(last - first + 1)
	for i = first, last do
		local row = shown.rows[i]
		table.insert(rows, {
			key = row.key,
			cells = row.cells,
			action = vsm.action(vsm.opened(vs, row.key)),
			open = vs.open == row.key,
		})
	end
	local out: { Node } = {}
	if pages > 1 then
		table.insert(out, pager(vs, vsm, page, pages, matched))
	end
	table.insert(
		out,
		Grid.grid({
			key = "yaml-docs",
			headers = HEADERS,
			types = TYPES,
			rows = rows,
			sortCol = vs.sort,
			desc = vs.desc,
			sortAction = function(col: string): string
				return vsm.action(vsm.sortedBy(vs, col))
			end,
			inspector = function(rowKey: string): Node?
				local index = docIndex(rowKey)
				local doc = if index then docs[index] else nil
				return if doc then codeNode(lines, doc, rowKey) else nil
			end,
		})
	)
	if pages > 1 then
		table.insert(out, ui.overflow(matched - (last - first + 1)))
	end
	return out
end

function M.render(capture: Capture, vs: ViewState, vsm: typeof(Viewstate)): Node
	local split = capture.yaml
	local children: { Node } = {}
	for i, notice in Redact.notices(capture.policy, capture.sensitive, capture.masked, M.SENSITIVE) do
		table.insert(
			children,
			ui.text({ ui.span(notice, "warning") }, {
				key = if i == 1 then "sensitive" else "sensitive" .. i,
				tone = "warning",
				role = "kube-lens.sensitive",
			})
		)
	end
	if split then
		local lines = capture.yamlLines or Yaml.redact(capture.lines, split.docs, capture.policy)
		for _, n in diagnosticNodes(split.diagnostics) do
			table.insert(children, n)
		end
		local docs = split.docs
		if #docs == 1 then
			table.insert(children, ui.text(title(docs[1]), { key = "doc:1/title" }))
			table.insert(children, codeNode(lines, docs[1], M.docKey(1)))
		elseif #docs > 1 then
			table.insert(children, ui.muted(string.format("%d documents; click one to show its YAML", #docs)))
			for _, n in docsGrid(docs, lines, vs, vsm) do
				table.insert(children, n)
			end
		end
		if #docs == 0 and #split.diagnostics == 0 then
			table.insert(children, ui.muted("kubectl printed no objects"))
		end
	end
	return ui.col(children, { role = "kube-lens.yaml" })
end

return M
