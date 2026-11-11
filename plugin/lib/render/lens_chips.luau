--!strict
-- Inspector chips of the k9s-parity lens tables (rollout history, contexts,
-- api-resources, can-i --list) and of the can-i card, plus the Explore URL
-- and copy text behind them. Chips carry only a row key or a link built
-- from validated fields; the host rebuilds every URL from the capture.

local Cani = require("../parse/cani")
local Capture = require("../lens/capture")
local Command = require("../kubectl/command")
local Contexts = require("../parse/contexts")
local Discovery = require("../kubectl/discovery")
local K9s = require("../lens/k9s")
local Link = require("../mutation/link")
local Quick = require("../actions/quick")
local Types = require("../model/types")
local ui = require("../ui")

type Capture = Capture.Capture
type Invocation = Types.Invocation
type Node = ui.Node

export type Options = { mutations: boolean?, quick: Quick.Settings? }

export type Chip = {
	label: string,
	-- `act=value` for the lens event.
	action: string,
	title: string,
	tone: string,
	role: string,
}

local M = {}

-- The can-i card's key for its single question.
M.ANSWER = "answer"
-- The revision view's key for its workload.
M.REVISION = "revision"

local function programOf(inv: Invocation): string
	return if string.match(inv.program, "([^/\\]+)$") == "kubecolor" then "kubecolor" else "kubectl"
end

local function target(inv: Invocation): Quick.Target
	return { context = inv.context, kubeconfig = inv.kubeconfig }
end

local function explore(label: string, key: string, title: string): Chip
	return {
		label = label,
		action = "explore-row=" .. key,
		title = title,
		tone = "accent",
		role = "tern-kube.lens-chip",
	}
end

local function copy(label: string, what: string, key: string, text: string): Chip
	return {
		label = label,
		action = "lens-copy=" .. what .. "|" .. key,
		title = text,
		tone = "neutral",
		role = "tern-kube.lens-chip",
	}
end

local function typed(label: string, url: string, title: string): Chip
	return { label = label, action = "act=" .. url, title = title, tone = "info", role = "tern-kube.quick" }
end

local function has(list: { string }?, ...: string): boolean
	for _, v in { ... } do
		if list and table.find(list, v) then
			return true
		end
	end
	return false
end

-- Copyable commands --------------------------------------------------------------

local function base(inv: Invocation, ...: string): { string }
	local argv = { programOf(inv) }
	for _, a in Command.connectionArgs(inv) do
		table.insert(argv, a)
	end
	for _, w in { ... } do
		table.insert(argv, w)
	end
	return argv
end

local function historyCommand(inv: Invocation, h: K9s.HistoryRow): string
	local argv = base(inv, "rollout", "history", h.object.type .. "/" .. h.object.name)
	if inv.namespace then
		table.insert(argv, "-n")
		table.insert(argv, inv.namespace)
	end
	table.insert(argv, string.format("--revision=%d", h.revision))
	return Command.format(argv)
end

local function getCommand(inv: Invocation, k: Discovery.KindRow): string
	local argv = base(inv, "get", k.name)
	if k.namespaced ~= false then
		if inv.allNamespaces then
			table.insert(argv, "-A")
		elseif inv.namespace then
			table.insert(argv, "-n")
			table.insert(argv, inv.namespace)
		end
	end
	return Command.format(argv)
end

-- The text behind a `lens-copy=what|key` chip; nil when the row is gone or
-- `what` does not apply to it.
function M.copyText(capture: Capture, what: string, key: string): string?
	local d = capture.k9s
	if d == nil then
		return nil
	end
	local inv = capture.invocation
	if what == "command" and d.history and d.history[key] then
		return historyCommand(inv, d.history[key])
	elseif what == "name" and d.contexts and d.contexts[key] then
		return d.contexts[key].name
	elseif what == "name" and d.kinds and d.kinds[key] then
		return d.kinds[key].name
	elseif what == "get" and d.kinds and d.kinds[key] then
		return getCommand(inv, d.kinds[key])
	elseif what == "resource" and d.rules and d.rules[key] then
		local r = d.rules[key]
		return if r.cells[1] ~= "" then r.cells[1] else table.concat(r.urls, " ")
	end
	return nil
end

-- Explore ----------------------------------------------------------------------------

local function resourceRef(
	inv: Invocation,
	resource: string,
	group: string?,
	name: string,
	namespace: string?
): Types.ResourceRef
	return {
		clusterContext = inv.context,
		namespace = namespace,
		group = group,
		version = nil,
		kind = resource,
		name = name,
		uid = nil,
		source = "snapshot",
	}
end

-- What Explore can open for a can-i rule or question: a listable plain
-- resource type (or one named object), never `*` or a subresource.
local function rbacTarget(
	resource: string?,
	group: string?,
	sub: string?,
	names: { string },
	verbs: { string }
): boolean
	if resource == nil or resource == "*" or group == "*" or sub ~= nil then
		return false
	end
	if #names == 1 then
		return has(verbs, "get", "*")
	end
	return #names == 0 and has(verbs, "list", "*")
