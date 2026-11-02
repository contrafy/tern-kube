--!strict
-- Incremental store of one `kubectl logs` run: `push` per delivered line,
-- `finish` once with the exit status. Replaying the same lines rebuilds the
-- same store (same record indices), which is how a reloaded lens rehydrates.
--
-- Ring: only the newest `limits.maxLines` records and at most
-- `limits.maxBytes` of their text are kept (`records[first..last]`); older
-- ones are only in Raw (`dropped`, one "dropped" notice). `counts` and
-- `sourceCounts` are totals over every record ever pushed (the header shows
-- totals); filters run on kept records. `firstError` is the first KEPT
-- record at error level or above, so a jump target always exists.
local Parse = require("./parse")
local T = require("./types")

type Level = T.Level
type Record = T.Record
type Notice = T.Notice

export type Store = {
	opts: T.Options,
	limits: T.Limits,
	records: { Record },
	-- records[first..last] are kept; last = index of the newest record.
	first: number,
	last: number,
	dropped: number,
	-- Bytes of kept records: delivered lines plus continuation payloads.
	bytes: number,
	-- Delivered lines, including diagnostics and continuations.
	lines: number,
	sources: { T.Source },
	counts: { [Level]: number },
	sourceCounts: { [number]: number },
	notices: { Notice },
	firstError: number?,
	status: number?,
	stopped: boolean,
	-- Source of unprefixed lines (0 = unattributed).
	defaultSource: number,
	sourceKeys: { [string]: number },
	-- Newest record per source, for continuation lines.
	lastOf: { [number]: number },
	-- Source of the previous delivered line, nil after a diagnostic.
	prevSource: number?,
}

local M = {}

local ERROR_RANK = Parse.rank("error")

local function addSource(s: Store, pod: string?, container: string?): number
	table.insert(s.sources, { pod = pod, container = container })
	local idx = #s.sources
	s.sourceCounts[idx] = 0
	return idx
end

function M.new(opts: T.Options, limits: T.Limits): Store
	local s: Store = {
		opts = opts,
		limits = limits,
		records = {},
		first = 1,
		last = 0,
		dropped = 0,
		bytes = 0,
		lines = 0,
		sources = {},
		counts = { fatal = 0, error = 0, warn = 0, info = 0, debug = 0, trace = 0, none = 0 },
		sourceCounts = { [0] = 0 },
		notices = {},
		firstError = nil,
		status = nil,
		stopped = false,
		defaultSource = 0,
		sourceKeys = {},
		lastOf = {},
		prevSource = nil,
	}
	-- Unprefixed lines belong to one source unless several pods or containers
	-- interleave without attribution (`-l`, `--all-pods`, `--all-containers`).
	if not opts.prefix and not opts.multiPod then
		local container = if opts.allContainers then nil else opts.container
		if opts.pod or container then
			s.defaultSource = addSource(s, opts.pod, container)
		end
	end
	return s
end

local function addNotice(s: Store, n: Notice)
	for _, e in s.notices do
		if e.kind == n.kind and e.text == n.text then
			return
		end
	end
	table.insert(s.notices, n)
end

local function defaultSource(s: Store): T.Source?
	if s.opts.prefix or s.opts.multiPod then
		return nil
	end
	if s.defaultSource == 0 then
		s.defaultSource = addSource(s, nil, nil)
	end
	return s.sources[s.defaultSource]
end

local function onDiagnostic(s: Store, n: Notice)
	addNotice(s, n)
	if n.kind == "found-pods" then
		local src = defaultSource(s)
		if src and src.pod == nil then
			src.pod = n.pod
		end
	elseif n.kind == "defaulted-container" and not s.opts.allContainers then
		local src = defaultSource(s)
		if src and src.container == nil then
			src.container = n.container
		end
	end
end

local function sourceFor(s: Store, pod: string, container: string): number
	local key = pod .. "/" .. container
	local idx = s.sourceKeys[key]
	if idx == nil then
		idx = addSource(s, pod, container)
		s.sourceKeys[key] = idx
	end
	return idx
end

local function recordBytes(r: Record): number
	local n = #r.raw
	if r.extra then
		for _, l in r.extra do
			n += #l
		end
	end
	return n
end

local function rescanFirstError(s: Store, from: number)
	for i = math.max(from, s.first), s.last do
		if Parse.rank(s.records[i].level) >= ERROR_RANK then
			s.firstError = i
			return
		end
	end
	s.firstError = nil
end

