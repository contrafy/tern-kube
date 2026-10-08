--!strict
-- Splits `kubectl diff` output (kubectl's built-in `diff -u -N LIVE MERGED`
-- over two temp dirs) into one segment per object. kubectl names each file
-- `[<group>.]<version>.<Kind>.<namespace>.<name>`; the namespace is empty for
-- cluster-scoped objects and both the group and the name may contain dots.
-- Hunk headers are trusted for line accounting, so content lines that look
-- like headers (`+++ x`, `diff ...`) never start a new segment, and a missing
-- side (`-0,0` / `+0,0`) classifies the object as created or deleted.
local M = {}

export type Action = "create" | "modify" | "delete" | "unknown"

export type Segment = {
	-- File name kubectl gave the object (unique per diff run).
	key: string,
	group: string?,
	version: string?,
	kind: string?,
	namespace: string?,
	name: string?,
	action: Action,
	added: number,
	removed: number,
	binary: boolean,
	-- The segment's lines verbatim, header included.
	lines: { string },
}

export type Summary = {
	segments: { Segment },
	create: number,
	modify: number,
	delete: number,
	unknown: number,
	added: number,
	removed: number,
	-- Lines outside any segment (stderr interleaved, truncated hunks).
	notes: { string },
}

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

-- `--- <path>\t<timestamp>`; the tab cannot occur in kubectl's temp paths.
local function headerPath(line: string): string
	local body = string.sub(line, 5)
	local tab = string.find(body, "\t", 1, true)
	return if tab then string.sub(body, 1, tab - 1) else body
end

local function isVersion(token: string): boolean
	return string.match(token, "^v%d+$") ~= nil or string.match(token, "^v%d+%l+%d+$") ~= nil
end

export type Identity = { group: string?, version: string, kind: string, namespace: string?, name: string }

function M.identity(fileName: string): Identity?
	local parts = string.split(fileName, ".")
	for i = 1, #parts - 3 do
		if isVersion(parts[i]) and string.match(parts[i + 1], "^%u") then
			local group = if i > 1 then table.concat(parts, ".", 1, i - 1) else nil
			local namespace = parts[i + 2]
			local name = table.concat(parts, ".", i + 3)
			if name == "" then
				return nil
			end
			return {
				group = group,
				version = parts[i],
				kind = parts[i + 1],
				namespace = if namespace ~= "" then namespace else nil,
				name = name,
			}
		end
	end
	return nil
end

local function newSegment(key: string, first: string): Segment
	local id = M.identity(key)
	return {
		key = key,
		group = if id then id.group else nil,
		version = if id then id.version else nil,
		kind = if id then id.kind else nil,
		namespace = if id then id.namespace else nil,
		name = if id then id.name else nil,
		action = "unknown",
		added = 0,
		removed = 0,
		binary = false,
		lines = { first },
	}
end

