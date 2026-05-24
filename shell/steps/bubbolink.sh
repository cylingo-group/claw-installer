#!/usr/bin/env bash
# steps/bubbolink.sh — install the @bubbolink/cli global npm package via pnpm.
# Requires pnpm on PATH (run steps/pnpm.sh first) and the npm registry mirror
# already configured (run steps/npmrc.sh first).

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_bubbolink() {
  display "@@step:bubbolink:Installing @bubbolink/cli…"
  command -v pnpm >/dev/null 2>&1 \
    || die_step "Install @bubbolink/cli" "pnpm not on PATH — run steps/pnpm.sh first" 1

  if command -v bubbolink >/dev/null 2>&1 && [[ -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    display "@bubbolink/cli is already installed; skipping (version $(bubbolink --version 2>/dev/null || echo unknown))"
    manifest_record pnpm_global_pkg "@bubbolink/cli" preexisting
    return
  fi

  log "pnpm add -g @bubbolink/cli (registry=${NPM_REGISTRY:-default})"
  # Close stdin so pnpm 11's interactive "approve build scripts" prompt
  # falls back to non-interactive mode (matches openclaw_pkg install).
  run pnpm add -g @bubbolink/cli </dev/null
  hash -r 2>/dev/null || true
  command -v bubbolink >/dev/null 2>&1 \
    || die_step "Install @bubbolink/cli" "bubbolink not on PATH after install (PNPM_HOME=${PNPM_HOME:-unset})" 1
  display "✓ @bubbolink/cli installed: $(command -v bubbolink)"
  manifest_record pnpm_global_pkg "@bubbolink/cli" installed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_bubbolink
fi
