--!strict
-- Inspector chips of the k9s-parity lens views: what each row offers, that
-- every link decodes (typed splits, mutate links, Explore URLs rebuilt from
-- the capture), and the safety rules: no roll back to the current revision
-- or with mutations off, contexts open unconfirmed (pick=1), Explore hidden
-- for impersonated can-i answers.
local Capture = require("../../../plugin/lib/lens/capture")
local LensChips = require("../../../plugin/lib/render/lens_chips")
local Link = require("../../../plugin/lib/mutation/link")
local Quick = require("../../../plugin/lib/actions/quick")
local json = require("../../lib/json")
local k9s = require("../../lib/k9s")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function build(id: string): Capture.Capture
	local f = k9s.load(id)
	return Capture.build(f.run, f.lines, f.status, { decode = json.decode })
end

local function labels(chips: { LensChips.Chip }): { string }
	local out: { string } = {}
	for _, c in chips do
		table.insert(out, c.label)
	end
	return out
end

local function chip(chips: { LensChips.Chip }, label: string): LensChips.Chip
	for _, c in chips do
		if c.label == label then
			return c
		end
	end
	error("no chip " .. label)
end

local function value(c: LensChips.Chip, act: string): string
	local v = string.match(c.action, "^" .. string.gsub(act, "%-", "%%-") .. "=(.+)$")
	assert(v, c.action)
	return v
end

local function query(url: string): { [string]: string }
	local out: { [string]: string } = {}
	for k, v in string.gmatch(string.match(url, "%?(.*)$") or "", "([^&=]+)=([^&]*)") do
		out[k] = (
			string.gsub(v :: string, "%%(%x%x)", function(h: string): string
				return string.char(tonumber(h, 16) :: number)
			end)
		)
	end
	return out
end

describe("lens chips: rollout history", function()
	it("offers show, roll back (not to the current revision), explore and copy", function()
		local c = build("rh-deploy")
		local old = LensChips.rowChips(c, "deployment.apps/hist@1", { mutations = true }) :: { LensChips.Chip }
		expect(labels(old)).toEqual({ "Show revision 1", "Roll back to 1", "Explore", "Copy command" })
		local current = LensChips.rowChips(c, "deployment.apps/hist@3", { mutations = true }) :: { LensChips.Chip }
		expect(labels(current)).toEqual({ "Show revision 3", "Explore", "Copy command" })
		local off = LensChips.rowChips(c, "deployment.apps/hist@1", { mutations = false }) :: { LensChips.Chip }
		expect(labels(off)).toEqual({ "Show revision 1", "Explore", "Copy command" })
	end)

	it("Show revision is a typed split; Roll back an undo link to that revision", function()
		local c = build("rh-deploy")
		local chips = LensChips.rowChips(c, "deployment.apps/hist@1", { mutations = true }) :: { LensChips.Chip }
		local req = Quick.decode(value(chip(chips, "Show revision 1"), "act")) :: Quick.Request
		expect(req.action).toBe("history")
		local line = Quick.typedLine(req.action, req.target, req.ref, req.opts) :: Quick.TypedLaunch
		expect(line.line).toBe(
			"kubectl rollout history --context kind-tern-kube-dev -n tern-test-k9s deployment/hist --revision=1"
		)
		local link = Link.decode(value(chip(chips, "Roll back to 1"), "mutate")) :: Link.Request
		expect(link.op).toBe("undo")
		expect(link.revision).toBe(1)
		expect(link.context).toBe("kind-tern-kube-dev")
		expect(link.source).toBe("flag")
		expect(LensChips.copyText(c, "command", "deployment.apps/hist@1")).toBe(
			"kubectl --context kind-tern-kube-dev rollout history deployment.apps/hist -n tern-test-k9s --revision=1"
		)
		local url = LensChips.exploreUrl(c, "deployment.apps/hist@1", nil) :: string
		expect(query(url).name).toBe("hist")
	end)

	it("the revision view offers roll back, history and explore", function()
		local c = build("rh-deploy-rev2")
		expect(labels(LensChips.revisionChips(c, { mutations = true }))).toEqual({
			"Roll back to this revision",
			"History",
			"Explore",
		})
		expect(labels(LensChips.revisionChips(c, { mutations = false }))).toEqual({ "History", "Explore" })
		expect(LensChips.exploreUrl(c, LensChips.REVISION, nil) ~= nil).toBe(true)
	end)
end)

