#!/usr/bin/env bash
# agents/hermes/start.sh — start the Hermes gateway service.
#
# Hermes exposes its messaging gateway as a launchd/systemd background service
# via `hermes gateway` subcommands. This mirrors OpenClaw's start.sh:
#   - fast-path if status reports running
#   - ensure the service definition exists (gateway install) before first start
#   - dispatch `gateway start` under a wall-clock timeout
#   - verify and report status
#
# Idempotent: re-running on a running gateway exits 0.

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__HE_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:hermes-start:正在启动 Hermes 网关…"
  command -v hermes >/dev/null 2>&1 \
    || die_step "启动 Hermes 网关" "hermes not on PATH — 请先安装 Hermes" 1

  # Fast-path: gateway already loaded by launchd. A running hermes gateway
  # status prints a "✓ Gateway service is loaded" (or "active") line; the
  # ✗-prefixed "is not loaded" line and the ⚠-prefixed orphan-process line
  # must NOT count. Anchor on the ✓ + key phrase.
  local status_out=""
  status_out="$(run_with_timeout 10 hermes gateway status </dev/null 2>&1 || true)"
  if printf '%s' "$status_out" | grep -Eq '^[[:space:]]*✓[[:space:]]+Gateway service is (loaded|active|running)\b'; then
    log "$status_out"
    display "✓ Hermes 网关已在运行"
    exit 0
  fi

  # Ensure the launchd/systemd service definition is in place. `gateway install`
  # is idempotent: it overwrites the plist/unit but doesn't start the service.
  # If hermes was installed bare (without postinstall registering the gateway),
  # this is the first time the plist gets written.
  log "Ensuring service definition: hermes gateway install (timeout 30s)"
  run run_with_timeout 30 hermes gateway install </dev/null \
    || log "hermes gateway install: timed out or non-zero — continuing"

  log "Dispatching: hermes gateway start (timeout 60s)"
  if run run_with_timeout 60 hermes gateway start </dev/null; then
    sleep 1
    run hermes gateway status </dev/null || true
    display "✓ Hermes 网关已启动"
  else
    display "✗ Hermes 网关启动失败"
    log "hermes gateway start exited non-zero. Run 'hermes doctor' for diagnostics."
    run hermes gateway status </dev/null 2>&1 || true
    exit 1
  fi
}

main "$@"
