--!strict
local Command = require("./lib/kubectl/command")
local ConfigHost = require("./config_host")
local Entropy = require("./lib/env/entropy")
local Link = require("./lib/mutation/link")
local PaneEnv = require("./lib/actions/pane_env")
local PaneHost = require("./lib/env/panehost")
local Quick = require("./lib/actions/quick")
local Shellenv = require("./lib/env/shellenv")

local log = tern.log

local SCHEME = "tern-kube://"
local APPROVE = "tern-kube.approve"
local EXPLORE = "tern-kube.explore"
local SETTINGS = "tern-kube.settings"
local SETTINGS_URL = "tern-kube://settings"
local SPOOL = tern.plugin.data .. "/spool"
-- The shell guard core ships in the installed package; native edit runs it.
local GUARD_CORE = tern.plugin.dir .. "/shell/tern-kube-guard"

-- Which host `pane` is on; a window without the hosts API is local.
local function paneHost(cx: WindowCx, pane: number?): PaneHost.PaneHost
	local ok, result = pcall(function(): PaneHost.PaneHost
		local rows: { PaneHost.HostRow } = {}
		for _, h in cx.hosts:list() do
			table.insert(rows, { kind = h.kind, name = h.name, address = h.address, panes = h.panes })
		end
		local cur = cx.hosts:current()
		return PaneHost.of(rows, pane, { kind = cur.kind, name = cur.name, address = cur.address, panes = cur.panes })
	end)
	if not ok then
		log.debug("tern-kube hosts listing failed", tostring(result))
		return { remote = false }
	end
	return result
end

-- The split runs on the remote host: its login environment and loopback.
-- The display name is the ssh spelling (`tk@localhost:2222`); the address
-- may be an iroh endpoint id, which ssh cannot reach.
local function remoteOf(host: PaneHost.PaneHost): Quick.Remote?
	if not host.remote then
		return nil
	end
	local name = host.name or host.address or "the remote host"
	local ssh = PaneHost.sshDestination(name)
	if ssh == nil and host.address then
		ssh = PaneHost.sshDestination(host.address)
	end
	return { name = name, ssh = ssh }
end

-- The KUBECONFIG the shell in `pane` had at its last prompt, when the opt-in
-- shell snippet recorded one (shell/PROTOCOL.md "Pane env record").
local function paneKubeconfig(pane: number?): string?
	local path = if pane then PaneEnv.path(SPOOL, pane) else nil
	if path == nil then
		return nil
	end
	local ok, text = pcall(tern.fs.read, path, PaneEnv.MAX_BYTES)
	if not ok then
		return nil
	end
	local value, why = PaneEnv.kubeconfig(text)
	if value == nil then
		log.debug("tern-kube pane env record ignored", path, why)
	end
	return value
end

-- The split's shell has the user's login environment, so a bare kubectl
-- resolves there; only an explicit program setting is pinned.
local function quickProgram(configValue: string): string
	local explicit = Shellenv.explicitKubectl(configValue, tern.kv.get("kubectl"), tern.getenv("TKUBE_KUBECTL"))
	return if explicit then explicit.value else "kubectl"
end

-- This machine's config governs only what a link does not carry (`place`,
-- `tail` come from the pane host's config) and the window-scoped shell
-- command. A remote pane resolves bare kubectl on its own PATH. `outcome`:
-- a confirmed mutating action, whose split records kubectl's outcome.
local function launch(at: number, req: Quick.Request, cx: WindowCx, host: PaneHost.PaneHost, outcome: { run: string? }?)
	local cfg = ConfigHost.load().config
	local program = if host.remote then "kubectl" else quickProgram(cfg.kubectl)
	local target = { context = req.target.context, kubeconfig = req.target.kubeconfig, program = program }
	local cmd, cerr = Quick.command(req.action, target, req.ref, req.opts, {
		shellCommand = cfg.quick_actions.shell_command,
		logsTail = cfg.quick_actions.logs_tail,
		debugImage = cfg.quick_actions.debug_image,
		guardCore = GUARD_CORE,
		remote = remoteOf(host),
		outcome = outcome,
	})
	if cmd == nil then
		cx:toast("error", "Tern Kube: invalid quick action", cerr)
		return
	end
	local place = Quick.placement(req.opts.place or cfg.quick_actions.placement)
	local pane: number?
	if place.how == "tab" then
		pane = cx.layout:new_tab({ command = cmd.line })
	else
		pane = cx.layout:split(at, place.dir, { command = cmd.line })
	end
	log.info("tern-kube quick action", req.action, cmd.title, "pane=" .. tostring(pane))
	if pane == nil then
		cx:copy(cmd.line)
		cx:toast("error", "Tern Kube: could not open a pane", "Command copied to the clipboard")
	end
