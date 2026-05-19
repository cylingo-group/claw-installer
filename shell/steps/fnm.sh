#!/usr/bin/env bash
# steps/fnm.sh — install fnm via the vendored installer and activate it.
# Exports FNM_DIR on success.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_fnm() {
  display "@@step:fnm:正在安装 fnm（Node 版本管理器）…"
  local fnm_status="installed"
  if command -v fnm >/dev/null 2>&1; then
    log "fnm already on PATH: $(fnm --version)"
    fnm_status="preexisting"
    display "fnm 已就绪：$(fnm --version)"
  else
    local installer="$CLAW_INSTALLER_ROOT/vendor/fnm/install.sh"
    [[ -f "$installer" ]] || die_step "安装 fnm" "Missing vendored fnm installer at $installer" 1
    log "Installing fnm via vendored installer (skip-shell)"
    run bash "$installer" --skip-shell
  fi
  FNM_DIR="$(resolve_fnm_dir)"
  export FNM_DIR
  export PATH="$FNM_DIR:$PATH"
  command -v fnm >/dev/null 2>&1 || die_step "安装 fnm" "fnm still not on PATH after install (looked in $FNM_DIR)" 1
  # Activate fnm in this shell.
  eval "$(fnm env --shell bash)"
  log "fnm version: $(fnm --version), dir: $FNM_DIR"
  manifest_record fnm_binary "$FNM_DIR" "$fnm_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_fnm
fi
