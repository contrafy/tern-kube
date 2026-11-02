--!strict
-- Deterministic synthetic fixtures: `kubectl get pods` tables for scale
-- fixtures and mixed `kubectl logs` output for the logs lens.
--
--   .tools/bin/luau scripts/fixtures/synth.luau -a ROWS SEED [all] [wide]
--   .tools/bin/luau scripts/fixtures/synth.luau -a logs LINES SEED [prefix]
--
-- Tables: the table kubectl would print: rows sorted by name (by namespace,
-- then name, with `all`), cells laid out like kubectl's tabwriter (minwidth 6,
-- padding 3, last column unpadded). Ages and restart suffixes use kubectl's
-- HumanDuration format.
--
-- Logs: LINES lines mixing JSON, klog, logfmt, plain (with and without level
-- tokens), Java and Python stacks, ANSI colour and long lines, about 8 %
-- errors; `prefix` prints what `kubectl logs -l ... --all-containers --prefix
-- --timestamps` prints for 2 pods x 3 containers (per-source monotonic kubelet
-- times, sources interleaved). Required as a module (no arguments) it returns
-- `{ logLines = fn }`, so specs and bench build large inputs in memory
-- instead of embedding them. The small embedded samples are regenerated with
--   .tools/bin/luau scripts/fixtures/synth.luau -a logs 200 20261102 >tests/fixtures/logs/mixed-200.txt
--   .tools/bin/luau scripts/fixtures/synth.luau -a logs 200 20261102 prefix >tests/fixtures/logs/prefixed-200.txt

local state = 1

local function rand(n: number): number
	state = (state * 48271) % 2147483647
	return state % n + 1
end