end

-- Typed actions (`logs` variants, `history`, `can-i-list`) are typed at the
-- prompt of a new interactive split, not run as its command: Tern lenses
-- only typed commands, and the pane stays at a prompt afterwards. The line
-- is rebuilt from the validated fields; one no shell would read literally
-- is copied instead of typed.
local function launchTyped(link: LinkRequest, req: Quick.Request, cx: WindowCx)
	local typed, err = Quick.typedLine(req.action, req.target, req.ref, req.opts)
	if typed == nil then
		cx:toast("error", "Tern Kube: invalid quick action", err)
		return
	end
	if typed.refusal then
		cx:copy(typed.line)
		cx:toast("error", "Tern Kube: not typed into a split", typed.refusal .. "; command copied to the clipboard")
		return
	end
	-- A relative --kubeconfig resolves where the lensed command ran.
	local info = cx.session:pane(link.pane)
	local cwd = if info and info.cwd and string.sub(info.cwd, 1, 1) == "/" then info.cwd else nil
	local place = Quick.placement(req.opts.place or ConfigHost.load().config.quick_actions.placement)
	local pane: number?
	if place.how == "tab" then
		pane = cx.layout:new_tab({ cwd = cwd })
	else
		pane = cx.layout:split(link.pane, place.dir, { cwd = cwd })
	end
	log.info("tern-kube typed quick action", req.action, typed.title, "pane=" .. tostring(pane))
	if pane == nil then
		cx:copy(typed.line)
		cx:toast("error", "Tern Kube: could not open a pane", "Command copied to the clipboard")
		return
	end
	cx:run(pane, typed.line .. "\r")
end

-- Approve blocks take the slot of the pane that asked ("over": that pane is
-- parked and comes back when the block closes), so they never squeeze the
-- layout (MUT-F10). Approve pane -> the pane it covers.
local approveOrigin: { [number]: number } = {}

