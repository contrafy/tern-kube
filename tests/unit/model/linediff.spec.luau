--!strict
-- Unified diffs are read back by mutation/diffseg (object diff cards) and
-- shown verbatim in export previews, so hunk ranges and headers must be
-- exactly what `diff -u` would print.
local Diffseg = require("../../../plugin/lib/mutation/diffseg")
local Linediff = require("../../../plugin/lib/model/linediff")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("model.linediff unified", function()
	it("emits hunks with context and correct ranges", function()
		local old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
		local new = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\nk\n"
		expect(Linediff.unified(old, new, "/p")).toBe(table.concat({
			"--- /p",
			"+++ /p",
			"@@ -2,9 +2,10 @@",
			" b",
			" c",
			" d",
			"-e",
			"+E",
			" f",
			" g",
			" h",
			" i",
			" j",
			"+k",
			"",
		}, "\n"))
	end)

	it("splits distant changes into separate hunks", function()
		local a, b = {}, {}
		for i = 1, 30 do
			table.insert(a, tostring(i))
			table.insert(b, if i == 2 or i == 28 then "x" else tostring(i))
		end
		local d = Linediff.unified(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", "/p") :: string
		local hunks = {}
		for h in string.gmatch(d, "@@ [^@]+ @@") do
			table.insert(hunks, h)
		end
		expect(hunks).toEqual({ "@@ -1,5 +1,5 @@", "@@ -25,6 +25,6 @@" })
	end)

	it("diffs new files against /dev/null", function()
		expect(Linediff.unified(nil, "a\n", "/p")).toBe("--- /dev/null\n+++ /p\n@@ -0,0 +1,1 @@\n+a\n")
	end)

	it("returns nil for equal texts so callers can report unchanged", function()
		expect(Linediff.unified("a\n", "a\n", "/p")).toBeNil()
	end)

	-- Object diffs name the sides like kubectl diff (LIVE vs MERGED dirs);
	-- diffseg keys the segment by the new side's basename.
	it("names the old side with oldPath and reads back through diffseg", function()
		local d =
			Linediff.unified("a: 1\n", "a: 2\n", "/merged/v1.ConfigMap.ns.cm", "/live/v1.ConfigMap.ns.cm") :: string
		expect(string.sub(d, 1, 60)).toBe("--- /live/v1.ConfigMap.ns.cm\n+++ /merged/v1.ConfigMap.ns.cm\n")
		local summary = Diffseg.parse(d)
		expect(#summary.segments).toBe(1)
		expect(summary.segments[1].key).toBe("v1.ConfigMap.ns.cm")
		expect(summary.segments[1].action).toBe("modify")
		expect(summary.modify).toBe(1)
	end)

	-- An object that disappears is diffed against an empty new text: the
	-- empty new side is what makes diffseg classify it as a delete.
	it("emits an empty new range for a removed text", function()
		local d = Linediff.unified("a\nb\n", "", "/merged/k", "/live/k") :: string
		expect(d).toBe("--- /live/k\n+++ /merged/k\n@@ -1,2 +0,0 @@\n-a\n-b\n")
		expect(Diffseg.parse(d).segments[1].action).toBe("delete")
	end)
end)

return nil
