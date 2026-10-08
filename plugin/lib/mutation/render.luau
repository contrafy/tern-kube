--!strict
-- View of the approve block (plugin/lib/mutation/session.luau state): what
-- will run where, what the preview found, how risky it looks and what the
-- user must do to confirm. Plain `{k, p, c}` tables only (no `tern`).
local Capture = require("../lens/capture")
local Command = require("../kubectl/command")
local Confirm = require("./confirm")
local Diffseg = require("./diffseg")
local MutationView = require("../render/mutation_view")
local Session = require("./session")
local T = require("./types")
local Viewstate = require("../lens/viewstate")
local ui = require("../ui")

type Node = ui.Node
type State = Session.State
type SpanLike = ui.SpanLike

export type View = { main: Node, dock: Node?, layer: Node? }

local M = {}

M.MAX_DIFF_LINES = 4000

local MODE_LABEL: { [Session.Mode]: string } = {
	native = "Live mutation",
	quick = "Quick action",
	guard = "Shell guard approval",
}

local SOURCE_LABEL: { [T.ContextSource]: string } = {
	flag = "from --context",
	chosen = "chosen in Tern Kube",
	inferred = "inferred from current-context",
}

local TIER: { [T.Tier]: { text: string, tone: string } } = {
	simple = { text = "Confirm", tone = "info" },
	typed = { text = "Typed confirm", tone = "warning" },
	blocked = { text = "Blocked", tone = "error" },
}

local SEVERITY_TONE: { [T.Severity]: string } = { high = "error", medium = "warning", low = "info", info = "neutral" }

local ACTION_TONE: { [Diffseg.Action]: string } = {
	create = "success",
	modify = "info",
	delete = "error",
	unknown = "neutral",
}

local PENDING_LABEL: { [string]: string } = {
	spool = "Checking the request",
	current = "Reading the current-context",
	target = "Reading the context from the kubeconfig",
	digest = "Hashing the input files",
	fp = "Fingerprinting the command",
	["v-digest"] = "Re-hashing the input files",
	["v-fp"] = "Re-computing the fingerprint",
	["v-target"] = "Re-reading the context",
	["v-current"] = "Re-reading the current-context",
	nonce = "Granting the action",
	respond = "Writing the response",
	manifests = "Reading the manifests",
}

local function spinner(label: string, key: string?): Node
	return ui.row({
		{ k = "spinner", p = { style = "dots", tone = "accent" } },
		ui.text({ ui.span(label, "muted") }),
	}, { key = key })
end

local function button(text: string, action: string?, class: string, key: string, title: string?): Node
	local p: { [string]: any } = { key = key, class = "tk-mbtn " .. class, text = text, title = title }
	if action then
		p.actions = { click = action }
	else
		p.class ..= " tk-mbtn-off"
	end
	return ui.el("button", p)
end

local function chip(text: string, action: string, key: string, tone: string?): Node
	return ui.badge(text, tone or "neutral", { key = key, actions = { click = action }, role = "tern-kube.chip" })
end

local function opLabel(s: State): string
	local plan = s.plan
	if plan then
		return "kubectl " .. plan.operation
	elseif s.quick then
		return (Session.quickLabel(s))
	elseif s.link then
		return "kubectl " .. s.link.op
	end
	return "kubectl"
end

local function contextOf(s: State): string?
	if s.plan then
		return s.plan.targetContext
	end
	return if s.env then s.env.context else nil
end

-- Header ----------------------------------------------------------------------

