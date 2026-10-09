--!strict
-- Tern started from the Dock/Finder (launchd) or a desktop session has the
-- minimal PATH /usr/bin:/bin:/usr/sbin:/sbin, so kubectl in /usr/local/bin
-- or /opt/homebrew/bin was "No such file or directory" and Explore showed a
-- Lua traceback. These specs pin how the user's PATH is recovered (login
-- shell, then common install dirs) and how a program is chosen.
local Shellenv = require("../../../plugin/lib/env/shellenv")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local GUI_PATH = { "/usr/bin", "/bin", "/usr/sbin", "/sbin" }

local function fs(paths: { string }): (string) -> boolean
	local set: { [string]: boolean } = {}
	for _, p in paths do
		set[p] = true
	end
	return function(p: string): boolean
		return set[p] == true
	end
end

describe("shell probe argv", function()
	it("runs POSIX shells as interactive login shells, since PATH is often set in .zshrc/.bashrc", function()
		local argv = Shellenv.probeArgv("/bin/zsh") :: { string }
		expect(argv[1]).toBe("/bin/zsh")
		expect(argv[2]).toBe("-l")
		expect(argv[3]).toBe("-i")
		expect(argv[4]).toBe("-c")
		expect(argv[5]).toContain(Shellenv.SENTINEL)
		expect(argv[5]).toContain('"$PATH"')
		expect(argv[5]).toContain('"${KUBECONFIG-}"')
		expect(Shellenv.probeArgv("/opt/homebrew/bin/bash") ~= nil).toBe(true)
		expect(Shellenv.probeArgv("/bin/sh") ~= nil).toBe(true)
	end)

	it('speaks fish syntax to fish, whose PATH is a list that "$PATH" would join with spaces', function()
		local argv = Shellenv.probeArgv("/opt/homebrew/bin/fish") :: { string }
		expect(argv[1]).toBe("/opt/homebrew/bin/fish")
		expect(argv[5]).toContain("string join : -- $PATH")
		expect((string.find(argv[5], "${", 1, true))).toBeNil()
	end)

	it("skips shells whose syntax it does not know, and a SHELL that is not an absolute path", function()
		expect(Shellenv.probeArgv("/bin/tcsh")).toBeNil()
		expect(Shellenv.probeArgv("/usr/local/bin/nu")).toBeNil()
		expect(Shellenv.probeArgv("zsh")).toBeNil()
		expect(Shellenv.probeArgv(nil)).toBeNil()
	end)
end)

