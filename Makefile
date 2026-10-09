SHELL = /bin/sh

BIN = .tools/bin
LUAU = $(BIN)/luau
LUAU_LSP = $(BIN)/luau-lsp
STYLUA = $(BIN)/stylua
SELENE = $(BIN)/selene
TERN_DEFS = .tools/types/tern.lsp.d.luau

LUAU_DIRS = $(wildcard plugin tests) scripts/bench.luau scripts/gen-config-schema.luau
FILTER =

.PHONY: bootstrap tools fixtures test test-runner-selfcheck bench e2e lint fmt fmt-check typecheck schema schema-check check

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

# schema/config.schema.json is generated from plugin/lib/config.luau.
schema: tools
	@$(LUAU) scripts/gen-config-schema.luau >schema/config.schema.json.tmp && \
		mv schema/config.schema.json.tmp schema/config.schema.json

schema-check: tools
	@$(LUAU) scripts/gen-config-schema.luau | cmp -s - schema/config.schema.json || \
		{ echo "schema/config.schema.json is stale: run 'make schema'" >&2; exit 1; }

check: fmt-check lint typecheck schema-check test-runner-selfcheck test bench

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

.PHONY: shots-optimize
OXIPNG = $(BIN)/oxipng
PNGQUANT = $(BIN)/pngquant
# Shrinks docs/screenshots/*.png in place: pngquant palette quantization with
# a quality floor of 95 (a shot it cannot hold stays truecolor), then lossless
# oxipng. Already-indexed PNGs skip pngquant and oxipng never rewrites a file
# it cannot shrink, so reruns change nothing.
shots-optimize:
	@for t in $(OXIPNG) $(PNGQUANT); do \
		[ -x "$$t" ] || { echo "missing $$t: run 'make bootstrap'" >&2; exit 1; }; \
	done; \
	set -- docs/screenshots/*.png; [ -e "$$1" ] || exit 0; \
	for f in "$$@"; do \
		[ "$$(od -An -N8 -tx1 "$$f" | tr -d ' \n')" = 89504e470d0a1a0a ] || { echo "$$f: not PNG data" >&2; exit 1; }; \
		[ "$$(od -An -j25 -N1 -tu1 "$$f" | tr -d ' ')" = 3 ] && continue; \
		rc=0; $(PNGQUANT) --quality=95-100 --speed 1 --strip --skip-if-larger --force --ext .png -- "$$f" || rc=$$?; \
		case $$rc in 0 | 98 | 99) ;; *) echo "pngquant failed on $$f ($$rc)" >&2; exit 1 ;; esac; \
	done; \
	$(OXIPNG) -q -o 4 --strip safe -- "$$@"
