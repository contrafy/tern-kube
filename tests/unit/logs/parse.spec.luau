--!strict
-- The logs line grammar (plan 4.2) on the exact lines kubectl and the
-- tk-logmix sampler print, plus the cases where Tern's built-in logs lens
-- gets the line wrong (plan section 2) as named regressions.
local t = require("../../lib/test")
local json = require("../../lib/json")
local Argv = require("../../../plugin/lib/kubectl/argv")
local Parse = require("../../../plugin/lib/logs/parse")
local describe, it, expect = t.describe, t.it, t.expect

local decode = json.decode

local function classify(line: string): Parse.Classified
	return Parse.classify(line, decode)
end

local function opts(args: { string })
	return Parse.optionsFor(Argv.parse("kubectl", args), decode)
end

describe("logs parse: optionsFor", function()
	it("reads prefix, timestamps and follow from the flags so the grammar only strips what kubectl added", function()
		local o = opts({ "logs", "-f", "-l", "app=x", "--prefix", "--timestamps" })
		expect(o.prefix).toBe(true)
		expect(o.timestamps).toBe(true)
		expect(o.follow).toBe(true)
		expect(o.multiPod).toBe(true)
		expect(o.pod).toBeNil()
	end)

	it("honours explicit =false so `--prefix=false` lines are not mistaken for prefixed ones", function()
		local o = opts({ "logs", "pod", "--prefix=false", "--timestamps=true", "--follow=false" })
		expect(o.prefix).toBe(false)
		expect(o.timestamps).toBe(true)
		expect(o.follow).toBe(false)
	end)

	it("knows pod and container of a single-source run so unprefixed lines can be attributed", function()
		local o = opts({ "-n", "ns", "logs", "web-1", "-c", "app" })
		expect(o.pod).toBe("web-1")
		expect(o.container).toBe("app")
		local typed = opts({ "logs", "deploy/web" })
		expect(typed.pod).toBeNil()
		expect(opts({ "logs", "pod/web-1" }).pod).toBe("web-1")
	end)

	it("drops -c under --all-containers because lines of every container interleave unattributed", function()
		local o = opts({ "logs", "web-1", "--all-containers", "-c", "app" })
		expect(o.container).toBeNil()
		expect(o.allContainers).toBe(true)
	end)
end)

describe("logs parse: diagnostics", function()
	it("recognises `Found N pods` with the chosen pod so the pod becomes the source", function()
		local n = Parse.diagnostic("Found 2 pods, using pod/tk-logmix-6856789c59-nthxv", "start")
		expect(n and n.kind).toBe("found-pods")
		expect(n and n.pod).toBe("tk-logmix-6856789c59-nthxv")
	end)

	it("recognises `Defaulted container` with the defaulted name and the container list for chips", function()
		local n = Parse.diagnostic('Defaulted container "app" out of: app, side, crashy', "start")
		expect(n and n.kind).toBe("defaulted-container")
		expect(n and n.container).toBe("app")
		expect(n and n.containers).toEqual({ "app", "side", "crashy" })
	end)

	it("treats `unable to retrieve container logs` as an error at any position (stdout, exit 0 on -p)", function()
		local n = Parse.diagnostic("unable to retrieve container logs for containerd://7e42e72966", "start")
		expect(n and n.kind).toBe("error")
	end)

	it("keeps kubectl error forms out of the start phase because a log line may begin with `error: `", function()
		expect(Parse.diagnostic("error: container nope is not valid for pod x", "start")).toBeNil()
		expect(Parse.diagnostic("Warning: something", "start")).toBeNil()
	end)

	it("recognises the trailing error, warning and Ctrl-C forms in the end phase", function()
		local cases: { { string } } = {
			{ 'error: error from server (NotFound): pods "nopod" not found in namespace "x"', "error" },
			{ 'Error from server (BadRequest): previous terminated container "app" in pod "p" not found', "error" },
			{
				"error: you are attempting to follow 6 log streams, but maximum allowed concurrency is 2, use --max-log-requests to increase the limit",
				"error",
			},
			{ "Warning: deprecated", "warning" },
			{ "^C%", "interrupted" },
			{ "^C", "interrupted" },
		}
		for _, c in cases do
			local n = Parse.diagnostic(c[1], "end")
			expect(n and n.kind).toBe(c[2])
		end
	end)

	it("never takes program output for a diagnostic", function()
		expect(Parse.diagnostic("Found it", "end")).toBeNil()
		expect(Parse.diagnostic("Defaulted to x", "end")).toBeNil()
		expect(Parse.diagnostic('{"level":"error"}', "end")).toBeNil()
	end)

	it("knows the shell's partial-line marks so a lone `%` final line is dropped", function()
		expect(Parse.isPromptMark("%")).toBe(true)
		expect(Parse.isPromptMark("#")).toBe(true)
		expect(Parse.isPromptMark("⏎")).toBe(true)
		expect(Parse.isPromptMark("100%")).toBe(false)
	end)
end)

