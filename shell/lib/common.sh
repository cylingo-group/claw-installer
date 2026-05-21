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

# Force the C locale for *this shell's own* parsing only.
#
# macOS ships bash 3.2 at /bin/bash. Under a UTF-8 LC_CTYPE, bash 3.2's
# tokenizer treats high-bit bytes as part of an identifier instead of as a
# word boundary. So  "版本 $hv）"  parses as ${hv）} — bash hunts for a
# variable literally named "hv<utf8-bytes-of-）>", and under `set -u` that
# unbound lookup is fatal and bypasses the ERR trap (no failure block, no
# fd-3 log line — the child just vanishes mid-pipeline).
#
# LC_CTYPE=C makes isalpha() ASCII-only again, restoring sane parsing. We
# deliberately do NOT export it: child processes (brew, git, npm, python, …)
# continue to see the user's real UTF-8 locale, so their own output isn't
# downgraded. Each script that sources common.sh reapplies this guard.
LC_CTYPE=C

# Resolve project root from this file's location: <root>/lib/common.sh
__CLAW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAW_INSTALLER_ROOT="${CLAW_INSTALLER_ROOT:-$(cd "$__CLAW_LIB_DIR/.." && pwd)}"
export CLAW_STEPS_DIR="$CLAW_INSTALLER_ROOT/steps"

# =============================================================================
# PATH composition — single source of truth
# =============================================================================
# Goals:
#   1. ONE function that knows the canonical PATH order. Every script that
#      needs PATH calls _claw_compose_path; nothing writes `export PATH=` by
#      hand.
#   2. Tools we manage (fnm-Node, pnpm-globals, uv) win over Homebrew. A host
#      with a broken `brew install node` (e.g. dylib drift after
#      `brew upgrade llhttp`) MUST NOT shadow fnm's working binary.
#   3. Idempotent: every prepend is dedup'd by `case`, so calling
#      _claw_compose_path N times is the same as calling it once.
#   4. Works in non-interactive Tauri spawns (start.sh / stop.sh / …) where
#      no shell rc file is sourced — we read fnm's active version from disk
#      via $FNM_DIR/aliases/default, no shell function dependency.
#
# Canonical order (top of PATH = most precedence):
#   1.  fnm-active-bin             — Node binary fnm currently points to
#   2.  $FNM_MULTISHELL_PATH/bin   — fnm's per-shell symlink (added by eval
#                                    "$(fnm env)" in step_fnm; we don't put
#                                    it there, but it survives our prepends)
#   3.  fnm dir                    — where the `fnm` binary itself lives
#   4.  $PNPM_HOME/bin             — explicit env (highest pnpm precedence)
#   5.  $PNPM_HOME                 — explicit env (legacy pnpm layout)
#   6.  $HOME/Library/pnpm/bin     — macOS default pnpm bin
#   7.  $HOME/.local/share/pnpm/bin — Linux default pnpm bin
#   8.  $HOME/Library/pnpm         — macOS default pnpm legacy
#   9.  $HOME/.local/share/pnpm    — Linux default pnpm legacy
#   10. $HOME/.local/bin           — uv and generic user binaries
#   11. /opt/homebrew/bin          — brew (Apple Silicon), AFTER fnm/pnpm
#   12. /opt/homebrew/sbin
#   13. /usr/local/bin             — brew (Intel) or system
#   14. /usr/local/sbin
#   15. original $PATH

# _claw_path_prepend <dir>
#   Idempotent prepend: if <dir> is empty or already on PATH, noop.
_claw_path_prepend() {
  local d="$1"
  [[ -z "$d" ]] && return 0
  case ":$PATH:" in *":$d:"*) return 0 ;; esac
  PATH="$d:$PATH"
}

