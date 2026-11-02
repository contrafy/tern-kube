--!strict
-- Line-level LCS diff in unified format (3 lines of context per hunk). Used
-- for export previews and for before/after object diffs, whose output is fed
-- back through mutation/diffseg, so headers and hunk ranges follow `diff -u`.

local M = {}

local MAX_DIFF_CELLS = 4000000

local function lines(text: string): { string }
	local out = string.split(text, "\n")
	if out[#out] == "" then
		table.remove(out)
	end
	return out
end

type Op = { tag: " " | "-" | "+", text: string, a: number, b: number }

local function editScript(a: { string }, b: { string }): { Op }
	local n, m = #a, #b
	local ops: { Op } = {}
	-- Beyond this the table would not fit: everything is replaced.
	if n * m > MAX_DIFF_CELLS then
		for i, s in a do
			table.insert(ops, { tag = "-", text = s, a = i, b = 0 })
		end
		for j, s in b do
			table.insert(ops, { tag = "+", text = s, a = n, b = j })
		end
		return ops
	end
	-- L(i, j) = LCS length of a[i..] and b[j..], for i in 1..n+1, j in 1..m+1.
	local w = m + 2
	local lcs = table.create((n + 2) * w, 0)
	local function at(i: number, j: number): number
		return i * w + j
	end
	for i = n, 1, -1 do
		for j = m, 1, -1 do
			lcs[at(i, j)] = if a[i] == b[j]
				then lcs[at(i + 1, j + 1)] + 1
				else math.max(lcs[at(i + 1, j)], lcs[at(i, j + 1)])
		end
	end
	local i, j = 1, 1
	while i <= n and j <= m do
		if a[i] == b[j] then
			table.insert(ops, { tag = " ", text = a[i], a = i, b = j })
			i += 1
			j += 1
		elseif lcs[at(i + 1, j)] >= lcs[at(i, j + 1)] then
			table.insert(ops, { tag = "-", text = a[i], a = i, b = j - 1 })
			i += 1
		else
			table.insert(ops, { tag = "+", text = b[j], a = i - 1, b = j })
			j += 1
		end
	end
	for k = i, n do
		table.insert(ops, { tag = "-", text = a[k], a = k, b = m })
	end
	for k = j, m do
		table.insert(ops, { tag = "+", text = b[k], a = n, b = k })
	end
	return ops
end

-- nil when the texts are equal. `old == nil` diffs against /dev/null (a new
-- file); `oldPath` names the old side when it differs from `path`.
function M.unified(old: string?, new: string, path: string, oldPath: string?): string?
	if old == new then
		return nil
	end
	local a, b = lines(old or ""), lines(new)
	local ops = editScript(a, b)
	local out = { "--- " .. (if old then oldPath or path else "/dev/null"), "+++ " .. path }
	local k = 1
	while k <= #ops do
		if ops[k].tag == " " then
			k += 1
			continue
		end
		local first = math.max(1, k - 3)
		local last = k
		local probe = k
		while probe <= #ops do
			if ops[probe].tag ~= " " then
				last = probe
				probe += 1
			elseif probe - last > 6 then
				break
			else
				probe += 1
			end
		end
		last = math.min(#ops, last + 3)
		local aStart, bStart, aCount, bCount = 0, 0, 0, 0
		local body = {}
		for x = first, last do
			local op = ops[x]
			if op.tag ~= "+" then
				aCount += 1
				if aStart == 0 then
					aStart = op.a
				end
			end
			if op.tag ~= "-" then
				bCount += 1
				if bStart == 0 then
					bStart = op.b
				end
			end
			table.insert(body, op.tag .. op.text)
		end
		if aCount == 0 then
			aStart = ops[first].a
		end
		if bCount == 0 then
			bStart = ops[first].b
		end
		table.insert(out, string.format("@@ -%d,%d +%d,%d @@", aStart, aCount, bStart, bCount))
		table.move(body, 1, #body, #out + 1, out)
		k = last + 1
	end
	return table.concat(out, "\n") .. "\n"
end

return M
