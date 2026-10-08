--!strict
-- The pane env record (shell/PROTOCOL.md "Pane env record"): the opt-in shell
-- snippets write `<spool>/pane-<pane>.env` holding the pane's effective
-- KUBECONFIG, so a quick action launched from that pane's lens targets the
-- same kubeconfig the user's command did instead of the daemon's.
local M = {}

M.MAX_BYTES = 8192

function M.path(spool: string, pane: number): string?
	if pane ~= pane // 1 or pane < 0 then
		return nil
	end
	return string.format("%s/pane-%d.env", spool, pane)
end

-- The kubeconfig to pin from a record's text, or nil with the reason. The
-- record is exactly one `kubeconfig=<value>` line. Only one absolute path can
-- be pinned (`--kubeconfig` takes a single file); an empty value means the
-- shell had no KUBECONFIG, so kubectl's default applies.
function M.kubeconfig(text: string): (string?, string?)
	local value = string.match(text, "^kubeconfig=([^\n]*)\n?$")
	if value == nil then
		return nil, "malformed pane env record"
	end
	if value == "" then
		return nil, "KUBECONFIG was unset in the pane"
	end
	if string.find(value, "%c") then
		return nil, "KUBECONFIG has control characters"
	end
	if string.sub(value, 1, 1) ~= "/" then
		return nil, "KUBECONFIG is not an absolute path"
	end
	if string.find(value, ":", 1, true) then
		return nil, "KUBECONFIG lists several files; --kubeconfig takes one"
	end
	return value, nil
end

return M