# _claw_pnpm_home
#   Resolve the canonical PNPM_HOME for this platform. Explicit $PNPM_HOME
#   wins; otherwise fall back to the OS default. Used by pnpm.sh, shell-rc.sh,
#   and uninstall.sh so the same path is computed in exactly one place.
_claw_pnpm_home() {
  if [[ -n "${PNPM_HOME:-}" ]]; then
    printf '%s' "$PNPM_HOME"
    return
  fi
  case "${PLATFORM:-$(uname -s)}" in
    macos|Darwin) printf '%s' "$HOME/Library/pnpm" ;;
    *)            printf '%s' "$HOME/.local/share/pnpm" ;;
  esac
}

# _claw_fnm_active_bin
#   Return the bin dir of fnm's currently-defaulted Node version, by reading
#   the $FNM_DIR/aliases/default symlink directly — works in non-interactive
#   shells that never eval'd `fnm env`. Empty output if no default is set.
_claw_fnm_active_bin() {
  local d ver bin candidates=(
    "$HOME/.local/share/fnm"
    "$HOME/.fnm"
    "$HOME/Library/Application Support/fnm"
    "${XDG_DATA_HOME:-}/fnm"
  )
  for d in "${candidates[@]}"; do
    [[ -z "$d" || "$d" == "/fnm" ]] && continue
    [[ -L "$d/aliases/default" ]] || continue
    ver="$(readlink "$d/aliases/default" 2>/dev/null)"
    ver="${ver##*/}"
    bin="$d/node-versions/$ver/installation/bin"
    if [[ -d "$bin" ]]; then
      printf '%s' "$bin"
      return 0
    fi
  done
  return 1
}

# _claw_compose_path
#   Re-derive PATH against the canonical order. Idempotent. Call this at the
#   end of common.sh (every source), after step_fnm/pnpm/uv modifies relevant
#   env, or whenever you want to assert the canonical order.
_claw_compose_path() {
  # Prepend lowest-precedence entries first so the highest end up at the top
  # of PATH after all prepends are done.
  _claw_path_prepend /usr/local/sbin
  _claw_path_prepend /usr/local/bin
  _claw_path_prepend /opt/homebrew/sbin
  _claw_path_prepend /opt/homebrew/bin
  _claw_path_prepend "$HOME/.local/bin"
  # pnpm: platform defaults BELOW explicit env
  _claw_path_prepend "$HOME/.local/share/pnpm"
  _claw_path_prepend "$HOME/Library/pnpm"
  _claw_path_prepend "$HOME/.local/share/pnpm/bin"
  _claw_path_prepend "$HOME/Library/pnpm/bin"
  if [[ -n "${PNPM_HOME:-}" ]]; then
    _claw_path_prepend "$PNPM_HOME"
    _claw_path_prepend "$PNPM_HOME/bin"
  fi
  # fnm: binary dir, then the active version's bin dir (highest precedence)
  local _fnm_dir _fnm_bin
  _fnm_dir="$(resolve_fnm_dir 2>/dev/null || true)"
  _claw_path_prepend "$_fnm_dir"
  _fnm_bin="$(_claw_fnm_active_bin 2>/dev/null || true)"
  _claw_path_prepend "$_fnm_bin"
  export PATH
}

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

# --- Homebrew mirror env (macOS) -------------------------------------------
# GUI / scripted callers can preselect a mirror (Aliyun / Tsinghua / official)
# via these INSTALLER_BREW_* vars; we promote them to the HOMEBREW_* env names
# that brew itself reads. Each is independently optional so the user can mix
# (e.g. only override bottle CDN). Empty → fall back to upstream defaults.
if [[ -n "${INSTALLER_BREW_GIT_REMOTE:-}" ]]; then
  export HOMEBREW_BREW_GIT_REMOTE="$INSTALLER_BREW_GIT_REMOTE"
fi
if [[ -n "${INSTALLER_BREW_CORE_GIT_REMOTE:-}" ]]; then
  export HOMEBREW_CORE_GIT_REMOTE="$INSTALLER_BREW_CORE_GIT_REMOTE"
