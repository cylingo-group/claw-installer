#!/usr/bin/env bash
# agents/hermes/uninstall.sh — uninstall Hermes only.
#
# Delegates to the top-level uninstall.sh with CLAW_UNINSTALL_AGENT=hermes so
# shared env (fnm/pnpm/node/npmrc/shell-rc/system pkgs) and OpenClaw's own
# files are left intact. The manifest is rewritten in place.

set -euo pipefail

__HE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env CLAW_UNINSTALL_AGENT=hermes \
  bash "$__HE_DIR/../../uninstall.sh" "$@"
