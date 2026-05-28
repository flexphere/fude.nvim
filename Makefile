.PHONY: lint format format-check test check-state-deps check-purity all setup

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

all: lint format-check test check-state-deps check-purity

setup:
	git config core.hooksPath .githooks
