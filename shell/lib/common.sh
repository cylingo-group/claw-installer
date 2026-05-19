#!/usr/bin/env bash
# lib/common.sh — shared helpers + env defaults for the claw-installer.
# This file is meant to be SOURCED, never executed directly.
#
# =============================================================================
# TWO-STREAM LOGGING CONTRACT
# =============================================================================
# Scripts must author EVERY user-visible string explicitly. Three primitives:
#
#   display "中文描述…"
#       Writes to stdout (user sees it) AND to fd 3 (session log file).
#       If the argument matches @@step:<key>:<label>, it also sets CURRENT_STEP.
#
#   log "technical detail"
#       Writes to fd 3 ONLY. Never appears on the user's terminal.
#
#   run <cmd> [args…]
#       Writes "+ <cmd> [args…]" to fd 3, then executes <cmd> with both stdout
#       and stderr redirected to fd 3. Returns the command's exit code.
#
# Convenience macros:
#
#   step "<label>" -- <cmd> [args…]
#       Shorthand: display "@@step:<auto-key>:<label>" then run <cmd> [args…].
#       Use display + run directly when you need explicit key control.
#
#   die_step_handler   (call from: trap 'die_step_handler' ERR)
#       Emits the 3-line ✗ failure block using $CURRENT_STEP / $BASH_COMMAND.
#       Register at the top of every entry-point main():
#           trap 'die_step_handler' ERR
#
#   die_step "<label>" "<cmd-description>" <exit-code>
#       Explicit variant of the failure block when you want to call it directly.
#
# IMPORTANT — trap ERR + conditional footgun:
#   `trap ERR` does NOT fire when a command is inside an `if` conditional, a
#   `&&` / `||` chain, or a `while`/`until` condition. Examples:
#       if run cmd; then ...   # trap ERR will NOT fire if cmd fails
#       run cmd || true        # intentional non-zero; trap correctly suppressed
#   Authors MUST use `run cmd || true` for commands that may legitimately fail.
#   The only safe use of run inside a conditional is when the caller handles
#   the non-zero return explicitly (without relying on the trap).
# =============================================================================

# Resolve project root from this file's location: <root>/lib/common.sh
__CLAW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAW_INSTALLER_ROOT="${CLAW_INSTALLER_ROOT:-$(cd "$__CLAW_LIB_DIR/.." && pwd)}"
export CLAW_STEPS_DIR="$CLAW_INSTALLER_ROOT/steps"

# When launched from a macOS .app bundle (double-click) the parent PATH is the
# minimal system stub (/usr/bin:/bin:/usr/sbin:/sbin) — brew/fnm/pnpm are
# missing. Prepend the standard package-manager bin dirs so command-v lookups
# work regardless of how we were spawned.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.local/bin:$PATH"

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

# =============================================================================
# fd 3 — session log setup
# =============================================================================
# Rust sets CLAW_SESSION_LOG before spawning. If running directly from CLI
# without Rust, auto-generate a fallback so scripts always have a log file.
CURRENT_STEP="${CURRENT_STEP:-}"

if [[ -n "${CLAW_SESSION_LOG:-}" ]]; then
  exec 3>>"$CLAW_SESSION_LOG"
else
  # Auto-generate a CLI fallback log path.
  _fallback_log_dir="${TMPDIR:-/tmp}/claw-installer"
  mkdir -p "$_fallback_log_dir"
  _fallback_ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
  export CLAW_SESSION_LOG="$_fallback_log_dir/cli-${_fallback_ts}.log"
  exec 3>>"$CLAW_SESSION_LOG"
  unset _fallback_log_dir _fallback_ts
fi

# =============================================================================
# Core primitives
# =============================================================================

# display <msg>
#   Write to stdout AND fd 3 (log file).
#   If msg matches @@step:<key>:<label>, set CURRENT_STEP to <label>.
display() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >&3
  # Check for @@step:<key>:<label> sentinel and update CURRENT_STEP
  if [[ "$*" =~ ^@@step:([a-z][a-z0-9-]*):(.+)$ ]]; then
    CURRENT_STEP="${BASH_REMATCH[2]}"
  fi
}

# log <msg>
#   Write to fd 3 (log file) ONLY. Nothing on stdout.
log() {
  printf '%s\n' "$*" >&3
}

# run <cmd> [args…]
#   Log the command, execute it with stdout+stderr → fd 3, return exit code.
run() {
  log "+ $*"
  "$@" >&3 2>&3
  return $?
}

