#!/usr/bin/env bash
# steps/npmrc.sh — write the registry mirror into ~/.npmrc between sentinels.
# Skipped if INSTALLER_SKIP_USER_NPMRC is set.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_npmrc() {
  display "@@step:npmrc:正在写入 npm 镜像源配置…"
  if [[ -n "${INSTALLER_SKIP_USER_NPMRC:-}" ]]; then
    display "跳过 ~/.npmrc 更新（INSTALLER_SKIP_USER_NPMRC 已设置）"
    return
  fi
  local rc="$HOME/.npmrc"

  # Fast-path: existing managed block already has the desired registry line.
  if [[ -f "$rc" ]] && awk -v b="$NPMRC_SENTINEL_BEGIN" -v e="$NPMRC_SENTINEL_END" \
        -v r="registry=$NPM_REGISTRY" '
        BEGIN { in_blk=0; ok=0 }
        $0 == b { in_blk=1; next }
        $0 == e { in_blk=0; next }
        in_blk && $0 == r { ok=1 }
        END { exit ok ? 0 : 1 }
      ' "$rc"; then
    display "~/.npmrc 镜像源配置已是最新，跳过"
    manifest_record npmrc_block "$rc" preexisting "registry=$NPM_REGISTRY"
    return
  fi

  local tmp
  tmp="$(mktemp -p "$(_claw_tmp_dir)")"
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
  log "Updated $rc → registry=$NPM_REGISTRY (managed block)"
  mv "$tmp" "$rc"
  display "✓ ~/.npmrc 镜像源已更新：$NPM_REGISTRY"
  manifest_record npmrc_block "$rc" inserted "registry=$NPM_REGISTRY"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  step_npmrc
fi
