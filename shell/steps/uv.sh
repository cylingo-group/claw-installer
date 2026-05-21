#!/usr/bin/env bash
# steps/uv.sh — install uv (the Python toolchain manager) into ~/.local/bin
# if not already on PATH. Hermes's upstream installer detects uv via
# `command -v uv` (or fallback paths $HOME/.local/bin/uv, $HOME/.cargo/bin/uv)
# and skips its own bootstrap when found.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_uv() {
  display "@@step:uv:正在安装 uv（Python 包管理器）…"
  local uv_bin="$HOME/.local/bin/uv"
  if command -v uv >/dev/null 2>&1; then
    log "uv already on PATH: $(uv --version 2>/dev/null || echo unknown) ($(command -v uv))"
    display "uv 已就绪：$(uv --version 2>/dev/null || echo unknown)"
    manifest_record uv_binary "$(command -v uv)" preexisting
    return
  fi
  if [[ -x "$uv_bin" ]]; then
    log "uv already at $uv_bin"
    # PATH ordering owned by _claw_compose_path in common.sh (it already
    # includes $HOME/.local/bin). Re-derive in case PATH was clobbered.
    _claw_compose_path
    display "uv 已就绪：$uv_bin"
    manifest_record uv_binary "$uv_bin" preexisting
    return
  fi
  log "Installing uv via https://astral.sh/uv/install.sh (no PATH modification)"
  # --no-modify-path: don't have uv's installer touch shell rc files. We don't
  # need its PATH block because: (a) hermes's installer also writes its own
  # ~/.local/bin PATH line, and (b) our shell-rc step doesn't run for the
  # hermes-only path. Users still get the binary at a stable, on-PATH location.
  run bash -c 'curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALLER_NO_MODIFY_PATH=1 sh' </dev/null
  _claw_compose_path
  hash -r 2>/dev/null || true
  command -v uv >/dev/null 2>&1 || die_step "安装 uv" "uv not on PATH after install (looked in $uv_bin)" 1
  log "uv installed: $(uv --version) at $uv_bin"
  display "✓ uv 已安装：$(uv --version)"
  manifest_record uv_binary "$uv_bin" installed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  step_uv
fi
