--!strict
-- The redaction policy decides what the native views hide. Masking Secrets
-- is the safe default; strict mode is an opt-in heuristic over key names,
-- so its boundaries (what counts as a sensitive name) are pinned here.
local Config = require("../../../plugin/lib/config")
local Redact = require("../../../plugin/lib/model/redact")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("redact policy", function()
	it("masks Secrets and skips the heuristic by default", function()
		expect(Redact.DEFAULT).toEqual({ showSecrets = false, strict = false })
		expect(table.isfrozen(Redact.DEFAULT)).toBe(true)
	end)

	it("reads both security settings from the config", function()
		local cfg = Config.parse(
			[[{"security": {"show_secret_values": true, "sensitive_output_strict_mode": true}}]],
			json.decode
		)
		expect(Redact.fromConfig(cfg)).toEqual({ showSecrets = true, strict = true })
		expect(Redact.fromConfig(Config.defaults())).toEqual({ showSecrets = false, strict = false })
	end)

	-- A missing config must never weaken masking.
	it("falls back to the default without a config", function()
		expect(Redact.fromConfig(nil)).toEqual(Redact.DEFAULT)
	end)
end)

describe("redact.sensitiveKey", function()
	it("matches the listed words in env var, snake, kebab, dotted and camelCase names", function()
		for _, name in
			{
				"DB_PASSWORD",
				"password",
				"mysql-passwd",
				"AWS_SECRET_ACCESS_KEY",
				"clientSecret",
				"GITHUB_TOKEN",
				"auth.token",
				"API_KEY",
				"apiKey",
				"APIKey",
				"apikey",
				"PRIVATE_KEY",
				"privateKey",
				"GOOGLE_APPLICATION_CREDENTIALS",
				"credentials",
				"tokens",
				"Passwords",
			}
		do
			if not Redact.sensitiveKey(name) then
				error("expected sensitive: " .. name)
			end
		end
	end)

	-- Substring matching would mask `tokenizer_mode` or `secretary`; only
	-- whole name segments count, so unrelated settings stay readable.
	it("ignores names that merely contain a word inside another word", function()
		for _, name in
			{ "tokenizer_mode", "TOKENIZER", "secretary", "passwordless", "LOG_LEVEL", "key", "api", "private" }
		do
			if Redact.sensitiveKey(name) then
				error("expected not sensitive: " .. name)
			end
		end
	end)

	-- secretName / secretKeyRef name the Secret that holds a value; hiding
	-- them would hide where the value lives without protecting anything.
	it("treats names ending in name or ref as references", function()
		expect(Redact.sensitiveKey("secretName")).toBe(false)
		expect(Redact.sensitiveKey("SecretName")).toBe(false)
		expect(Redact.sensitiveKey("tokenSecretRef")).toBe(false)
		expect(Redact.sensitiveKey("secret_name")).toBe(false)
	end)
end)

describe("redact.maskValue", function()
	it("reports the size of a string, like the Secret masks", function()
		expect(Redact.maskValue("hunter2")).toBe("<redacted: 7 bytes>")
		expect(Redact.maskValue("aGk=", " base64")).toBe("<redacted: 4 bytes base64>")
		expect(Redact.maskValue(42)).toBe("<redacted>")
	end)

	-- Views mask objects that were already masked when captured; masking a
	-- mask again would report the mask's own length as the secret's size.
	it("leaves an existing mask unchanged", function()
		expect(Redact.isMask("<redacted: 7 bytes>")).toBe(true)
		expect(Redact.isMask("<redacted>")).toBe(true)
		expect(Redact.isMask("redacted")).toBe(false)
		expect(Redact.maskValue("<redacted: 7 bytes>")).toBe("<redacted: 7 bytes>")
	end)
end)

describe("redact.notices", function()
	local MASKED = "masked text"

	it("keeps the masking notice for Secret output by default", function()
		expect(Redact.notices(Redact.DEFAULT, true, true, MASKED)).toEqual({ MASKED })
		expect(Redact.notices(Redact.DEFAULT, false, false, MASKED)).toEqual({})
	end)

	-- With values shown the user still has to know the output is sensitive.
	it("warns instead when Secret values are shown", function()
		local shown = { showSecrets = true, strict = false }
		expect(Redact.notices(shown, true, false, MASKED)).toEqual({ Redact.REVEALED })
		expect(Redact.REVEALED).toContain("security.show_secret_values")
	end)

	it("says when strict mode hid values", function()
		local strict = { showSecrets = false, strict = true }
		expect(Redact.notices(strict, false, true, MASKED)).toEqual({ Redact.STRICT })
		expect(Redact.notices(strict, true, true, MASKED)).toEqual({ MASKED })
		local both = { showSecrets = true, strict = true }
		expect(Redact.notices(both, true, true, MASKED)).toEqual({ Redact.REVEALED, Redact.STRICT })
	end)
end)

