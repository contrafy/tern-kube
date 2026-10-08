SHELL = /bin/sh

BIN = .tools/bin
LUAU = $(BIN)/luau
LUAU_LSP = $(BIN)/luau-lsp
STYLUA = $(BIN)/stylua
SELENE = $(BIN)/selene
TERN_DEFS = .tools/types/tern.lsp.d.luau

LUAU_DIRS = $(wildcard plugin tests) scripts/bench.luau
FILTER =

.PHONY: bootstrap tools fixtures test test-runner-selfcheck bench e2e lint fmt fmt-check typecheck check

bootstrap:
	sh scripts/bootstrap.sh

fixtures:
	@sh scripts/fixtures/embed.sh

tools:
	@for f in $(LUAU) $(LUAU_LSP) $(STYLUA) $(SELENE) $(TERN_DEFS); do \
		[ -e "$$f" ] || { echo "missing $$f: run 'make bootstrap'" >&2; exit 1; }; \
	done

test: tools fixtures
	@[ -d tests/unit ] || { echo "no tests/unit directory" >&2; exit 1; }; \
	set -- $$(find tests/unit -name '*.spec.luau' | sort); \
	[ $$# -gt 0 ] || { echo "no specs under tests/unit" >&2; exit 1; }; \
	if [ -n "$(FILTER)" ]; then set -- "$(FILTER)" "$$@"; fi; \
	$(LUAU) tests/run.luau -a "$$@"

test-runner-selfcheck: tools
	@LUAU=$(LUAU) sh tests/selfcheck/check.sh

# Deterministic standalone benchmark; fails only on gross regressions.
bench: tools fixtures
	@$(LUAU) scripts/bench.luau

# Drives an isolated Tern window (local only; skipped when `tern` is absent).
e2e:
	@sh scripts/e2e.sh

lint: tools
	$(SELENE) $(LUAU_DIRS)

fmt: tools
	$(STYLUA) $(LUAU_DIRS)

fmt-check: tools
	$(STYLUA) --check $(LUAU_DIRS)

# Transcripts recorded by tests/integration/mutate are gitignored, not sources.
typecheck: tools fixtures
	$(LUAU_LSP) analyze --platform=standard --definitions=@tern=$(TERN_DEFS) --ignore='**/.transcripts/**' $(LUAU_DIRS)

check: fmt-check lint typecheck test-runner-selfcheck test bench

.PHONY: test-shell-aliases
test-shell-aliases:
	@sh tests/shell/aliases/run.sh

.PHONY: guard-flags guard-flags-check test-shell-guard
# Regenerates the flag table embedded in shell/tern-kube-guard.
guard-flags:
	@LUAU=$(LUAU) sh scripts/guard/gen-flags

guard-flags-check:
	@LUAU=$(LUAU) sh scripts/guard/gen-flags --check

test-shell-guard: guard-flags-check
	@LUAU=$(LUAU) sh tests/shell/guard/run.sh

.PHONY: test-shell-drift
test-shell-drift:
	@LUAU=$(LUAU) sh tests/shell/drift/run.sh