local function evict(s: Store)
	local before = s.dropped
	while s.last - s.first + 1 > s.limits.maxLines or (s.bytes > s.limits.maxBytes and s.last > s.first) do
		local r = s.records[s.first]
		s.records[s.first] = nil
		s.bytes -= recordBytes(r)
		s.first += 1
		s.dropped += 1
	end
	if s.dropped == before then
		return
	end
	local fe = s.firstError
	if fe and fe < s.first then
		rescanFirstError(s, fe + 1)
	end
	local text = string.format("%d earlier lines only in Raw", s.dropped)
	for _, n in s.notices do
		if n.kind == "dropped" then
			n.text = text
			return
		end
	end
	table.insert(s.notices, { kind = "dropped", text = text })
end

local function attach(s: Store, r: Record, payload: string)
	local extra: { string } = r.extra or {}
	r.extra = extra
	if #extra < Parse.MAX_EXTRA then
		table.insert(extra, payload)
		s.bytes += #payload
	else
		r.more = (r.more or 0) + 1
	end
end

function M.push(s: Store, line: string)
	s.lines += 1
	local text = if string.byte(line, -1) == 13 then string.sub(line, 1, -2) else line
	local diag = Parse.diagnostic(text, "start")
	if diag then
		onDiagnostic(s, diag)
		s.prevSource = nil
		return
	end
	local source = s.defaultSource
	local rest = text
	if s.opts.prefix then
		local pod, container, after = Parse.splitPrefix(text)
		rest = after
		source = if pod and container then sourceFor(s, pod, container) else 0
	end
	local ts: string? = nil
	if s.opts.timestamps then
		ts, rest = Parse.splitTimestamp(rest)
	end
	if rest ~= text then
		local inner = Parse.diagnostic(rest, "start")
		if inner and inner.kind == "error" then
			addNotice(s, inner)
			s.prevSource = nil
			return
		end
	end
	if Parse.isContinuation(rest) or (s.prevSource == source and Parse.isIndented(rest)) then
		local idx = s.lastOf[source]
		local r = if idx and idx >= s.first then s.records[idx] else nil
		if r then
			attach(s, r, rest)
			s.prevSource = source
			evict(s)
			return
		end
	end
	local c = Parse.classify(rest, s.opts.decode)
	s.last += 1
	local idx = s.last
	s.records[idx] = {
		index = idx,
		source = source,
		ts = ts,
		appTime = c.appTime,
		level = c.level,
		format = c.format,
		message = c.message,
		fields = c.fields,
		location = c.location,
		raw = text,
		extra = nil,
		more = nil,
	}
	s.counts[c.level] += 1
	s.sourceCounts[source] = (s.sourceCounts[source] or 0) + 1
	s.lastOf[source] = idx
	s.prevSource = source
	s.bytes += #text
	if s.firstError == nil and Parse.rank(c.level) >= ERROR_RANK then
		s.firstError = idx
	end
	evict(s)
end

local function removeLast(s: Store)
	local r = s.records[s.last]
	s.records[s.last] = nil
	s.last -= 1
	s.counts[r.level] -= 1
	s.sourceCounts[r.source] -= 1
	s.bytes -= recordBytes(r)
	if s.firstError == r.index then
		s.firstError = nil
	end
	if s.lastOf[r.source] == r.index then
		s.lastOf[r.source] = nil
	end
end

-- Trailing lines that are not the program's output leave the records: the
-- shell's partial-line mark, the echoed `^C` of a Ctrl-C (status 1, plan F6)
-- and, when kubectl failed, its closing error/warning lines.
function M.finish(s: Store, status: number)
	s.status = status
	local interrupted = false
	local trailing: { Notice } = {}
	while s.last >= s.first do
		local r = s.records[s.last]
		if r.extra or r.more then
			break
		end
		if Parse.isPromptMark(r.raw) then
			removeLast(s)
		else
			local n = Parse.diagnostic(r.raw, "end")
			if n and n.kind == "interrupted" then
				interrupted = true
				removeLast(s)
			elseif n and status ~= 0 and (n.kind == "error" or n.kind == "warning") then
				table.insert(trailing, 1, n)
				removeLast(s)
			else
				break
			end
		end
	end
	for _, n in trailing do
		addNotice(s, n)
	end
	if interrupted and status ~= 0 then
		s.stopped = true
		addNotice(s, { kind = "interrupted", text = "stopped (Ctrl-C)" })
	end
end

function M.get(s: Store, index: number): Record?
	if index < s.first or index > s.last then
		return nil
	end
	return s.records[index]
end

function M.size(s: Store): number
	return s.last - s.first + 1
end

return M
