#!/usr/bin/env bash
# agents/openclaw/start.sh — start the OpenClaw gateway service.
#
# Idempotent: if the gateway is already running, this exits 0 with a friendly
# message. Otherwise it dispatches `openclaw gateway start` under a wall-clock
# timeout so a crashed daemon can't deadlock the caller.
#
# Two-stream logging: user-visible status goes to stdout via display();
# raw command output goes to fd 3 via run(). Same contract as install.sh.

set -euo pipefail

__OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__OC_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:openclaw-start:Starting OpenClaw gateway…"
  command -v openclaw >/dev/null 2>&1 \
    || die_step "Start OpenClaw gateway" "openclaw not on PATH — please install OpenClaw first" 1

  local status_out=""
  status_out="$(run_with_timeout 10 openclaw gateway status </dev/null 2>&1 || true)"
  if printf '%s' "$status_out" | grep -Eqi 'running|active \(running\)|status:[[:space:]]*up'; then
    log "$status_out"
    display "✓ OpenClaw gateway is already running"
    exit 0
  fi

  log "Dispatching: openclaw gateway start (timeout 60s)"
  if run run_with_timeout 60 openclaw gateway start </dev/null; then
    sleep 1
    run openclaw gateway status </dev/null || true
    display "✓ OpenClaw gateway started"
  else
    display "✗ OpenClaw gateway failed to start"
    log "openclaw gateway start exited non-zero. Run 'openclaw doctor' for diagnostics."
    run openclaw gateway status </dev/null 2>&1 || true
    exit 1
  fi
}

main "$@"
