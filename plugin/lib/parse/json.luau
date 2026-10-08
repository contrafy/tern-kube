--!strict
-- Summarizes `kubectl ... -o json` output. Summary columns are derived only
-- from fields present in each object; status columns follow kubectl's own
-- printers (pkg/printers/internalversion) so they read the same as the table
-- the user would otherwise see. Ages are not computed: no clock is available
-- during replay, so CREATED shows creationTimestamp verbatim.
local Redact = require("../model/redact")
local Resource = require("../model/resource")
local Types = require("../model/types")

type Object = { [string]: any }
type Cells = { [string]: string }

export type Summary = { headers: { string }, cells: { string } }
export type Resource = { ref: Types.ResourceRef, object: Object, summary: Summary }
export type ParseKind = "list" | "object" | "invalid"
export type Result = { resources: { Resource }, diagnostics: { Types.Diagnostic }, kind: ParseKind }
export type Decode = (string) -> any

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

local function obj(v: any): Object?
	return if type(v) == "table" then v else nil
end

local EMPTY: { any } = table.freeze({})
local NONE: Object = table.freeze({})

local function list(v: any): { any }
	return if type(v) == "table" then v else EMPTY
end

local function int(n: number): string
	return string.format("%d", n)
end

local function hasTrueCondition(conditions: any, conditionType: string): boolean
	for _, c in ipairs(list(conditions)) do
		local cond = obj(c)
		if cond and cond.type == conditionType and cond.status == "True" then
			return true
		end
	end
	return false
end

local function terminatedReason(term: Object, prefix: string): string
	local reason = str(term.reason)
	if reason and reason ~= "" then
		return prefix .. reason
	end
	local signal = num(term.signal) or 0
	if signal ~= 0 then
		return prefix .. "Signal:" .. int(signal)
	end
	return prefix .. "ExitCode:" .. int(num(term.exitCode) or 0)
end