describe("logs parse: prefix and kubelet time", function()
	it("splits `[pod/<pod>/<container>] ` so prefixed lines are attributed", function()
		local pod, c, rest = Parse.splitPrefix("[pod/tk-logmix-1/app] WARN tick 3")
		expect(pod).toBe("tk-logmix-1")
		expect(c).toBe("app")
		expect(rest).toBe("WARN tick 3")
	end)

	it("leaves lines without a prefix untouched (kubectl's own lines)", function()
		local pod, c, rest = Parse.splitPrefix("[WARNING] deprecated flag --foo")
		expect(pod).toBeNil()
		expect(c).toBeNil()
		expect(rest).toBe("[WARNING] deprecated flag --foo")
	end)

	it("splits the RFC3339Nano kubelet time and one space", function()
		local ts, rest = Parse.splitTimestamp('2026-11-02T16:22:48.983933596Z {"level":"info"}')
		expect(ts).toBe("2026-11-02T16:22:48.983933596Z")
		expect(rest).toBe('{"level":"info"}')
		local none, same = Parse.splitTimestamp("WARN tick 3")
		expect(none).toBeNil()
		expect(same).toBe("WARN tick 3")
	end)
end)

describe("logs parse: continuation", function()
	it("recognises stack frames and chained causes so stacks group under their exception", function()
		expect(Parse.isContinuation("\tat com.example.Main.run(Main.java:10)")).toBe(true)
		expect(Parse.isContinuation("    at Object.<anonymous> (/app/index.js:1:1)")).toBe(true)
		expect(Parse.isContinuation("\t... 12 more")).toBe(true)
		expect(Parse.isContinuation("  ... 12 more")).toBe(true)
		expect(Parse.isContinuation("Caused by: java.io.IOException: x")).toBe(true)
		expect(Parse.isContinuation('  File "/app/main.py", line 3, in <module>')).toBe(true)
	end)

	it("does not treat ordinary lines as continuations", function()
		expect(Parse.isContinuation("WARN tick 3")).toBe(false)
		expect(Parse.isContinuation("  indented but not a frame")).toBe(false)
		expect(Parse.isIndented("  indented but not a frame")).toBe(true)
		expect(Parse.isIndented(" one space")).toBe(false)
	end)
end)

