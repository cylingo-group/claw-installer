#!/usr/bin/env bash
# steps/pnpm.sh — enable pnpm via corepack and set up PNPM_HOME on PATH.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_pnpm() {
  : "${PLATFORM:?PLATFORM not set — call detect_platform first}"
  command -v corepack >/dev/null 2>&1 || die "corepack not on PATH — run steps/node.sh first"
  log "Enabling pnpm via corepack (registry=$NPM_REGISTRY)"
  corepack enable
  corepack prepare pnpm@latest --activate
  manifest_record corepack_pnpm "pnpm@latest" activated
  if [[ "$PLATFORM" == "macos" ]]; then
    export PNPM_HOME="${PNPM_HOME:-$HOME/Library/pnpm}"
  else
    export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
  fi
  local pnpm_home_status="created"
  [[ -d "$PNPM_HOME" ]] && pnpm_home_status="preexisting"
  mkdir -p "$PNPM_HOME" "$PNPM_HOME/bin"
  manifest_record pnpm_home "$PNPM_HOME" "$pnpm_home_status"
  # pnpm 9+ keeps global bins under $PNPM_HOME/bin; older versions used
  # $PNPM_HOME itself. Add both to PATH so either layout works.
  case ":$PATH:" in *":$PNPM_HOME/bin:"*) ;; *) export PATH="$PNPM_HOME/bin:$PATH" ;; esac
  case ":$PATH:" in *":$PNPM_HOME:"*)     ;; *) export PATH="$PNPM_HOME:$PATH"     ;; esac
  # Best-effort: write pnpm path into user profile. We manage our own shell rc
  # block below, so failures here are non-fatal.
  SHELL="${SHELL:-/bin/bash}" pnpm setup >/dev/null 2>&1 || true
  log "pnpm version: $(pnpm --version) (PNPM_HOME=$PNPM_HOME)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_pnpm
fi
