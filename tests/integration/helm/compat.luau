--!strict
-- Decodes the extras template output of every revision template-compat.sh
-- recorded (standalone luau cannot read files or run helm, so the script
-- writes them hex-encoded into .sandbox/helm-compat/<name>.luau) and fails
-- unless each one parses with Parse.extras and describes that revision.
-- For revisions made with --reuse-values it also checks helm still stores
-- the previous computed values as the chart defaults (F8), which is what
-- the Values view's defaults-provenance logic assumes.
--
--   .tools/bin/luau tests/integration/helm/compat.luau -a outputs
local Parse = require("../../../plugin/lib/helm/parse")
local json = require("../../lib/json")

type Entry = { release: string, namespace: string, revision: number, extras: string, previous: string? }

local name = ({ ... })[1] :: string?
assert(name, "compat: module name argument missing")
local entries = (require :: any)("../../../.sandbox/helm-compat/" .. name) :: { Entry }

local function unhex(h: string): string
	return (string.gsub(h, "%x%x", function(x: string): string
		return string.char(tonumber(x, 16) :: number)
	end))
end

local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- Every leaf of `sub` is present and equal in `super` (paths for the report).
local function missing(sub: { [string]: any }, super: any, prefix: string, out: { string })
	for k, v in sub do
		local path = prefix .. tostring(k)
		local other = if type(super) == "table" then super[k] else nil
		if type(v) == "table" and next(v) ~= nil and #v == 0 then
			missing(v, other, path .. ".", out)
		elseif not same(v, other) then
			table.insert(out, path)
		end
	end
end

local failures: { string } = {}
local function fail(e: Entry, msg: string)
	table.insert(failures, string.format("%s r%d: %s", e.release, e.revision, msg))
end

for _, e in entries do
	local before = #failures
	local ex, err = Parse.extras(unhex(e.extras), json.decode)
	if ex == nil then
		fail(e, tostring(err))
	elseif ex.name ~= e.release or ex.namespace ~= e.namespace or ex.revision ~= e.revision then
		fail(e, string.format("describes %s/%s r%d", ex.namespace, ex.name, ex.revision))
	elseif ex.chart.name == "" or ex.chart.version == "" then
		fail(e, "chart metadata empty")
	elseif next(ex.defaults) == nil then
		fail(e, "chart defaults empty")
	elseif e.release == "web-b" and #ex.hooks == 0 then
		fail(e, "web chart hooks missing")
	else
		for _, hook in ex.hooks do
			if hook.name == "" or #hook.events == 0 or hook.manifest == "" then
				fail(e, "incomplete hook " .. hook.name)
			end
		end
		if e.previous then
			local prev, verr = Parse.values(unhex(e.previous), json.decode)
			if prev == nil then
				fail(e, "previous values: " .. tostring(verr))
			else
				local paths: { string } = {}
				missing(prev, ex.defaults, "", paths)
				if #paths > 0 then
					table.sort(paths)
					fail(e, "stored defaults lack reused values " .. table.concat(paths, ", "))
				end
			end
		end
		if #failures == before then
			print(
				string.format(
					"ok %s r%d (%s-%s, %d hooks)",
					e.release,
					e.revision,
					ex.chart.name,
					ex.chart.version,
					#ex.hooks
				)
			)
		end
	end
end

if #failures > 0 then
	for _, f in failures do
		print("FAIL " .. f)
	end
	error(string.format("compat: %d of %d revisions failed", #failures, #entries), 0)
end
print(string.format("compat: %d revisions decoded", #entries))

return nil
