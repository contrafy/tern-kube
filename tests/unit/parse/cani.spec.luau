--!strict
-- `kubectl auth can-i` (capture-k9s.sh): `no` exits 1 but is an answer, -q
-- answers by exit status only, warnings still answer, and --list rows
-- (blank Resources cells, bracketed lists, duplicates) all parse.
local Argv = require("../../../plugin/lib/kubectl/argv")
local Cani = require("../../../plugin/lib/parse/cani")
local k9s = require("../../lib/k9s")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function answerOf(id: string): Cani.Answer
	local f = k9s.load(id)
	local inv = Argv.parse(f.run.program, f.run.args)
	local quiet = inv.flags.quiet ~= nil
	return Cani.answer(f.lines, f.status, quiet)
end

local function question(command: string): Cani.Question
	local words = string.split(command, " ")
	local program = table.remove(words, 1) :: string
	return Cani.question(Argv.parse(program, words))
end

describe("parse.cani answer", function()
	it("yes exits 0, no exits 1, both are answers", function()
		expect(answerOf("ci-yes").answer).toBe("yes")
		expect(answerOf("ci-yes-as").answer).toBe("yes")
		local no = answerOf("ci-no-as")
		expect(no.answer).toBe("no")
		expect(no.diagnostics).toEqual({})
		expect(answerOf("ci-name-no").answer).toBe("no")
		expect(answerOf("ci-star").answer).toBe("yes")
	end)

	it("-q answers from the exit status", function()
		expect(answerOf("ci-quiet-yes").answer).toBe("yes")
		expect(answerOf("ci-quiet-no").answer).toBe("no")
		expect(answerOf("ci-quiet-no").line).toBeNil()
	end)

	it("keeps kubectl's warnings and still answers", function()
		local a = answerOf("ci-unknown")
		expect(a.answer).toBe("yes")
		expect(a.diagnostics[1].severity).toBe("warning")
		expect(a.diagnostics[1].text).toBe("Warning: the server doesn't have a resource type 'frobs'")
		expect(answerOf("ci-unknownverb").answer).toBe("yes")
	end)

	it("reads `no - reason`", function()
		local a = answerOf("synthetic/ci-no-reason")
		expect(a.answer).toBe("no")
		expect(a.reason).toBe('RBAC: role.rbac.authorization.k8s.io "x" not found')
	end)

	it("an error is no answer, even with -q", function()
		expect(answerOf("ci-noargs").answer).toBeNil()
		expect(Cani.answer({ "error: you must specify two arguments" }, 1, true).answer).toBeNil()
	end)
end)

describe("parse.cani question", function()
	it("reads resource, group, name, subresource and non-resource URLs", function()
		local q = question("kubectl -n ns auth can-i get deployments.apps/web --subresource=scale")
		expect(q.verb).toBe("get")
		expect(q.resource).toBe("deployments")
		expect(q.group).toBe("apps")
		expect(q.name).toBe("web")
		expect(q.subresource).toBe("scale")
		expect(q.namespace).toBe("ns")
		expect(q.impersonated).toBe(false)
		local url = question("kubectl auth can-i get /healthz")
		expect(url.url).toBe("/healthz")
		expect(url.resource).toBeNil()
	end)

	it("any of --as, --as-group, --as-uid, --user, --token is someone else", function()
		local q = question("kubectl --as=system:serviceaccount:a:b --as-group=g1 --as-group=g2 auth can-i list pods -A")
		expect(q.as).toBe("system:serviceaccount:a:b")
		expect(q.asGroups).toEqual({ "g1", "g2" })
		expect(q.allNamespaces).toBe(true)
		expect(q.impersonated).toBe(true)
		expect(question("kubectl --user u auth can-i list pods").impersonated).toBe(true)
		expect(question("kubectl --token x auth can-i list pods").impersonated).toBe(true)
	end)
end)

describe("parse.cani list", function()
	it("reads admin rules: *.* and non-resource rows with blank Resources", function()
		local p = Cani.list(k9s.stdout("ci-list"))
		expect(p.diagnostics).toEqual({})
		local first = p.rules[1]
		expect(first.resource).toBe("*")
		expect(first.group).toBe("*")
		expect(first.verbs).toEqual({ "*" })
		local second = p.rules[2]
		expect(second.resource).toBeNil()
		expect(second.urls).toEqual({ "*" })
		expect(second.cells[1]).toBe("")
	end)

	it("reads verbs, subresources and resource names", function()
		local p = Cani.list(k9s.stdout("ci-list-names"))
		expect(p.diagnostics).toEqual({})
		local names: { string } = {}
		for _, r in p.rules do
			if r.resource == "configmaps" then
				table.insert(names, r.names[1])
				expect(r.verbs).toEqual({ "get", "update" })
			end
		end
		expect(names).toEqual({ "cm-a", "cm-b" })
		local viewer = Cani.list(k9s.stdout("ci-list-as"))
		local log: Cani.Rule? = nil
		for _, r in viewer.rules do
			if r.resource == "pods" and r.subresource == "log" then
				log = r
			end
		end
		assert(log, "pods/log rule")
		expect(log.verbs).toEqual({ "get", "list", "watch" })
	end)

	it("reads --no-headers like the table", function()
		local a = Cani.list(k9s.stdout("ci-list-as"))
		local b = Cani.list(k9s.stdout("ci-list-as-noheaders"))
		expect(#b.rules).toBe(#a.rules)
		for i, r in a.rules do
			expect(b.rules[i].resource).toBe(r.resource)
			expect(b.rules[i].verbs).toEqual(r.verbs)
		end
	end)

	it("kubectl's refusals are diagnostics", function()
		local f = k9s.load("ci-list-A")
		local p = Cani.list(f.lines)
		expect(#p.rules).toBe(0)
		expect(p.diagnostics[1].severity).toBe("error")
	end)
end)

return nil
