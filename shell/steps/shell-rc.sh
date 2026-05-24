#!/usr/bin/env bash
# steps/shell-rc.sh — persist fnm + pnpm PATH into ~/.bashrc and ~/.zshrc
# between managed sentinels. Requires FNM_DIR and PNPM_HOME to be set.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

# Emit the canonical managed block body (between sentinels, exclusive).
# Used both to write the block and to diff against an existing block.
_shell_rc_block_body() {
  printf '# Managed by claw-installer — do not edit between sentinels\n'
  printf 'export FNM_DIR=%q\n' "$FNM_DIR"
  printf '%s\n' 'case ":$PATH:" in *":$FNM_DIR:"*) ;; *) export PATH="$FNM_DIR:$PATH";; esac'
  printf '%s\n' 'if command -v fnm >/dev/null 2>&1; then eval "$(fnm env --shell bash)" 2>/dev/null || true; fi'
  printf 'export PNPM_HOME=%q\n' "$PNPM_HOME"
  printf '%s\n' 'case ":$PATH:" in *":$PNPM_HOME/bin:"*) ;; *) export PATH="$PNPM_HOME/bin:$PATH";; esac'
  printf '%s\n' 'case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH";; esac'
}

step_shell_rc() {
  : "${FNM_DIR:?FNM_DIR not set — run steps/fnm.sh first}"
  : "${PNPM_HOME:?PNPM_HOME not set — run steps/pnpm.sh first}"
  display "@@step:shell-rc:Configuring shell PATH…"
  local targets=("$HOME/.bashrc")
  [[ -f "$HOME/.zshrc" ]] && targets+=("$HOME/.zshrc")
  local desired existing rc tmp
  desired="$(_shell_rc_block_body)"
  for rc in "${targets[@]}"; do
    [[ -e "$rc" ]] || : > "$rc"
    # Fast-path: existing managed block matches what we'd write.
    existing="$(awk -v b="$SHELL_RC_SENTINEL_BEGIN" -v e="$SHELL_RC_SENTINEL_END" '
        BEGIN { in_blk=0 }
        $0 == b { in_blk=1; next }
        $0 == e { in_blk=0; next }
        in_blk { print }
      ' "$rc")"
    if [[ -n "$existing" && "$existing" == "$desired" ]]; then
      display "$rc PATH block is up-to-date; skipping"
      manifest_record shell_rc_block "$rc" preexisting
      continue
    fi
    tmp="$(mktemp -p "$(_claw_tmp_dir)")"
    awk -v b="$SHELL_RC_SENTINEL_BEGIN" -v e="$SHELL_RC_SENTINEL_END" '
      BEGIN { skip = 0 }
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      skip == 0 { print }
    ' "$rc" > "$tmp"
    {
      printf '\n%s\n' "$SHELL_RC_SENTINEL_BEGIN"
      printf '%s\n' "$desired"
      printf '%s\n' "$SHELL_RC_SENTINEL_END"
    } >> "$tmp"
    mv "$tmp" "$rc"
    display "✓ $rc PATH block updated"
    manifest_record shell_rc_block "$rc" inserted
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  step_shell_rc
fi
