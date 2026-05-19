#!/usr/bin/env bash
# steps/pnpm.sh — enable pnpm via corepack and set up PNPM_HOME on PATH.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_pnpm() {
  : "${PLATFORM:?PLATFORM not set — call detect_platform first}"
  display "@@step:pnpm:正在准备 pnpm 包管理器…"
  command -v corepack >/dev/null 2>&1 || die_step "准备 pnpm" "corepack not on PATH — run steps/node.sh first" 1
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

  if command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1 \
     && [[ -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    display "pnpm $(pnpm --version) 已激活，跳过"
    manifest_record corepack_pnpm "pnpm@latest" preexisting
    return
  fi
  log "Enabling pnpm via corepack (registry=$NPM_REGISTRY)"
  run corepack enable
  run corepack prepare pnpm@latest --activate
  manifest_record corepack_pnpm "pnpm@latest" activated
  # Best-effort: write pnpm path into user profile. Failures are non-fatal.
  run SHELL="${SHELL:-/bin/bash}" pnpm setup || true
  display "✓ pnpm $(pnpm --version) 已就绪"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_pnpm
fi
