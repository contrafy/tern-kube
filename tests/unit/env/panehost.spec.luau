--!strict
-- A quick action's split runs on the clicked pane's host, but the window
-- only sees its own machine: on a remote pane the local kubectl path, the
-- local pane KUBECONFIG record and "localhost" in a port-forward would all
-- be wrong. PaneHost.of tells the window which host a pane is on from the
-- hosts listing, and sshDestination gives the ssh words a port-forward hint
-- may print (never for names ssh could not reach, such as endpoint ids).
local PaneHost = require("../../../plugin/lib/env/panehost")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local LOCAL: PaneHost.HostRow = { kind = "local", name = "highrise", panes = { 5, 7 } }
local REMOTE: PaneHost.HostRow =
	{ kind = "remote", name = "tk@localhost:2222", address = "tk@localhost:2222", panes = { 4521191813414920 } }

describe("PaneHost.of", function()
	it("finds a remote pane by the host's pane list", function()
		expect(PaneHost.of({ LOCAL, REMOTE }, 4521191813414920, LOCAL)).toEqual({
			remote = true,
			name = "tk@localhost:2222",
			address = "tk@localhost:2222",
		})
	end)

	it("finds a local pane even when a remote host is current", function()
		expect(PaneHost.of({ LOCAL, REMOTE }, 7, REMOTE)).toEqual({ remote = false, name = "highrise" })
	end)

	it("falls back to the current host for a pane no host lists", function()
		expect(PaneHost.of({ LOCAL, REMOTE }, 99, REMOTE).remote).toBe(true)
		expect(PaneHost.of({ LOCAL, REMOTE }, 99, LOCAL).remote).toBe(false)
		expect(PaneHost.of({ LOCAL, REMOTE }, nil, REMOTE).name).toBe("tk@localhost:2222")
	end)

	it("treats a window without a hosts API as local", function()
		expect(PaneHost.of({}, 5, nil)).toEqual({ remote = false })
	end)
end)

describe("PaneHost.sshDestination", function()
	it("turns [user@]host[:port] into ssh words", function()
		expect(PaneHost.sshDestination("tk@localhost:2222")).toBe("-p 2222 tk@localhost")
		expect(PaneHost.sshDestination("devbox")).toBe("devbox")
		expect(PaneHost.sshDestination("me@build.example.com")).toBe("me@build.example.com")
		expect(PaneHost.sshDestination("10.0.0.5:22")).toBe("-p 22 10.0.0.5")
	end)

	it("refuses names ssh cannot reach or a shell would re-read", function()
		for _, bad in
			{
				"tk@9831a11713ea99a4ab02400443edd5ac4db8d5180a95f122ab9974856680d2b8",
				"dev box",
				"-oProxyCommand=x",
				"tk@host:0",
				"tk@host:70000",
				"a@b@c",
				"host;id",
				"",
			}
		do
			expect(PaneHost.sshDestination(bad)).toBeNil()
		end
	end)
end)

return nil
