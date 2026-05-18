#!/usr/bin/env bash
# lib/common.sh — shared helpers + env defaults for the claw-installer.
# This file is meant to be SOURCED, never executed directly.

# Resolve project root from this file's location: <root>/lib/common.sh
__CLAW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAW_INSTALLER_ROOT="${CLAW_INSTALLER_ROOT:-$(cd "$__CLAW_LIB_DIR/.." && pwd)}"
export CLAW_STEPS_DIR="$CLAW_INSTALLER_ROOT/steps"

# --- public env-var defaults (consumed by GUI / scripted callers) -----------
export NODE_VERSION="${INSTALLER_NODE_VERSION:-24}"
export WORKSPACE_DIR="${INSTALLER_WORKSPACE:-$HOME/.openclaw/workspace}"
NPM_REGISTRY_RAW="${INSTALLER_NPM_REGISTRY:-https://registry.npmmirror.com}"
if [[ -n "${INSTALLER_KEEP_DEFAULT_REGISTRY:-}" ]]; then
  NPM_REGISTRY_RAW="https://registry.npmjs.org"
fi
# Corepack appends "/pnpm" verbatim; a trailing slash here produces "//pnpm"
# and npmmirror returns 404 for the double-slashed path.
export NPM_REGISTRY="${NPM_REGISTRY_RAW%/}"

# Honor mirror for any npm/pnpm/corepack call invoked downstream.
export npm_config_registry="$NPM_REGISTRY"
export COREPACK_NPM_REGISTRY="$NPM_REGISTRY"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
# pnpm 11+ prompts to approve build scripts when a TTY is attached; CI=true
# makes it skip the prompt and treat every untrusted dependency as deferred.
export CI=true

export NPMRC_SENTINEL_BEGIN="# >>> managed by claw-installer >>>"
export NPMRC_SENTINEL_END="# <<< managed by claw-installer <<<"
export SHELL_RC_SENTINEL_BEGIN="# >>> claw-installer env >>>"
export SHELL_RC_SENTINEL_END="# <<< claw-installer env <<<"

log()  { printf '\033[1;34m[claw-installer]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[claw-installer]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[claw-installer]\033[0m %s\n' "$*" >&2; exit 1; }

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Need root to run: $* (install sudo or rerun as root)"
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)
      if   command -v apt-get >/dev/null 2>&1; then PLATFORM="debian"
      elif command -v dnf     >/dev/null 2>&1; then PLATFORM="rhel"
      elif command -v yum     >/dev/null 2>&1; then PLATFORM="rhel"
      else die "Unsupported Linux distro (need apt-get / dnf / yum)"
      fi
      ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  export PLATFORM
  log "Detected platform: $PLATFORM ($(uname -sm))"
}

# shellcheck source=manifest.sh
source "$__CLAW_LIB_DIR/manifest.sh"

# run_with_timeout <seconds> <cmd...>
#   Run a command with a wall-clock timeout. Returns the command's exit code,
#   or 124 if it timed out. Uses GNU `timeout` / `gtimeout` when available;
#   otherwise falls back to a pure-bash background-and-kill scheme so this
#   works on a bare macOS without `coreutils` from brew.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return; fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return $rc
}

resolve_fnm_dir() {
  if [[ -d "$HOME/.fnm" ]]; then
    echo "$HOME/.fnm"
  elif [[ -n "${XDG_DATA_HOME:-}" && -d "$XDG_DATA_HOME/fnm" ]]; then
    echo "$XDG_DATA_HOME/fnm"
  elif [[ "${PLATFORM:-}" == "macos" && -d "$HOME/Library/Application Support/fnm" ]]; then
    echo "$HOME/Library/Application Support/fnm"
  else
    echo "$HOME/.local/share/fnm"
  fi
}

# run_steps <name> [<name> …]
#   Each <name> matches installer/steps/<name>.sh, which must define
#   step_<name_with_underscores>. Caller passes the agent-specific list (each
#   install-<agent>.sh declares ENV_STEPS=(…) up top).
run_steps() {
  detect_platform
  local s file fn
  for s in "$@"; do
    file="$CLAW_STEPS_DIR/$s.sh"
    [[ -f "$file" ]] || die "Unknown step: $s (no such file $file)"
    # shellcheck source=/dev/null
    source "$file"
    fn="step_${s//-/_}"
    type "$fn" >/dev/null 2>&1 || die "Step '$s' did not define function $fn"
    "$fn"
  done
}

# agent_env_steps <agent>  → emit the agent's declared ENV_STEPS, one per line.
# Reads by sourcing install-<agent>.sh in a subshell so its function defs
# don't leak into the caller's scope. main() inside the agent script is gated
# on BASH_SOURCE==$0, so sourcing has no installation side effects.
agent_env_steps() {
  local agent="$1"
  local script="$CLAW_INSTALLER_ROOT/install-$agent.sh"
  [[ -f "$script" ]] || die "Unknown agent: $agent (no $script)"
  ( # shellcheck source=/dev/null
    source "$script" >/dev/null 2>&1
    printf '%s\n' "${ENV_STEPS[@]:-}" )
}
