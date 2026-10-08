SHELL = /bin/sh

BIN = .tools/bin
LUAU = $(BIN)/luau
LUAU_LSP = $(BIN)/luau-lsp
STYLUA = $(BIN)/stylua
SELENE = $(BIN)/selene
TERN_DEFS = .tools/types/tern.lsp.d.luau

LUAU_DIRS = $(wildcard plugin tests)
FILTER =

.PHONY: bootstrap tools fixtures test test-runner-selfcheck lint fmt fmt-check typecheck check

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

lint: tools
	$(SELENE) $(LUAU_DIRS)

fmt: tools
	$(STYLUA) $(LUAU_DIRS)

fmt-check: tools
	$(STYLUA) --check $(LUAU_DIRS)

typecheck: tools
	$(LUAU_LSP) analyze --platform=standard --definitions=@tern=$(TERN_DEFS) $(LUAU_DIRS)

check: fmt-check lint typecheck test-runner-selfcheck test
