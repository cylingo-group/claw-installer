#!/usr/bin/env bash
# agents/openclaw/stop.sh — stop the OpenClaw gateway service.
#
# Idempotent: if the gateway is already stopped, this exits 0.

set -euo pipefail

__OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__OC_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:openclaw-stop:Stopping OpenClaw gateway…"
  command -v openclaw >/dev/null 2>&1 \
    || die_step "Stop OpenClaw gateway" "openclaw not on PATH — please install OpenClaw first" 1

  local status_out=""
  status_out="$(run_with_timeout 10 openclaw gateway status </dev/null 2>&1 || true)"
  if ! printf '%s' "$status_out" | grep -Eqi 'running|active \(running\)|status:[[:space:]]*up'; then
    log "$status_out"
    display "✓ OpenClaw gateway is already stopped"
    exit 0
  fi

  log "Dispatching: openclaw gateway stop (timeout 30s)"
  if run run_with_timeout 30 openclaw gateway stop </dev/null; then
    sleep 1
    run openclaw gateway status </dev/null || true
    display "✓ OpenClaw gateway stopped"
  else
    display "✗ OpenClaw gateway failed to stop"
    log "openclaw gateway stop exited non-zero."
    exit 1
  fi
}

main "$@"
