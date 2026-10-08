--!strict
-- The config file is hand-edited JSON: a typo must never take the plugin
-- down or silently weaken a safety default. Every bad value falls back to
-- its default with a diagnostic that names the key path, so the user can
-- fix the file without reading source.
local Config = require("../../../plugin/lib/config")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local decode = json.decode

local function parse(text: string?, opts: any?): (any, { any })
	return Config.parse(text, decode, opts)
end

local function find(diags: { any }, path: string): any
	for _, d in diags do
		if d.path == path then
			return d
		end
	end
	return nil
end

local function contains(s: string, needle: string): boolean
	return string.find(s, needle, 1, true) ~= nil
end

describe("config defaults", function()
	it("uses every default when the file is missing", function()
		local cfg, diags = parse(nil)
		expect(#diags).toBe(0)
		expect(cfg).toEqual(Config.defaults())
		expect(cfg.schema_version).toBe(1)
		expect(cfg.general.max_rendered_rows).toBe(500)
		expect(cfg.general.max_rows).toBe(20000)
		expect(cfg.general.max_capture_bytes).toBe(16777216)
		expect(cfg.general.native_default).toBe(true)
		expect(cfg.general.keyboard_mode).toBeNil()
		expect(cfg.explore.allow_live_queries).toBe(true)
		expect(cfg.explore.auto_refresh).toBe(false)
		expect(cfg.explore.query_timeout_ms).toBe(10000)
		expect(cfg.explore.relationship_max_nodes).toBe(250)
		expect(cfg.mutations.enabled).toBe(true)
		expect(cfg.mutations.interactive_guard).toBe(false)
		expect(cfg.mutations.require_target_confirmation).toBe(true)
		expect(cfg.mutations.allow_failed_preview_override).toBe(false)
		expect(cfg.mutations.preview_timeout_ms).toBe(30000)
		expect(cfg.mutations.execute_timeout_ms).toBe(300000)
		expect(cfg.quick_actions.placement).toBe("right")
		expect(cfg.quick_actions.shell_command).toEqual({
			"sh",
			"-c",
			"command -v bash >/dev/null 2>&1 && exec bash || exec sh",
		})
		expect(cfg.quick_actions.logs_tail).toBe(200)
		expect(cfg.quick_actions.debug_image).toBe("busybox:1.36")
		expect(cfg.kubectl).toBe("kubectl")
		expect(cfg.kubeconfig).toBeNil()
		expect(cfg.aliases.additional).toEqual({})
		expect(cfg.gitops).toEqual({
			helm = {},
			unmanaged_kinds = nil,
			max_files = 2000,
			max_bytes = 33554432,
			max_file_bytes = 1048576,
			render_kustomize = true,
			gh = "gh",
		})
	end)

	-- Secret values must stay hidden unless the user opts in explicitly.
	it("keeps secret handling safe by default", function()
		local cfg = parse(nil)
		expect(cfg.security.show_secret_values).toBe(false)
		expect(cfg.security.sensitive_output_strict_mode).toBe(false)
	end)

	it("treats an empty or blank file as missing", function()
		for _, text in { "", "  \n\t" } do
			local cfg, diags = parse(text)
			expect(#diags).toBe(0)
			expect(cfg).toEqual(Config.defaults())
		end
	end)

	it("accepts an empty object", function()
		local cfg, diags = parse("{}")
		expect(#diags).toBe(0)
		expect(cfg).toEqual(Config.defaults())
	end)

	-- The parsed config is shared by every caller through the host cache.
	it("returns frozen tables so callers cannot mutate shared state", function()
		local cfg = parse(nil)
		expect(table.isfrozen(cfg)).toBe(true)
		expect(table.isfrozen(cfg.general)).toBe(true)
		expect(table.isfrozen(cfg.quick_actions.shell_command)).toBe(true)
		expect(Config.defaults() ~= Config.defaults()).toBe(true)
	end)
end)

describe("config values", function()
	it("applies valid values from every section", function()
		local cfg, diags = parse([[{
			"schema_version": 1,
			"general": {"native_default": false, "max_rows": 5000, "max_rendered_rows": 100,
				"max_capture_bytes": 1048576},
			"aliases": {"additional": ["k", "kc"]},
			"explore": {"allow_live_queries": false, "auto_refresh": false, "query_timeout_ms": 30000,
				"relationship_max_nodes": 50},
			"mutations": {"enabled": false, "interactive_guard": true, "require_target_confirmation": true,
				"allow_failed_preview_override": true, "preview_timeout_ms": 5000, "execute_timeout_ms": 60000},
			"security": {"show_secret_values": true, "sensitive_output_strict_mode": true},
			"quick_actions": {"placement": "tab", "shell_command": ["bash", "-l"], "logs_tail": 1000,
				"debug_image": "nicolaka/netshoot:v0.13"},
			"kubectl": "/opt/homebrew/bin/kubectl",
			"kubeconfig": "/tmp/kc",
			"gitops": {}
		}]])
		expect(diags).toEqual({})
		expect(cfg.general.native_default).toBe(false)
		expect(cfg.general.max_rows).toBe(5000)
		expect(cfg.general.max_rendered_rows).toBe(100)
		expect(cfg.general.max_capture_bytes).toBe(1048576)
		expect(cfg.aliases.additional).toEqual({ "k", "kc" })
		expect(cfg.explore.allow_live_queries).toBe(false)
		expect(cfg.explore.query_timeout_ms).toBe(30000)
		expect(cfg.explore.relationship_max_nodes).toBe(50)
		expect(cfg.mutations.enabled).toBe(false)
		expect(cfg.mutations.interactive_guard).toBe(true)
		expect(cfg.mutations.allow_failed_preview_override).toBe(true)
		expect(cfg.mutations.preview_timeout_ms).toBe(5000)
		expect(cfg.mutations.execute_timeout_ms).toBe(60000)
		expect(cfg.security.show_secret_values).toBe(true)
		expect(cfg.security.sensitive_output_strict_mode).toBe(true)
		expect(cfg.quick_actions.placement).toBe("tab")
		expect(cfg.quick_actions.shell_command).toEqual({ "bash", "-l" })
		expect(cfg.quick_actions.logs_tail).toBe(1000)
		expect(cfg.quick_actions.debug_image).toBe("nicolaka/netshoot:v0.13")
		expect(cfg.kubectl).toBe("/opt/homebrew/bin/kubectl")
		expect(cfg.kubeconfig).toBe("/tmp/kc")
	end)

	it("keeps defaults for keys a partial file leaves out", function()
		local cfg, diags = parse([[{"general": {"max_rendered_rows": 50}}]])
		expect(#diags).toBe(0)
		expect(cfg.general.max_rendered_rows).toBe(50)
		expect(cfg.general.max_rows).toBe(20000)
		expect(cfg.explore).toEqual(Config.defaults().explore)
	end)

	-- tern.json.decode drops null members, so null means "use the default".
	it("treats a null kubeconfig as unset", function()
		local cfg, diags = parse([[{"kubeconfig": null}]])
		expect(#diags).toBe(0)
		expect(cfg.kubeconfig).toBeNil()
	end)

	it("expands a leading ~ in paths when the home directory is known", function()
		local cfg, diags = parse([[{"kubectl": "~/bin/kubectl", "kubeconfig": "~/.kube/dev"}]], { home = "/Users/me" })
		expect(#diags).toBe(0)
		expect(cfg.kubectl).toBe("/Users/me/bin/kubectl")
		expect(cfg.kubeconfig).toBe("/Users/me/.kube/dev")
	end)

	it("rejects a ~ path when the home directory is unknown", function()
		local cfg, diags = parse([[{"kubeconfig": "~/.kube/dev"}]])
		expect(cfg.kubeconfig).toBeNil()
		local d = find(diags, "kubeconfig")
		expect(d and d.level).toBe("error")
	end)

	-- A zero timeout would kill every preview before kubectl starts, and an
	-- unbounded execute would leave a hung mutation with no end.
	it("bounds the mutation timeouts", function()
		local cfg, diags = parse([[{"mutations": {"preview_timeout_ms": 0, "execute_timeout_ms": 99999999}}]])
		expect(cfg.mutations.preview_timeout_ms).toBe(30000)
		expect(cfg.mutations.execute_timeout_ms).toBe(300000)
		expect(find(diags, "mutations.preview_timeout_ms") ~= nil).toBe(true)
		expect(find(diags, "mutations.execute_timeout_ms") ~= nil).toBe(true)
	end)
end)

describe("config validation", function()
	it("falls back to the default on a wrong type and names the key path", function()
		local cfg, diags =
			parse([[{"general": {"max_rendered_rows": "lots"}, "security": {"show_secret_values": "yes"}}]])
		expect(cfg.general.max_rendered_rows).toBe(500)
		expect(cfg.security.show_secret_values).toBe(false)
		local rows = find(diags, "general.max_rendered_rows")
		expect(rows ~= nil).toBe(true)
		expect(rows.level).toBe("error")
		expect(contains(rows.message, "general.max_rendered_rows")).toBe(true)
		expect(contains(rows.message, "integer")).toBe(true)
		expect(contains(rows.message, "500")).toBe(true)
		local secrets = find(diags, "security.show_secret_values")
		expect(contains(secrets.message, "true or false")).toBe(true)
		expect(contains(secrets.message, "false")).toBe(true)
	end)

	it("rejects non-integers and out-of-range numbers", function()
		local cfg, diags = parse([[{"general": {"max_rows": 2.5, "max_rendered_rows": 0},
			"explore": {"query_timeout_ms": 99999999}, "quick_actions": {"logs_tail": -1}}]])
		expect(cfg.general.max_rows).toBe(20000)
		expect(cfg.general.max_rendered_rows).toBe(500)
		expect(cfg.explore.query_timeout_ms).toBe(10000)
		expect(cfg.quick_actions.logs_tail).toBe(200)
		expect(#diags).toBe(4)
		expect(contains(find(diags, "explore.query_timeout_ms").message, "between")).toBe(true)
	end)

	it("rejects values outside an enum and lists the allowed ones", function()
		local cfg, diags = parse([[{"quick_actions": {"placement": "left"}}]])
		expect(cfg.quick_actions.placement).toBe("right")
		local d = find(diags, "quick_actions.placement")
		expect(contains(d.message, '"right", "down", "tab"')).toBe(true)
	end)

	-- keyboard_mode was reserved but never read; it was removed instead of
	-- shipping a setting that does nothing, so old files only get a warning.
	it("treats the removed general.keyboard_mode as an unknown key", function()
		local cfg, diags = parse([[{"general": {"keyboard_mode": "keyboard"}}]])
		expect(cfg).toEqual(Config.defaults())
		expect(#diags).toBe(1)
		expect(diags[1].path).toBe("general.keyboard_mode")
		expect(diags[1].level).toBe("warning")
	end)

	it("rejects a section that is not an object and keeps its defaults", function()
		local cfg, diags = parse([[{"explore": true, "mutations": "off"}]])
		expect(cfg.explore).toEqual(Config.defaults().explore)
		expect(cfg.mutations).toEqual(Config.defaults().mutations)
		expect(contains(find(diags, "explore").message, "object")).toBe(true)
		expect(find(diags, "mutations") ~= nil).toBe(true)
	end)

	it("rejects an empty or non-string shell command", function()
		for _, text in
			{
				[[{"quick_actions": {"shell_command": []}}]],
				[[{"quick_actions": {"shell_command": "bash"}}]],
				[[{"quick_actions": {"shell_command": ["bash", 1]}}]],
				[[{"quick_actions": {"shell_command": ["", "-l"]}}]],
			}
		do
			local cfg, diags = parse(text)
			expect(cfg.quick_actions.shell_command).toEqual(Config.defaults().quick_actions.shell_command)
			expect(find(diags, "quick_actions.shell_command") ~= nil).toBe(true)
		end
	end)

	-- The image name lands in a kubectl argv; anything shell-like is a typo.
	it("rejects a debug image with whitespace", function()
		local cfg, diags = parse([[{"quick_actions": {"debug_image": "busybox latest"}}]])
		expect(cfg.quick_actions.debug_image).toBe("busybox:1.36")
		expect(find(diags, "quick_actions.debug_image") ~= nil).toBe(true)
	end)

	-- The daemon's working directory is not the user's, so a relative path
	-- would resolve somewhere unexpected.
	it("rejects relative paths but allows a bare kubectl program name", function()
		local cfg, diags = parse([[{"kubectl": "bin/kubectl", "kubeconfig": "kube/config"}]])
		expect(cfg.kubectl).toBe("kubectl")
		expect(cfg.kubeconfig).toBeNil()
		expect(#diags).toBe(2)
		local bare, none = parse([[{"kubectl": "kubecolor"}]])
		expect(bare.kubectl).toBe("kubecolor")
		expect(#none).toBe(0)
	end)
	it("rejects empty paths", function()
		local cfg, diags = parse([[{"kubectl": "", "kubeconfig": 3}]])
		expect(cfg.kubectl).toBe("kubectl")
		expect(cfg.kubeconfig).toBeNil()
		expect(find(diags, "kubectl") ~= nil).toBe(true)
		expect(find(diags, "kubeconfig") ~= nil).toBe(true)
	end)

	it("drops invalid alias names but keeps the valid ones", function()
		local cfg, diags = parse([[{"aliases": {"additional": ["k", "rm -rf", 7, "kc"]}}]])
		expect(cfg.aliases.additional).toEqual({ "k", "kc" })
		expect(find(diags, "aliases.additional[2]") ~= nil).toBe(true)
		expect(find(diags, "aliases.additional[3]") ~= nil).toBe(true)
	end)

	-- Auto refresh would poll the cluster, which Explore never does.
	it("refuses to enable auto refresh", function()
		local cfg, diags = parse([[{"explore": {"auto_refresh": true}}]])
		expect(cfg.explore.auto_refresh).toBe(false)
		local d = find(diags, "explore.auto_refresh")
		expect(d.level).toBe("warning")
	end)

	it("warns about unknown keys at every level", function()
		local cfg, diags = parse([[{"genral": {}, "general": {"max_row": 1}, "colour": "red"}]])
		expect(cfg).toEqual(Config.defaults())
		for _, path in { "genral", "general.max_row", "colour" } do
			local d = find(diags, path)
			expect(d ~= nil).toBe(true)
			expect(d.level).toBe("warning")
		end
	end)

	-- Helm releases feed `helm template` argv: anything that is not a plain
	-- path / DNS label is dropped with an error instead of reaching a process.
	it("validates gitops helm releases entry by entry", function()
		local cfg, diags = parse(
			[[{"gitops": {"helm": [
				{"chart": "charts/web", "release": "web", "namespace": "tern-test-helm", "values": ["~/v.yaml", "values-staging.yaml"]},
				{"chart": "charts/api", "release": "Bad_Release"},
				{"chart": "", "release": "x"},
				{"chart": "c", "release": "y", "values": "v.yaml"},
				"web"
			]}}]],
			{ home = "/home/u" }
		)
		expect(cfg.gitops.helm).toEqual({
			{
				chart = "charts/web",
				release = "web",
				namespace = "tern-test-helm",
				values = { "/home/u/v.yaml", "values-staging.yaml" },
			},
		})
		for _, path in { "gitops.helm[2]", "gitops.helm[3]", "gitops.helm[4]", "gitops.helm[5]" } do
			expect(find(diags, path).level).toBe("error")
		end
	end)

	it("reads the gitops scan limits, unmanaged kinds and gh program", function()
		local cfg, diags = parse([[{"gitops": {"max_files": 50, "max_bytes": 2097152, "max_file_bytes": 8192,
			"render_kustomize": false, "unmanaged_kinds": ["Deployment", "widgets.example.com", "bad kind"],
			"gh": "/opt/bin/gh"}}]])
		expect(cfg.gitops.max_files).toBe(50)
		expect(cfg.gitops.max_bytes).toBe(2097152)
		expect(cfg.gitops.max_file_bytes).toBe(8192)
		expect(cfg.gitops.render_kustomize).toBe(false)
		expect(cfg.gitops.unmanaged_kinds).toEqual({ "Deployment", "widgets.example.com" })
		expect(cfg.gitops.gh).toBe("/opt/bin/gh")
		expect(find(diags, "gitops.unmanaged_kinds[3]").level).toBe("error")
		local bad, wrong = parse([[{"gitops": {"max_files": 0, "gh": "bin/gh", "roots": []}}]])
		expect(bad.gitops.max_files).toBe(2000)
		expect(bad.gitops.gh).toBe("gh")
		expect(find(wrong, "gitops.max_files").level).toBe("error")
		expect(find(wrong, "gitops.gh").level).toBe("error")
		expect(find(wrong, "gitops.roots").level).toBe("warning")
		local _, notObject = parse([[{"gitops": "on"}]])
		expect(find(notObject, "gitops").level).toBe("error")
	end)

	it("reports diagnostics in a stable order", function()
		local _, diags = parse([[{"zeta": 1, "alpha": 1, "general": {"max_rows": "x"}}]])
		local paths = {}
		for _, d in diags do
			table.insert(paths, d.path)
		end
		expect(paths).toEqual({ "general.max_rows", "alpha", "zeta" })
	end)
end)

describe("config schema_version", function()
	it("warns about a newer schema but still applies known sections", function()
		local cfg, diags = parse([[{"schema_version": 3, "general": {"max_rendered_rows": 42}, "future": {}}]])
		expect(cfg.general.max_rendered_rows).toBe(42)
		expect(cfg.schema_version).toBe(3)
		local d = find(diags, "schema_version")
		expect(d.level).toBe("warning")
		expect(contains(d.message, "3")).toBe(true)
		expect(contains(d.message, "1")).toBe(true)
		local future = find(diags, "future")
		expect(contains(future.message, "newer")).toBe(true)
	end)

	it("rejects an invalid schema_version", function()
		for _, text in { [[{"schema_version": "1"}]], [[{"schema_version": 0}]], [[{"schema_version": 1.5}]] } do
			local cfg, diags = parse(text)
			expect(cfg.schema_version).toBe(1)
			expect(find(diags, "schema_version").level).toBe("error")
		end
	end)
end)

describe("config invalid JSON", function()
	it("uses defaults and reports the byte offset of a syntax error", function()
		local cfg, diags = parse('{"general": {"max_rows": 10,}}')
		expect(cfg).toEqual(Config.defaults())
		expect(#diags).toBe(1)
		expect(diags[1].level).toBe("error")
		expect(diags[1].path).toBe("")
		expect(diags[1].offset).toBe(29)
		expect(contains(diags[1].message, "byte 29")).toBe(true)
	end)

	-- Real Tern 0.6.2 message: serde_json "line L column C" plus a traceback.
	it("converts a line and column position into a byte offset and drops the traceback", function()
		local function ternDecode(_: string): any
			error(
				"runtime error: tern.json.decode: key must be a string at line 3 column 3\n"
					.. "stack traceback:\n        [C]: in ?",
				0
			)
		end
		local _, diags = Config.parse('{\n  "a": 1,\n  x}', ternDecode)
		expect(diags[1].offset).toBe(15)
		expect(diags[1].line).toBe(3)
		expect(diags[1].column).toBe(3)
		expect(contains(diags[1].message, "key must be a string at line 3 column 3.")).toBe(true)
		expect(contains(diags[1].message, "traceback")).toBe(false)
		expect(contains(diags[1].message, "runtime error")).toBe(false)
	end)

	it("still reports a decode error without a position", function()
		local function opaque(_: string): any
			error("boom", 0)
		end
		local cfg, diags = Config.parse("{", opaque)
		expect(cfg).toEqual(Config.defaults())
		expect(diags[1].offset).toBeNil()
		expect(contains(diags[1].message, "boom")).toBe(true)
	end)

	it("rejects a top-level value that is not an object", function()
		for _, text in { "[]", "[1, 2]", '"x"', "42" } do
			local cfg, diags = parse(text)
			expect(cfg).toEqual(Config.defaults())
			expect(diags[1].level).toBe("error")
		end
	end)
end)

describe("config path", function()
	it("prefers an absolute XDG_CONFIG_HOME", function()
		expect(Config.path({ XDG_CONFIG_HOME = "/x/cfg", HOME = "/Users/me" })).toBe("/x/cfg/tern-kube/config.json")
	end)

	-- The XDG spec says relative values are invalid and must be ignored.
	it("falls back to HOME/.config when XDG_CONFIG_HOME is unset, empty or relative", function()
		local want = "/Users/me/.config/tern-kube/config.json"
		expect(Config.path({ HOME = "/Users/me" })).toBe(want)
		expect(Config.path({ XDG_CONFIG_HOME = "", HOME = "/Users/me" })).toBe(want)
		expect(Config.path({ XDG_CONFIG_HOME = "cfg", HOME = "/Users/me/" })).toBe(want)
	end)

	it("has no path without a usable directory", function()
		expect(Config.path({})).toBeNil()
		expect(Config.path({ HOME = "" })).toBeNil()
	end)
end)

describe("config kubectl program", function()
	-- The kv override exists for tests and the settings flow; an explicit
	-- config path beats the environment; a bare default defers to it.
	it("resolves kv override, then config, then TKUBE_KUBECTL, then kubectl", function()
		local custom = parse([[{"kubectl": "/opt/k"}]])
		local plain = parse(nil)
		expect(Config.kubectlProgram(custom, "/kv/k", "/env/k")).toBe("/kv/k")
		expect(Config.kubectlProgram(custom, nil, "/env/k")).toBe("/opt/k")
		expect(Config.kubectlProgram(plain, "", "/env/k")).toBe("/env/k")
		expect(Config.kubectlProgram(plain, 5, "")).toBe("kubectl")
	end)
end)
return nil
