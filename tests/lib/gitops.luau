--!strict
-- Builds manifest indexes from the fixture repos under tests/fixtures/gitops,
-- mounted at ROOT as if they were one git checkout.
local Index = require("../../plugin/lib/gitops/index")
local fixtures = require("./fixtures")

local M = {}

M.ROOT = "/repo"

-- Repo-relative paths of every fixture repo file (renders captured from
-- real tools live outside the "repo").
function M.files(): { string }
	local out: { string } = {}
	for _, key in fixtures.list("gitops/") do
		local rel = string.sub(key, #"gitops/" + 1)
		if string.sub(rel, 1, #"captured/") ~= "captured/" then
			table.insert(out, rel)
		end
	end
	return out
end

function M.abs(rel: string): string
	return M.ROOT .. "/" .. rel
end

function M.text(rel: string): string
	return fixtures.read("gitops/" .. rel)
end

-- Indexes every planned file; `reverse` feeds them in the opposite order to
-- prove the result does not depend on read order.
function M.index(reverse: boolean?): Index.Index
	local plan = Index.plan(M.files(), {})
	local index = Index.new(M.ROOT, plan.limits)
	local n = #plan.read
	for i = 1, n do
		local rel = plan.read[if reverse then n + 1 - i else i]
		Index.addFile(index, M.abs(rel), M.text(rel))
	end
	return index
end

function M.rel(path: string): string
	return string.sub(path, #M.ROOT + 2)
end

-- "<file>:<start>-<end> <key or kind/name>" per doc, for compact assertions.
function M.brief(docs: { Index.ManifestDoc }): { string }
	local out: { string } = {}
	for _, d in docs do
		local id = d.key or ((if d.ref then d.ref.kind .. "/" .. d.ref.name else "?") .. " (ns?)")
		table.insert(out, string.format("%s:%d-%d %s", M.rel(d.file), d.startLine, d.endLine, id))
	end
	return out
end

return M
