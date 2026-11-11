--!strict
-- Usage trends: per row key (pod `ns/name`, container `ns/name/c`, node
-- name) a ring of the last CAP samples `{t, cpu, mem}`. A sample is kept
-- only when its metrics window is newer than the key's last one: metrics-server
-- moves a window every 10-30 s, so reading faster repeats the same numbers.
-- Copy on write (an older state keeps its rings). Pure; never persisted.

local M = {}

M.CAP = 30
-- Above this many rows a load keeps no trends (memory: CAP x 3 numbers a row).
M.MAX_ROWS = 5000

export type Ring = { t: { number }, cpu: { number }, mem: { number } }
export type Store = { [string]: Ring }
export type Sample = { key: string, t: number?, cpu: number?, mem: number? }

function M.new(): Store
	return {}
end

local function pushCapped(list: { number }, v: number): { number }
	local out = table.clone(list)
	table.insert(out, v)
	if #out > M.CAP then
		table.remove(out, 1)
	end
	return out
end

-- The store with every sample newer than its key's last one appended, and
-- how many were. Samples without a time or usage are skipped.
function M.add(store: Store, samples: { Sample }): (Store, number)
	local out: Store? = nil
	local added = 0
	for _, s in samples do
		local t, cpu, mem = s.t, s.cpu, s.mem
		if t == nil or cpu == nil or mem == nil then
			continue
		end
		local cur = (out or store)[s.key]
		if cur and #cur.t > 0 and cur.t[#cur.t] >= t then
			continue
		end
		if out == nil then
			out = table.clone(store)
		end
		local ring = cur or { t = {}, cpu = {}, mem = {} }
		(out :: Store)[s.key] = {
			t = pushCapped(ring.t, t),
			cpu = pushCapped(ring.cpu, cpu),
			mem = pushCapped(ring.mem, mem),
		}
		added += 1
	end
	return out or store, added
end

function M.count(store: Store, key: string): number
	local ring = store[key]
	return if ring then #ring.t else 0
end

export type SparkOpts = {
	field: "cpu" | "mem",
	-- Column word for the title: CPU, memory.
	label: string,
	format: (number) -> string,
	-- Local clock text of a sample time.
	clock: (number) -> string,
	-- The row's limit: the spark's top (headroom shows) and the error tone
	-- when the last sample is at or above ERROR_SHARE of it.
	limit: number?,
}

M.ERROR_SHARE = 0.95
M.ONE_SAMPLE = "1 sample; r or w adds more"

-- A Tern spark cell for `key`, or nil until two samples exist.
function M.spark(store: Store, key: string, o: SparkOpts): any?
	local ring = store[key]
	if ring == nil or #ring.t < 2 then
		return nil
	end
	local values: { number } = if o.field == "cpu" then ring.cpu else ring.mem
	local lo, hi = math.huge, -math.huge
	for _, v in values do
		lo = math.min(lo, v)
		hi = math.max(hi, v)
	end
	local parts = {
		string.format(
			"%s, %d samples %s-%s, min %s, max %s",
			o.label,
			#values,
			o.clock(ring.t[1]),
			o.clock(ring.t[#ring.t]),
			o.format(lo),
			o.format(hi)
		),
	}
	local limit = o.limit
	if limit then
		table.insert(parts, "limit " .. o.format(limit))
	end
	local last = values[#values]
	return {
		spark = {
			values = table.clone(values),
			max = if limit and limit > 0 then math.max(limit, hi) else nil,
			tone = if limit and limit > 0 and last >= limit * M.ERROR_SHARE then "error" else nil,
			title = table.concat(parts, ", "),
		},
	}
end

return M