describe("shell probe output", function()
	it("finds the sentinel among rc-file noise before and after it", function()
		local out = "Last login: today\n\27[1mwelcome\27[0m\n"
			.. Shellenv.SENTINEL
			.. "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin@@/Users/u/.kube/a:/Users/u/.kube/b@@\n"
			.. "bye from .zlogout\n"
		local p = Shellenv.parseProbe(out) :: Shellenv.Probe
		expect(p.path).toEqual({ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" })
		expect(p.kubeconfig).toBe("/Users/u/.kube/a:/Users/u/.kube/b")
	end)

	it("finds the sentinel mid-line when a prompt left no newline, and tolerates CRLF", function()
		local p = Shellenv.parseProbe("prompt% " .. Shellenv.SENTINEL .. "/usr/local/bin@@@@\r\n") :: Shellenv.Probe
		expect(p.path).toEqual({ "/usr/local/bin" })
		expect(p.kubeconfig).toBeNil()
	end)

	it("takes the last sentinel line when an rc file runs a shell that prints one too", function()
		local out = Shellenv.SENTINEL .. "/a@@@@\n" .. Shellenv.SENTINEL .. "/b@@@@\n"
		expect((Shellenv.parseProbe(out) :: Shellenv.Probe).path).toEqual({ "/b" })
	end)

	it("reports nothing when the sentinel is missing, truncated or carries no PATH", function()
		expect(Shellenv.parseProbe("")).toBeNil()
		expect(Shellenv.parseProbe("zsh: command not found: compinit\n")).toBeNil()
		expect(Shellenv.parseProbe(Shellenv.SENTINEL .. "/usr/bin")).toBeNil()
		expect(Shellenv.parseProbe(Shellenv.SENTINEL .. "@@@@\n")).toBeNil()
	end)
end)

describe("PATH handling", function()
	it("keeps absolute entries in order, once, without trailing slashes", function()
		expect(Shellenv.splitPath("/a/:/b::.:rel:/a:/")).toEqual({ "/a", "/b", "/" })
		expect(Shellenv.splitPath(nil)).toEqual({})
	end)

	it("expands home-relative known dirs and drops them without a HOME", function()
		local dirs = Shellenv.knownDirs("/Users/u/")
		expect(dirs).toContain("/opt/homebrew/bin")
		expect(dirs).toContain("/usr/local/bin")
		expect(dirs).toContain("/Users/u/.rd/bin")
		expect(dirs).toContain("/Users/u/.local/share/mise/shims")
		expect(dirs).toContain("/Users/u/.asdf/shims")
		expect(dirs).toContain("/nix/var/nix/profiles/default/bin")
		for _, d in Shellenv.knownDirs(nil) do
			expect(string.sub(d, 1, 1)).toBe("/")
			expect((string.find(d, "~", 1, true))).toBeNil()
		end
	end)

	it("merges shell PATH first, then known dirs, then the daemon PATH, so credential plugins resolve", function()
		local merged = Shellenv.mergePath({
			shell = { "/Users/u/.krew/bin", "/usr/bin" },
			known = { "/opt/homebrew/bin" },
			daemon = GUI_PATH,
		})
		expect(merged).toEqual({ "/Users/u/.krew/bin", "/usr/bin", "/opt/homebrew/bin", "/bin", "/usr/sbin", "/sbin" })
		expect(Shellenv.mergePath({ shell = nil, known = {}, daemon = GUI_PATH })).toEqual(GUI_PATH)
	end)
end)

describe("program resolution", function()
	local tiers: Shellenv.Tiers = {
		shell = { "/Users/u/bin", "/opt/homebrew/bin" },
		known = { "/opt/homebrew/bin", "/usr/local/bin" },
		daemon = GUI_PATH,
	}

	it("reproduces the bug: under the GUI PATH alone kubectl in /usr/local/bin is missing", function()
		local r = Shellenv.resolve(
			"kubectl",
			nil,
			{ shell = nil, known = {}, daemon = GUI_PATH },
			fs({ "/usr/local/bin/kubectl" })
		)
		expect(r).toEqual({ program = "kubectl", source = "missing", found = false })
	end)

	it("prefers the shell PATH over known dirs and the daemon PATH", function()
		local exists = fs({ "/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl", "/usr/bin/kubectl" })
		expect(Shellenv.resolve("kubectl", nil, tiers, exists)).toEqual({
			program = "/opt/homebrew/bin/kubectl",
			source = "shell",
			tier = "shell",
			found = true,
		})
	end)

	it("falls back to known dirs when the shell was not read, then to the daemon PATH", function()
		local noShell = { shell = nil, known = tiers.known, daemon = GUI_PATH }
		expect(Shellenv.resolve("kubectl", nil, noShell, fs({ "/usr/local/bin/kubectl" })).source).toBe("known")
		local daemon = Shellenv.resolve("helm", nil, noShell, fs({ "/usr/bin/helm" }))
		expect(daemon.program).toBe("/usr/bin/helm")
		expect(daemon.source).toBe("daemon")
	end)

	it("uses an explicit absolute path as is, even when it does not exist (the error then names it)", function()
		local r = Shellenv.resolve(
			"kubectl",
			{ value = "/opt/k/kubectl", source = "config" },
			tiers,
			fs({ "/opt/homebrew/bin/kubectl" })
		)
		expect(r).toEqual({ program = "/opt/k/kubectl", source = "config", found = false })
	end)

	it("searches the tiers for an explicit bare name and keeps the explicit source", function()
		local r = Shellenv.resolve(
			"kubectl",
			{ value = "kubecolor", source = "env" },
			tiers,
			fs({ "/Users/u/bin/kubecolor" })
		)
		expect(r).toEqual({ program = "/Users/u/bin/kubecolor", source = "env", tier = "shell", found = true })
		expect(Shellenv.describe(r)).toBe("from TKUBE_KUBECTL (found on your shell's PATH)")
	end)

	it("orders explicit settings kv > config > TKUBE_KUBECTL; the default config value is not explicit", function()
		expect(Shellenv.explicitKubectl("/c", "/kv", "/e")).toEqual({ value = "/kv", source = "kv" })
		expect(Shellenv.explicitKubectl("/c", nil, "/e")).toEqual({ value = "/c", source = "config" })
		expect(Shellenv.explicitKubectl("kubectl", "", "/e")).toEqual({ value = "/e", source = "env" })
		expect(Shellenv.explicitKubectl("kubectl", nil, "")).toBeNil()
	end)

	it("describes each source for the Settings status page", function()
		local function d(source: Shellenv.Source, found: boolean?): string
			return Shellenv.describe({ program = "x", source = source, tier = source, found = found ~= false })
		end
		expect(d("shell")).toBe("from your shell's PATH")
		expect(d("known")).toBe("from a common install location")
		expect(d("daemon")).toBe("from Tern's PATH")
		expect(d("missing", false)).toBe("not found")
		expect(Shellenv.describe({ program = "/x", source = "config", found = false })).toBe(
			"from config file (does not exist)"
		)
	end)
end)

describe("errors shown to users", function()
	it("drops the runtime-error prefix and the Lua stack traceback", function()
		local raw = "runtime error: tern.process.run kubectl: No such file or directory (os error 2)\n"
			.. "stack traceback:\n\t[C]: in ?\n\texplore_host.luau:79: in function <explore_host.luau:78>"
		expect(Shellenv.errorText(raw)).toBe("tern.process.run kubectl: No such file or directory (os error 2)")
		local oneLine = "runtime error: tern.process.run kubectl: No such file or directory (os error 2) "
			.. "stack traceback: [C]: in ? explore_host.luau:79"
		expect(Shellenv.errorText(oneLine)).toBe("tern.process.run kubectl: No such file or directory (os error 2)")
		expect(Shellenv.errorText("plugin/explore_host.luau:79: boom")).toBe("boom")
	end)

	it("recognizes not-found spawn errors", function()
		expect(Shellenv.isNotFound("tern.process.run kubectl: No such file or directory (os error 2)")).toBe(true)
		expect(Shellenv.isNotFound("Permission denied (os error 13)")).toBe(false)
	end)

	it("explains the launch PATH and the fix when a bare name is missing", function()
		local text = Shellenv.notFoundText("kubectl", "kubectl", "/usr/bin:/bin:/usr/sbin:/sbin")
		expect(text).toBe(
			"kubectl not found. Tern runs plugins with the PATH it was launched with (/usr/bin:/bin:/usr/sbin:/sbin), "
				.. "and kubectl isn't on it, your shell's PATH or the usual install locations. "
				.. 'Set "kubectl" to its full path in Tern Kube: Settings (or ~/.config/tern-kube/config.json).'
		)
		expect(Shellenv.notFoundText("kubectl", "/opt/k/kubectl", "/usr/bin")).toContain(
			"kubectl not found at /opt/k/kubectl."
		)
		expect(Shellenv.notFoundText("kubectl", "kubecolor", "/usr/bin")).toContain(
			"kubectl (kubecolor) not found. Tern runs plugins with the PATH it was launched with (/usr/bin), and kubecolor"
		)
	end)
end)

return nil
