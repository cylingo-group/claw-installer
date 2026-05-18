#!/usr/bin/env bash
# steps/node.sh — install + activate Node.js via fnm. Requires fnm on PATH.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_node() {
  command -v fnm >/dev/null 2>&1 || die "fnm not on PATH — run steps/fnm.sh first"
  local node_status="installed"
  # `fnm list` lists every fnm-managed version; match against the requested
  # version (loose match so a "24" request matches v24.x.y).
  if fnm list 2>/dev/null | grep -E "v${NODE_VERSION}([. ]|$)" >/dev/null; then
    node_status="preexisting"
  fi
  log "Installing Node.js v$NODE_VERSION via fnm"
  fnm install "$NODE_VERSION"
  fnm default "$NODE_VERSION"
  fnm use "$NODE_VERSION"
  hash -r 2>/dev/null || true
  local node_v
  node_v="$(node --version)"
  log "Active Node: $node_v"
  if ! node -e 'const v=process.versions.node.split(".").map(Number); process.exit((v[0]>22)||(v[0]===22&&v[1]>=16)?0:1)'; then
    die "Node $node_v is below required 22.16+. Try INSTALLER_NODE_VERSION=24."
  fi
  manifest_record fnm_node "$NODE_VERSION" "$node_status" "active=$node_v"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  # Activate fnm if it's installed but not yet sourced in this shell.
  if ! command -v fnm >/dev/null 2>&1; then
    source "$__STEP_DIR/fnm.sh"
    step_fnm
  fi
  step_node
fi
