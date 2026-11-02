--!strict
-- A one-line text field a block owns: its text, caret and undo history.
-- Tern only draws it. Keys without a selection arrive as keys; with the
-- block's "edit" feature, clicks, selections and what replaces them arrive
-- as `edit` events in UTF-16 offsets, and with "undo" ⌘Z/⌃Z arrives as an
-- `undo` event. The caret is a byte offset here and UTF-16 on the wire.

export type Snapshot = { text: string, cursor: number }

export type Field = {
	text: string,
	-- Byte offset of the caret, 0..#text, always on a character boundary.
	cursor: number,
	-- Oldest first; each entry is the field before one change.
	history: { Snapshot },
	-- The last change typed a character: the next one joins its undo step.
	typing: boolean,
}

export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

-- An `edit` event's payload as Tern sends it (UiEvent fields are untyped).
export type Edit = { from: any, to: any, text: any, cursor: any, len: any }

local M = {}

M.MAX_HISTORY = 100

-- BlockDef.features of a block with these fields.
M.FEATURES = { "edit", "undo" } :: { "edit" | "undo" }

local function isCont(b: number?): boolean
	return b ~= nil and b >= 0x80 and b < 0xC0
end

local function charBytes(b: number): number
	if b < 0xC0 then
		return 1
	elseif b < 0xE0 then
		return 2
	elseif b < 0xF0 then
		return 3
	end
	return 4
end

-- UTF-16 code units of the first `bytes` bytes of `text` (all by default).
function M.utf16(text: string, bytes: number?): number
	local n = 0
	for i = 1, bytes or #text do
		local b = string.byte(text, i)
		if b < 0x80 or b >= 0xC0 then
			n += if b >= 0xF0 then 2 else 1
		end
	end
	return n
end