local function header(s: State): Node
	local badges: { Node } = {
		ui.badge(MODE_LABEL[s.mode], if s.mode == "guard" then "accent" else "info", { key = "mode" }),
		ui.text({ ui.span(opLabel(s), "strong") }, { key = "op" }),
	}
	local a = s.assessment
	if a and s.phase ~= "done" then
		local tier = TIER[a.tier]
		table.insert(badges, ui.badge(tier.text, tier.tone, { key = "tier" }))
	end
	local items: { { { SpanLike } } } = {}
	local function add(k: string, v: { SpanLike })
		table.insert(items, { { k :: SpanLike }, v })
	end
	local ctx = contextOf(s)
	if ctx then
		local src: T.ContextSource? = if s.plan then s.plan.contextSource elseif s.env then s.env.contextSource else nil
		local spans: { SpanLike } = { ui.span(ctx, "strong") }
		if src then
			table.insert(spans, ui.span("  " .. SOURCE_LABEL[src], if src == "inferred" then "warning" else "muted"))
		end
		add("Context", spans)
	end
	local target = s.target
	if target then
		add("Cluster", { ui.span(target.server or "?", "mono"), ui.span("  " .. (target.cluster or ""), "muted") })
	end
	local plan = s.plan
	if plan then
		local ns: string
		if plan.allNamespaces then
			ns = "all namespaces"
		elseif plan.explicitNamespace then
			ns = plan.explicitNamespace :: string
		elseif #plan.filenames > 0 or plan.kustomize then
			ns = "as declared in the manifests, else " .. (plan.targetNamespace or "default")
		else
			ns = (plan.targetNamespace or "default") .. " (context default)"
		end
		add("Namespace", { ns })
		if plan.kubeconfig then
			add("Kubeconfig", { ui.span(plan.kubeconfig :: string, "mono muted") })
		end
	end
	local command = Session.commandText(s)
	if command ~= "" then
		add("Command", { ui.span(command, "mono") })
	end
	local r = s.request
	if r then
		local left = r.createdAt + r.timeoutS - s.now
		add("Requested", {
			ui.span("shell pane " .. r.pane .. " in " .. r.cwd, "muted"),
			ui.span(if left > 0 then string.format("  · expires in %ds", left) else "  · expired", "muted"),
		})
	elseif s.mode == "quick" then
		add("Runs", { ui.span("in a new split after confirmation", "muted") })
	end
	local kv = ui.kv(items)
	local kp = kv.p :: { [string]: any }
	kp.key = "target"
	return ui.col({
		ui.row(badges, { key = "bar", wrap = true, role = "tern-kube.bar" }),
		kv,
	}, { key = "header", role = "tern-kube.approve-header" })
end

-- Steps -----------------------------------------------------------------------

-- Step commands show with "View exact command"; failures always show.
local function stepRow(run: Session.StepRun, i: number, showArgv: boolean): Node
	local o = run.outcome
	local icon: Node
	if run.status == "running" then
		icon = { k = "spinner", p = { style = "dots", tone = "accent" } }
	elseif run.status == "ok" then
		icon = { k = "icon", p = { name = "success", tone = "success" } }
	else
		icon = { k = "icon", p = { name = "error", tone = "error" } }
	end
	local spans: { SpanLike } = { ui.span(run.step.label, "strong") }
	if o and o.status ~= "ok" then
		table.insert(spans, ui.span("  " .. o.text, if o.ok then "muted" else "error"))
	end
	local children: { Node } = { ui.row({ icon, ui.text(spans) }, { key = "line" }) }
	if showArgv then
		table.insert(children, ui.text({ ui.span(Command.format(run.step.argv), "mono muted") }, { key = "argv" }))
	end
	return ui.col(children, { key = "s" .. i, gap = "none" })
end

local function stepsCard(s: State): Node?
	local rows: { Node } = {}
	for tag in s.pending do
		local label = PENDING_LABEL[tag]
		if label and s.phase ~= "verifying" then
			table.insert(rows, spinner(label .. " …", "p-" .. tag))
		end
	end
	table.sort(rows, function(a: Node, b: Node): boolean
		return ((a.p :: any).key :: string) < ((b.p :: any).key :: string)
	end)
	for i, run in s.steps do
		table.insert(rows, stepRow(run, i, s.showCommand))
	end
	if #rows == 0 then
		return nil
	end
	local status = if s.phase == "previewing" or s.phase == "loading"
		then "running"
		elseif s.assessment and s.assessment.tier == "blocked" then "error"
		else "done"
	return ui.card({ "Preview" }, rows, { key = "steps", status = status, role = "tern-kube.approve-steps" })
end

-- Summary and objects ---------------------------------------------------------