local function splitLines(text: string): { string }
	local out = string.split(text, "\n")
	if out[#out] == "" then
		table.remove(out)
	end
	for i, line in out do
		if string.byte(line, -1) == 13 then
			out[i] = string.sub(line, 1, -2)
		end
	end
	return out
end

-- `diff -u -N <live> <merged>`: the merged path is the last field; temp dirs
-- never contain spaces in practice, but the header lines are preferred.
local function diffLineKey(line: string): string?
	local rest = string.match(line, "^diff %-u %-N (.+)$") or string.match(line, "^diff %-%S+ (.+)$")
	if rest == nil then
		return nil
	end
	local merged = string.match(rest, "(%S+)$")
	return if merged then basename(merged) else nil
end

type Hunk = { oldLeft: number, newLeft: number }

function M.parse(text: string): Summary
	local summary: Summary = {
		segments = {},
		create = 0,
		modify = 0,
		delete = 0,
		unknown = 0,
		added = 0,
		removed = 0,
		notes = {},
	}
	local current: Segment? = nil
	local hunk: Hunk? = nil
	-- Per segment: did any hunk have an empty old / new side, or a non-empty one.
	local oldEmpty, newEmpty, oldSeen, newSeen = false, false, false, false

	local function finish()
		local seg = current
		if seg == nil then
			return
		end
		if hunk and (hunk.oldLeft > 0 or hunk.newLeft > 0) then
			table.insert(summary.notes, string.format("%s: hunk ended early", seg.key))
		end
		if seg.binary then
			seg.action = "unknown"
		elseif oldEmpty and not oldSeen and newSeen then
			seg.action = "create"
		elseif newEmpty and not newSeen and oldSeen then
			seg.action = "delete"
		elseif oldSeen or newSeen then
			seg.action = "modify"
		end
		local action = seg.action
		if action == "create" then
			summary.create += 1
		elseif action == "modify" then
			summary.modify += 1
		elseif action == "delete" then
			summary.delete += 1
		else
			summary.unknown += 1
		end
		summary.added += seg.added
		summary.removed += seg.removed
		table.insert(summary.segments, seg)
		current = nil
		hunk = nil
	end

	local function start(key: string, first: string)
		finish()
		current = newSegment(key, first)
		oldEmpty, newEmpty, oldSeen, newSeen = false, false, false, false
	end

	local lines = splitLines(text)
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local h = hunk
		if h and (h.oldLeft > 0 or h.newLeft > 0) then
			local seg = current :: Segment
			local c = string.sub(line, 1, 1)
			if c == " " or line == "" then
				h.oldLeft -= 1
				h.newLeft -= 1
			elseif c == "-" then
				h.oldLeft -= 1
				seg.removed += 1
			elseif c == "+" then
				h.newLeft -= 1
				seg.added += 1
			elseif c ~= "\\" then
				-- Not hunk content: the hunk was cut short; reread as a header.
				table.insert(summary.notes, string.format("%s: hunk ended early", seg.key))
				hunk = nil
				continue
			end
			table.insert(seg.lines, line)
			i += 1
			continue
		end

		local key = diffLineKey(line)
		if key then
			start(key, line)
		elseif string.sub(line, 1, 4) == "--- " and string.sub(lines[i + 1] or "", 1, 4) == "+++ " then
			local merged = basename(headerPath(lines[i + 1]))
			local seg = current
			if seg == nil or #seg.lines > 1 then
				start(merged, line)
			else
				table.insert(seg.lines, line)
				if seg.name == nil then
					local fresh = newSegment(merged, seg.lines[1])
					fresh.lines = seg.lines
					current = fresh
				end
			end
			table.insert((current :: Segment).lines, lines[i + 1])
			i += 2
			continue
		elseif current and string.sub(line, 1, 3) == "@@ " then
			local seg = current :: Segment
			local os_, oc, nc = string.match(line, "^@@ %-(%d+),?(%d*) %+%d+,?(%d*) @@")
			if os_ == nil then
				table.insert(summary.notes, string.format("%s: unreadable hunk header %s", seg.key, line))
				table.insert(seg.lines, line)
				i += 1
				continue
			end
			local oldCount = if oc == "" then 1 else tonumber(oc) :: number
			local newCount = if nc == "" then 1 else tonumber(nc) :: number
			if oldCount == 0 then
				oldEmpty = true
			else
				oldSeen = true
			end
			if newCount == 0 then
				newEmpty = true
			else
				newSeen = true
			end
			hunk = { oldLeft = oldCount, newLeft = newCount }
			table.insert(seg.lines, line)
		elseif current and string.match(line, "^Binary files .+ differ$") then
			local seg = current :: Segment
			seg.binary = true
			table.insert(seg.lines, line)
		elseif line ~= "" then
			table.insert(summary.notes, line)
		end
		i += 1
	end
	finish()
	return summary
end

-- Segment text for a diff viewer.
function M.text(seg: Segment): string
	return table.concat(seg.lines, "\n")
end

M.REDACTED = "*** (last-applied-configuration redacted by kube-lens)"

local function isSecret(seg: Segment): boolean
	return seg.kind == "Secret" and seg.group == nil and seg.name ~= nil and not seg.binary
end

local function leaksSecret(line: string): boolean
	local c = string.sub(line, 1, 1)
	if c ~= " " and c ~= "+" and c ~= "-" then
		return false
	end
	local head = string.sub(line, 1, 4)
	if head == "--- " or head == "+++ " then
		return false
	end
	return string.find(line, '"kind":"Secret"', 1, true) ~= nil
		or string.find(line, '\\"kind\\":\\"Secret\\"', 1, true) ~= nil
end

-- kubectl diff masks Secret data but not the last-applied-configuration
-- annotation, which holds the applied data as one JSON line. The same rule
-- as bin/kube-lens-drift: in core Secret segments every content line that
-- embeds a Secret object as JSON is replaced, keeping its marker and
-- indentation so the +/- counts and hunk shape stay intact. Returns a copy.
function M.redactSecrets(summary: Summary): Summary
	local out = table.clone(summary)
	out.segments = {}
	for _, seg in summary.segments do
		if isSecret(seg) then
			local copy = table.clone(seg)
			copy.lines = {}
			for _, line in seg.lines do
				if leaksSecret(line) then
					local ws = string.match(line, "^.([ ]*)") or ""
					line = string.sub(line, 1, 1) .. ws .. M.REDACTED
				end
				table.insert(copy.lines, line)
			end
			seg = copy
		end
		table.insert(out.segments, seg)
	end
	return out
end

return M
