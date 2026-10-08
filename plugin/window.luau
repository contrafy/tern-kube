--!strict
local Command = require("./lib/kubectl/command")
local ConfigHost = require("./config_host")
local Link = require("./lib/mutation/link")
local PaneEnv = require("./lib/actions/pane_env")
local Quick = require("./lib/actions/quick")

local log = tern.log

local SCHEME = "tern-kube://"
local APPROVE = "tern-kube.approve"
local SPOOL = tern.plugin.data .. "/spool"

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

local function launch(link: LinkRequest, req: Quick.Request, cx: WindowCx)
	local cfg = ConfigHost.load().config
	local target = { context = req.target.context, kubeconfig = req.target.kubeconfig, program = ConfigHost.kubectl() }
	local cmd, cerr = Quick.command(req.action, target, req.ref, req.opts, {
		shellCommand = cfg.quick_actions.shell_command,
		logsTail = cfg.quick_actions.logs_tail,
		debugImage = cfg.quick_actions.debug_image,
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

-- Quick actions open a new split (or tab) running a kubectl command rebuilt
-- from the link's validated fields; the URL never supplies the command.
-- Mutating ones go to the approve block first; it re-opens the link with a
-- single-use `confirm` token once the user confirmed the preview.
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
	if Quick.mutates(req.action) then
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
	if string.sub(link.url, 1, #Quick.SCHEME) == Quick.SCHEME then
		local decision: RouteDecision? = nil
		local ok, err = pcall(function()
			decision = quickAction(link, cx)
		end)
		if not ok then
			log.warn("tern-kube quick action failed", link.url, tostring(err))
			pcall(function()
				cx:toast("error", "Tern Kube: quick action failed", tostring(err))
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
tern.command({
	id = "explore",
	title = "Tern Kube: Explore",
	icon = "box",
	run = function(cx: WindowCx)
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		local cwd = if info and info.cwd and string.sub(info.cwd, 1, 1) == "/" then info.cwd else nil
		local arg = if cwd then "tern-kube://explore?cwd=" .. Command.urlencode(cwd) else "palette"
		if cx:new_block("tern-kube.explore", { arg }, "beside") == nil then
			cx:toast("error", "Tern Kube is not loaded on this host")
		end
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
		if cx:new_block("tern-kube.settings", {}, "beside") == nil then
			cx:toast("error", "Tern Kube is not loaded on this host")
		end
	end,
})
