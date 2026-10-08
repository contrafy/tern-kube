--!strict
local ConfigHost = require("./config_host")
local Quick = require("./lib/actions/quick")

local log = tern.log

local SCHEME = "kube-lens://"

-- Quick actions open a new split (or tab) running a kubectl command rebuilt
-- from the link's validated fields; the URL never supplies the command.
local function quickAction(link: LinkRequest, cx: WindowCx)
	local req, err = Quick.decode(link.url)
	if req == nil then
		cx:toast("error", "Kube Lens: invalid quick action", err)
		return
	end
	local spec = Quick.spec(req.action) :: Quick.Action
	if spec.mutates then
		cx:toast("error", "Kube Lens: " .. spec.label .. " needs confirmation (coming in M3)")
		return
	end
	local cfg = ConfigHost.load().config
	local target = { context = req.target.context, kubeconfig = req.target.kubeconfig, program = ConfigHost.kubectl() }
	local launch, cerr = Quick.command(req.action, target, req.ref, req.opts, {
		shellCommand = cfg.quick_actions.shell_command,
		logsTail = cfg.quick_actions.logs_tail,
		debugImage = cfg.quick_actions.debug_image,
	})
	if launch == nil then
		cx:toast("error", "Kube Lens: invalid quick action", cerr)
		return
	end
	local place = Quick.placement(cfg.quick_actions.placement)
	local pane: number?
	if place.how == "tab" then
		pane = cx.layout:new_tab({ command = launch.line })
	else
		pane = cx.layout:split(link.pane, place.dir, { command = launch.line })
	end
	log.info("kube-lens quick action", req.action, launch.title, "pane=" .. tostring(pane))
	if pane == nil then
		cx:copy(launch.line)
		cx:toast("error", "Kube Lens: could not open a pane", "Command copied to the clipboard")
	end
end

-- Every kube-lens:// URL must be claimed here: an unclaimed one, or a
-- handler error, falls through to the OS, which shows a "no application"
-- dialog on macOS.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
		return nil
	end
	log.debug("kube-lens route.link", link.url)
	if string.sub(link.url, 1, #Quick.SCHEME) == Quick.SCHEME then
		local ok, err = pcall(function()
			quickAction(link, cx)
		end)
		if not ok then
			log.warn("kube-lens quick action failed", link.url, tostring(err))
			pcall(function()
				cx:toast("error", "Kube Lens: quick action failed", tostring(err))
			end)
		end
		return { handled = true }
	end
	return { block = "kube-lens.explore", args = { link.url } }
end)

tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
	if req.origin ~= "cli" then
		return nil
	end
	if string.match(req.path, "/kube%-lens/spool/req%-[%w%-]+%.json$") == nil then
		return nil
	end
	return { block = "kube-lens.approve", args = { req.path } }
end)

tern.command({
	id = "explore",
	title = "Kube Lens: Explore",
	icon = "box",
	run = function(cx: WindowCx)
		if cx:new_block("kube-lens.explore", { "palette" }, "beside") == nil then
			cx:toast("error", "Kube Lens is not loaded on this host")
		end
	end,
})