-- Mirrors kubectl printPod: init containers first, then regular containers in
-- reverse so the first container's state wins, then deletion overrides.
local function podCells(o: Object): Cells
	local out: Cells = {}
	local spec = obj(o.spec) or NONE
	local status = obj(o.status)
	local nodeName = str(spec.nodeName)
	if nodeName and nodeName ~= "" then
		out.NODE = nodeName
	end
	if not status then
		return out
	end

	local initSpecs = list(spec.initContainers)
	local total = #list(spec.containers)
	local restartableInit: { [string]: boolean } = {}
	for _, c in ipairs(initSpecs) do
		local container = obj(c)
		if container and container.restartPolicy == "Always" then
			total += 1
			local name = str(container.name)
			if name then
				restartableInit[name] = true
			end
		end
	end

	local reason = str(status.phase) or ""
	local statusReason = str(status.reason)
	if statusReason and statusReason ~= "" then
		reason = statusReason
	end
	for _, c in ipairs(list(status.conditions)) do
		local cond = obj(c)
		if cond and cond.type == "PodScheduled" and cond.reason == "SchedulingGated" then
			reason = "SchedulingGated"
		end
	end

	local ready, restarts, sidecarRestarts = 0, 0, 0
	local initializing = false
	for i, s in ipairs(list(status.initContainerStatuses)) do
		local cs = obj(s)
		if not cs then
			continue
		end
		local count = num(cs.restartCount) or 0
		restarts += count
		local name = str(cs.name)
		if name and restartableInit[name] then
			sidecarRestarts += count
			if cs.started == true and cs.ready == true then
				ready += 1
			end
			continue
		end
		local state = obj(cs.state) or NONE
		local term = obj(state.terminated)
		local waiting = obj(state.waiting)
		local waitingReason = if waiting then str(waiting.reason) else nil
		if term and (num(term.exitCode) or 0) == 0 then
			continue
		elseif term then
			reason = terminatedReason(term, "Init:")
		elseif waitingReason and waitingReason ~= "" and waitingReason ~= "PodInitializing" then
			reason = "Init:" .. waitingReason
		else
			reason = string.format("Init:%d/%d", i - 1, #initSpecs)
		end
		initializing = true
		break
	end

	if not initializing or hasTrueCondition(status.conditions, "Initialized") then
		restarts = sidecarRestarts
		local hasRunning = false
		local statuses = list(status.containerStatuses)
		for i = #statuses, 1, -1 do
			local cs = obj(statuses[i])
			if not cs then
				continue
			end
			restarts += num(cs.restartCount) or 0
			local state = obj(cs.state) or NONE
			local waiting = obj(state.waiting)
			local term = obj(state.terminated)
			local waitingReason = if waiting then str(waiting.reason) else nil
			if waitingReason and waitingReason ~= "" then
				reason = waitingReason
			elseif term then
				reason = terminatedReason(term, "")
			elseif cs.ready == true and obj(state.running) then
				hasRunning = true
				ready += 1
			end
		end
		if reason == "Completed" and hasRunning then
			reason = if hasTrueCondition(status.conditions, "Ready") then "Running" else "NotReady"
		end
	end

	local metadata = obj(o.metadata) or NONE
	if metadata.deletionTimestamp ~= nil then
		if status.reason == "NodeLost" then
			reason = "Unknown"
		elseif status.phase ~= "Succeeded" and status.phase ~= "Failed" then
			reason = "Terminating"
		end
	end

	out.READY = int(ready) .. "/" .. int(total)
	out.STATUS = reason
	out.RESTARTS = int(restarts)
	return out
end

local function deploymentCells(o: Object): Cells
	local out: Cells = {}
	local status = obj(o.status)
	if not status then
		return out
	end
	local spec = obj(o.spec)
	local desired = if spec then num(spec.replicas) else nil
	if desired then
		out.READY = int(num(status.readyReplicas) or 0) .. "/" .. int(desired)
	end
	out["UP-TO-DATE"] = int(num(status.updatedReplicas) or 0)
	out.AVAILABLE = int(num(status.availableReplicas) or 0)
	return out
end

local function serviceCells(o: Object): Cells
	local out: Cells = {}
	local spec = obj(o.spec)
	if not spec then
		return out
	end
	local serviceType = str(spec.type)
	if serviceType then
		out.TYPE = serviceType
	end
	local clusterIP = str(spec.clusterIP)
	if clusterIP and clusterIP ~= "" then
		out["CLUSTER-IP"] = clusterIP
	end
	local ports = {}
	for _, p in ipairs(list(spec.ports)) do
		local port = obj(p)
		if port then
			local text = int(num(port.port) or 0)
			local nodePort = num(port.nodePort) or 0
			if nodePort > 0 then
				text ..= ":" .. int(nodePort)
			end
			table.insert(ports, text .. "/" .. (str(port.protocol) or ""))
		end
	end
	out.PORTS = if #ports > 0 then table.concat(ports, ",") else "<none>"
	return out
end

local ROLE_PREFIX = "node-role.kubernetes.io/"

local function nodeCells(o: Object): Cells
	local out: Cells = {}
	local status = obj(o.status)
	local spec = obj(o.spec) or NONE
	if status then
		local readiness = "Unknown"
		for _, c in ipairs(list(status.conditions)) do
			local cond = obj(c)
			if cond and cond.type == "Ready" then
				readiness = if cond.status == "True" then "Ready" else "NotReady"
			end
		end
		out.STATUS = if spec.unschedulable == true then readiness .. ",SchedulingDisabled" else readiness
		local info = obj(status.nodeInfo)
		local version = if info then str(info.kubeletVersion) else nil
		if version then
			out.VERSION = version
		end
	end
	local metadata = obj(o.metadata) or NONE
	local roles = {}
	for k, v in pairs(obj(metadata.labels) or NONE) do
		if type(k) ~= "string" then
			continue
		end
		if string.sub(k, 1, #ROLE_PREFIX) == ROLE_PREFIX and #k > #ROLE_PREFIX then
			table.insert(roles, string.sub(k, #ROLE_PREFIX + 1))
		elseif k == "kubernetes.io/role" and type(v) == "string" and v ~= "" then
			table.insert(roles, v)
		end
	end
	table.sort(roles)
	out.ROLES = if #roles > 0 then table.concat(roles, ",") else "<none>"
	return out
end

local function jobCells(o: Object): Cells
	local out: Cells = {}
	local spec = obj(o.spec)
	local status = obj(o.status)
	if not spec or not status then
		return out
	end
	local succeeded = int(num(status.succeeded) or 0)
	local completions = num(spec.completions)
	local parallelism = num(spec.parallelism) or 0
	if completions then
		out.COMPLETIONS = succeeded .. "/" .. int(completions)
	elseif parallelism > 1 then
		out.COMPLETIONS = succeeded .. "/1 of " .. int(parallelism)
	else
		out.COMPLETIONS = succeeded .. "/1"
	end
	return out
end

local function conditionCells(o: Object): Cells
	local out: Cells = {}
	local status = obj(o.status)
	if not status or type(status.conditions) ~= "table" then
		return out
	end
	local parts = {}
	for _, c in ipairs(status.conditions) do
		local cond = obj(c)
		local condType = if cond then str(cond.type) else nil
		if cond and condType then
			table.insert(parts, condType .. "=" .. (str(cond.status) or "Unknown"))
		end
	end
	out.CONDITIONS = table.concat(parts, ",")
	return out
end

type Printer = { headers: { string }, cells: (Object) -> Cells }

local PRINTERS: { [string]: Printer } = {
	["/Pod"] = { headers = { "READY", "STATUS", "RESTARTS", "NODE" }, cells = podCells },
	["apps/Deployment"] = { headers = { "READY", "UP-TO-DATE", "AVAILABLE" }, cells = deploymentCells },
	["/Service"] = { headers = { "TYPE", "CLUSTER-IP", "PORTS" }, cells = serviceCells },
	["/Node"] = { headers = { "STATUS", "ROLES", "VERSION" }, cells = nodeCells },
	["batch/Job"] = { headers = { "COMPLETIONS" }, cells = jobCells },
}

local GENERIC: Printer = { headers = { "CONDITIONS" }, cells = conditionCells }

local function kindKey(ref: Types.ResourceRef): string
	return (ref.group or "") .. "/" .. ref.kind
end

type Group = { printer: Printer, members: { number }, derived: { Cells }, present: { [string]: boolean } }

local function summarize(refs: { Types.ResourceRef }, objects: { Object }): { Summary }
	local namespaces: { [string]: boolean } = {}
	local namespaceCount, kindCount = 0, 0
	local groups: { [string]: Group } = {}
	local order: { string } = {}
	for i, ref in refs do
		local ns = ref.namespace or ""
		if not namespaces[ns] then
			namespaces[ns] = true
			namespaceCount += 1
		end
		local key = kindKey(ref)
		local group = groups[key]
		if not group then
			group = { printer = PRINTERS[key] or GENERIC, members = {}, derived = {}, present = {} }
			groups[key] = group
			table.insert(order, key)
			kindCount += 1
		end
		local cells = group.printer.cells(objects[i])
		local metadata = obj(objects[i].metadata) or NONE
		local created = str(metadata.creationTimestamp)
		if created then
			cells.CREATED = created
		end
		for header in cells do
			group.present[header] = true
		end
		table.insert(group.members, i)
		table.insert(group.derived, cells)
	end

	local summaries: { Summary } = table.create(#refs)
	for _, key in order do
		local group = groups[key]
		local headers = {}
		if namespaceCount > 1 then
			table.insert(headers, "NAMESPACE")
		end
		if kindCount > 1 then
			table.insert(headers, "KIND")
		end
		table.insert(headers, "NAME")
		for _, header in group.printer.headers do
			if group.present[header] then
				table.insert(headers, header)
			end
		end
		if group.present.CREATED then
			table.insert(headers, "CREATED")
		end
		table.freeze(headers)
		for j, index in group.members do
			local ref = refs[index]
			local derived = group.derived[j]
			local cells = table.create(#headers)
			for h, header in headers do
				if header == "NAMESPACE" then
					cells[h] = ref.namespace or ""
				elseif header == "KIND" then
					cells[h] = ref.kind
				elseif header == "NAME" then
					cells[h] = ref.name
				else
					cells[h] = derived[header] or ""
				end
			end
			summaries[index] = { headers = headers, cells = cells }
		end
	end
	return summaries
end

local function isListKind(kind: any): boolean
	return type(kind) == "string" and (kind == "List" or (#kind > 4 and string.sub(kind, -4) == "List"))
end

local function invalid(diagnostics: { Types.Diagnostic }, text: string, line: number?): Result
	table.insert(diagnostics, { line = line, severity = "error", text = text })
	return { resources = {}, diagnostics = diagnostics, kind = "invalid" }
end

local function tryDecode(decode: Decode, text: string): (boolean, any)
	local ok, value = pcall(decode, text)
	if ok then
		return true, value
	end
	return false, if type(value) == "string" then value else "JSON decode failed"
end

local function splitLines(text: string): { string }
	local lines = string.split(text, "\n")
	for i, line in lines do
		if string.sub(line, -1) == "\r" then
			lines[i] = string.sub(line, 1, -2)
		end
	end
	return lines
end

local function strayLine(diagnostics: { Types.Diagnostic }, line: string, index: number)
	if string.match(line, "^%s*$") then
		return
	end
	local severity: "warning" | "error" = if string.sub(line, 1, 8) == "Warning:" then "warning" else "error"
	table.insert(diagnostics, { line = index, severity = severity, text = line })
end

-- kubectl pretty-prints JSON with the outer braces in column 1; anything
-- before the first or after the last such line is interleaved stderr.
local function decodeStripped(text: string, decode: Decode, diagnostics: { Types.Diagnostic }): (boolean, any)
	local lines = splitLines(text)
	local first, last
	for i, line in lines do
		local c = string.sub(line, 1, 1)
		if c == "{" or c == "[" then
			first = i
			break
		end
	end
	if not first then
		return false, "no JSON document found"
	end
	for i = #lines, first, -1 do
		local trimmed = string.match(lines[i], "^(.-)%s*$") :: string
		if
			trimmed == "}"
			or trimmed == "]"
			or (i == first and (string.sub(trimmed, -1) == "}" or string.sub(trimmed, -1) == "]"))
		then
			last = i
			break
		end
	end
	if not last then
		return false, "JSON document is incomplete (output truncated?)"
	end
	local ok, value = tryDecode(decode, table.concat(lines, "\n", first, last))
	if not ok then
		return false, value
	end
	for i = 1, first - 1 do
		strayLine(diagnostics, lines[i], i)
	end
	for i = last + 1, #lines do
		strayLine(diagnostics, lines[i], i)
	end
	return true, value
end

local function parse(text: string, decode: Decode): Result
	local diagnostics: { Types.Diagnostic } = {}
	local ok, value = tryDecode(decode, text)
	if not ok then
		local message = value
		ok, value = decodeStripped(text, decode, diagnostics)
		if not ok then
			return invalid(diagnostics, "invalid JSON: " .. tostring(if value then value else message))
		end
	end
	local top = obj(value)
	if not top or type(top.kind) ~= "string" then
		return invalid(diagnostics, "JSON is not a Kubernetes object")
	end

	local candidates: { any }
	local kind: ParseKind
	if isListKind(top.kind) and (top.items == nil or type(top.items) == "table") then
		candidates = list(top.items)
		kind = "list"
	else
		candidates = { top }
		kind = "object"
	end

	local refs: { Types.ResourceRef } = {}
	local objects: { Object } = {}
	for i, item in ipairs(candidates) do
		local o = obj(item)
		local ref = if o then Resource.fromObject(o, "snapshot") else nil
		if o and ref then
			table.insert(refs, ref)
			table.insert(objects, o)
		else
			table.insert(diagnostics, {
				severity = "warning",
				text = string.format("item %d has no kind or metadata.name; skipped", i),
			})
		end
	end
	if kind == "object" and #refs == 0 then
		return invalid(diagnostics, "JSON object has no kind or metadata.name")
	end

	local summaries = summarize(refs, objects)
	local resources: { Resource } = table.create(#refs)
	for i, ref in refs do
		resources[i] = { ref = ref, object = objects[i], summary = summaries[i] }
	end
	return { resources = resources, diagnostics = diagnostics, kind = kind }
end

local LAST_APPLIED = "kubectl.kubernetes.io/last-applied-configuration"
local SECRET_VALUES: { [string]: boolean } = { data = true, stringData = true }

local function maskValues(values: any, suffix: string): (any, boolean)
	local source = obj(values)
	if not source then
		return values, false
	end
	local masked = {}
	local changed = false
	for k, v in pairs(source) do
		local m = Redact.maskValue(v, suffix)
		masked[k] = m
		changed = changed or m ~= v
	end
	return masked, changed
end

-- The annotation is a verbatim copy of the applied manifest: it leaks
-- whatever was masked elsewhere in the object.
local function maskLastApplied(source: Object): (Object, boolean)
	local metadata = obj(source.metadata)
	local annotations = if metadata then obj(metadata.annotations) else nil
	if metadata == nil or annotations == nil then
		return source, false
	end
	local value = annotations[LAST_APPLIED]
	if value == nil or Redact.isMask(value) then
		return source, false
	end
	local maskedAnnotations = table.clone(annotations)
	maskedAnnotations[LAST_APPLIED] = Redact.maskValue(value)
	local maskedMetadata = table.clone(metadata)
	maskedMetadata.annotations = maskedAnnotations
	local copy = table.clone(source)
	copy.metadata = maskedMetadata
	return copy, true
end

local function maskable(v: any): boolean
	return (type(v) == "string" or type(v) == "number") and not Redact.isMask(v)
end

-- Strict mode: scalar values under sensitive keys, and the `value` of
-- `{name, value}` entries (container env) with a sensitive name. Copies only
-- the tables on the path to a change.
local function strictWalk(value: any, skip: { [string]: boolean }?): (any, boolean)
	if type(value) ~= "table" then
		return value, false
	end
	local copy: Object? = nil
	local name = value.name
	if type(name) == "string" and maskable(value.value) and Redact.sensitiveKey(name) then
		copy = table.clone(value);
		(copy :: Object).value = Redact.maskValue(value.value)
	end
	for k, v in pairs(value) do
		if skip and type(k) == "string" and skip[k] then
			continue
		end
		local out = v
		if type(v) == "table" then
			out = strictWalk(v, nil)
		elseif type(k) == "string" and maskable(v) and Redact.sensitiveKey(k) then
			out = Redact.maskValue(v)
		end
		if out ~= v then
			copy = copy or table.clone(value);
			(copy :: Object)[k] = out
		end
	end
	return copy or value, copy ~= nil
end

-- For native display only: masks on a copy what `policy` hides (Secret
-- values and their last-applied copy unless showSecrets; strict-mode
-- matches); the original object, used by Raw view, is never modified.
-- Returns the object itself when nothing is hidden, and whether anything was.
local function redactObject(source: Object, policy: Redact.Policy?): (Object, boolean)
	local p = policy or Redact.DEFAULT
	local out, masked = source, false
	local secret = source.kind == "Secret"
	if secret and not p.showSecrets then
		local copy = table.clone(source)
		local data, stringData, annotation
		copy.data, data = maskValues(source.data, " base64")
		copy.stringData, stringData = maskValues(source.stringData, "")
		out, annotation = maskLastApplied(copy)
		masked = data or stringData or annotation
	end
	if p.strict then
		local walked, found = strictWalk(out, if secret then SECRET_VALUES else nil)
		if found then
			out = maskLastApplied(walked)
			masked = true
		end
	end
	return out, masked
end

local function redactSecrets(resource: Resource, policy: Redact.Policy?): (Object, boolean)
	return redactObject(resource.object, policy)
end

return {
	parse = parse,
	redactSecrets = redactSecrets,
	redactObject = redactObject,
}