-- The byte offset of UTF-16 offset `units`; inside a surrogate pair it
-- rounds down, past the end it clamps.
function M.toByte(text: string, units: number): number
	local i, u = 1, 0
	while i <= #text do
		local b = string.byte(text, i)
		local w = if b >= 0xF0 then 2 else 1
		if u + w > units then
			break
		end
		u += w
		i = math.min(i + charBytes(b), #text + 1)
	end
	return i - 1
end

local function prevChar(text: string, c: number): number
	local p = math.max(c - 1, 0)
	while p > 0 and isCont(string.byte(text, p + 1)) do
		p -= 1
	end
	return p
end

local function nextChar(text: string, c: number): number
	local n = math.min(c + 1, #text)
	while n < #text and isCont(string.byte(text, n + 1)) do
		n += 1
	end
	return n
end

local function isSpaceAt(text: string, i: number): boolean
	return string.find(string.sub(text, i, i), "^%s") ~= nil
end

-- Start of the word before the caret: spaces, then non-spaces.
local function wordLeft(text: string, c: number): number
	local p = c
	while p > 0 and isSpaceAt(text, p) do
		p -= 1
	end
	while p > 0 and not isSpaceAt(text, p) do
		p -= 1
	end
	return p
end

local function wordRight(text: string, c: number): number
	local n = c
	while n < #text and isSpaceAt(text, n + 1) do
		n += 1
	end
	while n < #text and not isSpaceAt(text, n + 1) do
		n += 1
	end
	return n
end

-- One line: outer line breaks go (a copied line ends in one), inner line
-- breaks and tabs become one space, other controls go.
local function clean(text: string): string
	local line = string.gsub(string.gsub(text, "^[\r\n]+", ""), "[\r\n]+$", "")
	return (string.gsub(string.gsub(line, "[\r\n\t]+", " "), "%c", ""))
end

function M.new(text: string): Field
	return { text = text, cursor = #text, history = {}, typing = false }
end

-- `f` while it still holds `text`; else a fresh field (caret at the end)
-- for text that changed outside the field.
function M.sync(f: Field?, text: string): Field
	if f and f.text == text then
		return f
	end
	return M.new(text)
end

-- The `cursor` prop: the caret in UTF-16 code units.
function M.caret(f: Field): number
	return M.utf16(f.text, f.cursor)
end

-- The `cursor` prop of a field showing `text`: `f`'s caret while it is the
-- field being edited and holds that text, else the end.
function M.caretFor(f: Field?, text: string): number
	return if f and f.text == text then M.caret(f) else M.utf16(text)
end

-- The text a key types, if any (paste aside).
function M.printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function moved(f: Field, cursor: number): Field
	if cursor == f.cursor then
		return f
	end
	return { text = f.text, cursor = cursor, history = f.history, typing = false }
end

local function changed(f: Field, text: string, cursor: number, typing: boolean, join: boolean): Field
	if text == f.text then
		return moved(f, cursor)
	end
	local history = f.history
	if not join then
		history = table.clone(history)
		table.insert(history, { text = f.text, cursor = f.cursor })
		if #history > M.MAX_HISTORY then
			table.remove(history, 1)
		end
	end
	return { text = text, cursor = cursor, history = history, typing = typing }
end

local function replace(f: Field, from: number, to: number, insert: string): Field
	local text = string.sub(f.text, 1, from) .. insert .. string.sub(f.text, to + 1)
	return changed(f, text, from + #insert, false, false)
end

local function typeChar(f: Field, ch: string): Field
	local c = f.cursor
	-- A word typed after a space starts a new undo step.
	local join = f.typing and not (c > 0 and isSpaceAt(f.text, c) and not string.find(ch, "^%s"))
	local text = string.sub(f.text, 1, c) .. ch .. string.sub(f.text, c + 1)
	return changed(f, text, c + #ch, true, join)
end

-- Applies an editing key; nil when the key is not the field's (enter,
-- escape, up/down, tab, ...). An editing key that changes nothing returns
-- `f` itself.
function M.key(f: Field, key: Key): Field?
	local name = key.name
	local text, c = f.text, f.cursor
	local word = key.alt or key.ctrl
	if name == "paste" then
		local insert = clean(key.text or "")
		return if insert == "" then f else replace(f, c, c, insert)
	elseif name == "backspace" then
		local from = if key.meta then 0 elseif word then wordLeft(text, c) else prevChar(text, c)
		return replace(f, from, c, "")
	elseif name == "delete" then
		local to = if key.meta then #text elseif word then wordRight(text, c) else nextChar(text, c)
		return replace(f, c, to, "")
	elseif name == "left" then
		return moved(f, if key.meta then 0 elseif word then wordLeft(text, c) else prevChar(text, c))
	elseif name == "right" then
		return moved(f, if key.meta then #text elseif word then wordRight(text, c) else nextChar(text, c))
	elseif name == "home" then
		return moved(f, 0)
	elseif name == "end" then
		return moved(f, #text)
	elseif (key.ctrl or key.meta) and name == "z" then
		return M.undo(f) or f
	elseif key.ctrl and not key.meta and not key.alt then
		if name == "a" then
			return moved(f, 0)
		elseif name == "e" then
			return moved(f, #text)
		elseif name == "u" then
			return replace(f, 0, c, "")
		elseif name == "k" then
			return replace(f, c, #text, "")
		elseif name == "w" then
			return replace(f, wordLeft(text, c), c, "")
		end
		return nil
	end
	local ch = M.printable(key)
	return if ch then typeChar(f, ch) else nil
end

-- Applies an `edit` event; nil when it is malformed or stale (Tern saw a
-- text of another length: keys were still in flight).
function M.edit(f: Field, ev: Edit): Field?
	local from, to, insert = ev.from, ev.to, ev.text
	if type(from) ~= "number" or type(to) ~= "number" or type(insert) ~= "string" then
		return nil
	end
	local n = M.utf16(f.text)
	if type(ev.len) == "number" and ev.len ~= n then
		return nil
	end
	if from > to then
		from, to = to, from
	end
	local a = M.toByte(f.text, math.clamp(from, 0, n))
	local b = M.toByte(f.text, math.clamp(to, 0, n))
	local cleaned = clean(insert)
	local text = string.sub(f.text, 1, a) .. cleaned .. string.sub(f.text, b + 1)
	local cursor = a + #cleaned
	if type(ev.cursor) == "number" and cleaned == insert then
		cursor = M.toByte(text, math.clamp(ev.cursor, 0, M.utf16(text)))
	end
	return changed(f, text, cursor, false, false)
end

-- Steps back one change; nil when there is none.
function M.undo(f: Field): Field?
	local n = #f.history
	if n == 0 then
		return nil
	end
	local snap = f.history[n]
	local history = table.clone(f.history)
	history[n] = nil
	return { text = snap.text, cursor = snap.cursor, history = history, typing = false }
end

return M
