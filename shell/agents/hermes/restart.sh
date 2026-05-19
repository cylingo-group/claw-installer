#!/usr/bin/env bash
# agents/hermes/restart.sh — Hermes has no background service.
#
# Verifies installation and acknowledges the restart "completed". Mirrors the
# openclaw lifecycle interface so the GUI can call uniformly.

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__HE_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:hermes-restart:正在检查 Hermes 安装状态…"
  if [[ ! -x "$HOME/.local/bin/hermes" ]] && ! command -v hermes >/dev/null 2>&1; then
    die_step "重启 Hermes" "hermes not found on PATH — 请先安装 Hermes" 1
  fi
  log "Hermes is a CLI tool — there is no daemon to restart. Re-run 'hermes' in your terminal."
  display "✓ Hermes 已就绪：在终端运行 hermes 进入对话"
}

main "$@"