local function shape(_: any): boolean
	return false
end

local STRICT = table.freeze({ showSecrets = false, strict = true }) :: Redact.Policy
local SHOWN = table.freeze({ showSecrets = true, strict = false }) :: Redact.Policy

describe("redact.isCredentialText", function()
	-- Credentials end up in values under innocuous keys (`config.dsn`,
	-- `extraEnv[0].value`); their shape is the only signal left.
	it("recognises private keys, URL passwords, JWTs and bearer tokens", function()
		for _, s in
			{
				"-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----",
				"-----BEGIN PRIVATE KEY-----\nabc",
				"-----BEGIN OPENSSH PRIVATE KEY-----",
				"postgres://app:hunter2@db:5432/app",
				"https://user:p%40ss@example.com/x",
				"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln",
				"Bearer abcdef123456",
			}
		do
			if not Redact.isCredentialText(s) then
				error("expected credential text: " .. s)
			end
		end
	end)

	-- Certificates and plain URLs are public; masking them would hide the
	-- configuration users come to read.
	it("leaves certificates, public keys and URLs without a password alone", function()
		for _, s in
			{
				"-----BEGIN CERTIFICATE-----\nMIIB",
				"-----BEGIN PUBLIC KEY-----",
				"https://example.com/path",
				"postgres://app@db:5432/app",
				"http://host:8080/x",
				"eyJhbGciOi",
				"bearer",
				"",
			}
		do
			if Redact.isCredentialText(s) then
				error("expected not credential text: " .. s)
			end
		end
	end)
end)