local function isApprove(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	return info ~= nil and info.block == APPROVE
end

-- A link clicked inside an approve block acts for the pane it covers.
local function originOf(pane: number?): number?
	return if pane then approveOrigin[pane] or pane else nil
end

-- One approve block per pane (MUT-F12): a second request for a pane that
-- already has one (or for an approve block itself) focuses it; a follow-up
-- link clicked in a finished approve block (`fromLink`) replaces that block
-- over the same pane.
local function showApprove(cx: WindowCx, args: { string }, origin: number?, fromLink: boolean): number?
	local target = origin
	if target and isApprove(cx, target) then
		if not fromLink then
			cx.layout:focus(target)
			cx:toast("info", "Tern Kube: an approval is already open here", "Finish or close it first")
			return nil
		end
		local prev = target
		target = approveOrigin[prev]
		approveOrigin[prev] = nil
		cx.layout:close(prev)
	elseif target then
		for pane, covered in approveOrigin do
			if covered == target then
				if cx.session:pane(pane) then
					cx.layout:focus(pane)
					cx:toast("info", "Tern Kube: an approval is already open here", "Finish or close it first")
					return nil
				end
				approveOrigin[pane] = nil
			end
		end
	end
	local pane = cx:new_block(APPROVE, args, "over", if target then { target = target } else nil)
	if pane == nil then
		cx:toast("error", "Tern Kube is not loaded on this host")
	elseif target then
		approveOrigin[pane] = target
	end
	return pane
end

-- The grant token authorizes running the mutation, so it comes from
-- /dev/urandom (read by a process: route.link cannot wait, so the approve
-- block opens from the process callback), with the run id that correlates
-- the approved and outcome records. No clean read, no grant and no approve
-- block: fail closed.
local function openApprove(url: string, base: string, origin: number?)
	tern.process.run(Entropy.ARGV, { timeout_ms = Entropy.TIMEOUT_MS }, function(result: ProcessResult, cx: WindowCx?)
		if cx == nil then
			log.warn("tern-kube quick action: no window to open the approve block in")
			return
		end
		local token, run = Entropy.tokens(result)
		if token == nil then
			log.warn("tern-kube quick action: no randomness for a grant", tostring(result.status), result.stderr)
			cx:toast("error", "Tern Kube: cannot confirm", "reading /dev/urandom failed; nothing was started")
			return
		end
		local grants, err = Link.mintGrant(tern.kv.get(Link.GRANTS_KEY), token, base, os.time(), Link.GRANT_TTL, run)
		if grants == nil then
			cx:toast("error", "Tern Kube: cannot confirm", err)
			return
		end
		tern.kv.set(Link.GRANTS_KEY, grants)
		if showApprove(cx, { url, token, run :: string }, origin, true) == nil then
			local rest = table.clone(grants)
			rest[token] = nil
			tern.kv.set(Link.GRANTS_KEY, rest)
		end
	end)
end

-- Quick actions open a new split (or tab) running a kubectl command rebuilt
-- from the link's validated fields; the URL never supplies the command.
-- Mutating ones go to the approve block first, with a single-use grant token
-- minted here (window kv: the approve block may run on another host). It
-- re-opens the link with `confirm=<token>` once the user confirmed the
-- preview. Edit opens directly: the guard in the split asks for approval
-- after the user saves.
local function quickAction(link: LinkRequest, cx: WindowCx): RouteDecision?
	local req, err = Quick.decode(link.url)
	if req == nil then
		cx:toast("error", "Tern Kube: invalid quick action", err)
		return nil
	end
	local host = paneHost(cx, link.pane)
	local confirm = req.opts.confirm
	if confirm ~= nil then
		local grant, rest, why = Link.consumeGrant(tern.kv.get(Link.GRANTS_KEY), confirm, req, os.time())
		tern.kv.set(Link.GRANTS_KEY, rest)
		if grant == nil then
			cx:toast("error", "Tern Kube: not confirmed", why)
			return nil
		end
		-- The confirmed link comes from the approve block, which sits in the
		-- slot of the pane that asked: split beside it while it is open
		-- (run-now stays), else beside that pane (it is back).
		local at = if cx.session:pane(link.pane) then link.pane else originOf(link.pane) or link.pane
		launch(at, req, cx, host, { run = grant.run })
		return nil
	end
	-- Pane records live in this machine's spool; a remote pane's record is
	-- on its host and its id is not comparable, so the split falls back to
	-- the remote login environment (and says so).
	if req.target.kubeconfig == nil and not host.remote then
		local kubeconfig = paneKubeconfig(link.pane)
		if kubeconfig then
			req.target = { context = req.target.context, kubeconfig = kubeconfig }
		end
	end
	if Quick.typed(req.action) then
		launchTyped(link, req, cx)
		return nil
	end
	local gate = Quick.gate(req.action)
	-- On a remote pane the host half offered the chip under its own config,
	-- and the split runs that host's guard.
	if gate == "editor" and not host.remote then
		if not ConfigHost.load().config.mutations.enabled then
			cx:toast("error", "Mutations are disabled", "mutations.enabled is false in the config")
			return nil
		end
		local okExists, present = pcall(tern.fs.exists, GUARD_CORE)
		if not okExists or not present then
			cx:toast("error", "Tern Kube: cannot edit", "shell/tern-kube-guard is missing from the plugin directory")
			return nil
		end
	elseif gate == "approve" then
		local url = Quick.encode(req.action, req.target, req.ref, req.opts)
		local base = Link.quickBase(req)
		if url == nil or base == nil then
			cx:toast("error", "Tern Kube: invalid quick action", "the link does not encode")
			return nil
		end
		openApprove(url, base, link.pane)
		return nil
	end
	launch(link.pane, req, cx, host)
	return nil
end

-- Explore's manifest opens (B4): the file opens where Tern opens files, and
-- the focus stays in the pane that asked, so its next keys do not edit it.
local function openFile(link: LinkRequest, cx: WindowCx)
	local f = Quick.decodeFile(link.url)
	if f == nil then
		cx:toast("error", "Tern Kube: not opened", "only absolute paths of manifest files open from a tern-kube link")
		return
	end
	cx:open(f.path .. (if f.line then ":" .. string.format("%d", f.line) else ""), nil, { focus = false })
	local pane = link.pane
	if pane and cx.session:focused() ~= pane then
		cx.layout:focus(pane)
	end
end

-- Every tern-kube:// URL must be claimed here: an unclaimed one, or a
-- handler error, falls through to the OS, which shows a "no application"
-- dialog on macOS.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
		return nil
	end
	log.debug("tern-kube route.link", link.url)
	if string.sub(link.url, 1, #Link.SCHEME) == Link.SCHEME then
		showApprove(cx, { link.url }, link.pane, true)
		return { handled = true }
	end
	if link.url == SETTINGS_URL or string.sub(link.url, 1, #SETTINGS_URL + 1) == SETTINGS_URL .. "?" then
		-- `key` selects that setting (Explore's kubectl-not-found card).
		local args: { string } = {}
		for _, p in Command.parseQuery(link.url) do
			if p.key == "key" then
				args = { p.value }
			end
		end
		return { block = SETTINGS, args = args }
	end
	if string.sub(link.url, 1, #Quick.FILE_SCHEME) == Quick.FILE_SCHEME then
		local ok, err = pcall(function()
			openFile(link, cx)
		end)
		if not ok then
			log.warn("tern-kube file open failed", link.url, tostring(err))
		end
		return { handled = true }
	end
	if string.sub(link.url, 1, #Quick.SCHEME) == Quick.SCHEME then
		local decision: RouteDecision? = nil
		local ok, err = pcall(function()
			decision = quickAction(link, cx)
		end)
		if not ok then
			log.warn("tern-kube quick action failed", link.url, tostring(err))
			pcall(function()
				cx:toast("error", "Tern Kube: quick action failed", Shellenv.errorText(err))
			end)
		end
		return decision or { handled = true }
	end
	return { block = EXPLORE, args = { link.url } }
end)

tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
	if req.origin ~= "cli" then
		return nil
	end
	if string.match(req.path, "/tern%-kube/spool/req%-[%w%-]+%.json$") == nil then
		return nil
	end
	-- Opens beside the waiting shell: Tern 0.9.14 ignores `how` on a block
	-- decision (verified), and `tern open --wait` waits for the blocks its
	-- own open created, so the route must open this one.
	return { block = APPROVE, args = { req.path } }
end)

-- The Explore the palette should reuse (EXP-B9): the focused pane, else one
-- in the focused pane's tab.
local function openedExplore(cx: WindowCx, focused: number?): number?
	local info = if focused then cx.session:pane(focused) else nil
	if focused and info and info.block == EXPLORE then
		return focused
	end
	local tab = if info then info.tab else nil
	if tab == nil then
		return nil
	end
	for _, p in cx.session:panes() do
		if p.block == EXPLORE and p.tab == tab and not p.parked then
			return p.pane
		end
	end
	return nil
end

-- The focused pane's directory goes along: the GitOps views index the
-- repository that contains it. An open Explore is reused, keeping its
-- context and namespace; `route` switches it (nil keeps its route).
local function openExplore(cx: WindowCx, route: string?)
	local focused = cx.session:focused()
	local open = openedExplore(cx, focused)
	if open then
		cx.layout:focus(open)
		cx.session:event(open, { ev = "action", act = "palette-route", value = route or "" })
		return
	end
	local info = if focused then cx.session:pane(focused) else nil
	local cwd = if info and info.cwd and string.sub(info.cwd, 1, 1) == "/" then info.cwd else nil
	local params: { string } = {}
	if cwd then
		table.insert(params, "cwd=" .. Command.urlencode(cwd))
	end
	if route then
		table.insert(params, "route=" .. route)
	end
	local arg = if #params > 0 then "tern-kube://explore?" .. table.concat(params, "&") else "palette"
	if cx:new_block(EXPLORE, { arg }, "beside") == nil then
		cx:toast("error", "Tern Kube is not loaded on this host")
	end
end

tern.command({
	id = "explore",
	title = "Tern Kube: Explore",
	icon = "box",
	run = function(cx: WindowCx)
		openExplore(cx, nil)
	end,
})

tern.command({
	id = "events",
	title = "Tern Kube: Events",
	icon = "box",
	run = function(cx: WindowCx)
		openExplore(cx, "events")
	end,
})

tern.command({
	id = "helm",
	title = "Tern Kube: Helm releases",
	icon = "box",
	run = function(cx: WindowCx)
		openExplore(cx, "helm-releases")
	end,
})

tern.command({
	id = "usage",
	title = "Tern Kube: Resource usage",
	icon = "box",
	run = function(cx: WindowCx)
		openExplore(cx, "usage")
	end,
})

-- The approve block asks for the path; relative paths resolve against the
-- focused pane's working directory, and its recorded KUBECONFIG is pinned.
-- On a remote pane this machine's HOME and pane records do not apply: the
-- approve block (on that host) falls back to its own HOME and environment.
tern.command({
	id = "apply",
	title = "Tern Kube: Apply file or directory",
	icon = "box",
	run = function(cx: WindowCx)
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		local remote = paneHost(cx, focused).remote
		local cwd = if info
				and info.cwd
				and string.sub(info.cwd, 1, 1) == "/"
			then info.cwd
			elseif remote then nil
			else tern.getenv("HOME")
		local url, err = Link.encode({
			op = "apply",
			recursive = false,
			overwrite = false,
			cwd = cwd,
			kubeconfig = if remote then nil else paneKubeconfig(focused),
		})
		if url == nil then
			cx:toast("error", "Tern Kube: cannot apply from here", err)
			return
		end
		showApprove(cx, { url }, focused, false)
	end,
})

tern.command({
	id = "settings",
	title = "Tern Kube: Settings",
	icon = "sliders",
	run = function(cx: WindowCx)
		if cx:new_block(SETTINGS, {}, "beside") == nil then
			cx:toast("error", "Tern Kube is not loaded on this host")
		end
	end,
})
