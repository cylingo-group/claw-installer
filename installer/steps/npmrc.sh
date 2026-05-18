#!/usr/bin/env bash
# steps/npmrc.sh — write the registry mirror into ~/.npmrc between sentinels.
# Skipped if INSTALLER_SKIP_USER_NPMRC is set.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_npmrc() {
  if [[ -n "${INSTALLER_SKIP_USER_NPMRC:-}" ]]; then
    log "Skipping ~/.npmrc update (INSTALLER_SKIP_USER_NPMRC set)"
    return
  fi
  local rc="$HOME/.npmrc"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$rc" ]]; then
    awk -v b="$NPMRC_SENTINEL_BEGIN" -v e="$NPMRC_SENTINEL_END" '
      BEGIN { skip = 0 }
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      skip == 0 { print }
    ' "$rc" > "$tmp"
  fi
  {
    echo "$NPMRC_SENTINEL_BEGIN"
    echo "registry=$NPM_REGISTRY"
    echo "$NPMRC_SENTINEL_END"
  } >> "$tmp"
  mv "$tmp" "$rc"
  log "Updated $rc → registry=$NPM_REGISTRY (managed block)"
  manifest_record npmrc_block "$rc" inserted "registry=$NPM_REGISTRY"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  step_npmrc
fi
