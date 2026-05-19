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
# Flags:
#   --debug   Tail the session log to stderr in real time (useful for CLI triage).
#
# GUI integration:
#   Rust sets CLAW_SESSION_LOG before spawning; scripts open fd 3 against it.
#   Only display() lines and @@step: sentinels appear on stdout (fd 1).
#   Everything else (commands, raw tool output) goes to fd 3 (log file only).

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

DEBUG_MODE="${DEBUG_MODE:-0}"

run_agent() {
  local agent="$1"
  local script="$__INSTALL_DIR/install-${agent}.sh"
  [[ -f "$script" ]] || die_step "安装代理" "Agent installer not found: $script" 1
  display "@@step:agent-${agent}:正在安装 ${agent} 代理…"
  # Suppress per-agent env-step re-run; we already ran env deps once above.
  # Pass CLAW_SESSION_LOG and DEBUG_MODE down so the child appends to the same
  # log file and, if debug mode is active, also tails it.
  local extra_args=()
  if [[ "${DEBUG_MODE}" == "1" ]]; then
    extra_args+=(--debug)
  fi
  INSTALLER_SKIP_ENV=1 CLAW_SESSION_LOG="$CLAW_SESSION_LOG" bash "$script" "${extra_args[@]}"
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
  # Parse flags
  for arg in "$@"; do
    case "$arg" in
      --debug) DEBUG_MODE=1 ;;
      --help|-h)
        cat <<'EOF'
install.sh — claw-installer top-level entry

Usage: install.sh [--debug] [--help]

Flags:
  --debug   Tail the session log to stderr in real time.
            Useful for CLI triage and verifying installer output.
  --help    Show this help message.

Environment overrides (INSTALLER_* prefix):
  INSTALLER_AGENTS=openclaw,hermes   Install a subset of agents (comma-separated).
  INSTALLER_FORCE_REINSTALL=1        Re-run all steps even if already installed.
  INSTALLER_SERVICE_MODE=skip        Install + configure but don't start the gateway.
  INSTALLER_GATEWAY_PORT=<port>      Override gateway listen port (default: 18789).
  INSTALLER_GATEWAY_TOKEN=<hex>      Override gateway auth token.
  INSTALLER_NPM_REGISTRY=<url>       Override npm registry URL.
  INSTALLER_SKIP_USER_NPMRC=1        Skip writing ~/.npmrc mirror block.

Session log: written to \$CLAW_SESSION_LOG (set by Rust) or auto-generated under
  \$TMPDIR/claw-installer/cli-<ts>.log when run directly from the terminal.
EOF
        exit 0
        ;;
    esac
  done

  # Start debug tail AFTER fd 3 is open (common.sh opens it at source time)
  if [[ "$DEBUG_MODE" == "1" ]]; then
    display "日志文件：$CLAW_SESSION_LOG"
    tail -F "$CLAW_SESSION_LOG" >&2 &
    TAIL_PID=$!
    trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT
  fi

  trap 'die_step_handler' ERR

  display "@@step:start:正在初始化安装程序…"
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

  display "✓ 全部安装完成"
  log "Manifest: $CLAW_MANIFEST"
}

main "$@"
