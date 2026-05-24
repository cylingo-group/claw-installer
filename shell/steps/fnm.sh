#!/usr/bin/env bash
# steps/fnm.sh — install fnm via the vendored installer and activate it.
# Exports FNM_DIR on success.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_fnm() {
  display "@@step:fnm:Installing fnm (Node version manager)…"
  local fnm_status="installed"
  if command -v fnm >/dev/null 2>&1; then
    log "fnm already on PATH: $(fnm --version)"
    fnm_status="preexisting"
    display "fnm is ready: $(fnm --version)"
  else
    local installer="$CLAW_INSTALLER_ROOT/vendor/fnm/install.sh"
    [[ -f "$installer" ]] || die_step "Install fnm" "Missing vendored fnm installer at $installer" 1
    log "Installing fnm via vendored installer (skip-shell)"
    run bash "$installer" --skip-shell
  fi
  FNM_DIR="$(resolve_fnm_dir)"
  export FNM_DIR
  # PATH ordering owned by _claw_compose_path in common.sh — re-assert now
  # that FNM_DIR is exported so it shows up in the canonical slot.
  _claw_compose_path
  command -v fnm >/dev/null 2>&1 || die_step "Install fnm" "fnm still not on PATH after install (looked in $FNM_DIR)" 1
  # Activate fnm in this shell. This adds $FNM_MULTISHELL_PATH/bin to PATH
  # and defines the `fnm` shell function (used by `fnm use`).
  eval "$(fnm env --shell bash)"
  # _claw_fnm_active_bin reads $FNM_DIR/aliases/default — re-derive PATH so
  # the active version's bin dir takes the top slot.
  _claw_compose_path
  log "fnm version: $(fnm --version), dir: $FNM_DIR"
  manifest_record fnm_binary "$FNM_DIR" "$fnm_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_fnm
fi
