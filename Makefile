.DEFAULT_GOAL := help
.PHONY: help install dev frontend build build-windows test typecheck clean

REPO_ROOT := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
export INSTALLER_REPO_DIR ?= $(REPO_ROOT)/shell

# Windows distribution paths. The Tauri build emits claw-gui.exe under
# target/<triple>/release/ and (via tauri-build) copies the shell/ tree
# alongside it. We then stage a tidy directory and zip them together so the
# customer gets one artifact to extract.
WIN_TARGET_DIR  := $(REPO_ROOT)/gui/src-tauri/target/x86_64-pc-windows-msvc/release
WIN_DIST_DIR    := $(REPO_ROOT)/dist/windows
WIN_STAGE_DIR   := $(WIN_DIST_DIR)/claw-installer
WIN_ZIP         := $(WIN_DIST_DIR)/claw-installer-windows.zip

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

build-windows: install ## Cross-compile Windows .exe and zip with shell/ for distribution
	@command -v cargo-xwin >/dev/null || { echo "cargo-xwin not found. Run: cargo install cargo-xwin"; exit 1; }
	@rustup target list --installed | grep -q x86_64-pc-windows-msvc || rustup target add x86_64-pc-windows-msvc
	pnpm --filter ./gui tauri build --runner cargo-xwin --target x86_64-pc-windows-msvc --no-bundle
	@# tauri-build copies "../../shell" → target/release/shell/ but the .exe
	@# alone is useless: at runtime resource_dir() expects shell/ alongside.
	@# Stage both into dist/windows/claw-installer/ then zip.
	@echo "==> staging Windows distribution"
	@rm -rf "$(WIN_STAGE_DIR)" "$(WIN_ZIP)"
	@mkdir -p "$(WIN_STAGE_DIR)"
	@cp "$(WIN_TARGET_DIR)/claw-gui.exe" "$(WIN_STAGE_DIR)/claw-installer.exe"
	@# `--no-bundle` skips Tauri's resource copy into target/release/, so we
	@# stage shell/ directly from the repo's source-of-truth instead.
	@cp -R "$(REPO_ROOT)/shell" "$(WIN_STAGE_DIR)/shell"
	@# Sanity: customer's bootstrap.ps1 must have UTF-8 BOM (PS 5.1 needs it
	@# to decode the Chinese strings in the script).
	@head -c 3 "$(WIN_STAGE_DIR)/shell/windows/bootstrap.ps1" | xxd -p | grep -q '^efbbbf' \
		|| { echo "!! ERROR: bootstrap.ps1 missing UTF-8 BOM — refusing to ship"; exit 1; }
	@echo "==> creating $(WIN_ZIP)"
	@cd "$(WIN_DIST_DIR)" && zip -qr "$(notdir $(WIN_ZIP))" claw-installer
	@echo ""
	@echo "✓ Built: $(WIN_ZIP)"
	@echo "  Customer instructions: unzip → open the claw-installer folder → double-click claw-installer.exe"

test: ## Run frontend + Rust test suites
	pnpm --filter ./gui test
	cargo test --manifest-path gui/src-tauri/Cargo.toml

typecheck: ## Run TypeScript typecheck on the GUI
	pnpm --filter ./gui typecheck

clean: ## Remove build artifacts and node_modules
	rm -rf gui/dist gui/src-tauri/target gui/node_modules node_modules dist