# step "<label>" -- <cmd> [args…]
#   Convenience macro: derive a key from the label, emit the @@step sentinel,
#   then run the command. For explicit key control use display + run directly.
#
#   Usage:
#     step "正在安装 Node 22 运行时" -- fnm install 22
#     step --key node "正在安装 Node 22 运行时" -- fnm install 22
step() {
  local key label
  if [[ "${1:-}" == "--key" ]]; then
    key="$2"
    label="$3"
    shift 3
  else
    label="$1"
    # Derive key: lowercase, replace non-alnum chars with -, strip leading/trailing -
    key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' \
          | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
          | cut -c1-30)"
    shift
  fi
  # Expect "--" separator
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  display "@@step:${key}:${label}"
  run "$@"
}

# die_step_handler — call from: trap 'die_step_handler' ERR
#   Reads $CURRENT_STEP, $BASH_COMMAND from caller scope.
#   Emits 3-line ✗ failure block to stdout and fd 3, then exits 1.
die_step_handler() {
  local exit_code=$?
  local step_label="${CURRENT_STEP:-（未知步骤）}"
  local cmd="${BASH_COMMAND:-（未知命令）}"
  printf '✗ 失败步骤：%s\n' "$step_label"
  printf '✗ 失败原因：%s 退出码 %s\n' "$cmd" "$exit_code"
  printf '✗ 详见完整日志：%s\n' "${CLAW_SESSION_LOG:-（日志路径未知）}"
  {
    printf '✗ 失败步骤：%s\n' "$step_label"
    printf '✗ 失败原因：%s 退出码 %s\n' "$cmd" "$exit_code"
    printf '✗ 详见完整日志：%s\n' "${CLAW_SESSION_LOG:-（日志路径未知）}"
  } >&3
  exit 1
}

# die_step <label> <cmd-description> <exit-code>
#   Explicit variant: caller provides all three values directly.
die_step() {
  local step_label="${1:-（未知步骤）}"
  local cmd="${2:-（未知命令）}"
  local exit_code="${3:-1}"
  printf '✗ 失败步骤：%s\n' "$step_label"
  printf '✗ 失败原因：%s 退出码 %s\n' "$cmd" "$exit_code"
  printf '✗ 详见完整日志：%s\n' "${CLAW_SESSION_LOG:-（日志路径未知）}"
  {
    printf '✗ 失败步骤：%s\n' "$step_label"
    printf '✗ 失败原因：%s 退出码 %s\n' "$cmd" "$exit_code"
    printf '✗ 详见完整日志：%s\n' "${CLAW_SESSION_LOG:-（日志路径未知）}"
  } >&3
  exit 1
}

# =============================================================================
# Preserved helpers (updated to use new log() primitive)
# =============================================================================

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die_step "权限检查" "Need root to run: $* (install sudo or rerun as root)" 1
  fi
}

detect_platform() {
  display "@@step:detect-platform:正在检测系统平台…"
  case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)
      if   command -v apt-get >/dev/null 2>&1; then PLATFORM="debian"
      elif command -v dnf     >/dev/null 2>&1; then PLATFORM="rhel"
      elif command -v yum     >/dev/null 2>&1; then PLATFORM="rhel"
      else die_step "系统平台检测" "Unsupported Linux distro (need apt-get / dnf / yum)" 1
      fi
      ;;
    *) die_step "系统平台检测" "Unsupported OS: $(uname -s)" 1 ;;
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
#   Each <name> matches shell/steps/<name>.sh, which must define
#   step_<name_with_underscores>. Caller passes the agent-specific list (each
#   agents/<agent>/install.sh declares ENV_STEPS=(…) up top).
run_steps() {
  detect_platform
  local s file fn
  for s in "$@"; do
    file="$CLAW_STEPS_DIR/$s.sh"
    [[ -f "$file" ]] || die_step "步骤加载" "Unknown step: $s (no such file $file)" 1
    # shellcheck source=/dev/null
    source "$file"
    fn="step_${s//-/_}"
    type "$fn" >/dev/null 2>&1 || die_step "步骤加载" "Step '$s' did not define function $fn" 1
    "$fn"
  done
}

# agent_env_steps <agent>  → emit the agent's declared ENV_STEPS, one per line.
# Reads by sourcing agents/<agent>/install.sh in a subshell so its function defs
# don't leak into the caller's scope. main() inside the agent script is gated
# on BASH_SOURCE==$0, so sourcing has no installation side effects.
agent_env_steps() {
  local agent="$1"
  local script="$CLAW_INSTALLER_ROOT/agents/$agent/install.sh"
  [[ -f "$script" ]] || die_step "代理查找" "Unknown agent: $agent (no $script)" 1
  ( # shellcheck source=/dev/null
    source "$script" >/dev/null 2>&1
    printf '%s\n' "${ENV_STEPS[@]:-}" )
}