local function countBadges(s: State): { Node }
	local out: { Node } = {}
	local function add(n: number, word: string, tone: string)
		if n > 0 then
			table.insert(out, ui.badge(string.format("%d %s", n, word), tone, { key = "c-" .. word }))
		end
	end
	local diff = s.diff
	if diff then
		add(diff.create, "create", "success")
		add(diff.modify, "modify", "info")
		add(diff.delete, "delete", "error")
		add(diff.unknown, "unknown", "neutral")
	end
	local dry = s.dryRun
	if dry and s.plan and (s.plan :: T.Plan).family == "apply" then
		local by: { [string]: number } = {}
		local order: { string } = {}
		for _, r in dry.results do
			if by[r.action] == nil then
				by[r.action] = 0
				table.insert(order, r.action)
			end
			by[r.action] += 1
		end
		for _, action in order do
			if not (diff and (action == "created" or action == "configured")) then
				add(by[action], action, if action == "unchanged" then "muted" else "neutral")
			end
		end
	end
	local plan = s.plan
	if plan and s.targets and plan.family ~= "apply" then
		local n = #(s.targets :: { any })
		local word = ({
			delete = "to delete",
			scale = "to scale",
			restart = "to restart",
		} :: { [string]: string })[plan.family] or "target"
		add(n, word, if plan.family == "delete" then "error" else "info")
		if n == 0 then
			table.insert(out, ui.badge("nothing matched", "warning", { key = "c-none" }))
		end
	end
	return out
end

local function hunks(seg: Diffseg.Segment): (string, number)
	local out: { string } = {}
	local started = false
	local hidden = 0
	for _, line in seg.lines do
		if string.sub(line, 1, 2) == "@@" then
			started = true
		end
		if started then
			if #out < M.MAX_DIFF_LINES then
				table.insert(out, line)
			else
				hidden += 1
			end
		end
	end
	return table.concat(out, "\n"), hidden
end

local function segName(seg: Diffseg.Segment): string
	return (seg.kind or "?") .. " " .. (if seg.namespace then seg.namespace .. "/" else "") .. (seg.name or seg.key)
end

local function diffCards(s: State): Node?
	local diff = s.diff
	if diff == nil or #diff.segments == 0 then
		return nil
	end
	local cards: { Node } = {}
	for i, seg in diff.segments do
		local text, hidden = hunks(seg)
		local body: { Node } = {}
		if seg.binary then
			table.insert(body, ui.muted("Binary or unreadable difference", { key = "bin" }))
		else
			table.insert(
				body,
				{ k = "diff", p = { key = "diff", text = text, path = "object.yaml", mode = "unified" } }
			)
		end
		if hidden > 0 then
			table.insert(
				body,
				ui.muted(string.format("… %d more lines (View exact command to diff locally)", hidden))
			)
		end
		local head: { SpanLike } = {
			ui.span(string.upper(seg.action) .. "  ", "strong"),
			ui.span(segName(seg), "strong"),
			ui.span(string.format("   +%d −%d", seg.added, seg.removed), "muted"),
		}
		table.insert(
			cards,
			ui.card(head, body, {
				key = "d" .. i,
				collapsible = true,
				collapsed = not s.expanded[i],
				selected = s.focus == i,
				inset = true,
				tone = ACTION_TONE[seg.action],
				role = "tern-kube.approve-diff",
			})
		)
	end
	return ui.col(cards, { key = "diffs" })
end

local function unchangedNote(s: State): Node?
	local dry = s.dryRun
	if dry == nil or s.plan == nil or (s.plan :: T.Plan).family ~= "apply" then
		return nil
	end
	local names: { string } = {}
	for _, r in dry.results do
		if r.action == "unchanged" then
			table.insert(names, string.lower(r.kind) .. "/" .. r.name)
		end
	end
	if #names == 0 then
		return nil
	end
	return ui.muted("Unchanged: " .. table.concat(names, ", "), { key = "unchanged" })
end

