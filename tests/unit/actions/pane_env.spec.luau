--!strict
-- A quick action launched from a lens must reach the cluster the user's own
-- command reached: the pane record carries that pane's KUBECONFIG. Anything
-- that is not exactly one usable path is ignored rather than guessed at.
local PaneEnv = require("../../../plugin/lib/actions/pane_env")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("pane env record", function()
	it("names the record after the pane inside the spool", function()
		expect(PaneEnv.path("/d/spool", 12)).toBe("/d/spool/pane-12.env")
		expect(PaneEnv.path("/d/spool", 1.5)).toBeNil()
		expect(PaneEnv.path("/d/spool", -1)).toBeNil()
	end)

	it("pins a single absolute KUBECONFIG, with or without the trailing newline", function()
		expect((PaneEnv.kubeconfig("kubeconfig=/Users/me/.kube/kind dev\n"))).toBe("/Users/me/.kube/kind dev")
		expect((PaneEnv.kubeconfig("kubeconfig=/k/c"))).toBe("/k/c")
	end)

	it("pins nothing when the shell had no KUBECONFIG", function()
		local v, why = PaneEnv.kubeconfig("kubeconfig=\n")
		expect(v).toBeNil()
		expect(why).toContain("unset")
	end)

	it("ignores path lists, relative paths, control characters and malformed records", function()
		for _, text in
			{
				"kubeconfig=/a:/b\n",
				"kubeconfig=rel/config\n",
				"kubeconfig=/a\tb\n",
				"kubeconfig=/a\nkubeconfig=/b\n",
				"kubeconfig=/a\n\n",
				"KUBECONFIG=/a\n",
				"context=x\n",
				"",
			}
		do
			local v, why = PaneEnv.kubeconfig(text)
			expect(v).toBeNil()
			expect(type(why)).toBe("string")
		end
	end)
end)

return nil