local function pick<T>(list: { T }): T
	return list[rand(#list)]
end

local function tables(argv: { string })
	local rows = tonumber(argv[1])
	local seed = tonumber(argv[2])
	assert(rows and rows > 0 and seed, "usage: synth.luau -a ROWS SEED [all] [wide]")
	local allNamespaces = false
	local wide = false
	for i = 3, #argv do
		if argv[i] == "all" then
			allNamespaces = true
		elseif argv[i] == "wide" then
			wide = true
		else
			error("unknown flag " .. tostring(argv[i]))
		end
	end

	state = seed % 2147483646 + 1

	local SAFE = "bcdfghjklmnpqrstvwxz2456789"

	local function safeString(len: number): string
		local out = table.create(len)
		for i = 1, len do
			local k = rand(#SAFE)
			out[i] = string.sub(SAFE, k, k)
		end
		return table.concat(out)
	end

	local function humanDuration(seconds: number): string
		if seconds < 120 then
			return `{seconds}s`
		end
		local minutes = seconds // 60
		if minutes < 10 then
			local s = seconds % 60
			return if s == 0 then `{minutes}m` else `{minutes}m{s}s`
		elseif minutes < 180 then
			return `{minutes}m`
		end
		local hours = seconds // 3600
		if hours < 8 then
			local m = minutes % 60
			return if m == 0 then `{hours}h` else `{hours}h{m}m`
		elseif hours < 48 then
			return `{hours}h`
		elseif hours < 24 * 8 then
			local h = hours % 24
			return if h == 0 then `{hours // 24}d` else `{hours // 24}d{h}h`
		elseif hours < 24 * 365 * 2 then
			return `{hours // 24}d`
		elseif hours < 24 * 365 * 8 then
			local d = (hours // 24) % 365
			return if d == 0 then `{hours // 24 // 365}y` else `{hours // 24 // 365}y{d}d`
		end
		return `{hours // 24 // 365}y`
	end

	local NAMESPACES = {
		"auth",
		"checkout",
		"data-pipeline",
		"default",
		"ingress-nginx",
		"kube-system",
		"monitoring",
		"payments",
		"search",
		"team-recommendations-experimental",
	}

	type Workload = { name: string, kind: string, containers: number, hash: string }

	local APP_NAMES = {
		"api-gateway",
		"auth-service",
		"cart",
		"checkout-service",
		"coredns",
		"elasticsearch-data",
		"frontend",
		"image-resizer",
		"kafka",
		"kube-proxy",
		"node-exporter",
		"notification-sender",
		"payments-worker",
		"postgres",
		"prometheus-server",
		"recommendation-engine-batch-scoring",
		"redis",
		"report-generator",
		"search-indexer",
		"user-profile",
	}

	local KINDS: { string } = { "deploy", "deploy", "deploy", "deploy", "deploy", "sts", "ds", "job" }

	local workloads: { Workload } = {}
	for _, name in APP_NAMES do
		table.insert(
			workloads,
			{ name = name, kind = pick(KINDS), containers = rand(3), hash = safeString(rand(2) + 8) }
		)
	end

	local NODES = {
		"prod-worker-01",
		"prod-worker-02",
		"prod-worker-03",
		"prod-worker-04",
		"prod-worker-05",
		"prod-worker-06",
		"gke-prod-default-pool-8c1f2a3b-q7xz",
		"ip-10-0-142-17.us-west-2.compute.internal",
	}

	local STATUSES: { { any } } = {
		{ "Running", 70 },
		{ "Completed", 7 },
		{ "CrashLoopBackOff", 6 },
		{ "Pending", 4 },
		{ "Error", 4 },
		{ "ImagePullBackOff", 3 },
		{ "Terminating", 3 },
		{ "ContainerCreating", 1 },
		{ "Init:0/1", 1 },
		{ "OOMKilled", 1 },
	}

	local function pickStatus(): string
		local roll = rand(100)
		for _, entry in STATUSES do
			roll -= entry[2] :: number
			if roll <= 0 then
				return entry[1] :: string
			end
		end
		return "Running"
	end

	type Row = { namespace: string, cells: { string } }

	local function podName(w: Workload, index: number): string
		if w.kind == "deploy" then
			return `{w.name}-{w.hash}-{safeString(5)}`
		elseif w.kind == "sts" then
			return `{w.name}-{index}`
		elseif w.kind == "ds" then
			return `{w.name}-{safeString(5)}`
		end
		return `{w.name}-{29000000 + rand(999999)}-{safeString(5)}`
	end

	local function restartsCell(count: number, age: number): string
		if count == 0 then
			return "0"
		end
		return `{count} ({humanDuration(math.min(age, rand(3600 * 6)))} ago)`
	end

	local function makeRow(i: number, seen: { [string]: boolean }): Row
		local w = pick(workloads)
		local namespace = if allNamespaces then pick(NAMESPACES) else "default"
		local name = podName(w, i - 1)
		while seen[namespace .. "/" .. name] do
			name = podName(w, rand(50))
		end
		seen[namespace .. "/" .. name] = true

		local status = if w.kind == "job" and rand(2) == 1 then "Completed" else pickStatus()
		local total = w.containers
		local ageBucket = rand(6)
		local age = if ageBucket == 1
			then rand(119)
			elseif ageBucket == 2 then 120 + rand(3600 * 3)
			elseif ageBucket == 3 then 3600 * 3 + rand(3600 * 45)
			elseif ageBucket == 4 then 3600 * 48 + rand(3600 * 24 * 6)
			elseif ageBucket == 5 then 3600 * 24 * 8 + rand(3600 * 24 * 300)
			else 3600 * 24 * 730 + rand(3600 * 24 * 900)

		local ready = 0
		local restarts = 0
		if status == "Running" then
			ready = if rand(10) == 1 then total - 1 else total
			restarts = if rand(5) == 1 then rand(4) else 0
		elseif status == "Terminating" then
			ready = if rand(2) == 1 then total else 0
		elseif status == "CrashLoopBackOff" or status == "OOMKilled" then
			ready = total - 1
			restarts = rand(250)
		elseif status == "Error" then
			restarts = rand(3) - 1
		end

		local scheduled = status ~= "Pending" or rand(3) == 1
		local cells = {
			name,
			`{ready}/{total}`,
			status,
			restartsCell(restarts, age),
			humanDuration(age),
		}
		if wide then
			local ip = if scheduled
					and status ~= "Pending"
					and status ~= "ContainerCreating"
				then `10.244.{rand(16) - 1}.{rand(254)}`
				else "<none>"
			table.insert(cells, ip)
			table.insert(cells, if scheduled then pick(NODES) else "<none>")
			table.insert(cells, if not scheduled and rand(4) == 1 then pick(NODES) else "<none>")
			table.insert(cells, if rand(15) == 1 then `{if status == "Running" then 1 else 0}/1` else "<none>")
		end
		if allNamespaces then
			table.insert(cells, 1, namespace)
		end
		return { namespace = namespace, cells = cells }
	end

	local seen: { [string]: boolean } = {}
	local body: { Row } = {}
	for i = 1, rows do
		table.insert(body, makeRow(i, seen))
	end
	local nameColumn = if allNamespaces then 2 else 1
	table.sort(body, function(a: Row, b: Row): boolean
		if a.namespace ~= b.namespace then
			return a.namespace < b.namespace
		end
		return a.cells[nameColumn] < b.cells[nameColumn]
	end)

	local header = { "NAME", "READY", "STATUS", "RESTARTS", "AGE" }
	if wide then
		for _, h in { "IP", "NODE", "NOMINATED NODE", "READINESS GATES" } do
			table.insert(header, h)
		end
	end
	if allNamespaces then
		table.insert(header, 1, "NAMESPACE")
	end

	local all: { { string } } = { header }
	for _, row in body do
		table.insert(all, row.cells)
	end

	local widths: { number } = {}
	for c = 1, #header - 1 do
		local widest = 0
		for _, cells in all do
			widest = math.max(widest, utf8.len(cells[c]) or #cells[c])
		end
		widths[c] = math.max(6, widest + 3)
	end

	local out = table.create(#all)
	for r, cells in all do
		local parts = table.create(#cells)
		for c, cell in cells do
			if c < #cells then
				parts[c] = cell .. string.rep(" ", widths[c] - (utf8.len(cell) or #cell))
			else
				parts[c] = cell
			end
		end
		out[r] = table.concat(parts)
	end
	print(table.concat(out, "\n"))
end

local PODS = { "shop-api-7d9f8c6b5-x2k4p", "shop-api-7d9f8c6b5-q9w7z" }
local CONTAINERS = { "app", "sidecar", "worker" }
local MESSAGES = {
	"request served",
	"cache miss",
	"user signed in",
	"order created",
	"payment authorised",
	"retrying upstream call",
	"queue drained",
	"config reloaded",
	"connection pool resized",
	"slow query",
}
local PATHS = { "/api/orders", "/api/cart", "/healthz", "/api/users/me", "/api/checkout" }
local FILES = { "controller.go", "reflector.go", "sync.go", "leaderelection.go", "server.go" }

-- Plain strings: the type solver widens singleton unions returned from functions.
type Level = string

local function pickLevel(): Level
	local roll = rand(100)
	if roll <= 8 then
		return "error"
	elseif roll <= 20 then
		return "warn"
	elseif roll <= 30 then
		return "debug"
	end
	return "info"
end

-- Clock time of `ms` after 10:00:00 on 2026-10-30.
local function clock(ms: number): (number, number, number, number)
	local s = 36000 + ms // 1000
	return s // 3600, (s % 3600) // 60, s % 60, ms % 1000
end

-- Kubelet RFC3339Nano: UTC, fraction with trailing zeros trimmed (as Go does).
local function kubeletTime(ms: number): string
	local h, m, s, milli = clock(ms)
	local ns = milli * 1000000 + (if rand(10) == 1 then 0 else rand(999999))
	local frac = string.gsub(string.format("%09d", ns), "0+$", "")
	return string.format("2026-10-30T%02d:%02d:%02d%sZ", h, m, s, if frac == "" then "" else "." .. frac)
end

local function appTime(ms: number): string
	local h, m, s, milli = clock(ms)
	return string.format("2026-10-30T%02d:%02d:%02d.%03dZ", h, m, s, milli)
end

local function hex(n: number): string
	local out = table.create(n)
	for i = 1, n do
		local k = rand(16)
		out[i] = string.sub("0123456789abcdef", k, k)
	end
	return table.concat(out)
end

local function jsonLine(level: Level, ms: number): string
	local parts = {
		string.format('{"level":"%s","ts":"%s","msg":"%s"', level, appTime(ms), pick(MESSAGES)),
		string.format('"request_id":"%s"', hex(12)),
		string.format(
			'"path":"%s","status":%d,"dur_ms":%d.%d',
			pick(PATHS),
			pick({ 200, 201, 404, 500 }),
			rand(900),
			rand(9)
		),
	}
	if rand(5) == 1 then
		table.insert(parts, string.format('"user":{"id":%d,"roles":["admin","dev"]}', rand(9999)))
	end
	return table.concat(parts, ",") .. "}"
end

local KLOG: { [Level]: string } = { error = "E", warn = "W", info = "I", debug = "I" }

local function klogLine(level: Level, ms: number): string
	local h, m, s, milli = clock(ms)
	local head = string.format(
		"%s1030 %02d:%02d:%02d.%03d%03d       1 %s:%d] ",
		KLOG[level],
		h,
		m,
		s,
		milli,
		rand(999),
		pick(FILES),
		rand(400)
	)
	if rand(2) == 1 then
		return head .. string.format('"%s" key="ns/obj-%d" attempt=%d', pick(MESSAGES), rand(99), rand(5))
	end
	return head .. pick(MESSAGES)
end

local function logfmtLine(level: Level, ms: number): string
	return string.format(
		'time=%s level=%s msg="%s" path=%s dur=%d.%ds',
		appTime(ms),
		level,
		pick(MESSAGES),
		pick(PATHS),
		rand(3) - 1,
		rand(9)
	)
end

local function plainLine(level: Level, ms: number): string
	local style = rand(4)
	local upper = string.upper(level)
	if style == 1 then
		return upper .. " " .. pick(MESSAGES)
	elseif style == 2 then
		return "[" .. upper .. "] " .. pick(MESSAGES)
	elseif style == 3 then
		local h, m, s, milli = clock(ms)
		return string.format("2026-10-30 %02d:%02d:%02d,%03d %s [main] %s", h, m, s, milli, upper, pick(MESSAGES))
	end
	return pick(MESSAGES) .. " in " .. rand(900) .. "ms"
end

local function javaStack(ms: number): { string }
	local h, m, s, milli = clock(ms)
	local out = {
		string.format(
			"2026-10-30 %02d:%02d:%02d,%03d ERROR [main] java.lang.IllegalStateException: order %d in bad state",
			h,
			m,
			s,
			milli,
			rand(99999)
		),
	}
	for _ = 1, rand(4) + 1 do
		table.insert(out, string.format("\tat com.example.shop.Service.handle(Service.java:%d)", rand(300)))
	end
	if rand(3) == 1 then
		table.insert(out, "Caused by: java.io.IOException: connection reset")
		table.insert(out, "\t... 3 more")
	end
	return out
end

local function pythonStack(): { string }
	return {
		"Traceback (most recent call last):",
		string.format('  File "/app/worker.py", line %d, in run', rand(200)),
		"    raise ValueError('bad payload')",
		"ValueError: bad payload",
	}
end

-- Payload lines of one event of one source.
local function event(ms: number): { string }
	local roll = rand(100)
	local level = pickLevel()
	if roll <= 30 then
		return { jsonLine(level, ms) }
	elseif roll <= 45 then
		return { klogLine(level, ms) }
	elseif roll <= 60 then
		return { logfmtLine(level, ms) }
	elseif roll <= 85 then
		return { plainLine(level, ms) }
	elseif roll <= 89 then
		return javaStack(ms)
	elseif roll <= 91 then
		return pythonStack()
	elseif roll <= 95 then
		return { "\27[33mWARN\27[0m " .. pick(MESSAGES) }
	elseif roll <= 96 then
		return { "long: " .. string.rep("x", 500 + rand(2500)) }
	end
	return { pick(MESSAGES) .. " (" .. hex(8) .. ")" }
end

local function logLines(n: number, seed: number, prefixed: boolean): { string }
	state = seed % 2147483646 + 1
	local sources = #PODS * #CONTAINERS
	local clocks: { number } = table.create(sources)
	for i = 1, sources do
		clocks[i] = rand(1000)
	end
	local appMs = 0
	local out: { string } = table.create(n)
	while #out < n do
		local src = rand(sources)
		appMs += rand(300)
		for _, payload in event(appMs) do
			if #out >= n then
				break
			end
			if prefixed then
				clocks[src] += rand(400)
				local pod = PODS[(src - 1) // #CONTAINERS + 1]
				local container = CONTAINERS[(src - 1) % #CONTAINERS + 1]
				table.insert(out, string.format("[pod/%s/%s] %s %s", pod, container, kubeletTime(clocks[src]), payload))
			else
				table.insert(out, payload)
			end
		end
	end
	return out
end

local argv: { string } = { ... }
if argv[1] == "logs" then
	local n = tonumber(argv[2])
	local seed = tonumber(argv[3])
	assert(n and n > 0 and seed, "usage: synth.luau -a logs LINES SEED [prefix]")
	print(table.concat(logLines(n, seed, argv[4] == "prefix"), "\n"))
elseif argv[1] ~= nil then
	tables(argv)
end

return { logLines = logLines }
