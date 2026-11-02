--!strict
-- Every text field of the blocks (Explore filter and GitOps fields, the
-- Settings editor, the approve block's typed token and prompts) is owned by
-- the plugin: Tern only draws it. Keys must edit at the caret, Tern's native
-- edit events (UTF-16 offsets, possibly stale) must apply exactly or not at
-- all, and undo must step back through what the user did.
local Textfield = require("../../../plugin/lib/textfield")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Field = Textfield.Field

local function key(name: string, mods: { [string]: any }?): Textfield.Key
	local k: Textfield.Key = { name = name, text = nil, ctrl = false, alt = false, shift = false, meta = false }
	local extra: { [string]: any } = mods or {}
	for m, v in extra do
		(k :: any)[m] = v
	end
	return k
end

local function typed(f: Field, text: string): Field
	for _, cp in utf8.codes(text) do
		local ch = utf8.char(cp)
		f = Textfield.key(f, { name = ch, text = ch, ctrl = false, alt = false, shift = false, meta = false }) :: Field
	end
	return f
end

local function at(text: string, cursor: number): Field
	return { text = text, cursor = cursor, history = {}, typing = false }
end

describe("textfield keys", function()
	it("types at the caret, not at the end", function()
		local f = typed(at("helo", 3), "l")
		expect(f.text).toBe("hello")
		expect(f.cursor).toBe(4)
	end)

	it("moves the caret by character, word and line", function()
		local f = Textfield.new("get pods now")
		f = Textfield.key(f, key("left")) :: Field
		expect(f.cursor).toBe(11)
		f = Textfield.key(f, key("left", { alt = true })) :: Field
		expect(f.cursor).toBe(9)
		f = Textfield.key(f, key("left", { alt = true })) :: Field
		expect(f.cursor).toBe(4)
		f = Textfield.key(f, key("home")) :: Field
		expect(f.cursor).toBe(0)
		f = Textfield.key(f, key("right", { alt = true })) :: Field
		expect(f.cursor).toBe(3)
		f = Textfield.key(f, key("end")) :: Field
		expect(f.cursor).toBe(12)
		f = Textfield.key(f, key("a", { ctrl = true })) :: Field
		expect(f.cursor).toBe(0)
		f = Textfield.key(f, key("e", { ctrl = true })) :: Field
		expect(f.cursor).toBe(12)
	end)

	it("deletes before and after the caret, by character, word and line", function()
		local f = at("one two three", 7)
		expect((Textfield.key(f, key("backspace")) :: Field).text).toBe("one tw three")
		expect((Textfield.key(f, key("delete")) :: Field).text).toBe("one twothree")
		expect((Textfield.key(f, key("backspace", { alt = true })) :: Field).text).toBe("one  three")
		expect((Textfield.key(f, key("w", { ctrl = true })) :: Field).text).toBe("one  three")
		expect((Textfield.key(f, key("backspace", { meta = true })) :: Field).text).toBe(" three")
		expect((Textfield.key(f, key("u", { ctrl = true })) :: Field).text).toBe(" three")
		expect((Textfield.key(f, key("k", { ctrl = true })) :: Field).text).toBe("one two")
	end)

	it("never splits a multi-byte character", function()
		local f = Textfield.new("ns-é😀")
		f = Textfield.key(f, key("backspace")) :: Field
		expect(f.text).toBe("ns-é")
		f = Textfield.key(f, key("left")) :: Field
		expect(f.cursor).toBe(3)
		f = Textfield.key(f, key("delete")) :: Field
		expect(f.text).toBe("ns-")
	end)

	it("pastes one line at the caret", function()
		local f = Textfield.key(at("ab", 1), { name = "paste", text = "x\ny\tz\27" }) :: Field
		expect(f.text).toBe("ax y zb")
		expect(f.cursor).toBe(6)
	end)

	it("drops the line break a copied line ends in", function()
		local f = Textfield.key(Textfield.new(""), { name = "paste", text = "db-0\n" }) :: Field
		expect(f.text).toBe("db-0")
	end)

	it("leaves enter, escape, up, down and tab to the block", function()
		local f = Textfield.new("x")
		for _, name in { "enter", "return", "escape", "up", "down", "tab" } do
			expect(Textfield.key(f, key(name))).toBeNil()
		end
	end)

	it("answers an editing key that changes nothing with the same field", function()
		local f = Textfield.new("")
		expect(Textfield.key(f, key("backspace"))).toBe(f)
		expect(Textfield.key(f, key("left"))).toBe(f)
	end)
end)

describe("textfield native edits", function()
	it("replaces a UTF-16 range and puts the caret where Tern says", function()
		local f = Textfield.edit(Textfield.new("deploy/web"), { from = 0, to = 6, text = "sts", cursor = 3, len = 10 })
		expect(f and f.text).toBe("sts/web")
		expect(f and f.cursor).toBe(3)
	end)

	it("moves the caret only (a click) without an undo step", function()
		local f = Textfield.edit(Textfield.new("pods"), { from = 1, to = 1, text = "", cursor = 1, len = 4 }) :: Field
		expect(f.text).toBe("pods")
		expect(f.cursor).toBe(1)
		expect(#f.history).toBe(0)
	end)

	it("counts astral characters as two UTF-16 units", function()
		local f = Textfield.new("a😀b")
		expect(Textfield.caret(f)).toBe(4)
		local e = Textfield.edit(f, { from = 3, to = 4, text = "", cursor = 3, len = 4 }) :: Field
		expect(e.text).toBe("a😀")
		expect(e.cursor).toBe(5)
	end)

	it("ignores an edit made against text that has changed since", function()
		local f = typed(Textfield.new("abc"), "d")
		expect(Textfield.edit(f, { from = 0, to = 3, text = "", cursor = 0, len = 3 })).toBeNil()
	end)

	it("ignores a malformed edit", function()
		expect(Textfield.edit(Textfield.new("abc"), { from = "0", to = 1, text = "", cursor = 0, len = 3 })).toBeNil()
	end)

	it("keeps a pasted replacement on one line", function()
		local f =
			Textfield.edit(Textfield.new("abc"), { from = 0, to = 3, text = "x\ny", cursor = 3, len = 3 }) :: Field
		expect(f.text).toBe("x y")
		expect(f.cursor).toBe(3)
	end)
end)

describe("textfield undo", function()
	it("steps back one typed word at a time", function()
		local f = typed(Textfield.new(""), "hello world")
		f = Textfield.undo(f) :: Field
		expect(f.text).toBe("hello ")
		f = Textfield.undo(f) :: Field
		expect(f.text).toBe("")
		expect(Textfield.undo(f)).toBeNil()
	end)

	it("undoes each native edit as one step and restores the caret", function()
		local f = Textfield.new("kube-system")
		f = Textfield.edit(f, { from = 0, to = 11, text = "default", cursor = 7, len = 11 }) :: Field
		f = Textfield.key(f, key("backspace")) :: Field
		expect(f.text).toBe("defaul")
		f = Textfield.undo(f) :: Field
		expect(f.text).toBe("default")
		f = Textfield.undo(f) :: Field
		expect(f.text).toBe("kube-system")
		expect(f.cursor).toBe(11)
	end)

	it("treats ⌃Z or ⌘Z as undo when it arrives as a key", function()
		local f = typed(Textfield.new(""), "x")
		expect((Textfield.key(f, key("z", { ctrl = true })) :: Field).text).toBe("")
		expect((Textfield.key(f, key("z", { meta = true })) :: Field).text).toBe("")
	end)

	it("keeps a bounded history", function()
		local f = Textfield.new("")
		for _ = 1, Textfield.MAX_HISTORY + 20 do
			f = Textfield.key(f, { name = "paste", text = "x" }) :: Field
		end
		expect(#f.history).toBe(Textfield.MAX_HISTORY)
	end)
end)

describe("textfield sync", function()
	it("keeps the caret and history while the text is the field's", function()
		local f = Textfield.key(Textfield.new("abc"), key("left")) :: Field
		expect(Textfield.sync(f, "abc")).toBe(f)
	end)

	it("starts over at the end when the text changed elsewhere", function()
		local f = Textfield.key(Textfield.new("abc"), key("left")) :: Field
		local g = Textfield.sync(f, "")
		expect(g.text).toBe("")
		expect(g.cursor).toBe(0)
		expect(#g.history).toBe(0)
	end)
end)

return nil
