--!strict
-- Finding kubectl, helm, gh and kubectl's exec credential plugins when Tern
-- was not started from a terminal. A daemon launched by launchd or a desktop
-- session has a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), and
-- tern.process.run looks programs up on that PATH. The user's PATH comes
-- from their login shell (read once per daemon), then from the usual
-- install locations, then from the daemon's own PATH.
--
-- Pure: the host injects `exists` and runs the probe argv.

local M = {}

export type Source = "kv" | "config" | "env" | "shell" | "known" | "daemon" | "missing"

-- Where an explicit program setting came from (kv > config > env).
export type Explicit = { value: string, source: Source }

-- Directory lists searched in order; `shell` is nil when the shell was not read.
export type Tiers = { shell: { string }?, known: { string }, daemon: { string } }

export type Resolution = {
	-- What to put in argv[1]: absolute when found, else the bare name.
	program: string,
	-- The explicit setting, else the tier that had it, else "missing".
	source: Source,
	-- The tier the directory came from (explicit names are searched too).
	tier: Source?,
	found: boolean,
}

export type Probe = { path: { string }, kubeconfig: string? }

M.SENTINEL = "@@TKENV@@"

-- Install locations GUI-launched daemons miss: Homebrew (Apple silicon and
-- Intel), user bins, Rancher Desktop, Docker Desktop, mise/asdf shims, Nix,
-- snap. `~/` is the user's HOME.
M.KNOWN_DIRS = table.freeze({
	"/opt/homebrew/bin",
	"/usr/local/bin",
	"~/.local/bin",
	"~/bin",
	"~/.rd/bin",
	"~/.docker/bin",
	"~/.local/share/mise/shims",
	"~/.asdf/shims",
	"~/.nix-profile/bin",
	"/run/current-system/sw/bin",
	"/nix/var/nix/profiles/default/bin",
	"/snap/bin",
	"/usr/local/sbin",
})

local POSIX_SHELLS: { [string]: boolean } = { sh = true, bash = true, zsh = true, ksh = true, dash = true, mksh = true }

-- printf, not echo: rc files may alias echo, and the sentinel must start a
-- line of its own whatever the rc printed before it.
local POSIX_SCRIPT = 'printf "\\n' .. M.SENTINEL .. '%s@@%s@@\\n" "$PATH" "${KUBECONFIG-}"'

-- fish keeps PATH as a list ("$PATH" would join it with spaces); a quoted
-- variable always expands to exactly one argument, even when empty.
local FISH_SCRIPT = "set -l tkp (string join : -- $PATH); set -l tkk (string join : -- $KUBECONFIG); "
	.. "printf '\\n"
	.. M.SENTINEL
	.. '%s@@%s@@\\n\' "$tkp" "$tkk"'

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- "posix" or "fish"; nil for shells whose syntax we do not speak (csh,
-- nushell, ...), which skip the shell read.
function M.shellKind(shell: string?): ("posix" | "fish")?
	if shell == nil or string.sub(shell, 1, 1) ~= "/" then
		return nil
	end
	local name = string.gsub(basename(shell), "^%-", "")
	if POSIX_SHELLS[name] then
		return "posix"
	elseif name == "fish" then
		return "fish"
	end
	return nil
end

-- The argv that prints the login shell's PATH and KUBECONFIG on a sentinel
-- line. Interactive as well as login: many users set PATH in .zshrc/.bashrc.
function M.probeArgv(shell: string?): { string }?
	local kind = M.shellKind(shell)
	if kind == nil then
		return nil
	end
	return { shell :: string, "-l", "-i", "-c", if kind == "fish" then FISH_SCRIPT else POSIX_SCRIPT }
end