describe("redact.maskTree", function()
	-- Helm values are not Secrets, but charts copy them into ConfigMaps,
	-- notes and env vars; the key name rule is on for them in every mode.
	it("masks scalars under sensitive keys, whole subtrees under sensitive tables", function()
		local values = {
			auth = { password = "hunter2-REDACTME", apiToken = "tok-REDACTME", user = "app" },
			credentials = { aws = { id = "AKIAEXAMPLE", region = "eu" } },
			image = { tag = "1.27" },
			replicaCount = 2,
		}
		local m = Redact.maskTree(values, Redact.DEFAULT, shape)
		expect(m.value).toEqual({
			auth = { password = "<redacted: 16 bytes>", apiToken = "<redacted: 12 bytes>", user = "app" },
			credentials = { aws = { id = "<redacted: 11 bytes>", region = "<redacted: 2 bytes>" } },
			image = { tag = "1.27" },
			replicaCount = 2,
		})
		expect(m.masked).toBe(4)
		table.sort(m.secrets)
		expect(m.secrets).toEqual({ "AKIAEXAMPLE", "hunter2-REDACTME", "tok-REDACTME" })
	end)

	-- secretName points at a Secret; masking it hides where the value lives.
	it("keeps reference names and non-secret scalars", function()
		local values = { existingSecretName = "db-creds", tls = { secretName = "tls" }, enabled = true }
		local m = Redact.maskTree(values, Redact.DEFAULT, shape)
		expect(m.value).toEqual({ existingSecretName = "db-creds", tls = { secretName = "tls" }, enabled = true })
		expect(m.masked).toBe(0)
	end)

	-- Only the password of a DSN is secret; host and database stay readable.
	it("masks the URL password and PEM blocks by shape under any key", function()
		local pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\n"
		local values = { config = { dsn = "postgres://app:hunter2-REDACTME@db:5432/app", tlsPem = pem } }
		local m = Redact.maskTree(values, Redact.DEFAULT, shape)
		expect(m.value.config.dsn).toBe("postgres://app:<redacted: 16 bytes>@db:5432/app")
		expect(m.value.config.tlsPem).toBe("<redacted: " .. #pem .. " bytes>")
		expect(m.masked).toBe(2)
		expect(table.find(m.secrets, "hunter2-REDACTME") ~= nil).toBe(true)
		expect(table.find(m.secrets, pem) ~= nil).toBe(true)
		-- Templates re-indent multi-line values (`| nindent 4`), so the
		-- whole block never appears verbatim; its long lines still do.
		expect(table.find(m.secrets, "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC") ~= nil).toBe(true)
	end)

	-- Lists are values like any other: an entry under a sensitive key is
	-- masked, a list of plain strings is not.
	it("walks lists and keeps the sensitive context of their parent key", function()
		local m = Redact.maskTree({ tokens = { "aaaa-1", "bbbb-2" }, hosts = { "a.example" } }, Redact.DEFAULT, shape)
		expect(m.value).toEqual({ tokens = { "<redacted: 6 bytes>", "<redacted: 6 bytes>" }, hosts = { "a.example" } })
	end)

	it("adds auth, cert and key names in strict mode only", function()
		local values = { authConfig = { realm = "corp" }, tlsCert = "cert-data", keyFile = "k.pem", monkey = "x" }
		expect(Redact.maskTree(values, Redact.DEFAULT, shape).masked).toBe(0)
		local m = Redact.maskTree(values, STRICT, shape)
		expect(m.value).toEqual({
			authConfig = { realm = "<redacted: 4 bytes>" },
			tlsCert = "<redacted: 9 bytes>",
			keyFile = "<redacted: 5 bytes>",
			monkey = "x",
		})
	end)

	it("returns the input untouched when Secret values are shown", function()
		local values = { auth = { password = "hunter2-REDACTME" } }
		local m = Redact.maskTree(values, SHOWN, shape)
		expect(m.value).toBe(values)
		expect(m.secrets).toEqual({})
		expect(m.masked).toBe(0)
	end)

	-- Tern tags decoded arrays; a copy of an empty list would turn into `{}`
	-- in YAML, so unchanged subtrees keep their identity.
	it("shares unchanged subtrees and never mutates the input", function()
		local empty = {}
		local image = { tag = "1" }
		local values = { list = empty, image = image, auth = { password = "abcd" } }
		local m = Redact.maskTree(values, Redact.DEFAULT, shape)
		expect(m.value.list).toBe(empty)
		expect(m.value.image).toBe(image)
		expect(values.auth.password).toBe("abcd")
	end)

	-- Short values (`on`, `1`) would mask unrelated text everywhere; existing
	-- masks are not secrets.
	it("collects only echo candidates of at least four bytes", function()
		local values = { password = "abc", token = "<redacted: 7 bytes>", secret = 1234 }
		local m = Redact.maskTree(values, Redact.DEFAULT, shape)
		expect(m.secrets).toEqual({})
		expect(m.value.secret).toBe("<redacted>")
		expect(m.masked).toBe(2)
	end)
end)

describe("redact.maskEchoes", function()
	-- kubectl masks Secret data only; a chart that templates the password
	-- into a ConfigMap DSN or NOTES.txt would leak it in clear (F13).
	it("masks secret values echoed into a ConfigMap and notes", function()
		local text = table.concat({
			"kind: ConfigMap",
			"data:",
			'  dsn: "postgres://app:hunter2-REDACTME@db:5432/app"',
			"API token: tok-REDACTME",
			"",
		}, "\n")
		local out, n = Redact.maskEchoes(text, { "tok-REDACTME", "hunter2-REDACTME" })
		expect(n).toBe(2)
		expect((string.find(out, "REDACTME", 1, true))).toBeNil()
		expect(out).toContain('dsn: "postgres://app:<redacted: 16 bytes>@db:5432/app"')
		expect(out).toContain("API token: <redacted: 12 bytes>")
	end)

	-- With `pass` and `password1` both secret, shortest-first would leave
	-- `word1` of the longer one in clear.
	it("replaces longer secrets first and never inside an earlier mask", function()
		local out, n = Redact.maskEchoes("a=password1 b=pass c=pass", { "pass", "password1", "bytes" })
		expect(out).toBe("a=<redacted: 9 bytes> b=<redacted: 4 bytes> c=<redacted: 4 bytes>")
		expect(n).toBe(3)
	end)

	it("ignores short, duplicate and mask-shaped entries and handles pattern characters", function()
		local out, n = Redact.maskEchoes("x=a.b% y=on z=a.b%", { "on", "a.b%", "a.b%", "<redacted>" })
		expect(out).toBe("x=<redacted: 4 bytes> y=on z=<redacted: 4 bytes>")
		expect(n).toBe(2)
		local same, zero = Redact.maskEchoes("nothing here", {})
		expect(same).toBe("nothing here")
		expect(zero).toBe(0)
	end)
end)

describe("redact.hiddenChange", function()
	-- A password rotation renders as identical masked text; the view must
	-- still say something changed instead of showing "no changes".
	it("reports raw text that differs only inside masked secrets", function()
		local old = "dsn: postgres://app:hunter2-REDACTME@db\n"
		local new = "dsn: postgres://app:hunter3-REDACTME@db\n"
		local secrets = { "hunter2-REDACTME", "hunter3-REDACTME" }
		expect(Redact.hiddenChange(old, new, secrets)).toBe(true)
		expect(Redact.hiddenChange(old, old, secrets)).toBe(false)
		expect(Redact.hiddenChange(old, "dsn: other\n", secrets)).toBe(false)
	end)
end)

return nil
