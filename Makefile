.PHONY: lint format format-check test check-state-deps check-purity check-docs check-doc-lang coverage all setup

lint:
	luacheck lua/ plugin/ tests/ scripts/

format:
	stylua lua/ plugin/ tests/ scripts/

format-check:
	stylua --check lua/ plugin/ tests/ scripts/

test:
	bash run_tests.sh

check-state-deps:
	nvim --headless -l scripts/check_state_deps.lua

check-purity:
	nvim --headless -l scripts/check_purity.lua

check-docs:
	nvim --headless -l scripts/check_docs.lua

# Optional ROOT=<dir> on the make command line checks another directory
# (default: the repository root). ROOT from the environment is ignored, since
# make imports environment variables and an exported ROOT would otherwise
# redirect `make all` to another directory.
DOC_LANG_ROOT := $(if $(filter command line,$(origin ROOT)),$(ROOT))

check-doc-lang:
	nvim --headless -l scripts/check_doc_lang.lua $(if $(DOC_LANG_ROOT),"$(DOC_LANG_ROOT)")

# Test coverage via luacov. Requires `luarocks install --local luacov`.
# `eval $(luarocks path)` exports LUA_PATH so nvim can require("luacov.runner").
# Stats and report files are gitignored. Not part of `make all` (report-only).
coverage:
	@rm -f luacov.stats.out luacov.report.out
	@eval "$$(luarocks path)" && LUACOV=1 bash run_tests.sh
	@eval "$$(luarocks path)" && luacov
	@echo ""
	@echo "==> Coverage summary:"
	@awk '/^Summary$$/,0' luacov.report.out
	@echo ""
	@echo "==> Full report: luacov.report.out"

all: lint format-check test check-state-deps check-purity check-docs check-doc-lang

setup:
	git config core.hooksPath .githooks
