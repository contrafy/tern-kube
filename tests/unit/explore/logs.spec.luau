--!strict
-- Explore's logs route: kubectl logs read once with exact times and
-- attribution, parsed by lib/logs into records the keyboard can walk (errors,
-- level floor, search, containers, previous instance, inspector), opened by
-- `L` or by a lens link that may name only a selector.
local LogsParse = require("../../../plugin/lib/logs/parse")
local LogsQuery = require("../../../plugin/lib/logs/query")
local LogsStore = require("../../../plugin/lib/logs/store")
local Render = require("../../../plugin/lib/explore/render")
local State = require("../../../plugin/lib/explore/state")
local W = require("../../lib/explore")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect

local SELECTOR_LINK: { [string]: string } = {
	context = W.CTX,
	namespace = "tern-test-logs",
	route = "logs",
	selector = "app%3Dtk-logmix",
}

local function top(s: State): State.Route
	return s.stack[#s.stack]
end

local function data(s: State): State.LogsData
	local load = State.currentLoad(s) :: State.Load
	expect(load.status).toBe("ok")
	return load.data :: State.LogsData
end

local function record(s: State, key: string?): any
	return LogsStore.get(data(s).store, tonumber(key or "") or 0)
end

local function selected(s: State): any
	local item = State.selectedItem(s) :: State.Item
	return record(s, item.key)
end

local function lastRun(trace: W.Trace): { string }
	return trace.runs[#trace.runs].argv :: { string }
end

local function typeText(s: State, text: string): State
	local names = { "/" }
	for i = 1, #text do
		table.insert(names, string.sub(text, i, i))
	end
	table.insert(names, "enter")
	return (W.keys(s, names))
end

local function isError(rec: any): boolean
	return LogsParse.rank(rec.level) >= LogsParse.rank("error")
end

local function openSelector(extra: { [string]: string }?): (State, W.Trace)
	local p: { [string]: string } = table.clone(SELECTOR_LINK)
	local more: { [string]: string } = extra or {}
	for k, v in more do
		p[k] = v
	end
	return W.open(p)
end

describe("explore logs: reading", function()
	it("L reads every container with kubelet times and prefixes, as many lines as explore.logs_tail", function()
		local s = W.open(nil, W.config('{"explore":{"logs_tail":42}}'))
		local _, trace = W.keys(s, { "L" })
		local argv = lastRun(trace)
		expect(argv).toContain("logs")
		expect(argv).toContain("--all-containers")
		expect(argv).toContain("--timestamps")
		expect(argv).toContain("--prefix")
		expect(argv).toContain("--tail=42")
	end)

	it("lines become records of every source, merged by kubelet time, newest selected", function()
		local s = W.keys(W.open(), { "L" })
		local d = data(s)
		local containers: { string } = {}
		for _, src in d.store.sources do
			table.insert(containers, src.container :: string)
		end
		expect(containers).toEqual({ "app", "side", "crashy" })
		local items = State.items(s)
		expect(#items).toBe(LogsStore.size(d.store))
		local prev = ""
		for _, item in items do
			local key = LogsQuery.sortKey((record(s, item.key) :: any).ts)
			expect(key >= prev).toBe(true)
			prev = key
		end
		expect((State.selectedItem(s) :: State.Item).key).toBe(items[#items].key)
	end)

	-- The Java stack in the capture is three lines; as one record its frames
	-- cannot be filtered away from the exception.
	it("continuation lines stay with their record", function()
		local s = W.keys(W.open(), { "L" })
		local found = false
		for _, item in State.items(s) do
			local rec = record(s, item.key)
			if string.find(rec.message, "IllegalStateException", 1, true) then
				found = true
				expect(rec.level).toBe("error")
				expect(#(rec.extra :: { string })).toBe(2)
			end
		end
		expect(found).toBe(true)
	end)
end)

describe("explore logs: keys", function()
	it("] from no selection jumps to the first error, ] [ step between errors", function()
		local s = W.keys(W.open(), { "L" })
		local items = State.items(s)
		local firstError: string? = nil
		local secondError: string? = nil
		for _, item in items do
			if isError(record(s, item.key)) then
				if firstError == nil then
					firstError = item.key
				elseif secondError == nil then
					secondError = item.key
				end
			end
		end
		s = W.keys(s, { "]" })
		expect((State.selectedItem(s) :: State.Item).key).toBe(firstError)
		s = W.keys(s, { "]" })
		expect((State.selectedItem(s) :: State.Item).key).toBe(secondError)
		s = W.keys(s, { "[" })
		expect((State.selectedItem(s) :: State.Item).key).toBe(firstError)
		local _, effects = State.update(s, W.key("["))
		expect(effects[1].t).toBe("toast")
		expect(effects[1].text).toBe("No more errors above")
	end)

	it("x raises the level floor (warnings+, errors+) and comes back to every level", function()
		local s = W.keys(W.open(), { "L" })
		local all = #State.items(s)
		s = W.keys(s, { "x" })
		expect(top(s).floor).toBe("warn")
		for _, item in State.items(s) do
			expect(LogsParse.rank(record(s, item.key).level) >= LogsParse.rank("warn")).toBe(true)
		end
		s = W.keys(s, { "x" })
		expect(top(s).floor).toBe("error")
		for _, item in State.items(s) do
			expect(isError(record(s, item.key))).toBe(true)
		end
		s = W.keys(s, { "x" })
		expect(top(s).floor).toBeNil()
		expect(#State.items(s)).toBe(all)
	end)

	it("/ searches messages, fields and the pod/container of each line", function()
		local s = typeText(W.keys(W.open(), { "L" }), "side")
		local items = State.items(s)
		expect(#items > 0).toBe(true)
		for _, item in items do
			local rec = record(s, item.key)
			local src = data(s).store.sources[rec.source]
			local hit = src.container == "side" or string.find(string.lower(rec.message), "side", 1, true) ~= nil
			expect(hit).toBe(true)
		end
		s = typeText((W.action(s, "filter-clear")), "tick 4 failed")
		expect(#State.items(s)).toBe(1)
		expect(selected(s).message).toBe("tick 4 failed")
	end)

	it("a cycles all containers, then each one, then all again, keeping the search", function()
		local s = openSelector()
		s = typeText(s, "tick")
		local order: { string } = {}
		local runs: { { string } } = {}
		for _ = 1, 4 do
			local trace
			s, trace = W.keys(s, { "a" })
			table.insert(order, top(s).container or "all")
			table.insert(runs, if #trace.runs > 0 then lastRun(trace) else {})
			expect(s.filter[State.currentKey(s)]).toBe("tick")
		end
		-- Sources in order of appearance: the selector capture starts with a
		-- crashy line.
		expect(order).toEqual({ "crashy", "app", "side", "all" })
		expect(runs[1]).toContain("crashy")
		expect(table.find(runs[1], "--all-containers")).toBeNil()
		-- Back to every container: the first read is still cached.
		expect(runs[4]).toEqual({})
	end)

	it("o asks for the previous instance; without one the error says so instead of 'not found'", function()
		local s = W.keys(W.open(), { "L" })
		local trace
		s, trace = W.keys(s, { "o" })
		expect(top(s).previous).toBe(true)
		expect(lastRun(trace)).toContain("--previous")
		local load = State.currentLoad(s) :: State.Load
		expect(load.status).toBe("error")
		expect(load.error :: string).toContain("No previous instance")
		expect(load.errorKind).toBe("previous")
		s = W.keys(s, { "o" })
		expect(top(s).previous).toBeNil()
		expect((State.currentLoad(s) :: State.Load).status).toBe("ok")
	end)

	-- B8: with every container, `kubectl logs --previous --all-containers`
	-- fails as a whole when one container never restarted, hiding the
	-- previous logs of the one that did.
	local POD = "tk-logmix-6856789c59-kh4x5"
	local function logmix(restarted: { string }): W.Responder
		local statuses: { any } = {}
		for _, name in { "app", "side", "crashy" } do
			local last = if table.find(restarted, name) then { terminated = { exitCode = 1 } } else {}
			table.insert(
				statuses,
				{ name = name, restartCount = if table.find(restarted, name) then 3 else 0, lastState = last }
			)
		end
		local pod = {
			apiVersion = "v1",
			kind = "Pod",
			metadata = { name = POD, namespace = "tern-test-logs" },
			spec = { containers = { { name = "app" }, { name = "side" }, { name = "crashy" } } },
			status = { phase = "Running", containerStatuses = statuses },
		}
		return function(argv: { string }): (W.Result?, string?)
			if table.find(argv, "get") and table.find(argv, POD) then
				return {
					status = 0,
					stdout = W.token("@pod:" .. table.concat(restarted, ","), pod),
					stderr = "",
					timed_out = false,
				}
			end
			return W.responder(argv)
		end
	end

	local function previousOf(restarted: { string }): (State, W.Trace)
		local s, effects = State.init({
			W.link({ context = W.CTX, namespace = "tern-test-logs", kind = "Pod", name = POD, route = "logs" }),
		}, nil, W.config(nil), W.env())
		s = W.settle(s, effects, logmix(restarted))
		local s2, more = State.update(s, W.key("o"))
		return W.settle(s2, more, logmix(restarted))
	end

	it("o with every container reads the previous instance of each container that has one", function()
		local s, trace = previousOf({ "crashy" })
		local logsRuns: { string } = {}
		for _, run in trace.runs do
			local argv = run.argv :: { string }
			if table.find(argv, "logs") then
				table.insert(logsRuns, table.concat(argv, " "))
			end
		end
		expect(#logsRuns).toBe(1)
		expect(logsRuns[1]).toContain("-c crashy --previous")
		local d = data(s)
		expect(LogsStore.size(d.store) > 0).toBe(true)
		local notes: { string } = {}
		for _, n in d.store.notices do
			table.insert(notes, n.text)
		end
		expect(table.concat(notes, "\n")).toContain("no previous instance: app, side")
	end)

	it("a container whose previous read fails is noted; the others still show", function()
		local s, trace = previousOf({ "side", "crashy" })
		local containers: { string } = {}
		for _, run in trace.runs do
			local argv = run.argv :: { string }
			local c = table.find(argv, "-c")
			if table.find(argv, "--previous") and c then
				table.insert(containers, argv[c + 1])
			end
		end
		expect(containers).toEqual({ "side", "crashy" })
		local d = data(s)
		expect(LogsStore.size(d.store) > 0).toBe(true)
		local notes: { string } = {}
		for _, n in d.store.notices do
			table.insert(notes, n.text)
		end
		expect(table.concat(notes, "\n")).toContain('previous terminated container "side"')
	end)

	it("enter opens the selected line's inspector; esc closes it before leaving", function()
		local s = W.keys(W.open(), { "L", "enter" })
		expect(top(s).inspect).toBe(true)
		s = W.keys(s, { "w" })
		expect(top(s).wrap).toBe(true)
		s = W.keys(s, { "escape" })
		expect(top(s).kind).toBe("logs")
		expect(top(s).inspect).toBeNil()
		s = W.keys(s, { "escape" })
		expect(top(s).kind).toBe("list")
	end)

	it("copies the line as kubectl printed it, its message, or its JSON payload", function()
		local s = typeText(W.keys(W.open(), { "L" }), "server started")
		local item = State.selectedItem(s) :: State.Item
		local _, line = State.update(s, { t = "action", act = "lcopy", value = "line:" .. item.key })
		expect(line[1].text :: string).toContain("[pod/tk-logmix-6856789c59-kh4x5/app] 2026-11-02T")
		local _, msg = State.update(s, { t = "action", act = "lcopy", value = "msg:" .. item.key })
		expect(msg[1].text).toBe("server started")
		local _, js = State.update(s, { t = "action", act = "lcopy", value = "json:" .. item.key })
		expect(js[1].text).toBe('{"level":"info","ts":"2026-10-30T10:00:00Z","msg":"server started","port":8080}')
	end)

	-- x is global since track 5 (compare across contexts); logs and events
	-- shadow it, covered above.
	it("route keys do not leak: w, a and ] stay unbound outside logs and events", function()
		local s = W.open()
		for _, k in { "w", "a", "]", "[", "o" } do
			local s2 = State.update(s, W.key(k))
			expect(s2 == s).toBe(true)
		end
	end)
end)

describe("explore logs: links", function()
	it("route=logs opens the logs of the object with the lens's container, previous, since and tail", function()
		local s, trace = W.open({
			context = W.CTX,
			namespace = W.NS,
			kind = "Pod",
			name = "crashloop",
			route = "logs",
			container = "crashy",
			previous = "1",
			since = "2h",
			tail = "50",
			q = "panic",
		})
		local kinds: { string } = {}
		for _, r in s.stack do
			table.insert(kinds, r.kind)
		end
		expect(kinds).toEqual({ "list", "detail", "logs" })
		local argv = lastRun(trace)
		for _, a in { "crashloop", "-c", "crashy", "--previous", "--since=2h", "--tail=50" } do
			expect(argv).toContain(a)
		end
		expect(s.filter[State.currentKey(s)]).toBe("panic")
		expect(selected(s).message).toContain("panic: runtime error")
	end)

	-- Link text reaches kubectl's argv: anything that is not what it claims
	-- to be is dropped rather than passed on.
	it("invalid link values are dropped and the route still opens", function()
		local s, trace = W.open({
			context = W.CTX,
			namespace = W.NS,
			kind = "Pod",
			name = "crashloop",
			route = "logs",
			container = "Bad_Name",
			since = "1d%3Brm",
			tail = "abc",
			q = "x%01y",
		})
		local r = top(s)
		expect(r.kind).toBe("logs")
		expect(r.container).toBeNil()
		expect(r.since).toBeNil()
		expect(r.tail).toBeNil()
		local argv = lastRun(trace)
		expect(argv).toContain("--tail=500")
		expect(argv).toContain("--all-containers")
		expect(s.filter[State.currentKey(s)]).toBeNil()
		expect(State.validSelector("app=x;rm -rf")).toBeNil()
		expect(State.validSelector("app in (a,b),!gone")).toBe("app in (a,b),!gone")
		expect(State.validTail("-1")).toBe(-1)
		expect(State.validTail("-2")).toBeNil()
		expect(State.validTail("12345678")).toBeNil()
	end)

	it("a selector-only link reads -l in the link's namespace and is titled by its selector", function()
		local s, trace = openSelector()
		expect(top(s).ref).toBeNil()
		local argv = lastRun(trace)
		local i = table.find(argv, "-l") :: number
		expect(argv[i + 1]).toBe("app=tk-logmix")
		expect(argv).toContain("tern-test-logs")
		expect(argv).toContain("--max-log-requests=10")
		expect(Render.title(s)).toContain("Logs -l app=tk-logmix")
		expect(#State.items(s) > 0).toBe(true)
	end)

	it("l on a selector-only route follows the same selector in a split", function()
		local s = openSelector()
		local _, effects = State.update(s, W.key("l"))
		expect(effects[1].t).toBe("open")
		local url = effects[1].url :: string
		expect(url).toContain("logs-follow?")
		expect(url).toContain("selector=app%3Dtk-logmix")
		expect(url).toContain("namespace=tern-test-logs")
	end)

	-- The lens's "Search…" chip: the filter field must take the keyboard,
	-- but only once the block is up (after the target resolved).
	it("search=1 focuses the filter after the target resolves, with the query in it", function()
		local s, trace = openSelector({ search = "1", q = "tick" })
		expect(s.editing).toBe(true)
		expect(s.searchPending).toBe(false)
		local focus: Effect? = nil
		for _, e in trace.effects do
			if e.t == "focus" then
				focus = e
			end
		end
		expect((focus :: Effect).id).toBe(State.FILTER_INPUT)
		expect(s.filter[State.currentKey(s)]).toBe("tick")
	end)

	it("a saved selector-only route comes back; an invalid one does not", function()
		local s = W.keys(openSelector(), { "x", "w" })
		local saved = State.save(s)
		local again = State.init({}, saved, W.config(nil), W.env())
		local r = again.stack[#again.stack]
		expect(r.kind).toBe("logs")
		expect(r.selector).toBe("app=tk-logmix")
		expect(r.floor).toBe("warn")
		expect(r.wrap).toBe(true)
		saved.stack[#saved.stack].selector = "a;b"
		local bad = State.init({}, saved, W.config(nil), W.env())
		expect(bad.stack[#bad.stack].kind).toBe("list")
	end)
end)

return nil
