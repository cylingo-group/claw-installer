#!/usr/bin/env bash
# steps/python.sh — ensure Python 3.11 is installed via uv. Hermes's upstream
# installer probes `uv python find "3.11"`; if it succeeds, hermes skips its
# own `uv python install 3.11` call.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_python() {
  display "@@step:python:正在安装 Python 3.11…"
  command -v uv >/dev/null 2>&1 || die_step "安装 Python" "uv not on PATH — run steps/uv.sh first" 1
  local version="${INSTALLER_HERMES_PYTHON_VERSION:-3.11}"

  if uv python find "$version" >/dev/null 2>&1; then
    log "Python $version already known to uv: $(uv python find "$version")"
    display "Python $version 已就绪，跳过安装"
    manifest_record uv_python "$version" preexisting
    return
  fi
  log "Installing Python $version via uv"
  run uv python install "$version" </dev/null
  log "Python $version installed: $(uv python find "$version" 2>/dev/null || echo '?')"
  display "✓ Python $version 已安装"
  manifest_record uv_python "$version" installed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  step_python
fi
