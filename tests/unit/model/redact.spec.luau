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

return nil
