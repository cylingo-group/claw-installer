.DEFAULT_GOAL := help
.PHONY: help install dev frontend build test typecheck clean

REPO_ROOT := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
export INSTALLER_REPO_DIR ?= $(REPO_ROOT)/shell

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: ## Install workspace dependencies via pnpm
	pnpm install

dev: install ## Start the GUI in Tauri dev mode (recommended)
	pnpm --filter ./gui tauri dev

frontend: install ## Start only the Vite dev server (browser stub mode, no Rust)
	pnpm --filter ./gui dev

build: install ## Produce a production bundle for the current platform
	pnpm --filter ./gui tauri build

test: ## Run frontend + Rust test suites
	pnpm --filter ./gui test
	cargo test --manifest-path gui/src-tauri/Cargo.toml

typecheck: ## Run TypeScript typecheck on the GUI
	pnpm --filter ./gui typecheck

clean: ## Remove build artifacts and node_modules
	rm -rf gui/dist gui/src-tauri/target gui/node_modules node_modules
