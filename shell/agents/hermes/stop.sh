#!/usr/bin/env bash
# agents/hermes/stop.sh — Hermes has no background service.
#
# The hermes REPL stops when the user closes the terminal session. This script
# is a friendly no-op for parity with openclaw's lifecycle interface.

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__HE_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:hermes-stop:Hermes 无后台服务，无需停止"
  log "Hermes is a CLI tool — there is no daemon to stop. Close the terminal running hermes to end the session."
  display "✓ 完成"
}

main "$@"
