#!/usr/bin/env bash
# agents/hermes/start.sh — Hermes is a CLI/REPL, not a persistent service.
#
# Upstream provides no `hermes daemon` or `hermes start` subcommand; the agent
# only runs while the user has the interactive `hermes` REPL open. This script
# verifies the binary is installed and reports the canonical status. The GUI
# treats Hermes as "ready" whenever it's installed.

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__HE_DIR/../../lib/common.sh"

main() {
  trap 'die_step_handler' ERR

  display "@@step:hermes-start:正在检查 Hermes 安装状态…"
  local bin="$HOME/.local/bin/hermes"
  if [[ ! -x "$bin" ]] && ! command -v hermes >/dev/null 2>&1; then
    die_step "启动 Hermes" "hermes not found on PATH — 请先安装 Hermes" 1
  fi
  local hv=""
  hv="$(hermes --version 2>/dev/null || true)"
  [[ -n "$hv" ]] && log "Hermes version: $hv"

  display "✓ Hermes 已就绪：在终端运行 hermes 进入对话"
  log "Hermes is a CLI tool — no background service to start. Open a terminal and run: hermes"
}

main "$@"
