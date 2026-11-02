--!strict
-- Which host a window pane is on. The window half runs on the machine
-- showing the window, but a quick action's split runs on the clicked pane's
-- host, so host-local state (kubectl path, pane KUBECONFIG records,
-- loopback) of this machine does not apply to a remote pane.
--
-- Rows are the window's `cx.hosts:list()` (ManagedHost); their `panes` use
-- the same window pane ids as LinkRequest.pane.

export type HostRow = { kind: "local" | "remote", name: string, address: string?, panes: { number } }
export type PaneHost = { remote: boolean, name: string?, address: string? }

local M = {}

local function describe(h: HostRow): PaneHost
	return { remote = h.kind == "remote", name = h.name, address = h.address }
end

-- A pane no host lists (or no pane) belongs to the current host; without a
-- hosts API everything is local.
function M.of(hosts: { HostRow }, pane: number?, current: HostRow?): PaneHost
	if pane ~= nil then
		for _, h in hosts do
			if table.find(h.panes, pane) then
				return describe(h)
			end
		end
	end
	if current then
		return describe(current)
	end
	return { remote = false }
end

local function hostname(s: string): boolean
	if #s > 253 or string.find(s, "^[%w][%w%.%-]*$") == nil then
		return false
	end
	-- An iroh endpoint id (hex or base32, no dots) is not resolvable by ssh.
	return string.find(s, ".", 1, true) ~= nil or #s < 32
end

-- The ssh words reaching `spec` ("[user@]host[:port]"), safe to print
-- unquoted; nil for anything else.
function M.sshDestination(spec: string): string?
	local user, rest = string.match(spec, "^([^@]+)@(.+)$")
	if user == nil then
		rest = spec
	elseif string.find(user, "^[%w_][%w%._%-]*$") == nil or #user > 32 then
		return nil
	end
	local h, port = string.match(rest :: string, "^([^:]+):(%d+)$")
	local host: string = h or rest :: string
	if not hostname(host) then
		return nil
	end
	local who = if user then user .. "@" .. host else host
	if port == nil then
		return who
	end
	local n = tonumber(port) :: number
	if string.sub(port, 1, 1) == "0" or n < 1 or n > 65535 then
		return nil
	end
	return "-p " .. port .. " " .. who
end

return M