local function objectsCard(s: State): Node?
	local plan = s.plan
	local targets = s.targets
	if plan == nil or targets == nil or plan.family == "apply" or #targets == 0 then
		return nil
	end
	local items: { { { SpanLike } } } = {}
	for _, r in targets do
		local value: { SpanLike } = { ui.span((if r.namespace then r.namespace .. "/" else "") .. r.name, "mono") }
		if plan.family == "scale" then
			local now = s.replicasNow[r.name]
			table.insert(
				value,
				ui.span(
					string.format(
						"   replicas %s → %s",
						if now then tostring(now) else "?",
						if plan.replicas then tostring(plan.replicas) else "?"
					),
					"strong"
				)
			)
		end
		table.insert(items, { { r.kind :: SpanLike }, value })
	end
	local kv = ui.kv(items)
	local verb = ({ delete = "deleted", scale = "scaled", restart = "restarted" } :: { [string]: string })[plan.family]
		or "affected"
	return ui.card({ string.format("%d object(s) to be %s", #targets, verb) }, { kv }, { key = "objects" })
end

local function risksCard(s: State): Node?
	local a = s.assessment
	if a == nil then
		return nil
	end
	local rows: { Node } = {}
	-- Blocking reasons are listed under "Cannot be confirmed".
	for i, r in a.reasons do
		if r.tier ~= "blocked" then
			table.insert(
				rows,
				ui.row({
					ui.badge(r.severity, SEVERITY_TONE[r.severity], { key = "sev" }),
					ui.text({ ui.span(r.text) }, { key = "text" }),
				}, { key = "r" .. i })
			)
		end
	end
	if #rows == 0 then
		table.insert(rows, ui.muted("No risk findings.", { key = "none" }))
	end
	for i, n in s.notes do
		table.insert(rows, ui.muted(n, { key = "n" .. i }))
	end
	return ui.card(
		{ "Risks", ui.span("  heuristics are advisory; no policy conformance is claimed", "muted") },
		rows,
		{ key = "risks", role = "tern-kube.approve-risks" }
	)
end

-- Confirmation ------------------------------------------------------------------

local function confirmable(s: State): boolean
	local plan = s.plan
	if s.phase ~= "ready" or plan == nil or s.assessment == nil or s.stale then
		return false
	end
	local ok = Confirm.canConfirm(
		plan,
		{ assessment = s.assessment :: T.Assessment, fingerprint = s.fingerprint },
		{ typed = s.typed, targetConfirmed = s.targetConfirmed, override = s.override, fingerprint = s.fingerprint },
		s.config
	)
	return ok
end

local function confirmLabel(s: State): string
	if s.mode == "guard" then
		return "Approve"
	elseif s.mode == "quick" then
		return "Confirm and open"
	end
	return "Confirm and run"
end

local function confirmNodes(s: State, out: { Node })
	local req = s.requirements
	if s.phase == "input" then
		local link = s.link
		if link and link.op == "apply" then
			table.insert(
				out,
				ui.text({
					ui.span("Apply which file or directory? ", "strong"),
					ui.span("relative to ", "muted"),
					ui.span(link.cwd or "/", "mono"),
					ui.span("; -k DIR for a kustomization, -R to recurse; then enter", "muted"),
				}, { key = "prompt" })
			)
		else
			table.insert(
				out,
				ui.text({
					ui.span("Scale ", "strong"),
					ui.span(if link then (link.kind or "") .. "/" .. (link.name or "") else "", "mono"),
					ui.span(" to how many replicas? ", "strong"),
					ui.span("digits, then enter", "muted"),
				}, { key = "prompt" })
			)
		end
		local apply = link ~= nil and link.op == "apply"
		table.insert(out, {
			k = "input",
			p = {
				key = "typed",
				text = s.typed,
				cursor = #s.typed,
				placeholder = if apply then "path" else "replicas",
				prompt = if apply then ">" else "#",
			},
		})
	elseif s.phase == "ready" and req then
		if #req.blockedBy > 0 then
			local lines: { Node } = {}
			for i, r in req.blockedBy do
				local text = if r.id == "preview-failed"
					then "The preview failed (see Preview above); a failed preview cannot be confirmed "
						.. "unless mutations.allow_failed_preview_override is enabled."
					else r.text
				table.insert(lines, ui.text({ ui.span(text, "error") }, { key = "b" .. i }))
			end
			table.insert(
				out,
				ui.card(
					{ "Cannot be confirmed" },
					lines,
					{ key = "blocked", tone = "error", role = "tern-kube.approve-blocked" }
				)
			)
		elseif req.overrideAvailable and not s.override then
			table.insert(
				out,
				ui.text({
					ui.span("The preview failed. ", "error"),
					ui.span("Override confirms without a successful preview and requires typing the name.", "muted"),
				}, { key = "override-note" })
			)
		end
		if req.targetConfirmation then
			local plan = s.plan :: T.Plan
			table.insert(
				out,
				ui.row({
					ui.text({
						ui.span(
							"The context was inferred from the kubeconfig's current-context: ",
							if s.targetConfirmed then "muted" else "warning"
						),
						ui.span(plan.targetContext, "strong"),
					}, { key = "t" }),
					if s.targetConfirmed
						then ui.badge("target confirmed", "success", { key = "tc" })
						else button("Confirm target", "target", "tk-mbtn-plain", "tc", "t"),
				}, { key = "target-confirm", wrap = true })
			)
		end
		if Session.typing(s) and req.typed then
			table.insert(
				out,
				ui.text({
					ui.span("Type ", "strong"),
					ui.span(req.typed :: string, "mono strong"),
					ui.span(" to confirm", "strong"),
				}, { key = "prompt" })
			)
			table.insert(out, {
				k = "input",
				p = {
					key = "typed",
					text = s.typed,
					cursor = #s.typed,
					placeholder = req.typed,
					prompt = ">",
					tone = if s.typed == req.typed then "success" else nil,
				},
			})
		end
	elseif s.phase == "verifying" then
		table.insert(out, spinner("Re-checking the inputs and the target before running …", "verifying"))
	elseif s.phase == "executing" then
		table.insert(out, spinner("Running. It cannot be cancelled once started.", "executing"))
	elseif s.phase == "responding" then
		table.insert(out, spinner("Sending the decision …", "responding"))
	end
	if s.confirmError then
		table.insert(out, ui.text({ ui.span(s.confirmError :: string, "error") }, { key = "confirm-error" }))
	end
	if s.notice then
		table.insert(out, ui.text({ ui.span(s.notice :: string, "warning") }, { key = "notice" }))
	end
	local buttons: { Node } = {}
	if s.phase == "input" then
		table.insert(buttons, button("Preview", "confirm", "tk-mbtn-primary", "go"))
	elseif s.phase == "ready" then
		local canOverride = req and req.overrideAvailable and not s.override
		if canOverride then
			table.insert(buttons, button("Override failed preview", "override", "tk-mbtn-danger", "override"))
		end
		local ok = confirmable(s)
		local danger = s.assessment and s.assessment.tier ~= "simple"
		table.insert(
			buttons,
			button(
				confirmLabel(s),
				if ok then "confirm" else nil,
				if danger then "tk-mbtn-danger" else "tk-mbtn-primary",
				"confirm",
				if Session.typing(s) then "type the name, then enter" else "enter"
			)
		)
	end
	if s.phase ~= "done" and s.phase ~= "closed" then
		local cancelText = if s.mode == "guard" and s.canRespond and not s.decided then "Deny" else "Cancel"
		if s.phase == "error" or s.phase == "expired" then
			cancelText = if s.mode == "guard" and s.canRespond and not s.decided then "Deny" else "Close"
		end
		table.insert(
			buttons,
			button(cancelText, if s.phase == "executing" then nil else "cancel", "tk-mbtn-plain", "cancel", "esc")
		)
	end
	if s.argv then
		table.insert(
			buttons,
			button(
				if s.showCommand then "Hide exact command" else "View exact command",
				"command",
				"tk-mbtn-plain",
				"command",
				"c"
			)
		)
	end
	if s.phase == "ready" or s.phase == "error" then
		if s.argv and not s.decided then
			table.insert(buttons, button("Preview again", "rerun", "tk-mbtn-plain", "rerun", "r"))
		end
	end
	table.insert(buttons, button("?", "help", "tk-mbtn-plain", "help", "help"))
	table.insert(out, ui.row(buttons, { key = "buttons", wrap = true, role = "tern-kube.approve-buttons" }))
end

local function commandNode(s: State): Node?
	if not s.showCommand or s.argv == nil then
		return nil
	end
	local children: { Node } = {
		ui.code(Session.commandText(s), "sh", nil, { key = "code" }),
	}
	local note: string
	if s.mode == "guard" then
		local r = s.request
		note = "The shell guard runs this argv unchanged with "
			.. (if r then r.program else "kubectl")
			.. " after re-checking the fingerprint and the context."
	elseif s.mode == "quick" then
		note = "Opens in a new split; the window rebuilds this command from the confirmed link."
	else
		note = "Runs once, without retries, with the context and kubeconfig pinned."
	end
	table.insert(children, ui.muted(note, { key = "note" }))
	table.insert(children, ui.row({ chip("Copy", "copy", "copy") }, { key = "copy" }))
	return ui.card({ "Exact command" }, children, { key = "command" })
end

-- Result ------------------------------------------------------------------------

-- One line per object re-read after a run: replicas for workloads and the
-- restartedAt annotation a rollout restart stamps.
local function objectSummary(s: State, stdout: string): string
	local ok, doc = pcall(s.decode, stdout)
	if not ok or type(doc) ~= "table" then
		return "found"
	end
	local items = if type(doc.items) == "table" then doc.items else { doc }
	local parts: { string } = {}
	for _, item in items do
		if type(item) ~= "table" or type(item.metadata) ~= "table" then
			continue
		end
		local text = string.lower(tostring(item.kind or "?")) .. "/" .. tostring(item.metadata.name)
		local spec = if type(item.spec) == "table" then item.spec else {}
		local status = if type(item.status) == "table" then item.status else {}
		if type(spec.replicas) == "number" then
			text ..= string.format(" %d/%d ready", tonumber(status.readyReplicas) or 0, spec.replicas)
		end
		local template = if type(spec.template) == "table" then spec.template else {}
		local meta = if type(template.metadata) == "table" then template.metadata else {}
		local ann = if type(meta.annotations) == "table" then meta.annotations else {}
		local restarted = ann["kubectl.kubernetes.io/restartedAt"]
		if type(restarted) == "string" then
			text ..= " restartedAt " .. restarted
		end
		table.insert(parts, text)
	end
	return if #parts == 0 then "nothing found" else table.concat(parts, "; ")
end

local function resultNodes(s: State, out: { Node })
	local ex = s.exec
	local plan = s.plan
	if ex == nil or plan == nil then
		return
	end
	local text = ex.stdout .. (if ex.stderr ~= "" then (if ex.stdout ~= "" then "\n" else "") .. ex.stderr else "")
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	local args = table.move(plan.execArgv, 2, #plan.execArgv, 1, {})
	local ok, capture = pcall(Capture.build, { program = plan.execArgv[1], args = args }, lines, ex.status, {
		decode = s.decode,
	})
	local native = ok and capture.mutation ~= nil and not ex.timedOut
	local bar: { Node } = {}
	if ex.timedOut then
		table.insert(bar, ui.badge("timed out: the outcome is unknown, requery", "error", { key = "st" }))
	elseif not native then
		local tone = if ex.status == 0 then "success" else "error"
		table.insert(bar, ui.badge("exit " .. tostring(ex.status), tone, { key = "st" }))
	end
	table.insert(bar, chip("Requery", "requery", "rq", "accent"))
	local children: { Node } = { ui.row(bar, { key = "bar" }) }
	if native then
		table.insert(children, MutationView.render(capture, s.resultView, Viewstate))
	elseif text ~= "" then
		table.insert(children, ui.code(text, nil, nil, { key = "out" }))
	end
	local rq = s.requery
	if rq then
		local rows: { Node } = {}
		for i, run in rq.steps do
			local o = run.outcome
			local spans: { SpanLike } = { ui.span(run.step.label .. ": ", "strong") }
			if o == nil then
				table.insert(spans, ui.span("running …", "muted"))
			elseif run.step.kind == "targets" then
				if o.ok then
					table.insert(spans, ui.span(objectSummary(s, run.stdout or ""), "success"))
				else
					table.insert(spans, ui.span(o.text, "warning"))
				end
			else
				table.insert(spans, ui.span(o.text, if o.status == "no-changes" then "success" else "warning"))
			end
			table.insert(rows, ui.text(spans, { key = "q" .. i }))
		end
		table.insert(rows, ui.muted(if rq.at then "re-read at " .. os.date("%H:%M:%S", rq.at) else "re-reading …"))
		table.insert(children, ui.card({ "Requery" }, rows, { key = "requery" }))
	end
	table.insert(
		out,
		ui.card({ "Result" }, children, {
			key = "result",
			status = if ex.status == 0 and not ex.timedOut then "done" else "error",
			role = "tern-kube.approve-result",
		})
	)
	table.insert(out, ui.row({ button("Close", "close", "tk-mbtn-plain", "close", "esc") }, { key = "buttons" }))
end

-- Dock and help -------------------------------------------------------------------

local function hints(s: State): { SpanLike }
	if s.phase == "input" then
		local link = s.link
		local apply = link ~= nil and link.op == "apply"
		return { ui.span((if apply then "path" else "digits") .. " · enter preview · esc cancel", "muted") }
	elseif s.phase == "ready" then
		if Session.typing(s) then
			return {
				ui.span(
					"type the name · enter confirms when it matches · tab next diff · esc cancel · ? help",
					"muted"
				),
			}
		end
		local tier = s.assessment and s.assessment.tier
		if tier == "blocked" then
			return {
				ui.span(
					"esc "
						.. (if s.mode == "guard" then "deny" else "cancel")
						.. " · r preview again · c command · ? help",
					"muted"
				),
			}
		end
		local req = s.requirements
		local target = if req and req.targetConfirmation and not s.targetConfirmed then "t confirm target · " else ""
		return {
			ui.span(
				target
					.. "enter confirm · esc cancel · tab next diff · r preview again · c command · y copy · ? help",
				"muted"
			),
		}
	elseif s.phase == "done" then
		return { ui.span("r requery · esc close · y copy command", "muted") }
	elseif s.phase == "executing" then
		return { ui.span("running; cannot be cancelled", "warning") }
	elseif s.phase == "expired" then
		return { ui.span("the request expired; esc closes", "warning") }
	elseif s.phase == "error" then
		return { ui.span("esc close · c command · ? help", "muted") }
	end
	return { ui.span("previewing … esc cancel", "muted") }
end

M.KEYS = {
	{ "enter", "Confirm (simple tier); in the typed tier once the exact name is typed" },
	{ "esc", "Cancel; a guard request is denied" },
	{ "typing", "Fills the confirmation field (typed tier)" },
	{ "tab / shift+tab", "Next / previous resource diff" },
	{ "t", "Confirm an inferred target context" },
	{ "r", "Preview again (after a result: requery)" },
	{ "c", "Show the exact command" },
	{ "y", "Copy the exact command" },
	{ "?", "This help" },
}

local function help(): Node
	local items: { { { SpanLike } } } = {}
	for _, k in M.KEYS do
		table.insert(items, { { ui.span(k[1], "mono strong") :: SpanLike }, { k[2] :: SpanLike } })
	end
	return ui.col({
		ui.text(
			{ ui.span("Tern Kube Approve keys", "strong"), ui.span("   esc or ? closes", "muted") },
			{ key = "title" }
		),
		ui.kv(items),
		ui.muted(
			"Nothing runs before confirmation. The command, its input files and the target "
				.. "are re-checked right before running; any change refuses. Risk findings marked "
				.. "advisory are text heuristics, not policy checks."
		),
	}, { key = "help", role = "tern-kube.approve-help" })
end

-- View --------------------------------------------------------------------------

function M.view(s: State): View
	local main: { Node } = { header(s) }
	local function add(n: Node?)
		if n then
			table.insert(main, n)
		end
	end
	if #s.errors > 0 then
		local rows: { Node } = {}
		for i, e in s.errors do
			table.insert(rows, ui.text({ ui.span(e, "error") }, { key = "e" .. i }))
		end
		add(ui.card({ "Cannot continue" }, rows, { key = "errors", tone = "error", role = "tern-kube.error" }))
	end
	if s.phase == "expired" then
		add(ui.card({ "Request expired" }, {
			ui.text({ ui.span("The shell stopped waiting; nothing was approved and nothing ran.", "warning") }),
		}, { key = "expired", tone = "warning" }))
	end
	add(commandNode(s))
	add(stepsCard(s))
	local summary = countBadges(s)
	if #summary > 0 then
		add(ui.row(summary, { key = "summary", wrap = true }))
	end
	add(diffCards(s))
	add(unchangedNote(s))
	add(objectsCard(s))
	add(risksCard(s))
	if s.phase == "done" then
		resultNodes(s, main)
	else
		confirmNodes(s, main)
	end
	return {
		main = ui.col(main, { role = "tern-kube.approve" }),
		dock = ui.col({ ui.text(hints(s), { key = "hints" }) }, { role = "tern-kube.approve-dock" }),
		layer = if s.help then ui.col({ help() }, { role = "tern-kube.approve-layer" }) else nil,
	}
end

function M.title(s: State): string
	local ctx = contextOf(s)
	return "Tern Kube Approve · " .. opLabel(s) .. (if ctx then " · " .. ctx else "")
end

return M
