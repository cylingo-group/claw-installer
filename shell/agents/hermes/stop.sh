#!/usr/bin/env bash
# agents/hermes/stop.sh — stop the Hermes gateway service.
#
# Idempotent: if the gateway is already stopped, this exits 0.

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__HE_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:hermes-stop:正在停止 Hermes 网关…"
  command -v hermes >/dev/null 2>&1 \
    || die_step "停止 Hermes 网关" "hermes not on PATH — 请先安装 Hermes" 1

  # Same precise check as start.sh — only the ✓-prefixed loaded/active line
  # counts as "running". If we don't see it, the service isn't loaded by launchd.
  local status_out=""
  status_out="$(run_with_timeout 10 hermes gateway status </dev/null 2>&1 || true)"
  if ! printf '%s' "$status_out" | grep -Eq '^[[:space:]]*✓[[:space:]]+Gateway service is (loaded|active|running)\b'; then
    log "$status_out"
    display "✓ Hermes 网关已停止"
    exit 0
  fi

  log "Dispatching: hermes gateway stop (timeout 30s)"
  if run run_with_timeout 30 hermes gateway stop </dev/null; then
    sleep 1
    run hermes gateway status </dev/null || true
    display "✓ Hermes 网关已停止"
  else
    display "✗ Hermes 网关停止失败"
    log "hermes gateway stop exited non-zero."
    exit 1
  fi
}

main "$@"