end

function M.exploreUrl(capture: Capture, key: string, cwd: string?): string?
	local d = capture.k9s
	if d == nil then
		return nil
	end
	local inv = capture.invocation
	if key == M.REVISION and d.revision then
		return Command.exploreUrl(inv, d.revision.ref, { cwd = cwd })
	elseif d.history and d.history[key] then
		local row = Capture.findRow(capture, key)
		return if row and row.ref then Command.exploreUrl(inv, row.ref, { cwd = cwd }) else nil
	elseif d.contexts and d.contexts[key] then
		local c = d.contexts[key]
		local picked = table.clone(inv)
		picked.context = c.name
		return Command.exploreUrl(picked, nil, { namespace = c.namespace or "", pick = true, cwd = cwd })
	elseif d.kinds and d.kinds[key] then
		local k = d.kinds[key]
		if k.verbs and not has(k.verbs, "list") then
			return nil
		end
		return Command.exploreUrl(inv, nil, {
			kind = k.plural,
			group = k.group,
			namespace = if k.namespaced == false then "" else nil,
			cwd = cwd,
		})
	end
	local rule: { resource: string?, group: string?, sub: string?, names: { string }, verbs: { string } }? = nil
	local namespace = if inv.allNamespaces then "*" else inv.namespace
	if d.rules and d.rules[key] then
		local r = d.rules[key]
		rule = { resource = r.resource, group = r.group, sub = r.subresource, names = r.names, verbs = r.verbs }
	elseif key == M.ANSWER and d.cani and d.cani.answer.answer == "yes" then
		local q = d.cani.question
		-- Any yes about a plain type offers it: Explore reports its own refusal.
		local verbs = { "*" }
		local names: { string } = if q.name then { q.name :: string } else {}
		rule = { resource = q.resource, group = q.group, sub = q.subresource, names = names, verbs = verbs }
	end
	if rule == nil or M.impersonated(capture) then
		return nil
	end
	if not rbacTarget(rule.resource, rule.group, rule.sub, rule.names, rule.verbs) then
		return nil
	end
	local resource = rule.resource :: string
	if #rule.names == 1 then
		return Command.exploreUrl(inv, resourceRef(inv, resource, rule.group, rule.names[1], namespace), { cwd = cwd })
	end
	return Command.exploreUrl(inv, nil, { kind = resource, group = rule.group, cwd = cwd })
end

-- can-i answered for someone else (--as, --as-group, --as-uid, --user,
-- --token): Explore would run as the context's own user.
function M.impersonated(capture: Capture): boolean
	local d = capture.k9s
	if d and d.cani then
		return d.cani.question.impersonated
	end
	local inv = capture.invocation
	return inv.flags.as ~= nil
		or inv.flags["as-group"] ~= nil
		or inv.flags["as-uid"] ~= nil
		or inv.user ~= nil
		or inv.flags.token ~= nil
end

-- Row chips -----------------------------------------------------------------------------

local function historyChips(capture: Capture, key: string, h: K9s.HistoryRow, opts: Options): { Chip }
	local inv = capture.invocation
	local row = Capture.findRow(capture, key)
	local ref = if row then row.ref else nil
	local out: { Chip } = {}
	if ref == nil then
		return out
	end
	local qopts: Quick.Opts = { revision = h.revision, program = programOf(inv) }
	local url = Quick.encode("history", target(inv), ref, Quick.withHost("history", qopts, opts.quick))
	if url then
		local line = Quick.typedLine("history", target(inv), ref, qopts)
		table.insert(
			out,
			typed(
				string.format("Show revision %d", h.revision),
				url,
				"Typed into a new split, where it gets the revision view: " .. (if line then line.line else "")
			)
		)
	end
	if opts.mutations and not h.current then
		local link = Link.forRevision(ref, h.revision, {
			context = inv.context,
			source = if inv.context then "flag" else nil,
			kubeconfig = inv.kubeconfig,
		})
		if link then
			table.insert(out, {
				label = string.format("Roll back to %d", h.revision),
				action = "mutate=" .. link,
				title = string.format(
					"Previews rollout undo --to-revision=%d in the approve block, then asks for confirmation",
					h.revision
				),
				tone = "warning",
				role = "tern-kube.mutate",
			})
		end
	end
	table.insert(out, explore("Explore", key, "Open the workload in the Explore block (may run kubectl)"))
	table.insert(out, copy("Copy command", "command", key, historyCommand(inv, h)))
	return out
end

local function contextChips(key: string, c: Contexts.ContextRow): { Chip }
	return {
		explore(
			"Explore in this context",
			key,
			"Open Explore against " .. c.name .. " (chosen, not confirmed; the kubeconfig is not changed)"
		),
		copy("Copy name", "name", key, c.name),
	}
end

