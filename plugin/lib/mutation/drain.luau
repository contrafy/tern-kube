--!strict
-- Reads `kubectl drain --dry-run=client|server` output into facts for the
-- preview. drain has no `-o`, so its text is the only source:
--   stdout  `node/N cordoned (...)`, `evicting pod NS/NAME (...)`, `node/N drained (...)`
--   stderr  `Warning: ignoring DaemonSet-managed Pods: a/b; deleting Pods that declare no controller: c/d`,
--           pre-flight refusals `cannot delete <what> (use --flag to override): NS/NAME, ...`
--           (kubectl prints "cannot delete cannot delete Pods that declare no controller"),
--           PodDisruptionBudget refusals `error when evicting pods/"NAME" -n "NS" (will retry
--           after 5s): Cannot evict pod as it would violate the pod's disruption budget.`
--           and `global timeout reached` / `context deadline exceeded` once --timeout expires.
-- A client dry run lists pods sorted and never consults PodDisruptionBudgets;
-- a server dry run goes through the Eviction API (so it sees budgets) but
-- retries blocked pods until --timeout, printing them repeatedly.

export type PodRef = { namespace: string, name: string }
export type Category = "unmanaged" | "daemonset" | "local-storage" | "other"
export type Preflight = { category: Category, pods: { PodRef }, flag: string? }
export type Facts = {
	nodes: { string },
	evictions: { PodRef },
	daemonSetIgnored: { PodRef },
	unmanaged: { PodRef },
	preflight: { Preflight },
	pdbBlocked: { PodRef },
	timedOut: boolean,
}

local M = {}

local POD_REF = "^([%l%d][%l%d%.%-]*)/([%l%d][%l%d%.%-]*)"

local function refKey(p: PodRef): string
	return p.namespace .. "/" .. p.name
end

local function addUnique(list: { PodRef }, p: PodRef)
	local key = refKey(p)
	for _, existing in list do
		if refKey(existing) == key then
			return
		end
	end
	table.insert(list, p)
end

local function addNode(nodes: { string }, name: string)
	if table.find(nodes, name) == nil then
		table.insert(nodes, name)
	end
end

-- `ns/a, ns/b` from `pos` on; stops at the first token that is not a pod.
local function podList(text: string, pos: number): { PodRef }
	local out: { PodRef } = {}
	local i = pos
	while true do
		local ns, name = string.match(text, POD_REF, i)
		if ns == nil or name == nil then
			break
		end
		addUnique(out, { namespace = ns, name = name })
		i += #ns + 1 + #name
		if string.sub(text, i, i + 1) ~= ", " then
			break
		end
		i += 2
	end
	return out
end

local function category(what: string): Category
	if string.find(what, "declare no controller", 1, true) then
		return "unmanaged"
	elseif string.find(what, "DaemonSet-managed", 1, true) then
		return "daemonset"
	elseif string.find(what, "local storage", 1, true) then
		return "local-storage"
	end
	return "other"
end

local function addPreflight(list: { Preflight }, cat: Category, flag: string?, pods: { PodRef })
	for _, existing in list do
		if existing.category == cat and existing.flag == flag then
			for _, p in pods do
				addUnique(existing.pods, p)
			end
			return
		end
	end
	table.insert(list, { category = cat, pods = pods, flag = flag })
end

local function parseWarning(facts: Facts, body: string)
	for _, clause in string.split(body, "; ") do
		local what, list = string.match(clause, "^(.-): (.*)$")
		if what and list then
			local pods = podList(list, 1)
			local target = if string.find(what, "DaemonSet-managed", 1, true)
				then facts.daemonSetIgnored
				elseif string.find(what, "declare no controller", 1, true) then facts.unmanaged
				else nil
			if target then
				for _, p in pods do
					addUnique(target, p)
				end
			end
		end
	end
end

