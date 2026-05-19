#!/usr/bin/env bash
# steps/hermes-node.sh — make Node v22 available at the exact path hermes
# expects ($HERMES_HOME/node/bin/node), reusing fnm rather than downloading
# a second copy from nodejs.org.
#
# Hermes's upstream installer probes (in this order):
#   1. `command -v node` AND `node --version` → v22.x
#   2. `[ -x "$HERMES_HOME/node/bin/node" ]`
# Our default shell Node is v24 (via the `node` step, for openclaw), so #1
# fails. We satisfy #2 by symlinking from the fnm-installed Node v22 into
# $HERMES_HOME/node/bin/, leaving the rest of the shell environment alone.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_hermes_node() {
  display "@@step:hermes-node:正在配置 Hermes 专属 Node 运行时…"
  local hermes_home="${INSTALLER_HERMES_HOME:-${HERMES_HOME:-$HOME/.hermes}}"
  local node_dir="$hermes_home/node"
  local node_bin="$node_dir/bin/node"

  # Fast-path 1: an existing $HERMES_HOME/node/bin/node (from a previous run
  # of us, or hermes itself) — upstream check #2 will accept it.
  if [[ -x "$node_bin" ]]; then
    log "Node already at $node_bin (version: $("$node_bin" --version 2>/dev/null || echo ?))"
    display "Hermes 专属 Node 已就绪，跳过配置"
    manifest_record hermes_node_symlink "$node_dir" preexisting
    return
  fi

  # Fast-path 2: the user's shell already has Node >= 22 on PATH. In practice
  # the upstream installer accepts this (despite some docs saying "v22 only";
  # we observed it accepting v24 fine). No need to install a second Node or
  # build a symlink — record the situation and bail.
  if command -v node >/dev/null 2>&1; then
    if node -e 'process.exit(process.versions.node.split(".").map(Number)[0] >= 22 ? 0 : 1)' 2>/dev/null; then
      log "PATH already has Node $(node --version) (>= 22); leaving hermes' Node detection to upstream"
      display "PATH 上的 Node $(node --version) 满足 Hermes 要求，跳过专属 Node 配置"
      manifest_record hermes_node_symlink "$node_dir" preexisting "system Node $(node --version) satisfies upstream check"
      return
    fi
  fi

  command -v fnm >/dev/null 2>&1 || die_step "配置 Hermes Node" "fnm not on PATH — run steps/fnm.sh first" 1

  # Ensure fnm has Node v22 (the version hermes expects).
  local node22_status="installed"
  if fnm list 2>/dev/null | grep -E "v22([. ]|$)" >/dev/null; then
    node22_status="preexisting"
    log "fnm already has Node v22"
  else
    log "Installing Node v22 via fnm"
    run fnm install 22
  fi
  manifest_record fnm_node 22 "$node22_status" "for hermes"

  # Resolve fnm's Node v22 bin dir. `fnm exec --using=22 -- node -e ...`
  # is the most reliable way to get the absolute path without grepping
  # fnm-internal layout.
  local node22_path node22_bindir
  node22_path="$(fnm exec --using=22 -- node -e 'process.stdout.write(process.execPath)')"
  [[ -x "$node22_path" ]] || die_step "配置 Hermes Node" "Could not resolve fnm Node v22 binary (got: '$node22_path')" 1
  node22_bindir="$(dirname "$node22_path")"
  log "fnm Node v22 binary: $node22_path"

  # Build the symlink tree under $HERMES_HOME/node/bin/ that hermes's check #2
  # expects. We link node + npm + npx (hermes uses all three for the upstream's
  # npm install / npx playwright steps).
  mkdir -p "$node_dir/bin"
  ln -sfn "$node22_path" "$node_bin"
  local bin
  for bin in npm npx; do
    if [[ -e "$node22_bindir/$bin" ]]; then
      ln -sfn "$node22_bindir/$bin" "$node_dir/bin/$bin"
    fi
  done
  log "Symlinked $node_dir/bin/{node,npm,npx} → $node22_bindir"
  display "✓ Hermes 专属 Node v22 已配置"
  manifest_record hermes_node_symlink "$node_dir" installed "→ $node22_bindir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_hermes_node
fi
