#!/usr/bin/env bash
# agents/openclaw/uninstall.sh — uninstall OpenClaw only.
#
# Delegates to the top-level uninstall.sh with CLAW_UNINSTALL_AGENT=openclaw so
# shared env (fnm/pnpm/node/npmrc/shell-rc/system pkgs) and Hermes's own files
# are left intact. The manifest is rewritten in place.

set -euo pipefail

__OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env CLAW_UNINSTALL_AGENT=openclaw \
  bash "$__OC_DIR/../../uninstall.sh" "$@"
