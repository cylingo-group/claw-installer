#!/usr/bin/env bash
# steps/node.sh — install + activate Node.js via fnm. Requires fnm on PATH.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_node() {
  display "@@step:node:正在配置 Node ${NODE_VERSION} 运行时…"
  command -v fnm >/dev/null 2>&1 || die_step "配置 Node" "fnm not on PATH — run steps/fnm.sh first" 1
  local node_status="installed"
  # `fnm list` lists every fnm-managed version; match against the requested
  # version (loose match so a "24" request matches v24.x.y).
  if fnm list 2>/dev/null | grep -E "v${NODE_VERSION}([. ]|$)" >/dev/null; then
    node_status="preexisting"
  fi

  # Fast-path: requested version is installed AND already active in this shell.
  # We still call fnm to ensure the default alias points at it (one-time setup),
  # but only when we just installed the version — not on every re-run.
  local req_major active_major=""
  req_major="${NODE_VERSION%%.*}"
  if command -v node >/dev/null 2>&1; then
    active_major="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])' 2>/dev/null || true)"
  fi
  if [[ "$node_status" == "preexisting" && "$active_major" == "$req_major" \
        && -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
    display "Node v$NODE_VERSION 已安装并激活，跳过"
  else
    log "Installing Node.js v$NODE_VERSION via fnm"
    run fnm install "$NODE_VERSION"
    run fnm default "$NODE_VERSION"
    run fnm use "$NODE_VERSION"
    hash -r 2>/dev/null || true
  fi
  local node_v
  node_v="$(node --version)"
  display "✓ Node $node_v 已激活"
  # node version check: die_step_handler fires via ERR trap if this exits 1
  if ! node -e 'const v=process.versions.node.split(".").map(Number); process.exit((v[0]>22)||(v[0]===22&&v[1]>=16)?0:1)'; then
    die_step "配置 Node 运行时" "Node $node_v is below required 22.16+. Try INSTALLER_NODE_VERSION=24." 1
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
