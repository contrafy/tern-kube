--!strict
-- Deterministic synthetic `kubectl get pods` tables for scale fixtures.
--
--   .tools/bin/luau scripts/fixtures/synth.luau -a ROWS SEED [all] [wide]
--
-- Prints the table kubectl would print: rows sorted by name (by namespace,
-- then name, with `all`), cells laid out like kubectl's tabwriter (minwidth 6,
-- padding 3, last column unpadded). Ages and restart suffixes use kubectl's
-- HumanDuration format.

local argv = { ... }
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

local state = seed % 2147483646 + 1

local function rand(n: number): number
	state = (state * 48271) % 2147483647
	return state % n + 1
end

local function pick<T>(list: { T }): T
	return list[rand(#list)]
end

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

type Workload = { name: string, kind: "deploy" | "sts" | "ds" | "job", containers: number, hash: string }

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

local KINDS: { "deploy" | "sts" | "ds" | "job" } =
	{ "deploy", "deploy", "deploy", "deploy", "deploy", "sts", "ds", "job" }

local workloads: { Workload } = {}
for _, name in APP_NAMES do
	table.insert(workloads, { name = name, kind = pick(KINDS), containers = rand(3), hash = safeString(rand(2) + 8) })
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

local STATUSES = {
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
		local ip = if scheduled and status ~= "Pending" and status ~= "ContainerCreating"
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
