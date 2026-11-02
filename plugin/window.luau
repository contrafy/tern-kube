--!strict
local Command = require("./lib/kubectl/command")
local ConfigHost = require("./config_host")
local Link = require("./lib/mutation/link")
local PaneEnv = require("./lib/actions/pane_env")
local Quick = require("./lib/actions/quick")
local Shellenv = require("./lib/env/shellenv")

local log = tern.log

local SCHEME = "tern-kube://"
local APPROVE = "tern-kube.approve"
local SETTINGS = "tern-kube.settings"
local SETTINGS_URL = "tern-kube://settings"
local SPOOL = tern.plugin.data .. "/spool"
-- The shell guard core ships in the installed package; native edit runs it.
local GUARD_CORE = tern.plugin.dir .. "/shell/tern-kube-guard"

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

local function launch(link: LinkRequest, req: Quick.Request, cx: WindowCx)
	local cfg = ConfigHost.load().config
	local target =
		{ context = req.target.context, kubeconfig = req.target.kubeconfig, program = quickProgram(cfg.kubectl) }
	local cmd, cerr = Quick.command(req.action, target, req.ref, req.opts, {
		shellCommand = cfg.quick_actions.shell_command,
		logsTail = cfg.quick_actions.logs_tail,
		debugImage = cfg.quick_actions.debug_image,
		guardCore = GUARD_CORE,
	})
	if cmd == nil then
		cx:toast("error", "Tern Kube: invalid quick action", cerr)
		return
	end
	local place = Quick.placement(cfg.quick_actions.placement)
	local pane: number?
	if place.how == "tab" then
		pane = cx.layout:new_tab({ command = cmd.line })
	else
		pane = cx.layout:split(link.pane, place.dir, { command = cmd.line })
	end
	log.info("tern-kube quick action", req.action, cmd.title, "pane=" .. tostring(pane))
	if pane == nil then
		cx:copy(cmd.line)
		cx:toast("error", "Tern Kube: could not open a pane", "Command copied to the clipboard")
	end
end

-- `logs` variants are typed at the prompt of a new interactive split, not
-- run as its command: Tern lenses only typed commands, and the pane stays
-- at a prompt afterwards. The line is rebuilt from the validated fields;
-- one no shell would read literally is copied instead of typed.
local function launchTyped(link: LinkRequest, req: Quick.Request, cx: WindowCx)
	local typed, err = Quick.typedLine(req.target, req.ref, req.opts)
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
	local place = Quick.placement(ConfigHost.load().config.quick_actions.placement)
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

-- Quick actions open a new split (or tab) running a kubectl command rebuilt
-- from the link's validated fields; the URL never supplies the command.
-- Mutating ones go to the approve block first; it re-opens the link with a
-- single-use `confirm` token once the user confirmed the preview. Edit opens
-- directly: the guard in the split asks for approval after the user saves.
local function quickAction(link: LinkRequest, cx: WindowCx): RouteDecision?
	local req, err = Quick.decode(link.url)
	if req == nil then
		cx:toast("error", "Tern Kube: invalid quick action", err)
		return nil
	end
	local confirm = req.opts.confirm
	if confirm ~= nil then
		local ok, rest, why =
			Link.consumeGrant(tern.kv.get(Link.GRANTS_KEY), confirm, Link.quickBase(req) or "", os.time())
		tern.kv.set(Link.GRANTS_KEY, rest)
		if not ok then
			cx:toast("error", "Tern Kube: not confirmed", why)
			return nil
		end
		launch(link, req, cx)
		return nil
	end
	if req.target.kubeconfig == nil then
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
	if gate == "editor" then
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
		return { block = APPROVE, args = { url or link.url } }
	end
	launch(link, req, cx)
	return nil
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
		return { block = APPROVE, args = { link.url } }
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
	return { block = "tern-kube.explore", args = { link.url } }
end)

tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
	if req.origin ~= "cli" then
		return nil
	end
	if string.match(req.path, "/tern%-kube/spool/req%-[%w%-]+%.json$") == nil then
		return nil
	end
	return { block = APPROVE, args = { req.path } }
end)

-- The focused pane's directory goes along: the GitOps views index the
-- repository that contains it.
local function openExplore(cx: WindowCx, route: string?)
	local focused = cx.session:focused()
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
	if cx:new_block("tern-kube.explore", { arg }, "beside") == nil then
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

-- The approve block asks for the path; relative paths resolve against the
-- focused pane's working directory, and its recorded KUBECONFIG is pinned.
tern.command({
	id = "apply",
	title = "Tern Kube: Apply file or directory",
	icon = "box",
	run = function(cx: WindowCx)
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		local cwd = if info and info.cwd and string.sub(info.cwd, 1, 1) == "/" then info.cwd else tern.getenv("HOME")
		local url, err = Link.encode({
			op = "apply",
			recursive = false,
			overwrite = false,
			cwd = cwd or "/",
			kubeconfig = paneKubeconfig(focused),
		})
		if url == nil then
			cx:toast("error", "Tern Kube: cannot apply from here", err)
			return
		end
		if cx:new_block(APPROVE, { url }, "beside") == nil then
			cx:toast("error", "Tern Kube is not loaded on this host")
		end
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
