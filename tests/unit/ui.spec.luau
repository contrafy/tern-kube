--!strict
-- Plain-table builders must encode exactly like the tern.ui builders they
-- stand in for, or Tern draws something else. Shapes probed live on Tern
-- 0.9.14 with tern.json.encode(tern.ui.button(...)).
local Ui = require("../../plugin/lib/ui")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("ui.button", function()
	it("matches tern.ui.button: text in props, keys and actions passed through", function()
		expect(Ui.button("Approve", { keys = { "enter" }, variant = "primary", actions = { click = "go" } })).toEqual({
			k = "button",
			p = { text = "Approve", keys = { "enter" }, variant = "primary", actions = { click = "go" } },
		})
	end)

	it("uses an empty label for an icon-only button", function()
		expect(Ui.button(nil, { icon = "x" })).toEqual({ k = "button", p = { text = "", icon = "x" } })
	end)
end)
return nil
