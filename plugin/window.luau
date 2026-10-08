--!strict
local log = tern.log

local SCHEME = "kube-lens://"

-- Every kube-lens:// URL must be claimed here: an unclaimed one falls
-- through to the OS, which shows a "no application" dialog on macOS.
tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
		return nil
	end
	log.debug("kube-lens route.link", link.url)
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
