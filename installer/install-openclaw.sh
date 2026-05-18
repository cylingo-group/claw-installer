#!/usr/bin/env bash
# install-openclaw.sh — agent-layer installer for OpenClaw.
#
# Layering:
#   install.sh                 — top-level entry (env deps + every agent)
#   install-openclaw.sh        — this file: openclaw agent install/config/service
#   steps/*.sh                 — fine-grained env/config primitives
#
# Behavior:
#   Direct execution        → run full env deps, then the openclaw agent.
#   Sourced from install.sh → only define install_openclaw_agent (and helpers);
#                             install.sh runs env deps once for all agents.
#
# Environment toggles:
#   INSTALLER_SERVICE_MODE   daemon | foreground | skip   (default: daemon)
#       skip = install + configure + validate only; caller starts gateway.
#   INSTALLER_GATEWAY_PORT   <port>                         (default: 18789)
#   INSTALLER_GATEWAY_BIND   auto | lan | loopback | tailnet | custom (default: loopback)
#   INSTALLER_GATEWAY_TOKEN  <hex token>                    (default: random 32-byte hex)
#   INSTALLER_NODE_VERSION   <major|semver>                 (default: 24)
#   INSTALLER_WORKSPACE      <dir>                          (default: $HOME/.openclaw/workspace)
#   INSTALLER_NPM_REGISTRY   <url>                          (default: https://registry.npmmirror.com/)
#   INSTALLER_SKIP_USER_NPMRC=1            skip writing to ~/.npmrc
#   INSTALLER_KEEP_DEFAULT_REGISTRY=1      keep npmjs.org instead of mirror
#   INSTALLER_SKIP_ENV=1                   skip env-deps step block
#       (set automatically when invoked from install.sh)

set -euo pipefail

__OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$__OC_DIR/lib/common.sh"

# Env-prep steps openclaw relies on. install.sh reads this when collecting
# the union across all selected agents. Order must be dependency-correct;
# later steps may rely on earlier ones (e.g. node needs fnm).
ENV_STEPS=(base-deps fnm node pnpm npmrc shell-rc)

SERVICE_MODE="${INSTALLER_SERVICE_MODE:-daemon}"
GATEWAY_PORT="${INSTALLER_GATEWAY_PORT:-18789}"
GATEWAY_BIND="${INSTALLER_GATEWAY_BIND:-loopback}"
GATEWAY_TOKEN="${INSTALLER_GATEWAY_TOKEN:-}"

install_openclaw_package() {
  if command -v openclaw >/dev/null 2>&1; then
    log "openclaw already on PATH ($(openclaw --version 2>/dev/null || echo unknown)) — reinstalling latest"
  fi
  log "pnpm add -g openclaw@latest (registry=$NPM_REGISTRY)"
  # pnpm 11 shows an interactive "approve build scripts" prompt when stdin is
  # a TTY. Close stdin with </dev/null so pnpm falls back to non-interactive
  # mode (build scripts are deferred but binaries with prebuilds still install).
  pnpm add -g openclaw@latest </dev/null
  hash -r 2>/dev/null || true
  command -v openclaw >/dev/null 2>&1 || die "openclaw not on PATH after install (PNPM_HOME=${PNPM_HOME:-unset})"
  log "openclaw installed: $(command -v openclaw)"
  manifest_record pnpm_global_pkg openclaw installed
}

write_openclaw_config() {
  if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN="$(openssl rand -hex 32)"
  fi
  local ws_status="created"
  [[ -d "$WORKSPACE_DIR" ]] && ws_status="preexisting"
  mkdir -p "$WORKSPACE_DIR"
  manifest_record openclaw_workspace "$WORKSPACE_DIR" "$ws_status"
  log "Writing openclaw config via 'openclaw config set'"
  # Token is masked in logs; the full value is printed once in the final summary.
  local token_masked="${GATEWAY_TOKEN:0:8}…${GATEWAY_TOKEN: -4} (len=${#GATEWAY_TOKEN})"
  local pair key val display
  for pair in \
      "gateway.mode=local" \
      "gateway.port=$GATEWAY_PORT" \
      "gateway.bind=$GATEWAY_BIND" \
      "gateway.auth.mode=token" \
      "gateway.auth.token=$GATEWAY_TOKEN" \
      "gateway.tailscale.mode=off" \
      "session.dmScope=per-channel-peer" \
      "tools.profile=coding" \
      "agents.defaults.workspace=$WORKSPACE_DIR"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if [[ "$key" == "gateway.auth.token" ]]; then
      display="$token_masked"
    else
      display="$val"
    fi
    log "  set $key = $display"
    openclaw config set "$key" "$val"
  done
  log "Validating config"
  openclaw config validate
  local cfg_file
  cfg_file="$(openclaw config file 2>/dev/null || echo "$HOME/.openclaw/openclaw.json")"
  log "Config file: $cfg_file"
  manifest_record openclaw_config_file "$cfg_file" written
}