fi
if [[ -n "${INSTALLER_BREW_BOTTLE_DOMAIN:-}" ]]; then
  export HOMEBREW_BOTTLE_DOMAIN="$INSTALLER_BREW_BOTTLE_DOMAIN"
fi
if [[ -n "${INSTALLER_BREW_API_DOMAIN:-}" ]]; then
  export HOMEBREW_API_DOMAIN="$INSTALLER_BREW_API_DOMAIN"
fi
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

# Per-process startup banner — written once per bash process (gated on the
# same $$ guard as PATH init above). Tells you which shell binary, which
# version, and which script is in charge so triage doesn't have to guess.
if [[ "${__CLAW_BANNER_PID:-}" != "$$" ]]; then
  __CLAW_BANNER_PID=$$
  {
    printf '── claw-installer shell start ──────────────────────────────\n'
    printf '  bash       : %s (v%s)\n' "${BASH:-?}" "${BASH_VERSION:-?}"
    printf '  script     : %s\n' "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-?}"
    printf '  pid/ppid   : %s / %s\n' "$$" "$PPID"
    printf '  user       : %s (uid=%s)\n' "${USER:-?}" "$(id -u 2>/dev/null || echo ?)"
    printf '  cwd        : %s\n' "$(pwd 2>/dev/null || echo ?)"
    printf '  locale     : LC_CTYPE=%s LANG=%s LC_ALL=%s\n' "${LC_CTYPE:-}" "${LANG:-}" "${LC_ALL:-}"
    printf '  PATH (head): %s\n' "${PATH%%:*}"
    printf '  TRACE      : INSTALLER_TRACE=%s\n' "${INSTALLER_TRACE:-0}"
    printf '─────────────────────────────────────────────────────────────\n'
  } >&3 2>/dev/null || true
fi

# =============================================================================
# Optional bash xtrace → session log (opt-in via INSTALLER_TRACE=1)
# =============================================================================
# When enabled, every command bash executes is appended to fd 3 with a rich
# PS4 prefix (file:line + function). Crucial for triage when a script dies
# mid-step with only the *last successful* command's output in the log.
#
# Why fd 3 and not stderr:
#   The Tauri side discards the bash child's stderr entirely (commands.rs).
#   Routing xtrace to stderr would lose every trace line. We need it in the
#   session-log file (fd 3) where it survives the parent process.
#
# Bash 3.2 (macOS default) does NOT support BASH_XTRACEFD, so we fall back to
# `exec 2>&3` which folds stderr into fd 3. Rust discards stderr anyway, so
# we lose nothing and gain a full trace.
#
# Called once at source time (so env-var-driven trace activates before any
# script line runs) and again from main() after flag parsing (so `--trace`
# CLI flag still works). `set -x` is idempotent.
#
# NB: this function is invoked AFTER the log() primitive is defined below
# (see "_claw_enable_trace" call after the Core primitives section). On
# macOS, /usr/bin/log is Apple's syslog CLI — calling `log "…"` before
# our shell function shadows it would dispatch there. We write directly
# to fd 3 with printf to be safe regardless of source-order.
_claw_enable_trace() {
  [[ -n "${INSTALLER_TRACE:-}" ]] || return 0
  [[ -n "${__CLAW_TRACE_ON:-}" ]] && return 0   # already enabled
  export INSTALLER_TRACE=1   # propagate to children
  # PS4 expansion is per-command; keep it cheap. ${SECONDS} is wall-clock
  # since this shell started (bash 2+); ${FUNCNAME[0]:-main} works in 3.2.
  export PS4='+ [${SECONDS}s ${BASH_SOURCE##*/}:${LINENO} ${FUNCNAME[0]:-main}] '
  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    export BASH_XTRACEFD=3
    printf 'xtrace enabled via BASH_XTRACEFD=3 (bash %s.%s)\n' \
      "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" >&3
  else
    # bash 3.2 fallback — xtrace goes to stderr, which we fold into fd 3.
    exec 2>&3
    printf 'xtrace enabled via stderr->fd3 fold (bash 3.2 compat)\n' >&3
  fi
  __CLAW_TRACE_ON=1
  set -x
}

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

