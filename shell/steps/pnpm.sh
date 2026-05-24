#!/usr/bin/env bash
# steps/pnpm.sh — enable pnpm via corepack and set up PNPM_HOME on PATH.

set -euo pipefail
__STEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$__STEP_DIR/../lib/common.sh"

step_pnpm() {
  : "${PLATFORM:?PLATFORM not set — call detect_platform first}"
  display "@@step:pnpm:Preparing the pnpm package manager…"
  command -v corepack >/dev/null 2>&1 || die_step "Prepare pnpm" "corepack not on PATH — run steps/node.sh first" 1
  log "corepack: $(command -v corepack)"
  log "node:     $(command -v node)"
  log "npm reg:  $NPM_REGISTRY"

  # PNPM_HOME is the single source of truth — derive it once via the helper
  # in common.sh so pnpm.sh, shell-rc.sh, and uninstall.sh agree exactly.
  export PNPM_HOME="$(_claw_pnpm_home)"
  local pnpm_home_status="created"
  [[ -d "$PNPM_HOME" ]] && pnpm_home_status="preexisting"
  mkdir -p "$PNPM_HOME" "$PNPM_HOME/bin"
  manifest_record pnpm_home "$PNPM_HOME" "$pnpm_home_status"
  # PATH ordering owned by _claw_compose_path — re-derive now that
  # PNPM_HOME is exported. pnpm 9+ keeps global bins under $PNPM_HOME/bin;
  # older versions used $PNPM_HOME itself. Both slots are in the canonical
  # order; the composer dedups, so re-calling is free.
  _claw_compose_path

  # Fast-path: explicit rc capture so a half-broken pnpm (corepack hash file
  # corrupt, partially-downloaded tarball, Node ABI mismatch) is surfaced
  # instead of being swallowed by `&& [[ ... ]]`.
  local pnpm_v_rc=0 pnpm_v=""
  if command -v pnpm >/dev/null 2>&1; then
    pnpm_v="$(pnpm --version 2>&1)" || pnpm_v_rc=$?
    log "pnpm preflight: path=$(command -v pnpm) rc=$pnpm_v_rc out=$pnpm_v"
    if [[ "$pnpm_v_rc" -eq 0 && -z "${INSTALLER_FORCE_REINSTALL:-}" ]]; then
      display "pnpm $pnpm_v already active; skipping"
      manifest_record corepack_pnpm "pnpm@latest" preexisting
      return
    fi
  else
    log "pnpm preflight: not on PATH"
  fi

  log "Enabling pnpm via corepack (registry=$NPM_REGISTRY)"
  local ce_rc=0
  corepack enable >&3 2>&3 || ce_rc=$?
  log "corepack enable: rc=$ce_rc"
  if [[ "$ce_rc" -ne 0 ]]; then
    die_step "Prepare pnpm" "corepack enable failed (rc=$ce_rc) — check write permission on PNPM_HOME=$PNPM_HOME and reachability of npm mirror $NPM_REGISTRY." "$ce_rc"
  fi

  local cp_rc=0
  corepack prepare pnpm@latest --activate >&3 2>&3 || cp_rc=$?
  log "corepack prepare pnpm@latest --activate: rc=$cp_rc"
  if [[ "$cp_rc" -ne 0 ]]; then
    die_step "Prepare pnpm" "corepack prepare pnpm@latest failed (rc=$cp_rc) — mirror $NPM_REGISTRY may be unreachable, or signature verification failed." "$cp_rc"
  fi
  manifest_record corepack_pnpm "pnpm@latest" activated

  # Best-effort: write pnpm path into user profile. Failures are non-fatal,
  # but log the rc so we can correlate.
  local setup_rc=0
  SHELL="${SHELL:-/bin/bash}" pnpm setup >&3 2>&3 || setup_rc=$?
  log "pnpm setup: rc=$setup_rc (non-fatal)"

  # Final probe — same explicit rc pattern.
  local final_rc=0
  pnpm_v="$(pnpm --version 2>&1)" || final_rc=$?
  log "pnpm --version (post-activate): rc=$final_rc out=$pnpm_v"
  if [[ "$final_rc" -ne 0 ]]; then
    die_step "Prepare pnpm" "pnpm --version exited $final_rc (output: $pnpm_v)" "$final_rc"
  fi
  display "✓ pnpm $pnpm_v is ready"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_platform
  step_pnpm
fi
