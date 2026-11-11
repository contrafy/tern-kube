--!strict
-- The Explore `:` prompt: `HEAD [ARG]` grammar, the picker rows it shows
-- and tab completion. Pure. Nothing typed reaches kubectl verbatim: kinds
-- resolve through discovery, scopes must be namespace names and contexts
-- must match the kubeconfig list exactly (state.luau).

local Discovery = require("../kubectl/discovery")

type KindRow = Discovery.KindRow
type Index = Discovery.Index

export type CmdT = "ctx" | "ns" | "helm" | "events" | "usage" | "kind" | "empty" | "invalid"

export type Cmd = {
	t: CmdT,
	-- The first word as typed.
	head: string,
	-- ctx: the rest of the line; others: a namespace name.
	arg: string?,
	-- `-A` / `*`: every namespace.
	all: boolean?,
	-- usage: the nodes view.
	nodes: boolean?,
	why: string?,
}
export type Builtin = { t: CmdT, heads: { string }, label: string, what: string }

-- A picker row: `key` is `:<t>` for a command, else the canonical resource.
export type Row = { key: string, cells: { string }, cmd: CmdT?, kind: KindRow? }

local M = {}
local BUILTINS: { Builtin } = {
	{ t = "ctx", heads = { "ctx", "context", "contexts" }, label = "ctx …", what = "context picker / switch" },
	{ t = "ns", heads = { "ns", "namespace" }, label = "ns …", what = "namespace scope" },
	{ t = "helm", heads = { "helm", "hm" }, label = "helm", what = "Helm releases" },
	{ t = "events", heads = { "events", "ev", "event" }, label = "events", what = "events timeline" },
	{ t = "usage", heads = { "top", "usage" }, label = "top …", what = "resource usage (pods, nodes)" },
}
M.BUILTINS = BUILTINS

M.PLACEHOLDER = "kind or alias (po, deploy, svc, cm, wd) · ns NAME · ctx NAME · helm · events · top"

local byHead: { [string]: Builtin } = {}
for _, b in BUILTINS do
	for _, h in b.heads do
		byHead[h] = b
	end
end

local NODES: { [string]: boolean } = { nodes = true, node = true, no = true }

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s)
end

function M.validNamespace(arg: string): boolean
	return #arg <= 63
		and (string.find(arg, "^[a-z0-9]$") ~= nil or string.find(arg, "^[a-z0-9][-a-z0-9]*[a-z0-9]$") ~= nil)
end

-- The first word and what follows it.
local function split(text: string): (string, string)
	local t = trim(text)
	local head, rest = string.match(t, "^(%S+)%s*(.*)$")
	return head or "", rest or ""
end

function M.parse(text: string): Cmd
	local head, rest = split(text)
	if head == "" then
		return { t = "empty", head = "" }
	end
	local b = byHead[string.lower(head)]
	if b and b.t == "ctx" then
		return { t = "ctx", head = head, arg = if rest ~= "" then rest else nil }
	end
	local t: CmdT = if b then b.t else "kind"
	if rest == "" then
		return { t = t, head = head }
	end
	if string.find(rest, "%s") then
		return { t = "invalid", head = head, why = "Too many arguments" }
	end
	if rest == "*" or rest == "-A" or rest == "--all-namespaces" then
		return { t = t, head = head, all = true }
	end
	if t == "usage" and NODES[string.lower(rest)] then
		return { t = t, head = head, nodes = true }
	end
	if M.validNamespace(rest) then
		return { t = t, head = head, arg = rest }
	end
	return { t = "invalid", head = head, why = string.format("Not a namespace name: %q", rest) }
end

local function builtinMatches(b: Builtin, word: string): boolean
	if word == "" then
		return true
	end
	if b.t == "helm" and word == "hr" then
		return true
	end
	for _, h in b.heads do
		if string.sub(h, 1, #word) == word then
			return true
		end
	end
	return false
end

local function aliasCell(index: Index, row: KindRow): string
	local plural = string.lower(row.plural)
	local short: { string } = {}
	local other: { string } = {}
	local shortSet: { [string]: boolean } = {}
	for _, s in row.short do
		shortSet[string.lower(s)] = true
		table.insert(short, string.lower(s))
	end
	for _, a in Discovery.aliases(index, row) do
		if a ~= plural and not shortSet[a] and not string.find(a, ".", 1, true) then
			table.insert(other, a)
		end
	end
	table.move(other, 1, #other, #short + 1, short)
	return table.concat(short, ", ")
end

function M.kindCells(index: Index, row: KindRow): { string }
	local scope = if row.namespaced == true then "namespaced" elseif row.namespaced == false then "cluster" else ""
	return { row.name, aliasCell(index, row), row.kind, scope }
end

-- Matching commands, then kinds ranked by Discovery.suggest on the first word.
function M.rows(index: Index, text: string, helmFound: boolean): { Row }
	local word = string.lower((split(text)))
	local out: { Row } = {}
	for _, b in M.BUILTINS do
		if (b.t ~= "helm" or helmFound) and builtinMatches(b, word) then
			table.insert(out, {
				key = ":" .. b.t,
				cells = { b.label, table.concat(b.heads, ", ", 2), b.what, "" },
				cmd = b.t,
			})
		end
	end
	for _, sug in Discovery.suggest(index, word) do
		table.insert(out, { key = sug.row.name, cells = M.kindCells(index, sug.row), kind = sug.row })
	end
	return out
end

-- `text` with its first word replaced by `row`'s canonical word.
function M.complete(text: string, row: Row): string
	local _, rest = split(text)
	local word = row.key
	if row.cmd then
		for _, b in M.BUILTINS do
			if b.t == row.cmd then
				word = b.heads[1]
			end
		end
	end
	return word .. " " .. rest
end

-- The kind an enter on `head` lists: an exact alias, else the best
-- suggestion when it is a prefix match (substring-only needs a pick).
function M.kindFor(index: Index, head: string): (KindRow?, boolean)
	local exact = Discovery.resolve(index, head)
	if exact then
		return exact, true
	end
	local best = Discovery.suggest(index, head)[1]
	if best and best.score <= 1 then
		return best.row, false
	end
	return nil, false
end

return M
