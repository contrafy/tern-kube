--!strict
-- Driver for check.sh. Standalone luau has no file I/O, so check.sh first
-- asks `argv` for the plugin's own usage reads (one shell-quoted command per
-- line), runs exactly those, then embeds their output (and `kubectl describe
-- nodes`) in a generated module that calls `check`.
local Model = require("../../../plugin/lib/usage/model")
local Parse = require("../../../plugin/lib/usage/parse")
local Query = require("../../../plugin/lib/explore/query")
local Values = require("../../../plugin/lib/model/values")

local M = {}

local function quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Prints `NAME<space>ARGV` lines: pods and pod metrics of `namespace`, nodes,
-- node metrics, and every pod (the nodes view's committed totals).
function M.argv(kubeconfig: string, context: string, namespace: string)
	local target: Query.Target = {
		kubeconfig = kubeconfig,
		context = context,
		contextSource = "flag",
		namespace = namespace,
		allNamespaces = false,
		confirmed = true,
	}
	local ns: Query.Scope = { namespace = namespace, all = false }
	local reads: { { name: string, argv: { string } } } = {
		{ name = "pods", argv = Query.usagePods("kubectl", target, ns) },
		{ name = "podmetrics", argv = Query.usagePodMetrics("kubectl", target, ns) },
		{ name = "nodes", argv = Query.usageNodes("kubectl", target) },
		{ name = "nodemetrics", argv = Query.usageNodeMetrics("kubectl", target) },
		{ name = "allpods", argv = Query.usagePods("kubectl", target, { namespace = nil, all = true }) },
	}
	for _, r in reads do
		local words: { string } = {}
		for _, a in r.argv do
			table.insert(words, quote(a))
		end
		print(r.name .. " " .. table.concat(words, " "))
	end
end

-- `kubectl describe nodes`: per node, the Allocated resources cpu/memory
-- request columns.
local function described(text: string): { [string]: { cpu: number, mem: number } }
	local out: { [string]: { cpu: number, mem: number } } = {}
	local node: string? = nil
	local inAlloc = false
	for line in string.gmatch(text, "[^\n]+") do
		local name = string.match(line, "^Name:%s+(%S+)")
		if name then
			node = name
			inAlloc = false
		elseif string.match(line, "^Allocated resources:") then
			inAlloc = true
		elseif inAlloc and node and string.match(line, "^%S") then
			inAlloc = false
		elseif inAlloc and node then
			local res, req = string.match(line, "^%s+(%a+)%s+(%S+)%s+%(")
			if res == "cpu" or res == "memory" then
				local entry: { cpu: number, mem: number } = out[node] or { cpu = 0, mem = 0 }
				out[node] = entry
				local v = Values.quantity(req :: string) or 0
				if res == "cpu" then
					entry.cpu = v
				else
					entry.mem = v
				end
			end
		end
	end
	return out
end

export type Outputs = {
	namespace: string,
	pods: string,
	podmetrics: string,
	nodes: string,
	nodemetrics: string,
	allpods: string,
	describe: string,
}

function M.check(o: Outputs)
	local failures: { string } = {}
	local function fail(msg: string)
		table.insert(failures, msg)
	end

	local pods = Parse.pods(o.pods)
	local metrics = Parse.podMetrics(o.podmetrics)
	local rows = Model.podRows(pods, metrics)
	local byName: { [string]: Model.PodRow } = {}
	for _, r in rows do
		byName[r.name] = r
	end
	for _, want in { "sidecar-init", "limits-only", "pod-level", "cpu-burner" } do
		local r = byName[want]
		if r == nil then
			fail(want .. ": not listed")
		elseif r.phase ~= "Running" then
			fail(want .. ": phase " .. tostring(r.phase))
		end
	end
	for _, r in rows do
		if r.phase == "Running" and r.metric == nil then
			fail(r.name .. ": running without metrics")
		end
	end

	local burner = byName["cpu-burner"]
	if burner then
		local pct = burner.limCpu.pct
		if pct == nil or pct < 90 then
			fail("cpu-burner: %CPU/L " .. tostring(pct) .. " < 90")
		end
	end
	local sidecar = byName["sidecar-init"]
	if sidecar then
		local eff = Model.effective(sidecar.pod, "req")
		if math.abs(eff.cpu - 0.5) > 1e-9 or eff.mem ~= 256 * 1024 * 1024 then
			fail(
				string.format(
					"sidecar-init: effective request %s/%s, want 500m/256Mi",
					Model.cpu(eff.cpu),
					Model.mem(eff.mem)
				)
			)
		end
	end
	local totals = Model.podTotals(rows)
	if totals.nearLimits < 1 then
		fail("podTotals.nearLimits = " .. totals.nearLimits)
	end

	local nodes = Parse.nodes(o.nodes)
	local nodeMetrics = Parse.nodeMetrics(o.nodemetrics)
	local all = Parse.pods(o.allpods)
	local committed = Model.committed(all)
	local nodeRows = Model.nodeRows(nodes, nodeMetrics, all)
	if #nodes == 0 then
		fail("no nodes listed")
	end
	for _, r in nodeRows do
		if r.metric == nil then
			fail("node " .. r.name .. ": no metrics")
		end
	end
	-- Older kubectl (1.34) `describe node` sums container requests only, so a
	-- pod with pod-level requests counts as its containers (none here); newer
	-- kubectl counts the pod-level value, as the usage views do. Either total
	-- must match ours exactly.
	local podLevel: { [string]: { cpu: number, mem: number } } = {}
	for _, p in all do
		if p.node and not Model.terminal(p) and (p.podReq.cpu or p.podReq.mem) then
			local e = podLevel[p.node] or { cpu = 0, mem = 0 }
			podLevel[p.node] = e
			local req = Model.effective(p, "req")
			e.cpu += req.cpu
			e.mem += req.mem
		end
	end
	local desc = described(o.describe)
	local compared = 0
	for _, n in nodes do
		local ours = committed[n.name]
		local theirs = desc[n.name]
		if ours == nil or theirs == nil then
			fail("node " .. n.name .. ": missing committed or describe totals")
			continue
		end
		local extra = podLevel[n.name] or { cpu = 0, mem = 0 }
		local function matches(cpu: number, mem: number): boolean
			return math.abs(ours.cpu - cpu) <= 1e-6 and math.abs(ours.mem - mem) <= 0.5
		end
		if not (matches(theirs.cpu, theirs.mem) or matches(theirs.cpu + extra.cpu, theirs.mem + extra.mem)) then
			fail(
				string.format(
					"node %s: committed %s/%s, describe %s/%s + pod-level %s/%s",
					n.name,
					Model.cpu(ours.cpu),
					Model.mem(ours.mem),
					Model.cpu(theirs.cpu),
					Model.mem(theirs.mem),
					Model.cpu(extra.cpu),
					Model.mem(extra.mem)
				)
			)
		end
		compared += 1
	end

	print(
		string.format(
			"usage check: %d pods in %s (%d with metrics, %d near limits), %d nodes compared, %d pods cluster-wide, %d problems",
			totals.listed,
			o.namespace,
			totals.withMetrics,
			totals.nearLimits,
			compared,
			#all,
			#failures
		)
	)
	if #failures > 0 then
		error("usage check failed:\n  " .. table.concat(failures, "\n  "), 0)
	end
end

return M
