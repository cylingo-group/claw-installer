#!/usr/bin/env bash
# install.sh — top-level entry for the claw-installer.
#
# Layering:
#   install.sh                 — this file: env deps + every agent
#   install-<agent>.sh         — per-agent installers (openclaw today, hermes next)
#   steps/*.sh                 — fine-grained env/config primitives
#
# Behavior:
#   No arguments → run the full sequence: env deps, then every supported
#   agent installer in order. Per-agent toggles (gateway port/token/mode,
#   workspace, npm registry, …) are read from INSTALLER_* env vars; see each
#   per-agent script header for the full list.
#
# Future GUI integration:
#   The GUI front-end will export INSTALLER_* vars and shell out to this
#   script. Keep that contract stable.

set -euo pipefail

__INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$__INSTALL_DIR/lib/common.sh"

# Default: install every agent we ship. Override with `INSTALLER_AGENTS=…`
# (comma-separated) to install a subset, e.g. `INSTALLER_AGENTS=openclaw` for
# openclaw-only smoke tests in the Dockerfile.
if [[ -n "${INSTALLER_AGENTS:-}" ]]; then
  IFS=',' read -ra AGENTS <<< "$INSTALLER_AGENTS"
else
  AGENTS=(openclaw hermes)
fi

run_agent() {
  local agent="$1"
  local script="$__INSTALL_DIR/install-${agent}.sh"
  [[ -f "$script" ]] || die "Agent installer not found: $script"
  log "=== Installing agent: $agent ==="
  # Suppress per-agent env-step re-run; we already ran env deps once above.
  # Inherit CLAW_INSTALL_LOG so the child appends to the same install log
  # (its setup_install_log() becomes a no-op).
  INSTALLER_SKIP_ENV=1 CLAW_INSTALL_LOG="$CLAW_INSTALL_LOG" bash "$script"
}

# Union of every selected agent's ENV_STEPS, preserving declaration order
# and deduping by first occurrence. Each install-<agent>.sh declares its
# ENV_STEPS at the top; we read them by sourcing in a subshell (main() is
# gated on BASH_SOURCE==$0 so sourcing has no install side effects).
collect_steps() {
  local agent s seen=" "
  local -a merged=()
  for agent in "${AGENTS[@]}"; do
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      [[ "$seen" == *" $s "* ]] && continue
      merged+=("$s")
      seen+="$s "
    done < <(agent_env_steps "$agent")
  done
  printf '%s\n' "${merged[@]}"
}

main() {
  setup_install_log
  log "claw-installer: full install (agents: ${AGENTS[*]})"
  local -a steps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && steps+=("$line")
  done < <(collect_steps)
  log "Env steps for selected agents: ${steps[*]}"
  run_steps "${steps[@]}"
  for agent in "${AGENTS[@]}"; do
    run_agent "$agent"
  done
  log "claw-installer: done. Manifest: $CLAW_MANIFEST"
}

main "$@"
