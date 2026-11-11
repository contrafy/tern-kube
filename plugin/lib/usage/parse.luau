--!strict
-- Readers of the usage views' kubectl output. Explore reads pods, nodes and
-- the metrics API with constant jsonpath templates (not `-o json`: ~100
-- bytes per pod instead of ~13 KB, and the metrics API keeps exact units and
-- the window time `kubectl top` drops). Delimiters (tab, `=`, `,`, `;`)
-- cannot occur in DNS names or quantities. A field kubectl printed empty is
-- nil, never 0: "no request" and "0 requested" read differently. Pure.

local Values = require("../model/values")

local M = {}

-- Per pod: namespace, name, node, phase, pod-level requests/limits, each
-- container `name=reqcpu,reqmem,limcpu,limmem;`, each init container
-- `name=restartPolicy,reqcpu,reqmem,limcpu,limmem;`, overhead.
M.POD_JP = '{range .items[*]}{.metadata.namespace}{"\\t"}{.metadata.name}{"\\t"}{.spec.nodeName}{"\\t"}'
	.. '{.status.phase}{"\\t"}{.spec.resources.requests.cpu}{","}{.spec.resources.requests.memory}{","}'
	.. '{.spec.resources.limits.cpu}{","}{.spec.resources.limits.memory}{"\\t"}{range .spec.containers[*]}'
	.. '{.name}{"="}{.resources.requests.cpu}{","}{.resources.requests.memory}{","}{.resources.limits.cpu}'
	.. '{","}{.resources.limits.memory}{";"}{end}{"\\t"}{range .spec.initContainers[*]}{.name}{"="}'
	.. '{.restartPolicy}{","}{.resources.requests.cpu}{","}{.resources.requests.memory}{","}'
	.. '{.resources.limits.cpu}{","}{.resources.limits.memory}{";"}{end}{"\\t"}{.spec.overhead.cpu}{","}'
	.. '{.spec.overhead.memory}{"\\n"}{end}'

M.PODM_JP = '{range .items[*]}{.metadata.namespace}{"\\t"}{.metadata.name}{"\\t"}{.timestamp}{"\\t"}'
	.. '{.window}{"\\t"}{range .containers[*]}{.name}{"="}{.usage.cpu}{","}{.usage.memory}{";"}{end}{"\\n"}{end}'

M.NODE_JP = '{range .items[*]}{.metadata.name}{"\\t"}{.status.allocatable.cpu}{","}'
	.. '{.status.allocatable.memory}{","}{.status.allocatable.pods}{"\\t"}{.status.capacity.cpu}{","}'
	.. '{.status.capacity.memory}{"\\t"}{.spec.unschedulable}{"\\t"}'
	.. '{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\\n"}{end}'

M.NODEM_JP = '{range .items[*]}{.metadata.name}{"\\t"}{.timestamp}{"\\t"}{.window}{"\\t"}{.usage.cpu}{","}'
	.. '{.usage.memory}{"\\n"}{end}'

-- cpu in cores, mem in bytes; nil = not set.
export type Res = { cpu: number?, mem: number? }
export type Container = { name: string, req: Res, lim: Res }
export type Init = { name: string, sidecar: boolean, req: Res, lim: Res }
export type Pod = {
	namespace: string,
	name: string,
	node: string?,
	phase: string?,
	podReq: Res,
	podLim: Res,
	containers: { Container },
	inits: { Init },
	overhead: Res,
}
export type Usage = { name: string, cpu: number?, mem: number? }
export type PodMetric = {
	namespace: string,
	name: string,
	-- Seconds since the epoch of the metrics window's end.
	t: number?,
	window: string?,
	containers: { Usage },
	-- Sum over containers; nil when any container's value is unreadable.
	cpu: number?,
	mem: number?,
}
export type Node = {
	name: string,
	alloc: { cpu: number?, mem: number?, pods: number? },
	cap: Res,
	unschedulable: boolean,
	-- The Ready condition's status (True / False / Unknown); nil = none.
	ready: string?,
}
export type NodeMetric = { name: string, t: number?, window: string?, cpu: number?, mem: number? }

local function nonEmpty(v: string?): string?
	return if v and v ~= "" then v else nil
end

local function qty(v: string?): number?
	local s = nonEmpty(v)
	return if s then Values.quantity(s) else nil
end

function M.time(v: string?): number?
	local s = nonEmpty(v)
	return if s then Values.timestamp(s) else nil
end