print_openclaw_summary() {
  cat <<EOF

==============================================================================
  OpenClaw 安装完成

  Gateway URL    : http://127.0.0.1:$GATEWAY_PORT
  Gateway Bind   : $GATEWAY_BIND
  Gateway Token  : $GATEWAY_TOKEN
  Workspace      : $WORKSPACE_DIR
  Service Mode   : $SERVICE_MODE
  npm registry   : $NPM_REGISTRY

  常用命令:
    openclaw gateway status
    openclaw gateway logs
    openclaw doctor
    openclaw config get gateway.auth.token

  ⚠  Gateway Token 只完整打印一次，请妥善保存。
  ⚠  ~/.npmrc 已写入镜像配置（sentinel 块），如需还原请手动删除该块。
==============================================================================
EOF
}

start_openclaw_service() {
  case "$SERVICE_MODE" in
    daemon)
      # All `openclaw` calls below close stdin (</dev/null) so they never block
      # on an interactive prompt, and run under a wall-clock timeout so a
      # crashed daemon can't deadlock the installer waiting for "ready".
      log "Installing gateway as user service (launchd/systemd)"
      run_with_timeout 60 openclaw gateway install </dev/null \
        || warn "openclaw gateway install: timed out or non-zero — continuing"
      manifest_record openclaw_service gateway installed

      # The launchd/systemd unit produced by `gateway install` often has known
      # issues on fresh boxes (missing PATH, Node pinned to fnm dir, …) that
      # cause the service to exit immediately. `doctor --repair` fixes these
      # in place. Best-effort: if the flag is unsupported on this openclaw
      # version, we just continue.
      log "Repairing service config (openclaw doctor --repair)"
      run_with_timeout 60 openclaw doctor --repair </dev/null \
        || warn "openclaw doctor --repair: timed out or returned non-zero — continuing"

      log "Starting gateway (timeout 60s)"
      if run_with_timeout 60 openclaw gateway start </dev/null; then
        sleep 2
        openclaw gateway status </dev/null || true
      else
        warn "openclaw gateway start did not complete within 60s."
        warn "  This usually means the daemon crashed on startup (service loaded but not running)."
        warn "  Quick triage:"
        warn "    openclaw gateway status      # see service state + config issues"
        warn "    openclaw doctor              # full diagnostic"
        warn "    openclaw doctor --repair     # auto-fix common service config issues"
        warn "    tail -n 200 /tmp/openclaw/openclaw-\$(date +%F).log"
        warn "    tail -n 200 \$HOME/.openclaw/logs/gateway.log"
        openclaw gateway status </dev/null 2>&1 | sed 's/^/  | /' || true
      fi
      print_openclaw_summary
      run_with_timeout 60 openclaw doctor </dev/null \
        || warn "openclaw doctor reported issues — review above"
      ;;
    foreground)
      print_openclaw_summary
      log "Starting gateway in foreground (exec)"
      exec openclaw gateway --port "$GATEWAY_PORT" --verbose
      ;;
    skip)
      log "Service mode = skip; install + config done, gateway not started"
      print_openclaw_summary
      ;;
    *)
      die "Unknown INSTALLER_SERVICE_MODE: $SERVICE_MODE (use daemon|foreground|skip)"
      ;;
  esac
}

# Public entry: install the openclaw agent. Assumes env deps are ready unless
# explicitly told to ensure them via the env-step block in main().
install_openclaw_agent() {
  install_openclaw_package
  write_openclaw_config
  start_openclaw_service
}

main() {
  setup_install_log
  if [[ -z "${INSTALLER_SKIP_ENV:-}" ]]; then
    run_steps "${ENV_STEPS[@]}"
  fi
  install_openclaw_agent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