function M.parse(stdout: string, stderr: string): Facts
	local facts: Facts = {
		nodes = {},
		evictions = {},
		daemonSetIgnored = {},
		unmanaged = {},
		preflight = {},
		pdbBlocked = {},
		timedOut = false,
	}
	for _, line in string.split(stdout .. "\n" .. stderr, "\n") do
		line = string.match(line, "^(.-)%s*$") or line
		local node = string.match(line, "^node/(%S+) cordoned")
			or string.match(line, "^node/(%S+) already cordoned")
			or string.match(line, "^node/(%S+) drained")
		if node then
			addNode(facts.nodes, node)
		end
		local evicting = string.match(line, "^evicting pod (.+)$")
		if evicting then
			local pods = podList(evicting, 1)
			if pods[1] then
				addUnique(facts.evictions, pods[1])
			end
		end
		local warning = string.match(line, "^Warning: (.+)$")
		if warning then
			parseWarning(facts, warning)
		end
	end
	-- Pre-flight causes appear inside the aggregated error and again one per
	-- line; scanning the whole text and merging by category covers both.
	local pos = 1
	while true do
		local s, e, what, flag = string.find(stderr, "cannot delete ([^:,%[%]\n]-) %(use (%-%-[%w%-]+) to %a+%): ", pos)
		if s == nil then
			break
		end
		addPreflight(facts.preflight, category(what :: string), flag, podList(stderr, (e :: number) + 1))
		pos = (e :: number) + 1
	end
	for name, ns in string.gmatch(stderr, 'error when evicting pods/"([^"]+)" %-n "([^"]+)"[^\n]-disruption budget') do
		addUnique(facts.pdbBlocked, { namespace = ns :: string, name = name })
	end
	facts.timedOut = string.find(stderr, "global timeout reached", 1, true) ~= nil
		or string.find(stderr, "context deadline exceeded", 1, true) ~= nil
	return facts
end

local function union(a: { PodRef }, b: { PodRef }): { PodRef }
	local out = table.clone(a)
	for _, p in b do
		addUnique(out, p)
	end
	return out
end

-- The client run decides the pod list (complete, sorted, deterministic) and
-- the pre-flight policy; the server run adds what only the Eviction API
-- knows: pods a budget blocks now and whether the probe timed out.
function M.merge(client: Facts, server: Facts?): Facts
	local preflight: { Preflight } = {}
	for _, source in { client.preflight, if server then server.preflight else {} } do
		for _, p in source do
			addPreflight(preflight, p.category, p.flag, table.clone(p.pods))
		end
	end
	local nodes = table.clone(client.nodes)
	local evictions = client.evictions
	local daemonSetIgnored, unmanaged = client.daemonSetIgnored, client.unmanaged
	if server then
		for _, n in server.nodes do
			addNode(nodes, n)
		end
		evictions = union(evictions, server.evictions)
		daemonSetIgnored = union(daemonSetIgnored, server.daemonSetIgnored)
		unmanaged = union(unmanaged, server.unmanaged)
	end
	return {
		nodes = nodes,
		evictions = table.clone(evictions),
		daemonSetIgnored = table.clone(daemonSetIgnored),
		unmanaged = table.clone(unmanaged),
		preflight = preflight,
		pdbBlocked = if server then table.clone(server.pdbBlocked) else {},
		timedOut = if server then server.timedOut else false,
	}
end

-- --timeout for the server dry run: leaves 5 s of the preview budget for
-- kubectl's own start-up and the final report; a budget is retried every
-- 5 s, so at least one retry is always observed.
function M.probeTimeoutS(previewTimeoutMs: number): number
	return math.clamp(math.floor((previewTimeoutMs - 5000) / 1000), 5, 15)
end

-- A probe that ends on the timeout because of a budget is a finding, not a
-- failed preview.
function M.probeOutcome(code: number, stdout: string, stderr: string): "ok" | "pdb-blocked" | "failed"
	if code == 0 then
		return "ok"
	end
	if code == 1 and string.find(stdout .. "\n" .. stderr, "disruption budget", 1, true) then
		return "pdb-blocked"
	end
	return "failed"
end

return M