-- Absolute entries of a PATH string, in order, without duplicates. Relative
-- entries ("", ".") are dropped: they would resolve against the plugin dir.
function M.splitPath(text: string?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, entry in string.split(text or "", ":") do
		local dir = if #entry > 1 then (string.gsub(entry, "/+$", "")) else entry
		if string.sub(dir, 1, 1) == "/" and not seen[dir] then
			seen[dir] = true
			table.insert(out, dir)
		end
	end
	return out
end

-- The last sentinel line of the probe's stdout; rc files may print anything
-- before or after it. nil when it is missing or carries no PATH.
function M.parseProbe(stdout: string): Probe?
	local found: Probe? = nil
	for _, raw in string.split(stdout, "\n") do
		local line = string.gsub(raw, "\r$", "")
		local start = string.find(line, M.SENTINEL, 1, true)
		if start then
			local path, kubeconfig = string.match(string.sub(line, start + #M.SENTINEL), "^(.-)@@(.*)@@$")
			local dirs = M.splitPath(path)
			if #dirs > 0 then
				found = { path = dirs, kubeconfig = if kubeconfig and kubeconfig ~= "" then kubeconfig else nil }
			end
		end
	end
	return found
end

-- KNOWN_DIRS with `~/` expanded; home-relative ones are dropped without a HOME.
function M.knownDirs(home: string?): { string }
	local out: { string } = {}
	local base = if home and string.sub(home, 1, 1) == "/" then (string.gsub(home, "/+$", "")) else nil
	for _, dir in M.KNOWN_DIRS do
		if string.sub(dir, 1, 2) == "~/" then
			if base then
				table.insert(out, base .. string.sub(dir, 2))
			end
		else
			table.insert(out, dir)
		end
	end
	return out
end

-- The PATH handed to every process: shell PATH, then the known dirs that
-- exist, then the daemon's PATH; first occurrence wins.
function M.mergePath(tiers: Tiers): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local lists: { { string } } = { tiers.shell or {}, tiers.known, tiers.daemon }
	for _, list in lists do
		for _, dir in list do
			if not seen[dir] then
				seen[dir] = true
				table.insert(out, dir)
			end
		end
	end
	return out
end

local function search(name: string, tiers: Tiers, exists: (string) -> boolean): (string?, Source?)
	local order: { { dirs: { string }, source: Source } } = {
		{ dirs = tiers.shell or {}, source = "shell" },
		{ dirs = tiers.known, source = "known" },
		{ dirs = tiers.daemon, source = "daemon" },
	}
	for _, tier in order do
		for _, dir in tier.dirs do
			local candidate = dir .. "/" .. name
			if exists(candidate) then
				return candidate, tier.source
			end
		end
	end
	return nil, nil
end

-- The program for `name`: an explicit absolute path as is; an explicit or
-- default bare name searched shell > known dirs > daemon PATH; not found
-- keeps the bare name (the spawn then fails with a clear message).
function M.resolve(name: string, explicit: Explicit?, tiers: Tiers, exists: (string) -> boolean): Resolution
	local wanted = if explicit then explicit.value else name
	if string.find(wanted, "/", 1, true) then
		local source: Source = if explicit then explicit.source else "missing"
		return {
			program = wanted,
			source = source,
			tier = nil,
			found = exists(wanted),
		}
	end
	local path: string?, tier: Source? = search(wanted, tiers, exists)
	local source: Source = "missing"
	if explicit then
		source = explicit.source
	elseif tier then
		source = tier
	end
	return {
		program = path or wanted,
		source = source,
		tier = tier,
		found = path ~= nil,
	}
end

-- The explicit kubectl setting: Tern kv "kubectl" (tests, settings flow) >
-- config `kubectl` other than the default > TKUBE_KUBECTL.
function M.explicitKubectl(configValue: string, kvValue: any, envValue: string?): Explicit?
	if type(kvValue) == "string" and kvValue ~= "" then
		return { value = kvValue, source = "kv" }
	end
	if configValue ~= "" and configValue ~= "kubectl" then
		return { value = configValue, source = "config" }
	end
	if envValue and envValue ~= "" then
		return { value = envValue, source = "env" }
	end
	return nil
end

local SOURCE_TEXT: { [Source]: string } = {
	kv = "Tern kv key kubectl",
	config = "config file",
	env = "TKUBE_KUBECTL",
	shell = "your shell's PATH",
	known = "a common install location",
	daemon = "Tern's PATH",
	missing = "not found",
}

-- "from your shell's PATH", "from config file (found on your shell's PATH)".
function M.describe(r: Resolution): string
	local text = "from " .. SOURCE_TEXT[r.source]
	if r.source == "missing" then
		return "not found"
	end
	if r.tier and r.tier ~= r.source then
		text ..= " (found on " .. SOURCE_TEXT[r.tier] .. ")"
	end
	if not r.found then
		text ..= " (does not exist)"
	end
	return text
end

-- Tern errors arrive as "runtime error: <reason>" followed by a stack
-- traceback (or with it on the same line); users need only the reason.
function M.errorText(err: any): string
	local text = tostring(err)
	local cut = string.find(text, "stack traceback", 1, true)
	if cut then
		text = string.sub(text, 1, cut - 1)
	end
	local first = string.match(text, "^%s*([^\n]*)") or ""
	first = string.gsub(first, "^runtime error: ", "")
	first = string.gsub(first, "^[^:%s]+%.luau?:%d+: ", "")
	first = string.gsub(first, '^%[string "[^"]*"%]:%d+: ', "")
	return (string.gsub(first, "%s+$", ""))
end

-- A spawn error meaning the program file is not there.
function M.isNotFound(err: string): boolean
	local lower = string.lower(err)
	return string.find(lower, "no such file or directory", 1, true) ~= nil
		or string.find(lower, "not found", 1, true) ~= nil
end

-- The actionable text for a program that could not be found.
function M.notFoundText(name: string, program: string, daemonPath: string?): string
	local fix =
		string.format('Set "%s" to its full path in Tern Kube: Settings (or ~/.config/tern-kube/config.json).', name)
	if string.find(program, "/", 1, true) then
		return string.format("%s not found at %s. %s", name, program, fix)
	end
	local what = if program == name then name else string.format("%s (%s)", name, program)
	return string.format(
		"%s not found. Tern runs plugins with the PATH it was launched with (%s), and %s isn't on it, "
			.. "your shell's PATH or the usual install locations. %s",
		what,
		if daemonPath and daemonPath ~= "" then daemonPath else "empty",
		program,
		fix
	)
end

return M