describe("logs parse: JSON", function()
	it("takes level, message and time and keeps the other keys as fields: `port=8080` is not dropped", function()
		local c = classify('{"level":"info","ts":"2026-10-30T10:00:00Z","msg":"server started","port":8080}')
		expect(c.format).toBe("json")
		expect(c.level).toBe("info")
		expect(c.message).toBe("server started")
		expect(c.appTime).toBe("2026-10-30T10:00:00Z")
		expect(c.fields).toEqual({ { key = "port", value = "8080" } })
	end)

	it("orders fields by their position in the line because decoded objects are unordered", function()
		local c = classify('{"msg":"x","zeta":1,"alpha":"a","mid":true}')
		expect(c.fields).toEqual({
			{ key = "zeta", value = "1" },
			{ key = "alpha", value = "a" },
			{ key = "mid", value = "true" },
		})
	end)

	it("re-encodes nested values compactly with sorted keys", function()
		local c = classify('{"msg":"x","req":{"path":"/a","id":7},"tags":["a","b"]}')
		expect(c.fields).toEqual({
			{ key = "req", value = '{"id":7,"path":"/a"}' },
			{ key = "tags", value = '["a","b"]' },
		})
	end)

	it("maps level names case-insensitively, including aliases", function()
		local cases = {
			{ "WARNING", "warn" },
			{ "Err", "error" },
			{ "crit", "fatal" },
			{ "critical", "fatal" },
			{ "panic", "fatal" },
			{ "notice", "info" },
			{ "DEBUG", "debug" },
			{ "trace", "trace" },
			{ "bogus", "none" },
		}
		for _, c in cases do
			expect(classify(string.format('{"level":"%s","msg":"m"}', c[1])).level).toBe(c[2])
		end
	end)

	it("maps pino/bunyan numeric levels", function()
		local cases: { { any } } =
			{ { 10, "trace" }, { 20, "debug" }, { 30, "info" }, { 40, "warn" }, { 50, "error" }, { 60, "fatal" } }
		for _, c in cases do
			expect(classify(string.format('{"level":%d,"msg":"m"}', c[1])).level).toBe(c[2])
		end
	end)

	it("accepts every documented level, message and time key", function()
		expect(classify('{"lvl":"warn","message":"a"}').message).toBe("a")
		expect(classify('{"severity":"ERROR","log":"b"}').level).toBe("error")
		expect(classify('{"log.level":"debug","text":"c"}').level).toBe("debug")
		expect(classify('{"levelname":"WARNING","@m":"d"}').level).toBe("warn")
		local clef = classify('{"@l":"Error","@mt":"e {X}","@t":"2026-01-01T00:00:00Z","X":1}')
		expect(clef.level).toBe("error")
		expect(clef.message).toBe("e {X}")
		expect(clef.appTime).toBe("2026-01-01T00:00:00Z")
		expect(classify('{"time":1730282400,"msg":"n"}').appTime).toBe("1730282400")
	end)

	it("caps fields at 32 so one huge object cannot flood the inspector", function()
		local parts = { '{"msg":"m"' }
		for i = 1, 40 do
			table.insert(parts, string.format('"k%02d":%d', i, i))
		end
		local c = classify(table.concat(parts, ",") .. "}")
		expect(#(c.fields :: { any })).toBe(32)
		expect((c.fields :: { any })[1]).toEqual({ key = "k01", value = "1" })
	end)

	it("falls back to plain text when a brace line is not JSON", function()
		local c = classify("{not json} ERROR here")
		expect(c.format).toBe("plain")
		expect(c.level).toBe("error")
	end)
end)

describe("logs parse: klog", function()
	it("klog keeps the severity letter out of the time", function()
		local c = classify('I1030 10:00:01.123456       1 controller.go:42] "Starting workers" count=2')
		expect(c.format).toBe("klog")
		expect(c.level).toBe("info")
		expect(c.appTime).toBe("1030 10:00:01.123456")
		expect(c.location).toBe("controller.go:42")
		expect(c.message).toBe("Starting workers")
		expect(c.fields).toEqual({ { key = "count", value = "2" } })
	end)

	it("maps W/E/F and keeps an unstructured message whole", function()
		local w = classify("W1030 10:00:02.000001       1 reflector.go:7] watch closed")
		expect(w.level).toBe("warn")
		expect(w.message).toBe("watch closed")
		expect(w.fields).toBeNil()
		local e = classify('E1030 10:00:03.000001       1 sync.go:99] "sync failed" err="boom"')
		expect(e.level).toBe("error")
		expect(e.message).toBe("sync failed")
		expect(e.fields).toEqual({ { key = "err", value = "boom" } })
		expect(classify("F1030 10:00:03.000001 7 main.go:1] dead").level).toBe("fatal")
	end)
end)

describe("logs parse: logfmt", function()
	it("logfmt message is the msg value", function()
		local c = classify('time=2026-10-30T10:00:04Z level=warn msg="slow request" path=/api dur=2.1s')
		expect(c.format).toBe("logfmt")
		expect(c.level).toBe("warn")
		expect(c.message).toBe("slow request")
		expect(c.appTime).toBe("2026-10-30T10:00:04Z")
		expect(c.fields).toEqual({ { key = "path", value = "/api" }, { key = "dur", value = "2.1s" } })
	end)

	it("parses the sampler's short form and escaped quotes", function()
		local c = classify('level=debug msg="tick 2"')
		expect(c.level).toBe("debug")
		expect(c.message).toBe("tick 2")
		local q = classify('level=info msg="say \\"hi\\"" k=v')
		expect(q.message).toBe('say "hi"')
	end)

	it("needs two pairs and a level or msg key, so `a=b` prose stays plain", function()
		expect(classify("x=1 y=2").format).toBe("plain")
		expect(classify("level=warn").format).toBe("plain")
	end)
end)

describe("logs parse: plain", function()
	it("finds level tokens bracketed, bare or before a colon", function()
		expect(classify("WARN tick 3").level).toBe("warn")
		expect(classify("[WARNING] deprecated flag --foo").level).toBe("warn")
		expect(classify("error: disk full").level).toBe("error")
		expect(classify("2026-10-30 10:00:05,123 ERROR [main] java.lang.IllegalStateException: bad").level).toBe(
			"error"
		)
	end)

	it("takes a leading timestamp as the payload time and looks for the level after it", function()
		local c = classify("2026-10-30T10:00:05.5+02:00 INFO up")
		expect(c.appTime).toBe("2026-10-30T10:00:05.5+02:00")
		expect(c.level).toBe("info")
		expect(classify("10:00:05.123 DEBUG x").level).toBe("debug")
	end)

	it("requires word boundaries so `information` or `errors_total` are not levels", function()
		expect(classify("side: beat 57").level).toBe("none")
		expect(classify("errors_total rose").level).toBe("none")
		expect(classify("infoboxes rendered").level).toBe("none")
	end)

	it("only looks at the first 48 bytes so a late word in prose does not set the level", function()
		local line = string.rep("a", 50) .. " ERROR"
		expect(classify(line).level).toBe("none")
	end)

	it("treats panics, tracebacks, fatal errors and exceptions as errors", function()
		expect(classify("panic: runtime error: index out of range").level).toBe("error")
		expect(classify("Traceback (most recent call last):").level).toBe("error")
		expect(classify("fatal error: all goroutines are asleep").level).toBe("error")
		expect(classify("java.lang.IllegalStateException: bad").level).toBe("error")
		expect(classify("ValueError: boom").level).toBe("error")
	end)

	it("ANSI-coloured lines classify by text", function()
		local c = classify("\27[31mred ansi error line\27[0m")
		expect(c.message).toBe("red ansi error line")
		expect(c.level).toBe("error")
	end)

	it("keeps the whole line as the message, as kubectl printed it", function()
		local long = "long: " .. string.rep("x", 3000)
		expect(classify(long).message).toBe(long)
		expect(classify(long).level).toBe("none")
	end)
end)

describe("logs parse: regressions vs the built-in lens", function()
	it("prefixed --timestamps JSON error lines are errors", function()
		local line =
			'[pod/tk-logmix-1/app] 2026-11-02T16:22:51.989221708Z {"level":"error","msg":"tick 4 failed","i":4}'
		local _, _, rest = Parse.splitPrefix(line)
		local ts, payload = Parse.splitTimestamp(rest)
		expect(ts).toBe("2026-11-02T16:22:51.989221708Z")
		local c = classify(payload)
		expect(c.level).toBe("error")
		expect(c.message).toBe("tick 4 failed")
	end)

	it("ranks levels fatal 6 down to none 0 so floors compare numerically", function()
		expect(Parse.rank("fatal")).toBe(6)
		expect(Parse.rank("error")).toBe(5)
		expect(Parse.rank("warn")).toBe(4)
		expect(Parse.rank("info")).toBe(3)
		expect(Parse.rank("debug")).toBe(2)
		expect(Parse.rank("trace")).toBe(1)
		expect(Parse.rank("none")).toBe(0)
	end)
end)

return nil