-- Fields of a line split on `sep`, empty fields kept.
local function fields(line: string, sep: string): { string }
	return string.split(line, sep)
end

local function lines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local l = string.gsub(line, "\r$", "")
		if l ~= "" then
			table.insert(out, l)
		end
	end
	return out
end

local function res(cpu: string?, mem: string?): Res
	return { cpu = qty(cpu), mem = qty(mem) }
end

-- `name=a,b,…;` entries.
local function entries(text: string?): { { name: string, values: { string } } }
	local out: { { name: string, values: { string } } } = {}
	for entry in string.gmatch(text or "", "[^;]+") do
		local name, rest = string.match(entry, "^([^=]*)=(.*)$")
		if name and name ~= "" then
			table.insert(out, { name = name, values = fields(rest :: string, ",") })
		end
	end
	return out
end

function M.pods(text: string): { Pod }
	local out: { Pod } = {}
	for _, line in lines(text) do
		local f = fields(line, "\t")
		local ns, name = nonEmpty(f[1]), nonEmpty(f[2])
		if ns == nil or name == nil then
			continue
		end
		local pod = fields(f[5] or "", ",")
		local containers: { Container } = {}
		for _, e in entries(f[6]) do
			local v = e.values
			table.insert(containers, { name = e.name, req = res(v[1], v[2]), lim = res(v[3], v[4]) })
		end
		local inits: { Init } = {}
		for _, e in entries(f[7]) do
			local v = e.values
			table.insert(inits, {
				name = e.name,
				sidecar = v[1] == "Always",
				req = res(v[2], v[3]),
				lim = res(v[4], v[5]),
			})
		end
		local overhead = fields(f[8] or "", ",")
		table.insert(out, {
			namespace = ns,
			name = name,
			node = nonEmpty(f[3]),
			phase = nonEmpty(f[4]),
			podReq = res(pod[1], pod[2]),
			podLim = res(pod[3], pod[4]),
			containers = containers,
			inits = inits,
			overhead = res(overhead[1], overhead[2]),
		})
	end
	return out
end

local function usages(text: string?): ({ Usage }, number?, number?)
	local list: { Usage } = {}
	local cpu: number?, mem: number? = 0, 0
	for _, e in entries(text) do
		local u: Usage = { name = e.name, cpu = qty(e.values[1]), mem = qty(e.values[2]) }
		table.insert(list, u)
		cpu = if cpu and u.cpu then cpu + u.cpu else nil
		mem = if mem and u.mem then mem + u.mem else nil
	end
	if #list == 0 then
		return list, nil, nil
	end
	return list, cpu, mem
end

function M.podMetrics(text: string): { PodMetric }
	local out: { PodMetric } = {}
	for _, line in lines(text) do
		local f = fields(line, "\t")
		local ns, name = nonEmpty(f[1]), nonEmpty(f[2])
		if ns == nil or name == nil then
			continue
		end
		local list, cpu, mem = usages(f[5])
		table.insert(out, {
			namespace = ns,
			name = name,
			t = M.time(f[3]),
			window = nonEmpty(f[4]),
			containers = list,
			cpu = cpu,
			mem = mem,
		})
	end
	return out
end

-- The usage of one container of a pod metric; nil when not reported.
function M.container(m: PodMetric, name: string): Usage?
	for _, c in m.containers do
		if c.name == name then
			return c
		end
	end
	return nil
end

function M.nodes(text: string): { Node }
	local out: { Node } = {}
	for _, line in lines(text) do
		local f = fields(line, "\t")
		local name = nonEmpty(f[1])
		if name == nil then
			continue
		end
		local alloc = fields(f[2] or "", ",")
		local cap = fields(f[3] or "", ",")
		table.insert(out, {
			name = name,
			alloc = { cpu = qty(alloc[1]), mem = qty(alloc[2]), pods = qty(alloc[3]) },
			cap = res(cap[1], cap[2]),
			unschedulable = f[4] == "true",
			ready = nonEmpty(f[5]),
		})
	end
	return out
end

function M.nodeMetrics(text: string): { NodeMetric }
	local out: { NodeMetric } = {}
	for _, line in lines(text) do
		local f = fields(line, "\t")
		local name = nonEmpty(f[1])
		if name == nil then
			continue
		end
		local u = fields(f[4] or "", ",")
		table.insert(out, { name = name, t = M.time(f[2]), window = nonEmpty(f[3]), cpu = qty(u[1]), mem = qty(u[2]) })
	end
	return out
end

return M