# Activate xtrace now that log/run/display/printf-to-fd3 are wired up.
# (Function defined far above; invocation deferred until here so its
# diagnostic writes can't accidentally hit /usr/bin/log on macOS.)
_claw_enable_trace

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

# _claw_emit_stack — print the current bash call stack to fd 3.
# Helps tell "trap fired here" from "subshell silently died" when only the
# last successful display() line is in the log.
_claw_emit_stack() {
  local i frame
  printf '✗ 调用栈 (frame: file:line function):\n' >&3
  # BASH_SOURCE[0] is this helper; skip it.
  for (( i=1; i<${#BASH_SOURCE[@]}; i++ )); do
    frame="${BASH_SOURCE[$i]##*/}:${BASH_LINENO[$i-1]:-?} ${FUNCNAME[$i]:-main}"
    printf '✗   #%d %s\n' "$((i-1))" "$frame" >&3
  done
}

# _claw_flush_log — force the OS to commit pending writes on fd 3.
# Bash uses stdio (block-buffered for regular files). If the script is about
# to exit non-normally (signal-killed child, SIGABRT cascade, …), buffered
# `printf … >&3` output can be lost. Closing fd 3 explicitly forces a flush.
_claw_flush_log() {
  exec 3>&- 2>/dev/null || true
}

# die_step_handler — call from: trap 'die_step_handler' ERR
#   Reads $CURRENT_STEP, $BASH_COMMAND from caller scope.
#   Emits ✗ failure block + stack trace to stdout and fd 3, force-flushes,
#   then exits with the original failing-command exit code.
die_step_handler() {
  local exit_code=$?
  # Suppress xtrace noise while we report the failure — otherwise the user's
  # screen and the tail of the log get drowned in trace lines for printf.
  set +x 2>/dev/null || true
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
  _claw_emit_stack
  _claw_flush_log
  exit "$exit_code"
}

# die_step <label> <cmd-description> <exit-code>
#   Explicit variant: caller provides all three values directly.
die_step() {
  set +x 2>/dev/null || true
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
  _claw_emit_stack
  _claw_flush_log
  exit "$exit_code"
}

# _claw_signal_handler — record external-kill signals in the log before exit.
# Distinguishes "Tauri killed us with SIGTERM" (cancel button, app quit) from
# "a child SIGABRT'd and set -e propagated 134" in postmortem analysis.
_claw_signal_handler() {
  local sig="$1"
  set +x 2>/dev/null || true
  {
    printf '⚠ 收到信号 %s — 步骤=%s cmd=%s pid=%s\n' \
      "$sig" "${CURRENT_STEP:-?}" "${BASH_COMMAND:-?}" "$$"
  } >&3 2>/dev/null || true
  _claw_emit_stack 2>/dev/null || true
  _claw_flush_log
  # 128 + signal number (TERM=15, HUP=1) — matches what the shell would
  # exit with if uncaught.
  case "$sig" in
    TERM) exit 143 ;;
    HUP)  exit 129 ;;
    INT)  exit 130 ;;
    *)    exit 1   ;;
  esac
}
trap '_claw_signal_handler TERM' TERM
trap '_claw_signal_handler HUP'  HUP

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

# Compose PATH once now that resolve_fnm_dir and _claw_fnm_active_bin are
# both defined. Every common.sh source goes through this — idempotent. Step
# scripts (steps/*.sh) re-call _claw_compose_path after they modify env that
# affects ordering (e.g. step_fnm runs `eval "$(fnm env)"`, step_pnpm sets
# PNPM_HOME) so the canonical order is re-asserted at each transition.
_claw_compose_path

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