describe("lens chips: contexts", function()
	it("Explore opens the row's context, picked (unconfirmed), in its namespace", function()
		local c = build("ctx-default")
		local chips = LensChips.rowChips(c, "context/tk-apps") :: { LensChips.Chip }
		expect(labels(chips)).toEqual({ "Explore in this context", "Copy name" })
		local q = query(LensChips.exploreUrl(c, "context/tk-apps", nil) :: string)
		expect(q.context).toBe("tk-apps")
		expect(q.namespace).toBe("tern-test-apps")
		expect(q.pick).toBe("1")
		expect(LensChips.copyText(c, "name", "context/tk spaced")).toBe("tk spaced")
		local plain = query(LensChips.exploreUrl(c, "context/kind-tern-kube-dev", nil) :: string)
		expect(plain.namespace).toBeNil()
	end)
end)

describe("lens chips: api-resources", function()
	it("Explore lists the resource; non-listable types get no Explore", function()
		local c = build("ar-wide")
		local chips = LensChips.rowChips(c, "api/widgets.lens.example.com") :: { LensChips.Chip }
		expect(labels(chips)).toEqual({ "Explore widgets", "Copy name", "Copy get command" })
		local q = query(LensChips.exploreUrl(c, "api/widgets.lens.example.com", nil) :: string)
		expect(q.kind).toBe("widgets")
		expect(q.group).toBe("lens.example.com")
		expect(labels(LensChips.rowChips(c, "api/bindings") :: { LensChips.Chip })).toEqual({
			"Copy name",
			"Copy get command",
		})
		expect(LensChips.copyText(c, "get", "api/nodes")).toBe("kubectl --context kind-tern-kube-dev get nodes")
	end)
end)

describe("lens chips: can-i", function()
	it("--list rows: Explore only for listable plain types, not for * or subresources", function()
		local c = build("ci-list-names")
		local tbl = (c.snapshot :: any).tables[1]
		local byCell: { [string]: string } = {}
		for _, row in tbl.rows do
			byCell[row.cells[1] .. row.cells[3]] = row.key
		end
		-- Impersonated: no Explore at all.
		local cm = LensChips.rowChips(c, byCell["configmaps[cm-a]"]) :: { LensChips.Chip }
		expect(labels(cm)).toEqual({ "Copy resource" })
		local admin = build("ci-list")
		local star = LensChips.rowChips(admin, (admin.snapshot :: any).tables[1].rows[1].key) :: { LensChips.Chip }
		expect(labels(star)).toEqual({ "Copy resource" })
	end)

	it("the card: Explore on yes for the context's own user, All permissions keeps impersonation", function()
		local yes = build("ci-yes")
		expect(labels(LensChips.answerChips(yes))).toEqual({ "Explore pods", "All permissions" })
		local q = query(LensChips.exploreUrl(yes, LensChips.ANSWER, nil) :: string)
		expect(q.kind).toBe("pods")
		local as = build("ci-yes-as")
		local chips = LensChips.answerChips(as)
		expect(labels(chips)).toEqual({ "All permissions" })
		local req = Quick.decode(value(chip(chips, "All permissions"), "act")) :: Quick.Request
		expect(req.opts.as).toBe("system:serviceaccount:tern-test-k9s:viewer")
		expect(req.opts.namespace).toBe("tern-test-k9s")
		expect(labels(LensChips.answerChips(build("ci-no-as")))).toEqual({ "All permissions" })
	end)
end)

return nil