local function kindChips(capture: Capture, key: string, k: Discovery.KindRow): { Chip }
	local out: { Chip } = {}
	if k.verbs == nil or has(k.verbs, "list") then
		table.insert(
			out,
			explore("Explore " .. k.plural, key, "List " .. k.name .. " in the Explore block (runs kubectl)")
		)
	end
	table.insert(out, copy("Copy name", "name", key, k.name))
	table.insert(out, copy("Copy get command", "get", key, getCommand(capture.invocation, k)))
	return out
end

local function ruleChips(capture: Capture, key: string, r: Cani.Rule): { Chip }
	local out: { Chip } = {}
	if M.exploreUrl(capture, key, nil) then
		local what = if #r.names == 1 then (r.resource :: string) .. "/" .. r.names[1] else r.resource :: string
		table.insert(
			out,
			explore("Explore " .. what, key, "Open it in the Explore block (runs kubectl as the context's user)")
		)
	end
	local text = M.copyText(capture, "resource", key)
	if text and text ~= "" then
		table.insert(out, copy(if r.resource then "Copy resource" else "Copy URLs", "resource", key, text))
	end
	return out
end

-- Chips for the row `key` of a k9s-parity table; nil when the capture is
-- not one (the generic resource chips apply).
function M.rowChips(capture: Capture, key: string, opts: Options?): { Chip }?
	local d = capture.k9s
	if d == nil then
		return nil
	end
	local o: Options = opts or {}
	if d.history and d.history[key] then
		return historyChips(capture, key, d.history[key], o)
	elseif d.contexts and d.contexts[key] then
		return contextChips(key, d.contexts[key])
	elseif d.kinds and d.kinds[key] then
		return kindChips(capture, key, d.kinds[key])
	elseif d.rules and d.rules[key] then
		return ruleChips(capture, key, d.rules[key])
	end
	return if K9s.TABLE_MODES[d.mode] then {} else nil
end

-- The can-i card: Explore on a yes, and every rule for the same subject.
function M.answerChips(capture: Capture, opts: Options?): { Chip }
	local d = capture.k9s
	local out: { Chip } = {}
	if d == nil or d.cani == nil then
		return out
	end
	local q = d.cani.question
	local inv = capture.invocation
	if M.exploreUrl(capture, M.ANSWER, nil) then
		local what = if q.name then (q.resource :: string) .. "/" .. q.name else q.resource :: string
		table.insert(out, explore("Explore " .. what, M.ANSWER, "Open it in the Explore block (runs kubectl)"))
	end
	-- --user and --token name credentials a link must not carry.
	if q.user == nil and not q.token then
		local qopts: Quick.Opts = {
			namespace = inv.namespace,
			as = q.as,
			asGroups = if #q.asGroups > 0 then q.asGroups else nil,
			asUid = q.asUid,
			program = programOf(inv),
		}
		local o: Options = opts or {}
		local url = Quick.encode("can-i-list", target(inv), nil, Quick.withHost("can-i-list", qopts, o.quick))
		if url then
			local line = Quick.typedLine("can-i-list", target(inv), nil, qopts)
			table.insert(
				out,
				typed(
					"All permissions",
					url,
					"Typed into a new split, where it gets the rules view: " .. (if line then line.line else "")
				)
			)
		end
	end
	return out
end

-- The revision view: roll back to it, the whole history, the workload.
function M.revisionChips(capture: Capture, opts: Options?): { Chip }
	local d = capture.k9s
	local out: { Chip } = {}
	local info = if d then d.revision else nil
	if info == nil then
		return out
	end
	local o: Options = opts or {}
	local inv = capture.invocation
	if o.mutations then
		local link = Link.forRevision(info.ref, info.revision, {
			context = inv.context,
			source = if inv.context then "flag" else nil,
			kubeconfig = inv.kubeconfig,
		})
		if link then
			table.insert(out, {
				label = "Roll back to this revision",
				action = "mutate=" .. link,
				title = string.format(
					"Previews rollout undo --to-revision=%d in the approve block, then asks for confirmation",
					info.revision
				),
				tone = "warning",
				role = "tern-kube.mutate",
			})
		end
	end
	local qopts: Quick.Opts = { program = programOf(inv) }
	local url = Quick.encode("history", target(inv), info.ref, Quick.withHost("history", qopts, o.quick))
	if url then
		local line = Quick.typedLine("history", target(inv), info.ref, qopts)
		table.insert(
			out,
			typed(
				"History",
				url,
				"Typed into a new split, where it gets the history view: " .. (if line then line.line else "")
			)
		)
	end
	table.insert(out, explore("Explore", M.REVISION, "Open the workload in the Explore block (may run kubectl)"))
	return out
end

function M.nodes(chips: { Chip }): { Node }
	local out: { Node } = table.create(#chips)
	for i, c in chips do
		out[i] = ui.badge(c.label, c.tone, { title = c.title, actions = { click = c.action }, role = c.role })
	end
	return out
end

return M
