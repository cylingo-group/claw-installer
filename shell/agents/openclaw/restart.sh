#!/usr/bin/env bash
# agents/openclaw/restart.sh — restart the OpenClaw gateway service.
#
# Prefers `openclaw gateway restart` if available; falls back to stop + start.

set -euo pipefail

__OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__OC_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:openclaw-restart:正在重启 OpenClaw 网关…"
  command -v openclaw >/dev/null 2>&1 \
    || die_step "重启 OpenClaw 网关" "openclaw not on PATH — 请先安装 OpenClaw" 1

  log "Dispatching: openclaw gateway restart (timeout 90s)"
  if run run_with_timeout 90 openclaw gateway restart </dev/null; then
    sleep 1
    run openclaw gateway status </dev/null || true
    display "✓ OpenClaw 网关已重启"
  else
    log "openclaw gateway restart non-zero — falling back to stop + start"
    run run_with_timeout 30 openclaw gateway stop </dev/null || true
    sleep 1
    if run run_with_timeout 60 openclaw gateway start </dev/null; then
      display "✓ OpenClaw 网关已重启"
    else
      display "✗ OpenClaw 网关重启失败"
      run openclaw gateway status </dev/null 2>&1 || true
      exit 1
    fi
  fi
}

main "$@"
